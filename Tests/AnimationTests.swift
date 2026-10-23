import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import CryptoKit

@main struct AnimationTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw EngineError.quality("TEST: " + message) }
    }
    static func fixture(_ root: URL, name: String, kind: Int, rate: CMTime = CMTime(value: 1, timescale: 30), rotated: Bool = false, offset: CMTime = .zero, width:Int = 320, height:Int = 180) async throws -> URL {
        let url = root.appendingPathComponent(name + ".mp4"), w = width, h = height
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]])
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        try require(writer.startWriting(), "fixture writer")
        writer.startSession(atSourceTime: .zero)
        for i in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            try autoreleasepool {
                var pixel: CVPixelBuffer?
                try require(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel) == kCVReturnSuccess, "fixture buffer")
                let buffer = pixel!
                CVPixelBufferLockBaseAddress(buffer, [])
                let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let row = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<h { for x in 0..<w {
                    let p = y * row + x * 4
                    let shift = kind == 0 ? i * 11 : 0
                    bytes[p] = UInt8((x + shift) % 256)
                    bytes[p + 1] = UInt8((y * 2 + shift) % 256)
                    bytes[p + 2] = UInt8((x + y + shift) % 256)
                    bytes[p + 3] = 255
                    if kind == 2 && x >= i * 3 && x < i * 3 + 15 && y < 15 { bytes[p] = 255; bytes[p + 1] = 0 }
                } }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                try require(adaptor.append(buffer, withPresentationTime: CMTimeAdd(CMTimeMultiply(rate, multiplier: Int32(i)), offset)), "fixture append")
            }
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTimeAdd(CMTimeMultiply(rate, multiplier: 60), offset))
        await writer.finishWriting()
        try require(writer.status == .completed, "fixture finish")
        return url
    }
    static func inspect(_ url: URL, expectedDuration: Double, frames: Int? = nil, width: Int? = nil, height: Int? = nil) throws {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let count = CGImageSourceGetCount(source)
        if let frames { try require(count == frames, "frame count \(count) != \(frames)") }
        if url.pathExtension == "gif" { try require(try Data(contentsOf: url).prefix(6) == Data("GIF89a".utf8), "GIF89a header") }
        var duration = 0.0
        for index in 0..<count {
            try autoreleasepool {
                guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw EngineError.quality("TEST: corrupt frame \(index)") }
                if let width, let height { try require(image.width == width && image.height == height, "frame dimensions") }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as! [CFString: Any]
                let gif = url.pathExtension == "gif"
                if gif { try require([.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo), "GIF frame \(index) decodes with alpha") }
                let dict = properties[gif ? kCGImagePropertyGIFDictionary : kCGImagePropertyWebPDictionary] as! [CFString: Any]
                let delay = dict[gif ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyWebPUnclampedDelayTime] as! Double
                try require(delay > 0, "zero delay")
                duration += delay
            }
        }
        try require(abs(duration - expectedDuration) < 0.0025, "duration \(duration) != \(expectedDuration)")
    }
    static func paletteSIMD() throws {
        // Independent scalar oracle, including ties, error-row carry and the
        // final partial row band. Optimizing palette lookup must be lossless.
        let width=37,height=45
        let total: Int = width*height*4
        let rgba: [UInt8] = (0..<total).map { (i: Int) -> UInt8 in let value = i*73+i/11;return UInt8(value%256) }
        for count in [1,2,63,255] {
            let palette=(0..<(count*3)).map { UInt8(($0*47+17)%256) }
            var actual=[UInt8](repeating:0,count:width*height),expected=actual
            var cache=[Int16](repeating:-1,count:32768),errors=[Float](repeating:0,count:(width+2)*6)
            for row in stride(from:0,to:height,by:32) {
                try require(ring_palette_dither(rgba,Int32(width),Int32(height),Int32(row),Int32(min(32,height-row)),
                    palette,Int32(count),&actual,&cache,&errors)==1,"SIMD palette band")
            }
            var current=[Float](repeating:0,count:(width+2)*3),next=current
            for y in 0..<height {
                let direction=y%2 == 0 ? 1:-1
                for column in 0..<width {
                    let x=direction>0 ? column:width-1-column
                    let pixel=y*width+x,e=(x+1)*3
                    let rgb=(0..<3).map { max(0,min(255,Int((Float(rgba[pixel*4+$0])+current[e+$0]).rounded()))) }
                    let quantized=rgb.map { ($0>>3)*8+4 }
                    var best=0,distance=Int.max
                    for index in 0..<count {
                        let d=(0..<3).reduce(0) { sum,c in let delta=quantized[c]-Int(palette[index*3+c]);return sum+delta*delta }
                        if d<distance { best=index;distance=d }
                    }
                    expected[pixel]=UInt8(best)
                    for c in 0..<3 {
                        let error=Float(rgb[c]-Int(palette[best*3+c]))
                        current[e+3*direction+c]+=error*(7.0/16);next[e-3*direction+c]+=error*(3.0/16)
                        next[e+c]+=error*(5.0/16);next[e+3*direction+c]+=error*(1.0/16)
                    }
                }
                swap(&current,&next);next=[Float](repeating:0,count:next.count)
            }
            try require(actual==expected,"SIMD changed palette pixels for \(count) colors")
        }
        print("PASS SIMD palette matches scalar oracle across row bands and palette sizes")
    }
    static func gifDeltaEdges() throws {
        let width=37,height=45,space=CGColorSpace(name:CGColorSpace.sRGB)!
        let table:[UInt8]=[10,20,30,220,180,120,50,100,200]
        let indexed=table.withUnsafeBufferPointer { CGColorSpace(indexedBaseSpace:space,last:2,colorTable:$0.baseAddress!)! }
        var pixels=(0..<(width*height)).map { UInt8(($0/3)%3) }
        func image(_ pixels:[UInt8]) -> CGImage {
            CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:width,
                space:indexed,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),
                provider:CGDataProvider(data:Data(pixels) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        }
        let first=image(pixels)
        pixels[7*width+3]=(pixels[7*width+3]+1)%3;pixels[pixels.count-1]=(pixels.last!+1)%3
        let second=image(pixels),previous=try AnimationPipeline.GIFDeltaFrame(first),current=try AnimationPipeline.GIFDeltaFrame(second)
        let region=try current.changedRegion(after:previous),cropped=try current.cropped(to:region)
        try require(region==CGRect(x:3,y:7,width:34,height:38),"delta bounding rectangle")
        let memory=NSMutableData()
        let animation=CGImageDestinationCreateWithData(memory,"com.compuserve.gif" as CFString,2,nil)!
        CGImageDestinationSetProperties(animation,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFHasGlobalColorMap:false]] as CFDictionary)
        for image in [first,cropped] { CGImageDestinationAddImage(animation,image,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.04]] as CFDictionary) }
        try require(CGImageDestinationFinalize(animation),"GIF delta edge encoding")
        let fixed=try AnimationPipeline.opaqueGIF(memory as Data,regions:[CGRect(x:0,y:0,width:width,height:height),region])
        let decoded=CGImageSourceCreateWithData(fixed as CFData,nil)!
        let reference=NSMutableData(),single=CGImageDestinationCreateWithData(reference,"com.compuserve.gif" as CFString,1,nil)!
        CGImageDestinationAddImage(single,second,nil);try require(CGImageDestinationFinalize(single),"GIF full-frame reference")
        let expected=CGImageSourceCreateWithData(reference,nil)!
        try require(try AdaptivePalette.sRGB(CGImageSourceCreateImageAtIndex(decoded,1,nil)!) == AdaptivePalette.sRGB(CGImageSourceCreateImageAtIndex(expected,0,nil)!),"GIF delta final scanline changed")
        print("PASS GIF delta odd-width crop retains the final row and column exactly")
    }
    static func stablePaletteMapping() throws {
        let width=37,height=45,total=width*height
        var rgba:[UInt8]=(0..<(total*4)).map { (i:Int)->UInt8 in let value=i*73+i/11;return UInt8(value%256) }
        let palette:[UInt8]=[0,0,0,255,255,255,255,0,0,0,255,0,0,0,255]
        var lookup=[UInt8](repeating:0,count:32768)
        try require(ring_palette_lookup(palette,5,&lookup)==1,"shared palette lookup")
        var whole=[UInt8](repeating:0,count:total),banded=whole,changed=whole
        try require(ring_palette_map(rgba,Int32(width),Int32(height),0,Int32(height),lookup,&whole)==1,"shared palette map")
        for row in stride(from:0,to:height,by:32) {
            try require(ring_palette_map(rgba,Int32(width),Int32(height),Int32(row),Int32(min(32,height-row)),lookup,&banded)==1,"shared palette band")
        }
        try require(whole==banded && whole.allSatisfy{$0<5},"shared palette band boundaries")
        let edited=total/2
        rgba[edited*4]=255;rgba[edited*4+1]=0;rgba[edited*4+2]=0
        try require(ring_palette_map(rgba,Int32(width),Int32(height),0,Int32(height),lookup,&changed)==1,"shared palette edited frame")
        try require((0..<total).allSatisfy{$0==edited || whole[$0]==changed[$0]},"one changed pixel affected other GIF pixels")
        print("PASS stable palette retains untouched pixels across frames and row bands")
    }
    static func webPHoldTiming() throws {
        let width=32,height=24
        var rgba=Data(count:width*height*4)
        rgba.withUnsafeMutableBytes { bytes in
            let p=bytes.bindMemory(to:UInt8.self)
            for i in stride(from:0,to:p.count,by:4) { p[i]=120;p[i+1]=80;p[i+2]=210;p[i+3]=255 }
        }
        let still=try TargetSizeCodec.memoryEncode(rgba,width:width,height:height,webp:true,quality:90)
        let mux=ring_webp_mux_create(Int32(width),Int32(height))!
        defer { ring_webp_mux_destroy(mux) }
        let delays:[Int32]=[5,33,4]
        let ok=delays.withUnsafeBufferPointer { d in still.withUnsafeBytes {
            ring_webp_mux_append(mux,$0.bindMemory(to:UInt8.self).baseAddress!,still.count,42,d.baseAddress!,3)
        } }
        try require(ok==1,"WebP hold mux")
        var bytes:UnsafeMutablePointer<UInt8>?,count=0
        try require(ring_webp_mux_finish(mux,&bytes,&count)==1,"WebP hold finish")
        defer { ring_buffer_free(bytes) }
        let data=Data(bytes:bytes!,count:count)
        let source=CGImageSourceCreateWithData(data as CFData,nil)!
        let reference=CGImageSourceCreateWithData(still as CFData,nil)!
        let expected=try AdaptivePalette.sRGB(CGImageSourceCreateImageAtIndex(reference,0,nil)!)
        try require(CGImageSourceGetCount(source)==3,"WebP merged requested hold frames")
        for i in 0..<3 {
            let image=CGImageSourceCreateImageAtIndex(source,i,nil)!
            try require(try AdaptivePalette.sRGB(image)==expected,"WebP hold cleared/changed canvas")
            let properties=CGImageSourceCopyPropertiesAtIndex(source,i,nil) as! [CFString:Any]
            let webp=properties[kCGImagePropertyWebPDictionary] as! [CFString:Any]
            let delay=webp[kCGImagePropertyWebPUnclampedDelayTime] as! Double
            try require(abs(delay-Double(delays[i])/1000)<0.00001,"WebP hold time changed")
        }
        let encoded=AnimationEncoding(bytes:data,width:width,height:height,parallelWebP:false)
        try AnimationPipeline.verify(encoded,plan:AnimationPlan(sourceOffsets:[0,0.005,0.038],duration:0.042,format:.webp),format:.webp)
        var rejected=false
        do { try AnimationPipeline.verify(encoded,plan:AnimationPlan(sourceOffsets:[0,0.006,0.038],duration:0.042,format:.webp),format:.webp) }
        catch { rejected=true }
        try require(rejected,"same total duration hid an individual frame timing mismatch")
        print("PASS WebP merged-frame holds preserve each delay, count and exact decoded canvas")
    }
    static func timing() throws {
        for format in [AnimationFormat.gif, .webp] {
            for fps in [15.0, 24, 29.97, 30, 59.94, 60] {
                for duration in [0.001, 0.005, 1.0, 1.017, 4.0] {
                    let plan = AnimationPlan(duration: duration, fps: fps, format: format)
                    var end = 0
                    for frame in plan.frames {
                        try require(frame.start == end && frame.end > frame.start, "non-contiguous timeline")
                        end = frame.end
                    }
                    try require(abs(plan.duration - duration) < 0.0101, "cumulative timing drift")
                }
            }
        }
        try require(AnimationOptions.frameRateText(29.9700298) == "29.97", "NTSC label")
        try require(AnimationOptions.frameRateText(60.000001) == "60", "integer label")
        print("PASS cumulative GIF/WebP timing, fractional FPS, short final frames")
    }
    static func sourceTiming(_ root:URL) async throws {
        let times=[0.0,0.0048,0.03817,0.0715,0.12,0.18,0.216,0.25,0.34,0.346]
        let source=root.appendingPathComponent("irregular.mp4")
        try await MediaFixture.write(source,times:times,duration:0.35,colorProperties:[
            AVVideoColorPrimariesKey:AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey:AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey:AVVideoYCbCrMatrix_ITU_R_709_2])
        let asset=AVURLAsset(url:source),fps=try await MediaEngine.sourceFrameRate(asset)!
        for format in [AnimationFormat.gif,.webp] {
            let plan=try await AnimationPlan.source(asset:asset,start:0,duration:0.35,fps:fps,format:format)
            try require(plan.frames.count==times.count,"VFR source frames removed")
            for i in times.indices { try require(abs(plan.frames[i].offset-times[i])<0.00002,"VFR source time changed") }
            try require(abs(plan.duration-0.35)<0.001,"VFR duration changed")
            let result=try await RingEngine.shared.run(.init(source:source,operation:.video(.animation(.init(format:format,fps:fps,maxDimension:160,duration:0.35)))))
            try inspect(result.url,expectedDuration:0.35,frames:times.count,width:160,height:90)
        }
        let sequential=try await SequentialAnimationReader.make(asset:asset)!
        let canonical=try await SequentialAnimationReader.make(asset:asset,canonical:true)!
        let reference=AVAssetImageGenerator(asset:asset)
        reference.requestedTimeToleranceBefore = .zero;reference.requestedTimeToleranceAfter = .zero
        for time in times {
            let a=try AdaptivePalette.sRGB(sequential.image(at:time))
            let b=try AdaptivePalette.sRGB(await reference.image(at:CMTime(seconds:time+0.00002,preferredTimescale:600000)).image)
            let mse=a.withUnsafeBytes { ar in b.withUnsafeBytes { br -> Double in
                let x=ar.bindMemory(to:UInt8.self),y=br.bindMemory(to:UInt8.self)
                return (0..<x.count).reduce(0.0) { sum,i in let d=Double(x[i])-Double(y[i]);return sum+d*d }/Double(x.count)
            } }
            try require(mse<2.1,"sequential reader color/frame mismatch at \(time): MSE \(mse)")
            let canonicalPixels=try AdaptivePalette.sRGB(canonical.image(at:time))
            let canonicalMSE=canonicalPixels.withUnsafeBytes { ar in b.withUnsafeBytes { br -> Double in
                let x=ar.bindMemory(to:UInt8.self),y=br.bindMemory(to:UInt8.self)
                return (0..<x.count).reduce(0.0) { sum,i in let d=Double(x[i])-Double(y[i]);return sum+d*d }/Double(x.count)
            } }
            try require(canonicalMSE<2.1,"canonical reader color/frame mismatch at \(time): MSE \(canonicalMSE)")
        }
        print("PASS VFR retains every displayed frame and duration; sequential reader matches generator colors/order")
    }
    static func main() async {
        setbuf(stdout, nil)
        do {
            try timing()
            try paletteSIMD()
            try stablePaletteMapping()
            try gifDeltaEdges()
            try webPHoldTiming()
            if CommandLine.arguments.contains("--palette") { return }
            let root = URL(fileURLWithPath: ".work/animation-tests-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await sourceTiming(root)
            if CommandLine.arguments.contains("--dimensions") {
                let source = try await fixture(root,name:"wide",kind:0,width:2048,height:64)
                for format in [AnimationFormat.webp,.gif] {
                    for limit in [2048,1024] {
                        let result = try await RingEngine.shared.run(.init(source:source,operation:.video(.animation(.init(format:format,fps:30,maxDimension:limit,duration:0.1)))))
                        try inspect(result.url,expectedDuration:AnimationPlan(duration:0.1,fps:30,format:format).duration,width:limit,height:limit/32)
                        print("PASS original/downscaled dimensions",format.rawValue,limit)
                    }
                }
                return
            }
            let moving = try await fixture(root, name: "moving", kind: 0)
            let still = try await fixture(root, name: "still", kind: 1)
            let subtle = try await fixture(root, name: "subtle", kind: 2)
            let rotated = try await fixture(root, name: "rotated", kind: 0, rate: CMTime(value: 1001, timescale: 30000), rotated: true)
            let sources = [moving, still, subtle, rotated]
            let hashes = try sources.map { Data(SHA256.hash(data: try Data(contentsOf: $0))) }
            let detected = try await MediaEngine.sourceFrameRate(AVURLAsset(url: rotated))!
            try require(abs(detected - 30000.0 / 1001) < 0.01, "source nominal FPS")
            for format in [AnimationFormat.gif, .webp] {
                for fps in [15.0, 24, 30, 60] {
                    print("CHECK", format.rawValue, fps)
                    let plan = AnimationPlan(duration: 1, fps: fps, format: format)
                    let result = try await RingEngine.shared.run(.init(source: moving, operation: .video(.animation(.init(format: format, fps: fps, maxDimension: 160, duration: 1)))))
                    try inspect(result.url, expectedDuration: plan.duration, frames: format == .gif ? plan.frames.count : nil, width: 160, height: 90)
                }
                let turned = try await RingEngine.shared.run(.init(source: rotated, operation: .video(.animation(.init(format: format, fps: detected, maxDimension: 160, start: 0.2, duration: 1.017)))))
                try inspect(turned.url, expectedDuration: AnimationPlan(duration: 1.017, fps: detected, format: format).duration, width: 90, height: 160)
                // A feasible cap must retain both the raster and all frames.
                let target: Int64 = 2_000_000
                let limited = try await RingEngine.shared.run(.init(source: moving, operation: .video(.animation(.init(format: format, fps: 30, maxDimension: 320, targetBytes: target, duration: 2)))))
                try require(try Data(contentsOf: limited.url).count <= target, "target exceeded")
                try inspect(limited.url,expectedDuration:2,frames:60,width:320,height:180)
                try require(limited.detail.contains("30fps"),"byte target silently lowered requested FPS")
                print("PASS", format.rawValue, "15/24/30/60fps, rotation, fractional FPS/trim, sampled target", limited.detail)
            }
            let frozen = try await RingEngine.shared.run(.init(source: still, operation: .video(.animation(.init(format: .webp, fps: 60, maxDimension: 160, duration: 1)))))
            try inspect(frozen.url, expectedDuration: 1, frames:60)
            let frozenGIF = try await RingEngine.shared.run(.init(source: still, operation: .video(.animation(.init(format: .gif, fps: 30, maxDimension: 160, duration: 1)))))
            try inspect(frozenGIF.url,expectedDuration:1,frames:30,width:160,height:90)
            // Also exercise the per-frame palette fallback independently: its
            // cropped delta canvas must match separately encoded whole frames.
            let legacyFrozen=try await AnimationPipeline.encode(asset:AVURLAsset(url:still),start:0,fps:30,dimension:160,
                extractionSize:CGSize(width:320,height:320),plan:AnimationPlan(duration:1,fps:30,format:.gif),format:.gif,
                quality:96,allowParallelWebP:false,stableGIF:false) {_ in}
            let frozenFrames=CGImageSourceCreateWithData(legacyFrozen.bytes as CFData,nil)!
            let frozenReference=AVAssetImageGenerator(asset:AVURLAsset(url:still))
            frozenReference.maximumSize=CGSize(width:320,height:320)
            frozenReference.requestedTimeToleranceBefore = .zero;frozenReference.requestedTimeToleranceAfter = .zero
            // A still scene encoded with H.264 can change a few decoded pixels
            // between frames. Compare each against its own independent palette.
            for index in 0..<30 {
                let reference=try ImageResampler.fit(await frozenReference.image(at:CMTime(value:Int64(index),timescale:30)).image,maxDimension:160)
                let memory=NSMutableData()
                let writer=CGImageDestinationCreateWithData(memory,"com.compuserve.gif" as CFString,1,nil)!
                CGImageDestinationAddImage(writer,try AdaptivePalette.indexed(reference),nil)
                try require(CGImageDestinationFinalize(writer),"independent GIF frame")
                let decoded=CGImageSourceCreateWithData(memory,nil)!
                let expected=try AdaptivePalette.sRGB(CGImageSourceCreateImageAtIndex(decoded,0,nil)!)
                try require(try AdaptivePalette.sRGB(CGImageSourceCreateImageAtIndex(frozenFrames,index,nil)!)==expected,"GIF delta canvas changed at \(index)")
            }
            let single = try await RingEngine.shared.run(.init(source: still, operation: .video(.animation(.init(format: .webp, fps: 1, maxDimension: 160, duration: 0.2)))))
            try inspect(single.url, expectedDuration: 0.2)
            // Automatic encoding may use lossless WebP when VP8 chroma
            // subsampling cannot meet the measured quality floor.
            let qualityReference=AVAssetImageGenerator(asset:AVURLAsset(url:still))
            qualityReference.appliesPreferredTrackTransform=true
            qualityReference.maximumSize=CGSize(width:320,height:320)
            let full=try await qualityReference.image(at:.zero).image
            let fitted=try ImageResampler.fit(full,maxDimension:160)
            let actualSource=CGImageSourceCreateWithURL(single.url as CFURL,nil)!
            let quality=try PixelCheck.compare(fitted,CGImageSourceCreateImageAtIndex(actualSource,0,nil)!)
            try require(quality.psnr>=36,"automatic WebP must meet its measured floor, including chroma/resize")
            print("PASS automatic WebP fidelity including lossless fallback and vImage resize")
            print("PASS still WebP and single sampled frame retain animation duration")

            // Exercise adaptive choice and inspect every decoded frame after mux.
            for (source, expectedMotion) in [(moving, true), (subtle, false)] {
                let plan = AnimationPlan(duration: 2, fps: 30, format: .webp)
                let encoded = try await AnimationPipeline.encode(asset: AVURLAsset(url: source), start: 0, fps: 30, dimension: 160, plan: plan, format: .webp, quality: 90, allowParallelWebP: true) { _ in }
                if AnimationResources.shared.workers > 1 { try require(encoded.parallelWebP == expectedMotion, "adaptive motion path: expected \(expectedMotion), got \(encoded.parallelWebP)") }
                try AnimationPipeline.verify(encoded, plan: plan, format: .webp)
                let url = root.appendingPathComponent(expectedMotion ? "parallel.webp" : "delta.webp")
                try encoded.bytes.write(to: url); try inspect(url, expectedDuration: 2)
                if expectedMotion {
                    let decoded = CGImageSourceCreateWithData(encoded.bytes as CFData, nil)!
                    try require(CGImageSourceGetCount(decoded) == 60, "moving WebP frame count")
                    let reference = AVAssetImageGenerator(asset: AVURLAsset(url: source))
                    reference.maximumSize = CGSize(width: 160, height: 160)
                    reference.appliesPreferredTrackTransform = true
                    reference.requestedTimeToleranceBefore = .zero
                    reference.requestedTimeToleranceAfter = .zero
                    for index in [0, 7, 8, 15, 16, 31, 32, 39, 40, 55, 56, 59] {
                        let original = try await reference.image(at: CMTime(value: Int64(index), timescale: 30)).image
                        let a = try AdaptivePalette.sRGB(original)
                        let b = try AdaptivePalette.sRGB(CGImageSourceCreateImageAtIndex(decoded, index, nil)!)
                        try require(a.count == b.count, "WebP boundary canvas")
                        let squaredError = a.withUnsafeBytes { ar in b.withUnsafeBytes { br -> Double in
                            let x = ar.bindMemory(to: UInt8.self), y = br.bindMemory(to: UInt8.self)
                            var total = 0.0
                            for p in stride(from: 0, to: a.count, by: 4) { for c in 0..<3 {
                                let difference = Double(x[p + c]) - Double(y[p + c])
                                total += difference * difference
                            } }
                            return total / Double(a.count / 4 * 3)
                        } }
                        try require(sqrt(squaredError) < 15, "WebP content/order at chunk boundary \(index)")
                    }
                }
            }
            // Parallel completion must not reorder the GIF's images.
            let ordered = try await RingEngine.shared.run(.init(source: moving, operation: .video(.animation(.init(format: .gif, fps: 30, maxDimension: 160, duration: 1)))))
            let output = CGImageSourceCreateWithURL(ordered.url as CFURL, nil)!
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: moving))
            generator.maximumSize = CGSize(width: 320, height: 320)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.008, preferredTimescale: 60000)
            generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
            for index in [0, 14, 29] {
                let reference = try ImageResampler.fit(await generator.image(at: CMTime(seconds: Double(index) / 30, preferredTimescale: 60000)).image,maxDimension:160)
                // Compare after the same GIF round trip: ImageIO assigns the
                // decoded palette a color space that can differ from CGImage's.
                let memory = NSMutableData()
                let serial = CGImageDestinationCreateWithData(memory, "com.compuserve.gif" as CFString, 1, nil)!
                let indexed = try AdaptivePalette.indexed(reference)
                try require((indexed.colorSpace?.colorTable?.count ?? 768) <= 255 * 3, "palette must leave GIF index 255 unused")
                CGImageDestinationAddImage(serial, indexed, nil)
                try require(CGImageDestinationFinalize(serial), "serial GIF reference")
                let referenceSource = CGImageSourceCreateWithData(memory, nil)!
                let expected = try AdaptivePalette.sRGB(CGImageSourceCreateImageAtIndex(referenceSource, 0, nil)!)
                let actual = try AdaptivePalette.sRGB(CGImageSourceCreateImageAtIndex(output, index, nil)!)
                try require(expected == actual, "GIF palette/order changed at \(index)")
            }
            print("PASS adaptive parallel/delta WebP and GIF pixel/order preservation")

            // Phone videos often start a few ms after zero. Each output frame
            // must be the source frame nearest its time: no repeats, no skips.
            let shifted = try await fixture(root, name: "shifted", kind: 0, offset: CMTime(value: 12, timescale: 1000))
            let nearest = try await RingEngine.shared.run(.init(source: shifted, operation: .video(.animation(.init(format: .gif, fps: 30, maxDimension: 160, duration: 1)))))
            let sampled = CGImageSourceCreateWithURL(nearest.url as CFURL, nil)!
            let exact = AVAssetImageGenerator(asset: AVURLAsset(url: shifted))
            exact.maximumSize = CGSize(width: 160, height: 160)
            exact.requestedTimeToleranceBefore = .zero
            exact.requestedTimeToleranceAfter = .zero
            var originals: [Data] = []
            for k in 0...30 { originals.append(try AdaptivePalette.sRGB(await exact.image(at: CMTime(seconds: Double(k) / 30 + 0.013, preferredTimescale: 60000)).image)) }
            func distance(_ a: Data, _ b: Data) -> Double {
                a.withUnsafeBytes { ar in b.withUnsafeBytes { br -> Double in
                    let x = ar.bindMemory(to: UInt8.self), y = br.bindMemory(to: UInt8.self)
                    var total = 0.0
                    for p in stride(from: 0, to: min(x.count, y.count), by: 4) { for c in 0..<3 { total += abs(Double(x[p + c]) - Double(y[p + c])) } }
                    return total
                } }
            }
            try require(CGImageSourceGetCount(sampled) == 30, "shifted GIF frame count")
            for index in 0..<30 {
                let frame = try AdaptivePalette.sRGB(CGImageSourceCreateImageAtIndex(sampled, index, nil)!)
                let candidates = max(0, index - 1)...min(30, index + 1)
                let best = candidates.min { distance(frame, originals[$0]) < distance(frame, originals[$1]) }!
                try require(best == index, "GIF frame \(index) shows source frame \(best)")
            }
            print("PASS offset-timestamp source: every GIF frame is the nearest source frame")

            let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
            for format in [AnimationFormat.gif, .webp] {
                let task = Task { try await RingEngine.shared.run(.init(source: moving, operation: .video(.animation(.init(format: format, fps: 60, maxDimension: 320, targetBytes: 100_000, duration: 2))))) }
                try await Task.sleep(nanoseconds: 10_000_000); task.cancel()
                do { _ = try await task.value; throw EngineError.quality("TEST: cancelled animation published") } catch is CancellationError { }
                do {
                    _ = try await RingEngine.shared.run(.init(source: moving, operation: .video(.animation(.init(format: format, fps: 15, maxDimension: 160, targetBytes: 1, duration: 0.5)))))
                    throw EngineError.quality("TEST: impossible target succeeded")
                } catch { if error.localizedDescription.contains("TEST:") { throw error } }
            }
            try require(before == Set(FileManager.default.contentsOfDirectory(atPath: root.path)), "cancel/failure leaked output")
            for (index, source) in sources.enumerated() { try require(Data(SHA256.hash(data: try Data(contentsOf: source))) == hashes[index], "source mutated") }
            print("PASS cancellation, impossible target rollback, original source hashes")
            print("PASS all animation tests", root.path)
        } catch { print("FAIL", error.localizedDescription); exit(1) }
    }
}

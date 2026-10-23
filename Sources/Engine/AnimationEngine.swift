import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

extension MediaEngine {
    static func sourceFrameRate(_ asset: AVAsset) async throws -> Double? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let nominal = Double(try await track.load(.nominalFrameRate))
        if nominal.isFinite, nominal > 0 { return nominal }
        let minimum = try await track.load(.minFrameDuration).seconds
        return minimum.isFinite && minimum > 0 ? 1 / minimum : nil
    }

    static func animate(_ source: URL, to output: URL, options: AnimationOptions) async throws -> String {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let assetDuration = try await asset.load(.duration)
        if options.format.isModern {
            let info = try await VideoSourceInfo.inspect(source)
            if let issue = info.reencodeRestriction { throw EngineError.unsupported(issue) }
        }
        let duration = options.duration ?? (assetDuration.seconds - options.start)
        guard options.start.isFinite, duration.isFinite, options.start >= 0, duration > 0,
              options.start + duration <= assetDuration.seconds + 0.001,
              options.fps.isFinite, (1...AnimationOptions.maximumFPS).contains(options.fps),
              (2...(options.format == .webp ? 16383:65535)).contains(options.maxDimension), duration * options.fps <= Double(AnimationOptions.maximumFrames),
              options.targetBytes == nil || options.targetBytes! > 0 else {
            throw EngineError.invalid("애니메이션 시간·FPS·크기 오류 (최대 60fps·1,800프레임)")
        }
        guard let sourceTrack=try await asset.loadTracks(withMediaType:.video).first else { throw EngineError.unsupported("비디오 트랙을 찾지 못했어요.") }
        let naturalSize=try await sourceTrack.load(.naturalSize),preferredTransform=try await sourceTrack.load(.preferredTransform)
        let displaySize=naturalSize.applying(preferredTransform)
        func extractionSize(for dimension:Int)->CGSize {
            VideoCropGeometry.extractionSize(width:abs(Double(displaySize.width)),height:abs(Double(displaySize.height)),crop:options.crop,maxDimension:dimension)
        }
        let resources = AnimationResources.shared
        let fps = options.fps
        let dimension = options.maxDimension
        var lastSize = 0
        let initial = options.preserveSourceTiming
            ? try await AnimationPlan.source(asset:asset,start:options.start,duration:duration,fps:fps,format:options.format)
            : AnimationPlan(duration:duration,fps:fps,format:options.format)
        if options.format.isModern {
            resources.enter(); defer { resources.leave() }
            let encoded = try await AnimationPipeline.encode(asset: asset, start: options.start, fps: fps, dimension: dimension,
                extractionSize: extractionSize(for: dimension), crop: options.crop, plan: initial, format: options.format,
                quality: 100, allowParallelWebP: false,
                maximumBytes: nil) { EngineProgress.report(0.05+0.85*$0) }
            if let target = options.targetBytes, encoded.bytes.count > target {
                throw EngineError.quality("무손실 결과가 목표 용량을 넘어요. 프레임·해상도·품질을 자동으로 낮추지 않았어요.")
            }
            try Task.checkCancellation()
            try encoded.bytes.write(to: output)
            return "\(options.format.rawValue.uppercased()) 무손실 움짤 · \(encoded.width)×\(encoded.height) · \(initial.frames.count)프레임 · 픽셀·타이밍 검증"
        }
        resources.enter(); defer { resources.leave() }
        // Preserve the selected raster and every planned picture. A byte cap
        // only changes codec quality/palette depth, never dimensions or FPS.
        let qualities = options.targetBytes == nil ? (options.format == .webp ? [96,100]:[96]) : (options.format == .gif ? [96,84,72] : [96,80,64,32,0])
        var first = 0
        var selectedQuality:Int?
        if let target=options.targetBytes,initial.frames.count>=48 {
            var previous:(quality:Int,bytes:Double)?
            for index in qualities.indices {
                let sample=initial.sample
                let trial=try await AnimationPipeline.encode(asset:asset,start:options.start,fps:fps,dimension:dimension,
                    extractionSize:extractionSize(for:dimension),crop:options.crop,plan:sample,format:options.format,
                    quality:qualities[index],allowParallelWebP:true) { EngineProgress.report(0.03+0.07*$0) }
                first=index
                let estimate=Double(trial.bytes.count)*Double(initial.frames.count)/Double(sample.frames.count)*1.03
                if estimate<=Double(target)*0.97 {
                    if options.format == .webp,let previous,previous.bytes>estimate {
                        // Interpolate an actually measured size bracket. This
                        // selects a request only; full output bytes/pixels still
                        // decide whether it can be saved.
                        let fraction=max(0,min(1,log(Double(target)*0.94/estimate)/log(previous.bytes/estimate)))
                        selectedQuality=Int(floor(Double(qualities[index])+Double(previous.quality-qualities[index])*fraction))
                    }
                    break
                }
                previous=(qualities[index],estimate)
            }
        }
        var candidates=Array(qualities.dropFirst(first)),attempts=0
        if let selectedQuality { candidates[0]=selectedQuality }
        let maximumAttempts=options.format == .gif ? 3:2
        while !candidates.isEmpty,attempts<maximumAttempts {
            let quality=candidates.removeFirst();attempts+=1
            try Task.checkCancellation()
            let encoded=try await AnimationPipeline.encode(asset:asset,start:options.start,fps:fps,dimension:dimension,
                extractionSize:extractionSize(for:dimension),crop:options.crop,plan:initial,format:options.format,
                quality:quality,allowParallelWebP:true,maximumBytes:nil) { EngineProgress.report(0.10+0.70*$0) }
            lastSize=encoded.bytes.count
            if let target=options.targetBytes,Int64(lastSize)>target {
                if options.format == .webp,quality>0 {
                    // A small cap miss should not jump straight from q96 to
                    // q88 and waste half the available bytes. This chooses a
                    // request only; actual bytes and all frames decide the pass.
                    let step=max(1,Int(ceil((quality>80 ? 8:16)*log2(Double(lastSize)/Double(target)))))
                    candidates=[max(0,quality-step)]
                }
                continue
            }
            try AnimationPipeline.verify(encoded,plan:initial,format:options.format)
            let measured:String
            do {
                measured=try await AnimationPipeline.verifyQuality(encoded,asset:asset,start:options.start,fps:fps,
                    dimension:dimension,extractionSize:extractionSize(for:dimension),crop:options.crop,
                    plan:initial,format:options.format,automatic:options.targetBytes == nil)
            } catch is AnimationQualityFailure where options.targetBytes == nil && options.format == .webp && quality<100 {
                // Saturated fine detail can exceed VP8's chroma-subsampling
                // error budget even at q96. Retry losslessly, not below the gate.
                continue
            }
            try Task.checkCancellation()
            try encoded.bytes.write(to:output)
            return "\(options.format.rawValue.uppercased()) · \(encoded.width)×\(encoded.height) · \(AnimationOptions.frameRateText(fps))fps · \(lastSize)바이트 · \(measured)"
        }
        throw EngineError.quality("선택한 해상도·프레임과 화질 하한을 유지하면서 목표 용량에 맞는 결과를 찾지 못했어요 (\(lastSize)바이트). 목표를 높이거나 비워 주세요.")
    }

    /// Measured encode of twelve frames in three windows, at the requested
    /// geometry/quality. This is a size estimate, never a quality or FPS change.
    static func animationEstimate(_ source:URL,options:AnimationOptions) async throws -> Int {
        let asset=AVURLAsset(url:source)
        let length=try await asset.load(.duration).seconds
        let duration=options.duration ?? length-options.start
        guard options.start.isFinite,options.start>=0,duration.isFinite,duration>0,
              options.start+duration<=length+0.001,options.fps.isFinite,(1...AnimationOptions.maximumFPS).contains(options.fps),
              duration*options.fps<=Double(AnimationOptions.maximumFrames),
              (2...(options.format == .webp ? 16383:65535)).contains(options.maxDimension) else {
            throw EngineError.invalid("구간·FPS·크기를 확인해 주세요.")
        }
        guard let track=try await asset.loadTracks(withMediaType:.video).first else { throw EngineError.invalid("영상 트랙 없음") }
        let natural=try await track.load(.naturalSize),transform=try await track.load(.preferredTransform)
        let shown=natural.applying(transform)
        let plan=options.preserveSourceTiming
            ? try await AnimationPlan.source(asset:asset,start:options.start,duration:duration,fps:options.fps,format:options.format)
            : AnimationPlan(duration:duration,fps:options.fps,format:options.format)
        AnimationResources.shared.enter();defer { AnimationResources.shared.leave() }
        let sample=plan.sample
        let encoded=try await AnimationPipeline.encode(asset:asset,start:options.start,fps:options.fps,dimension:options.maxDimension,
            extractionSize:VideoCropGeometry.extractionSize(width:abs(shown.width),height:abs(shown.height),crop:options.crop,maxDimension:options.maxDimension),
            crop:options.crop,plan:sample,format:options.format,quality:96,allowParallelWebP:true) { _ in }
        return Int(Double(encoded.bytes.count)*Double(plan.frames.count)/Double(sample.frames.count)*1.03)
    }
}

/// Native median cut over a bounded RGB histogram, followed by Floyd–Steinberg
/// error diffusion. vImage is used by the shared resize path; no codec subprocess.
enum AdaptivePalette {
    private static let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func sRGB(_ image:CGImage) throws -> Data {
        let w = image.width, h = image.height
        var data = Data(count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: w,
                      height: h,
                      bitsPerComponent: 8,
                      bytesPerRow: w * 4,
                      space: sRGBSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw EngineError.io("sRGB 변환 버퍼 생성 실패") }
        return data
    }
    private struct Color {
        var r:Int=0,g:Int=0,b:Int=0,count:Int=0
        @inline(__always) func component(_ channel:Int)->Int { channel==0 ? r:(channel==1 ? g:b) }
    }
    static func indexed(_ image:CGImage,quality:Int = 96) throws -> CGImage {
        let rgba=try sRGB(image),width=image.width,height=image.height
        var histogram=[Color](repeating:Color(),count:32768)
        rgba.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self).baseAddress!
            let total = width * height * 4
            var p = 0
            while p < total {
                let r = Int(ptr[p]), g = Int(ptr[p+1]), b = Int(ptr[p+2])
                let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                histogram[key].r += r
                histogram[key].g += g
                histogram[key].b += b
                histogram[key].count += 1
                p += 4
            }
        }
        var colors:[Color]=[]
        colors.reserveCapacity(4096)
        for h in histogram where h.count > 0 {
            colors.append(Color(r:h.r/h.count,g:h.g/h.count,b:h.b/h.count,count:h.count))
        }
        if colors.isEmpty { throw EngineError.invalid("빈 애니메이션 이미지") }
        struct Bucket { var colors:[Color];var channel:Int;var score:Int }
        func bucket(_ colors:[Color])->Bucket {
            var minR=255,maxR=0,minG=255,maxG=0,minB=255,maxB=0,totalCount=0
            for c in colors {
                if c.r < minR { minR = c.r }; if c.r > maxR { maxR = c.r }
                if c.g < minG { minG = c.g }; if c.g > maxG { maxG = c.g }
                if c.b < minB { minB = c.b }; if c.b > maxB { maxB = c.b }
                totalCount += c.count
            }
            let rRange = maxR - minR, gRange = maxG - minG, bRange = maxB - minB
            let channel: Int
            let maxRange: Int
            if rRange >= gRange && rRange >= bRange { channel = 0; maxRange = rRange }
            else if gRange >= bRange { channel = 1; maxRange = gRange }
            else { channel = 2; maxRange = bRange }
            return Bucket(colors:colors,channel:channel,score:maxRange*totalCount)
        }
        var buckets=[bucket(colors)]
        // ImageIO's GIF writer marks index 255 transparent on every frame, so
        // the palette stops at 255 colors and leaves that index unused.
        let maximumColors=quality>=94 ? 255:(quality>=80 ? 192:128)
        buckets.reserveCapacity(maximumColors)
        while buckets.count<maximumColors {
            var bestIdx = -1, bestScore = -1
            for idx in buckets.indices where buckets[idx].colors.count > 1 {
                if buckets[idx].score > bestScore { bestScore = buckets[idx].score; bestIdx = idx }
            }
            guard bestIdx >= 0 else { break }
            let old=buckets.remove(at:bestIdx),channel=old.channel
            colors=old.colors.sorted { $0.component(channel)<$1.component(channel) }
            let half=colors.reduce(0) { $0+$1.count }/2
            var count=0,split=1
            for i in 0..<(colors.count-1) { count+=colors[i].count;split=i+1;if count>=half { break } }
            buckets.append(bucket(Array(colors[..<split])));buckets.append(bucket(Array(colors[split...])))
        }
        let palette=buckets.map { bucket -> Color in
            let count=bucket.colors.reduce(0) { $0+$1.count }
            return Color(r:bucket.colors.reduce(0) { $0+$1.r*$1.count }/count,g:bucket.colors.reduce(0) { $0+$1.g*$1.count }/count,b:bucket.colors.reduce(0) { $0+$1.b*$1.count }/count,count:count)
        }
        var lookup=Data( capacity: palette.count * 3 )
        for color in palette { lookup.append(contentsOf:[UInt8(color.r),UInt8(color.g),UInt8(color.b)]) }
        var cache=[Int16](repeating:-1,count:32768),pixels=Data(count:width*height)
        var errors=[Float](repeating:0,count:(width+2)*3*2)
        try rgba.withUnsafeBytes { input in
            try pixels.withUnsafeMutableBytes { output in
                try lookup.withUnsafeBytes { palette in
                    try cache.withUnsafeMutableBufferPointer { cache in
                        try errors.withUnsafeMutableBufferPointer { errors in
                            for row in stride(from:0,to:height,by:32) {
                                try Task.checkCancellation()
                                guard ring_palette_dither(input.bindMemory(to:UInt8.self).baseAddress!,Int32(width),Int32(height),
                                    Int32(row),Int32(min(32,height-row)),palette.bindMemory(to:UInt8.self).baseAddress!,Int32(buckets.count),
                                    output.bindMemory(to:UInt8.self).baseAddress!,cache.baseAddress!,errors.baseAddress!) == 1 else {
                                    throw EngineError.io("팔레트 픽셀 변환 실패")
                                }
                            }
                        }
                    }
                }
            }
        }
        let space=lookup.withUnsafeBytes { CGColorSpace(indexedBaseSpace:sRGBSpace,last:palette.count-1,colorTable:$0.bindMemory(to:UInt8.self).baseAddress!) }
        guard let space,let provider=CGDataProvider(data:pixels as CFData),let result=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:width,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw EngineError.io("팔레트 이미지 생성 실패") }
        return result
    }
}

import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

extension MediaEngine {
    static func animate(_ source:URL,to output:URL,options:AnimationOptions) async throws -> String {
        let asset=AVURLAsset(url:source),assetDuration=try await asset.load(.duration)
        let duration=options.duration ?? (assetDuration.seconds-options.start)
        guard options.start.isFinite,duration.isFinite,options.start>=0,duration>0,
              options.start+duration<=assetDuration.seconds+0.001,
              options.fps.isFinite,(1...30).contains(options.fps),(16...1920).contains(options.maxDimension),
              duration*options.fps<=1800,options.targetBytes == nil || options.targetBytes!>0 else { throw EngineError.invalid("애니메이션 시간·FPS·크기 오류 (최대 1,800프레임)") }
        var fps=options.fps,dimension=options.maxDimension,lastSize=0
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let generator=AVAssetImageGenerator(asset:asset)
            generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:min(3840,dimension*2),height:min(3840,dimension*2))
            generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
            let frames=max(1,Int(ceil(duration*fps))),memory=NSMutableData()
            let gif:CGImageDestination?
            if options.format == .gif {
                gif=CGImageDestinationCreateWithData(memory,"com.compuserve.gif" as CFString,frames,nil)
                guard let gif else { throw EngineError.io("GIF 인코더 생성 실패") }
                CGImageDestinationSetProperties(gif,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0,kCGImagePropertyGIFHasGlobalColorMap:false]] as CFDictionary)
            } else { gif=nil }
            var webp:UnsafeMutableRawPointer?,size:CGSize = .zero
            defer { ring_webp_animation_destroy(webp);generator.cancelAllCGImageGeneration() }
            for i in 0..<frames {
                try Task.checkCancellation()
                let offset=Double(i)/fps
                let generated=try await generator.image(at:CMTime(seconds:options.start+offset,preferredTimescale:60000))
                try autoreleasepool {
                    let image=try ImageResampler.fit(generated.image,maxDimension:dimension)
                    if i==0 {
                        size=CGSize(width:image.width,height:image.height)
                        if options.format == .webp {
                            webp=ring_webp_animation_create(Int32(image.width),Int32(image.height))
                            guard webp != nil else { throw EngineError.io("WebP 애니메이션 생성 실패") }
                        }
                    }
                    guard size==CGSize(width:image.width,height:image.height) else { throw EngineError.unsupported("프레임별 해상도가 바뀌는 영상은 변환하지 않아요.") }
                    if let gif {
                        let indexed=try AdaptivePalette.indexed(image)
                        let delay=min(1/fps,duration-offset)
                        CGImageDestinationAddImage(gif,indexed,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:delay,kCGImagePropertyGIFUnclampedDelayTime:delay]] as CFDictionary)
                    } else {
                        let rgba=try AdaptivePalette.sRGB(image)
                        let ok=rgba.withUnsafeBytes { ring_webp_animation_add(webp,$0.bindMemory(to:UInt8.self).baseAddress!,Int32(image.width),Int32(image.height),Int32((offset*1000).rounded()),Int32(max(40,90-attempt*10)),Int32(ThermalPolicy.threads)) }
                        guard ok==1 else { throw EngineError.io("WebP 프레임 쓰기 실패") }
                    }
                }
                EngineProgress.step(i,of:frames)
            }
            let bytes:Data
            if let gif {
                guard CGImageDestinationFinalize(gif) else { throw EngineError.io("GIF 마감 실패") };bytes=memory as Data
            } else {
                var buffer:UnsafeMutablePointer<UInt8>?,count=0
                let ok=ring_webp_animation_finish(webp,Int32((duration*1000).rounded()),&buffer,&count)
                defer { ring_buffer_free(buffer) }
                guard ok==1,let buffer else { throw EngineError.io("WebP 애니메이션 마감 실패") };bytes=Data(bytes:buffer,count:count)
            }
            lastSize=bytes.count
            if options.targetBytes == nil || Int64(lastSize)<=options.targetBytes! {
                guard let check=CGImageSourceCreateWithData(bytes as CFData,nil),CGImageSourceGetStatus(check) == .statusComplete,
                      CGImageSourceGetCount(check)>0 else { throw EngineError.quality("애니메이션 디코딩 검사 실패") }
                // WebP may merge identical frames; GIF must retain each requested frame.
                if options.format == .gif && CGImageSourceGetCount(check) != frames { throw EngineError.quality("GIF 프레임 수 검사 실패") }
                var actualDuration:Double=0
                for index in 0..<CGImageSourceGetCount(check) {
                    try autoreleasepool {
                        guard let image=CGImageSourceCreateImageAtIndex(check,index,nil),image.width==Int(size.width),image.height==Int(size.height),
                              let props=CGImageSourceCopyPropertiesAtIndex(check,index,nil) as? [CFString:Any] else { throw EngineError.quality("애니메이션 프레임·크기 검사 실패") }
                        let dictionary=props[options.format == .gif ? kCGImagePropertyGIFDictionary:kCGImagePropertyWebPDictionary] as? [CFString:Any]
                        let delayKey=options.format == .gif ? kCGImagePropertyGIFUnclampedDelayTime:kCGImagePropertyWebPUnclampedDelayTime
                        let fallback=options.format == .gif ? kCGImagePropertyGIFDelayTime:kCGImagePropertyWebPDelayTime
                        actualDuration+=(dictionary?[delayKey] as? Double ?? dictionary?[fallback] as? Double ?? 0)
                    }
                }
                guard abs(actualDuration-duration)<=max(0.1,Double(frames)*0.0051) else { throw EngineError.quality("애니메이션 재생 길이 검사 실패") }
                try bytes.write(to:output)
                return "\(options.format.rawValue.uppercased()) · \(Int(size.width))×\(Int(size.height)) · \(String(format:"%.1f",fps))fps · \(lastSize)바이트" + (options.format == .gif ? " · 적응형 256색·오차 확산 디더링":"")
            }
            let ratio=sqrt(Double(options.targetBytes!)/Double(max(1,lastSize)))*0.90
            dimension=max(16,Int(Double(dimension)*max(0.4,min(0.85,ratio))))
            fps=max(1,fps*0.8)
        }
        throw EngineError.quality("애니메이션 \(lastSize)바이트가 목표를 초과했어요.")
    }
}

/// Native median cut over a bounded RGB histogram, followed by Floyd–Steinberg
/// error diffusion. vImage is used by the shared resize path; no codec subprocess.
enum AdaptivePalette {
    static func sRGB(_ image:CGImage) throws -> Data {
        let context=try PDFEngine.bitmap(width:image.width,height:image.height,space:CGColorSpace(name:CGColorSpace.sRGB)!)
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:image.width,height:image.height))
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        return try ExternalCodecs.straightRGBA8(context.makeImage()!)
    }
    private struct Color {
        var r:Int=0,g:Int=0,b:Int=0,count:Int=0
        func component(_ channel:Int)->Int { channel==0 ? r:channel==1 ? g:b }
    }
    static func indexed(_ image:CGImage) throws -> CGImage {
        let rgba=try sRGB(image),width=image.width,height=image.height
        var histogram=[Color](repeating:Color(),count:32768)
        for p in stride(from:0,to:rgba.count,by:4) {
            let r=Int(rgba[p]),g=Int(rgba[p+1]),b=Int(rgba[p+2]),key=(r>>3)<<10 | (g>>3)<<5 | (b>>3)
            histogram[key].r+=r;histogram[key].g+=g;histogram[key].b+=b;histogram[key].count+=1
        }
        var colors=histogram.filter { $0.count>0 }.map { Color(r:$0.r/$0.count,g:$0.g/$0.count,b:$0.b/$0.count,count:$0.count) }
        if colors.isEmpty { throw EngineError.invalid("빈 애니메이션 이미지") }
        struct Bucket { var colors:[Color];var channel:Int;var score:Int }
        func bucket(_ colors:[Color])->Bucket {
            let ranges=(0..<3).map { channel in colors.map { $0.component(channel) }.max()!-colors.map { $0.component(channel) }.min()! }
            let channel=ranges.indices.max { ranges[$0]<ranges[$1] }!
            return Bucket(colors:colors,channel:channel,score:ranges[channel]*colors.reduce(0) { $0+$1.count })
        }
        var buckets=[bucket(colors)]
        while buckets.count<256 {
            guard let index=buckets.indices.filter({buckets[$0].colors.count>1}).max(by:{buckets[$0].score<buckets[$1].score}) else { break }
            let old=buckets.remove(at:index),channel=old.channel
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
        var lookup=Data();for color in palette { lookup.append(contentsOf:[UInt8(color.r),UInt8(color.g),UInt8(color.b)]) }
        var cache=[Int](repeating:-1,count:32768),pixels=Data(count:width*height)
        var current=[Float](repeating:0,count:(width+2)*3),next=current
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let p=(y*width+x)*4,e=(x+1)*3
                let r=max(0,min(255,Int((Float(rgba[p])+current[e]).rounded()))),g=max(0,min(255,Int((Float(rgba[p+1])+current[e+1]).rounded()))),b=max(0,min(255,Int((Float(rgba[p+2])+current[e+2]).rounded())))
                let key=(r>>3)<<10 | (g>>3)<<5 | (b>>3)
                if cache[key]<0 {
                    let rr=((key>>10)&31)*8+4,gg=((key>>5)&31)*8+4,bb=(key&31)*8+4
                    var best=0,distance=Int.max
                    for (i,c) in palette.enumerated() { let d=(rr-c.r)*(rr-c.r)+(gg-c.g)*(gg-c.g)+(bb-c.b)*(bb-c.b);if d<distance { distance=d;best=i } }
                    cache[key]=best
                }
                let index=cache[key],color=palette[index];pixels[y*width+x]=UInt8(index)
                for (channel,delta) in [Float(r-color.r),Float(g-color.g),Float(b-color.b)].enumerated() {
                    current[e+3+channel]+=delta*7/16;next[e-3+channel]+=delta*3/16;next[e+channel]+=delta*5/16;next[e+3+channel]+=delta/16
                }
            }
            current=next;next=[Float](repeating:0,count:next.count)
        }
        let space=lookup.withUnsafeBytes { CGColorSpace(indexedBaseSpace:CGColorSpace(name:CGColorSpace.sRGB)!,last:palette.count-1,colorTable:$0.bindMemory(to:UInt8.self).baseAddress!) }
        guard let space,let provider=CGDataProvider(data:pixels as CFData),let result=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:width,space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw EngineError.io("팔레트 이미지 생성 실패") }
        return result
    }
}

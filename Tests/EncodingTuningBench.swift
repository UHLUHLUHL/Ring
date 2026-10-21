import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

/// Developer benchmark using synthetic fixtures only. Timing excludes the
/// separate four-frame PSNR / non-overlapping 8x8 RGB SSIM measurement.
@main struct EncodingTuningBench {
    static func emit(_ row:[String:Any]) throws {
        var record=row
        record["thermal"]=ProcessInfo.processInfo.thermalState.rawValue
        record["lowPower"]=ProcessInfo.processInfo.isLowPowerModeEnabled
        print(String(data:try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]),encoding:.utf8)!)
    }
    static func quality(_ source:URL,_ output:URL) async throws -> (Double,Double) {
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:source))
        generator.appliesPreferredTrackTransform=true
        generator.maximumSize=CGSize(width:1280,height:1280)
        generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        guard let decoded=CGImageSourceCreateWithURL(output as CFURL,nil) else { throw EngineError.io("benchmark decode") }
        var starts:[Double]=[],end=0.0
        for i in 0..<CGImageSourceGetCount(decoded) {
            starts.append(end)
            let p=CGImageSourceCopyPropertiesAtIndex(decoded,i,nil) as! [CFString:Any]
            let gif=output.pathExtension == "gif"
            let d=p[gif ? kCGImagePropertyGIFDictionary:kCGImagePropertyWebPDictionary] as! [CFString:Any]
            end+=d[gif ? kCGImagePropertyGIFUnclampedDelayTime:kCGImagePropertyWebPUnclampedDelayTime] as! Double
        }
        var squared=0.0,samples=0,ssim=0.0,windows=0
        for frame in [0,15,30,59] {
            let time=Double(frame)/15
            let index=output.pathExtension == "gif" ? frame:starts.lastIndex(where:{$0<=time+0.00001})!
            let reference=try ImageResampler.fit(await generator.image(at:CMTime(seconds:time,preferredTimescale:60000)).image,maxDimension:640)
            let actual=CGImageSourceCreateImageAtIndex(decoded,index,nil)!
            guard actual.width==reference.width,actual.height==reference.height else { throw EngineError.quality("benchmark frame dimensions") }
            let a=try AdaptivePalette.sRGB(reference),b=try AdaptivePalette.sRGB(actual),w=reference.width,h=reference.height
            a.withUnsafeBytes { ar in b.withUnsafeBytes { br in
                let x=ar.bindMemory(to:UInt8.self),y=br.bindMemory(to:UInt8.self)
                for p in stride(from:0,to:a.count,by:4) { for c in 0..<3 {
                    let d=Double(x[p+c])-Double(y[p+c]);squared+=d*d;samples+=1
                } }
                for yy in stride(from:0,to:h,by:8) { for xx in stride(from:0,to:w,by:8) { for c in 0..<3 {
                    var sx=0.0,sy=0.0,sxx=0.0,syy=0.0,sxy=0.0,n=0.0
                    for j in yy..<min(h,yy+8) { for i in xx..<min(w,xx+8) {
                        let p=(j*w+i)*4+c,aa=Double(x[p]),bb=Double(y[p])
                        sx+=aa;sy+=bb;sxx+=aa*aa;syy+=bb*bb;sxy+=aa*bb;n+=1
                    } }
                    let mx=sx/n,my=sy/n,vx=max(0,sxx/n-mx*mx),vy=max(0,syy/n-my*my),cov=sxy/n-mx*my
                    ssim+=((2*mx*my+6.5025)*(2*cov+58.5225))/((mx*mx+my*my+6.5025)*(vx+vy+58.5225));windows+=1
                } } }
            } }
        }
        return (squared==0 ? 100:10*log10(65025*Double(samples)/squared),ssim/Double(windows))
    }
    static func main() async throws {
        setbuf(stdout,nil)
        let label=CommandLine.arguments[1],root=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        if ProcessInfo.processInfo.environment["RING_BENCH_QUALITY_ONLY"] != nil {
            for name in ["smooth","textured","static"] { for format in [AnimationFormat.gif,.webp] {
                let source=URL(fileURLWithPath:".work/animation-implemented-bench/small/\(name).mp4")
                let metrics=try await quality(source,root.appendingPathComponent("\(label)-\(name)-0.\(format.rawValue)"))
                try emit(["kind":"quality","input":name,"format":format.rawValue,"psnr":metrics.0,"ssim8x8":metrics.1])
            } }
            return
        }
        for (name,path) in [("gradient",".work/stage1-final2/12mp.png"),("jpeg",".work/stage1-d/12mp.jpg")] where ProcessInfo.processInfo.environment["RING_BENCH_ANIMATION_ONLY"] == nil {
            for format in name == "gradient" ? [ImageFormat.webp,.avif]:[.webp] {
                for run in 0..<3 {
                    let output=root.appendingPathComponent("\(label)-\(name)-\(run).\(format.rawValue)")
                    let start=ProcessInfo.processInfo.systemUptime
                    _=try ExternalCodecs.convert(URL(fileURLWithPath:path),to:output,format:format)
                    try emit(["kind":"image","input":name,"format":format.rawValue,"run":run,"seconds":ProcessInfo.processInfo.systemUptime-start,"bytes":try Data(contentsOf:output).count])
                }
            }
        }
        for name in ["smooth","textured","static"] {
            let source=URL(fileURLWithPath:".work/animation-implemented-bench/small/\(name).mp4")
            for format in [AnimationFormat.gif,.webp] {
                for run in 0..<3 {
                    let output=root.appendingPathComponent("\(label)-\(name)-\(run).\(format.rawValue)")
                    let start=ProcessInfo.processInfo.systemUptime
                    let detail=try await MediaEngine.animate(source,to:output,options:.init(format:format,fps:15,maxDimension:640,duration:4))
                    try emit(["kind":"animation","input":name,"format":format.rawValue,"run":run,"seconds":ProcessInfo.processInfo.systemUptime-start,"bytes":try Data(contentsOf:output).count,"detail":detail])
                    if run==0 {
                        let metrics=try await quality(source,output)
                        try emit(["kind":"quality","input":name,"format":format.rawValue,"psnr":metrics.0,"ssim8x8":metrics.1])
                    }
                }
            }
        }
    }
}

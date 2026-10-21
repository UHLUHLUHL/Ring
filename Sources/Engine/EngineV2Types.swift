import Foundation
import CoreGraphics

enum CompressionIntent: Equatable {
    case lossless
    case quality(Double)
    case targetBytes(Int64)
}

struct PDFCompressionOptions {
    var maxImageDimension: Int = 2000
    var jpegQuality: Double = 0.82
}

struct DocumentRenderOptions {
    var pageSize: CGSize = CGSize(width: 595.28, height: 841.89)
    var margin: Double = 36
    var dpi: Double = 200
}

enum VideoCodec { case hevc, h264 }
enum VideoCropRatio: String, CaseIterable, Hashable {
    case free = "자유", square = "1:1", fourThree = "4:3", threeFour = "3:4", wide = "16:9", tall = "9:16"

    var cropUnits: (width: Int, height: Int)? {
        switch self {
        case .free: return nil
        case .square: return (1, 1)
        case .fourThree: return (4, 3)
        case .threeFour: return (3, 4)
        case .wide: return (16, 9)
        case .tall: return (9, 16)
        }
    }

    var aspectRatio: Double? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .fourThree: return 4.0 / 3
        case .threeFour: return 3.0 / 4
        case .wide: return 16.0 / 9
        case .tall: return 9.0 / 16
        }
    }
}

enum VideoCropGeometry {
    static func centeredSize(width: Double, height: Double, aspectRatio: Double?) -> CGSize {
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 else {
            return CGSize(width: CGFloat(width), height: CGFloat(height))
        }
        if width / height > aspectRatio {
            return CGSize(width: CGFloat(height * aspectRatio), height: CGFloat(height))
        }
        return CGSize(width: CGFloat(width), height: CGFloat(width / aspectRatio))
    }

    static func centeredRect(width: Int, height: Int, ratio: VideoCropRatio) -> CGRect {
        guard width > 0, height > 0, let units = ratio.cropUnits else {
            return CGRect(x: 0, y: 0, width: max(1, width), height: max(1, height))
        }
        // Integer multiples keep preset crops exact (for example, 16:9) and stable across frames.
        let scale = min(width / units.width, height / units.height)
        let cropWidth: Int, cropHeight: Int
        if scale > 0 {
            cropWidth=units.width*scale;cropHeight=units.height*scale
        } else {
            let size=centeredSize(width:Double(width),height:Double(height),aspectRatio:ratio.aspectRatio)
            cropWidth=min(width,max(1,Int(size.width.rounded(.down))))
            cropHeight=min(height,max(1,Int(size.height.rounded(.down))))
        }
        return CGRect(x: (width - cropWidth) / 2, y: (height - cropHeight) / 2,
                      width: cropWidth, height: cropHeight)
    }

    /// Video bitrate left after the AAC track, for a whole-file byte target.
    static func videoBitrate(targetBytes:Int64,duration:Double,audio:Bool) -> Double {
        Double(targetBytes)*0.94*8/duration-Double(audio ? 96000:0)
    }
    /// Displayed (upright) size of the first compression attempt. The short
    /// side is capped by bitrate; both sides are even for the encoder.
    static func compressedSize(width:Double,height:Double,ratio:VideoCropRatio,maxDimension:Int?,bitrate:Int) -> (width:Int,height:Int) {
        let cap=bitrate<400000 ? 480:bitrate<900000 ? 720:1080
        let crop=centeredSize(width:width,height:height,aspectRatio:ratio.aspectRatio)
        let longSide=Double(max(crop.width,crop.height)),shortSide=Double(min(crop.width,crop.height))
        let scale=min(1,min(Double(cap)/max(1,shortSide),Double(maxDimension ?? Int.max)/max(1,longSide)))
        return (max(2,Int((Double(crop.width)*scale/2).rounded(.down))*2),max(2,Int((Double(crop.height)*scale/2).rounded(.down))*2))
    }
    /// GIF/WebP frame size: the generator fills `extractionSize`, the crop is
    /// taken from that frame, and vImage fits it to the long side.
    static func animationSize(width:Double,height:Double,ratio:VideoCropRatio,maxDimension:Int) -> (width:Int,height:Int) {
        let safeWidth=max(1,width),safeHeight=max(1,height)
        let extraction=extractionSize(width:safeWidth,height:safeHeight,ratio:ratio,maxDimension:maxDimension)
        let scale=min(1,Double(extraction.width)/safeWidth,Double(extraction.height)/safeHeight)
        let frame=centeredRect(width:max(1,Int((safeWidth*scale).rounded())),height:max(1,Int((safeHeight*scale).rounded())),ratio:ratio)
        let factor=min(1,Double(maxDimension)/Double(max(frame.width,frame.height)))
        return (max(1,Int((Double(frame.width)*factor).rounded())),max(1,Int((Double(frame.height)*factor).rounded())))
    }

    static func extractionSize(width: Double, height: Double, ratio: VideoCropRatio, maxDimension: Int) -> CGSize {
        let safeWidth=max(1,width),safeHeight=max(1,height),limit=Double(maxDimension)*2
        let crop=centeredSize(width:safeWidth,height:safeHeight,aspectRatio:ratio.aspectRatio)
        let scale=min(1,limit/max(1,Double(max(crop.width,crop.height))))
        var outputWidth=safeWidth*scale,outputHeight=safeHeight*scale
        // Leave a bounded margin for pixels that will be discarded by the crop.
        let areaLimit=Double(maxDimension)*Double(maxDimension)*4
        if outputWidth*outputHeight>areaLimit {
            let areaScale=sqrt(areaLimit/(outputWidth*outputHeight))
            outputWidth*=areaScale;outputHeight*=areaScale
        }
        let sideLimit=Double(maxDimension)*4,sideScale=min(1,sideLimit/max(outputWidth,outputHeight))
        return CGSize(width:CGFloat(outputWidth*sideScale),height:CGFloat(outputHeight*sideScale))
    }
}

struct VideoCompressionOptions {
    var targetBytes: Int64
    var codec: VideoCodec
    var maxDimension: Int? = nil
    var cropRatio: VideoCropRatio = .free
}

enum AnimationFormat: String { case gif, webp }
struct AnimationOptions {
    static let maximumFPS: Double = 60
    static let maximumFrames = 1800
    var format: AnimationFormat = .gif
    var fps: Double = 30
    var maxDimension: Int = 640
    var targetBytes: Int64? = nil
    var start: Double = 0
    var duration: Double? = nil
    var cropRatio: VideoCropRatio = .free

    static func frameRateText(_ value: Double) -> String {
        var text = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }
}
enum VideoOperation {
    /// Passthrough cuts use container/sample boundaries, not arbitrary decoded frames.
    case trim(start: Double, end: Double)
    case compress(VideoCompressionOptions)
    case animation(AnimationOptions)
    var fileExtension: String {
        switch self {
        case .trim: return "mov"
        case .compress: return "mp4"
        case .animation(let options): return options.format.rawValue
        }
    }
}

/// Re-evaluated at every job admission and every encoder invocation/frame.
enum ThermalPolicy {
    static var threads: Int {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return 1 }
        switch info.thermalState {
        case .critical: return 1
        case .serious, .fair: return 2
        default: return min(4, max(1, info.activeProcessorCount / 2))
        }
    }
    // Full-resolution jobs have a larger memory cost than codec workers.
    static var jobs: Int {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState != .nominal ? 1 : min(2, info.activeProcessorCount)
    }
}

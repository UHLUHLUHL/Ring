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
/// Aspect presets offered beside the crop frame, following Photos. `units`
/// are landscape; `VideoCrop.portrait` swaps them.
enum VideoCropRatio: String, CaseIterable, Hashable {
    case free = "자유 형태", original = "원본", square = "정방형"
    case wide = "16:9", fourThree = "4:3", threeTwo = "3:2", fiveFour = "5:4", sevenFive = "7:5"

    /// Integer units in landscape orientation; nil for free form and original.
    var units: (width: Int, height: Int)? {
        switch self {
        case .free, .original: return nil
        case .square: return (1, 1)
        case .wide: return (16, 9)
        case .fourThree: return (4, 3)
        case .threeTwo: return (3, 2)
        case .fiveFour: return (5, 4)
        case .sevenFive: return (7, 5)
        }
    }
    var isSquare: Bool { self == .square }
    /// Short label for a portrait preset, e.g. 9:16 for 16:9.
    func label(portrait: Bool) -> String {
        guard portrait, let units, units.width != units.height else { return rawValue }
        return "\(units.height):\(units.width)"
    }
}

/// Region kept from the upright (displayed) video frame. `rect` is normalized
/// with a top-left origin. With `rect == nil` the largest centred rectangle of
/// `ratio` is kept. A preset ratio is snapped to an exact integer multiple of
/// its units so 16:9 stays 16:9 after rounding to pixels.
struct VideoCrop: Equatable {
    var ratio: VideoCropRatio = .free
    var portrait = false
    var rect: CGRect? = nil
    static let full = VideoCrop()
    init(ratio: VideoCropRatio = .free, portrait: Bool = false, rect: CGRect? = nil) {
        self.ratio = ratio; self.portrait = portrait; self.rect = rect
    }
    var isFull: Bool {
        guard let rect else { return ratio == .free || ratio == .original }
        return abs(rect.minX) < 1e-6 && abs(rect.minY) < 1e-6 && abs(rect.width - 1) < 1e-6 && abs(rect.height - 1) < 1e-6
    }
    func units(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard var u = ratio.units else { return nil }
        if portrait { u = (u.height, u.width) }
        return u
    }
    /// Normalized aspect (width / height) the frame must keep, if any.
    func aspect(width: Double, height: Double) -> Double? {
        if ratio == .original {
            return portrait == (width >= height) ? height / width : width / height
        }
        guard let u = ratio.units else { return nil }
        return portrait ? Double(u.height) / Double(u.width) : Double(u.width) / Double(u.height)
    }
    func pixelRect(width: Int, height: Int) -> CGRect {
        let w = max(1, width), h = max(1, height)
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        guard let rect else {
            if let u = units(width: w, height: h) {
                let scale = min(w / u.width, h / u.height)
                if scale > 0 {
                    let cw = u.width * scale, ch = u.height * scale
                    return CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch)
                }
            }
            guard let aspect = aspect(width: Double(w), height: Double(h)) else { return full }
            let size = VideoCropGeometry.centeredSize(width: Double(w), height: Double(h), aspectRatio: aspect)
            let cw = min(w, max(1, Int(size.width.rounded(.down)))), ch = min(h, max(1, Int(size.height.rounded(.down))))
            return CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch)
        }
        let unit = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !unit.isNull, unit.width > 0, unit.height > 0 else { return full }
        let x0 = Int((unit.minX * Double(w)).rounded()), y0 = Int((unit.minY * Double(h)).rounded())
        let x1 = Int((unit.maxX * Double(w)).rounded()), y1 = Int((unit.maxY * Double(h)).rounded())
        var cw = max(1, min(w, x1 - x0)), ch = max(1, min(h, y1 - y0))
        if let u = units(width: w, height: h) {
            let scale = min(cw / u.width, ch / u.height)
            if scale > 0 { cw = u.width * scale; ch = u.height * scale }
        }
        // Keep the user's centre; clamp inside the frame.
        let cx = Double(x0 + x1) / 2, cy = Double(y0 + y1) / 2
        let x = min(max(0, Int((cx - Double(cw) / 2).rounded())), w - cw)
        let y = min(max(0, Int((cy - Double(ch) / 2).rounded())), h - ch)
        return CGRect(x: x, y: y, width: cw, height: ch)
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

    /// Crop size in displayed pixels (doubles for scaling decisions).
    static func cropSize(width: Double, height: Double, crop: VideoCrop) -> CGSize {
        let w = max(1, Int(width.rounded())), h = max(1, Int(height.rounded()))
        let r = crop.pixelRect(width: w, height: h)
        return CGSize(width: r.width * width / Double(w), height: r.height * height / Double(h))
    }

    /// Video bitrate left after the AAC track, for a whole-file byte target.
    static func videoBitrate(targetBytes:Int64,duration:Double,audio:Bool) -> Double {
        Double(targetBytes)*0.94*8/duration-Double(audio ? 96000:0)
    }
    /// Displayed (upright) size of the first compression attempt. The short
    /// side is capped by bitrate; both sides are even for the encoder.
    static func compressedSize(width:Double,height:Double,crop:VideoCrop,maxDimension:Int?,bitrate:Int) -> (width:Int,height:Int) {
        let cap=bitrate<400000 ? 480:bitrate<900000 ? 720:1080
        let size=cropSize(width:width,height:height,crop:crop)
        let longSide=Double(max(size.width,size.height)),shortSide=Double(min(size.width,size.height))
        let scale=min(1,min(Double(cap)/max(1,shortSide),Double(maxDimension ?? Int.max)/max(1,longSide)))
        return (max(2,Int((Double(size.width)*scale/2).rounded(.down))*2),max(2,Int((Double(size.height)*scale/2).rounded(.down))*2))
    }
    /// GIF/WebP frame size: the generator fills `extractionSize`, the crop is
    /// taken from that frame, and vImage fits it to the long side.
    static func animationSize(width:Double,height:Double,crop:VideoCrop,maxDimension:Int) -> (width:Int,height:Int) {
        let safeWidth=max(1,width),safeHeight=max(1,height)
        let extraction=extractionSize(width:safeWidth,height:safeHeight,crop:crop,maxDimension:maxDimension)
        let scale=min(1,Double(extraction.width)/safeWidth,Double(extraction.height)/safeHeight)
        let frame=crop.pixelRect(width:max(1,Int((safeWidth*scale).rounded())),height:max(1,Int((safeHeight*scale).rounded())))
        let factor=min(1,Double(maxDimension)/Double(max(frame.width,frame.height)))
        return (max(1,Int((Double(frame.width)*factor).rounded())),max(1,Int((Double(frame.height)*factor).rounded())))
    }

    static func extractionSize(width: Double, height: Double, crop: VideoCrop, maxDimension: Int) -> CGSize {
        let safeWidth=max(1,width),safeHeight=max(1,height),limit=Double(maxDimension)*2
        let size=cropSize(width:safeWidth,height:safeHeight,crop:crop)
        let scale=min(1,limit/max(1,Double(max(size.width,size.height))))
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
    var crop: VideoCrop = .full
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
    var crop: VideoCrop = .full

    static func frameRateText(_ value: Double) -> String {
        var text = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }
}
enum VideoOperation {
    case convert(VideoConversionOptions)
    /// Passthrough cuts use container/sample boundaries, not arbitrary decoded frames.
    case trim(start: Double, end: Double)
    case compress(VideoCompressionOptions)
    case animation(AnimationOptions)
    var fileExtension: String {
        switch self {
        case .convert(let options): return options.container.rawValue
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

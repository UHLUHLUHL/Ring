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
    case compress(targetBytes: Int64, codec: VideoCodec)
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

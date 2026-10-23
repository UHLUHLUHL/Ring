import Foundation
import CoreGraphics
import ImageIO

/// Content-detected, bundled AVIF/JPEG XL reader. CGImages retain raw raster orientation.
final class ModernImageReader {
    private let handle: UnsafeMutableRawPointer
    let format: String
    let width: Int, height: Int, frameCount: Int, loops: Int, orientation: Int
    let timeScale: Int, durationTicks: [Int]
    let icc: Data, exif: Data
    let isAnimated: Bool
    let hasAlpha: Bool
    private let space: CGColorSpace
    static func sniff(_ data: Data) -> String? {
        data.withUnsafeBytes { bytes in
            switch ring_modern_sniff(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) {
            case 1: return "avif"
            case 2: return "jxl"
            default: return nil
            }
        }
    }
    convenience init(_ url: URL) throws { try self.init(data: Data(contentsOf: url, options: .mappedIfSafe)) }
    init(data: Data) throws {
        try Task.checkCancellation()
        var info = RingModernInfo(), error = [CChar](repeating: 0, count: 512)
        guard let handle = data.withUnsafeBytes({ bytes in
            ring_modern_open(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                Int32(ThermalPolicy.threads), &info, &error, error.count)
        }) else { throw EngineError.unsupported("AVIF/JPEG XL 읽기 실패: \(String(cString: error))") }
        do {
            func metadata(_ kind: Int32) -> Data {
                var size = 0
                guard let bytes = ring_modern_metadata(handle, kind, &size), size > 0 else { return Data() }
                return Data(bytes: bytes, count: size)
            }
            let icc = metadata(0), exif = metadata(1)
            let space: CGColorSpace
            if icc.isEmpty {
                // CICP without an ICC profile still describes a real color space.
                let primaries = info.color_primaries, transfer = info.transfer_characteristics
                let name: CFString
                switch (primaries, transfer) {
                case (0, 0), (2, 2), (1, 13), (2, 13): name = CGColorSpace.sRGB
                case (1, 1), (1, 6): name = CGColorSpace.itur_709
                case (12, 13): name = CGColorSpace.displayP3
                case (9, 14), (9, 15): name = CGColorSpace.itur_2020
                case (9, 13): name = CGColorSpace.itur_2020_sRGBGamma
                default: throw EngineError.unsupported("ICC가 없는 이 AVIF 색공간은 보존 검증 경로가 없어요.")
                }
                guard let color = CGColorSpace(name: name) else { throw EngineError.unsupported("AVIF 색공간 생성 실패") }
                space = color
            } else {
                guard let color = CGColorSpace(iccData: icc as CFData), color.model == .rgb || color.model == .monochrome,
                      !color.isHDR(), !CGColorSpaceUsesExtendedRange(color) else {
                    throw EngineError.unsupported("HDR·지원하지 않는 ICC 프로필은 보존 경로가 없어요.")
                }
                // Decoders expand gray JXL samples to RGBA. Preserve gray ICC only if RGB storage is compatible.
                guard color.model == .rgb else { throw EngineError.unsupported("회색조 JPEG XL ICC는 RGB 변환 없이 보존할 경로가 아직 없어요.") }
                space = color
            }
            var durations = [Int](); durations.reserveCapacity(Int(info.frame_count))
            for index in 0..<Int(info.frame_count) {
                let ticks = ring_modern_duration(handle, Int32(index))
                let (normalized, overflow) = ticks.multipliedReportingOverflow(by: UInt64(info.timescale_den))
                guard !overflow, normalized <= UInt64(Int.max) else { throw EngineError.unsupported("프레임 시간 범위를 초과했어요.") }
                durations.append(Int(normalized))
            }
            self.handle = handle; self.format = info.format == 1 ? "avif" : "jxl"
            width = Int(info.width); height = Int(info.height); frameCount = Int(info.frame_count)
            loops = Int(info.loops); orientation = Int(info.orientation); timeScale = Int(info.timescale_num)
            durationTicks = durations; self.icc = icc; self.exif = exif; self.space = space
            isAnimated = info.is_animated != 0; hasAlpha = info.has_alpha != 0
        } catch { ring_modern_close(handle); throw error }
    }
    deinit { ring_modern_close(handle) }
    func frame(_ index: Int) throws -> CGImage {
        try Task.checkCancellation()
        guard index >= 0, index < frameCount else { throw EngineError.invalid("프레임 번호가 범위를 벗어났어요.") }
        var rgba = Data(count: width * height * 4), error = [CChar](repeating: 0, count: 512)
        let result = rgba.withUnsafeMutableBytes { bytes in
            ring_modern_frame(handle, Int32(index), bytes.bindMemory(to: UInt8.self).baseAddress,
                              bytes.count, &error, error.count)
        }
        try Task.checkCancellation()
        guard result == 1, let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw EngineError.io("AVIF/JPEG XL 프레임 읽기 실패: \(String(cString: error))")
        }
        return image
    }
    /// ImageIO parses EXIF through a small complete JPEG carrier, independent of codec availability.
    var properties: [CFString: Any] {
        var properties: [CFString: Any] = [:]
        if !exif.isEmpty, exif.count <= 65527 {
            let carrier = NSMutableData()
            if let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
               let image = ctx.makeImage(),
               let destination = CGImageDestinationCreateWithData(carrier, "public.jpeg" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) {
                    let payload = Data("Exif\0\0".utf8) + exif, length = payload.count + 2
                    var jpeg = Data([0xff, 0xd8, 0xff, 0xe1, UInt8(length >> 8), UInt8(length & 255)])
                    jpeg.append(payload); jpeg.append((carrier as Data).dropFirst(2))
                    if let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                       let parsed = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                        properties = parsed
                    }
                }
            }
        }
        properties[kCGImagePropertyPixelWidth] = width; properties[kCGImagePropertyPixelHeight] = height
        properties[kCGImagePropertyDepth] = 8; properties[kCGImagePropertyOrientation] = orientation
        properties[kCGImagePropertyHasAlpha] = hasAlpha
        return properties
    }
}

final class ModernImageWriter {
    private let handle: UnsafeMutableRawPointer
    private let width: Int, height: Int
    private var finished = false
    init(format: ImageFormat, width: Int, height: Int, frameCount: Int, timeScale: Int, loops: Int,
         icc: Data, exif: Data, quality: Int = 100, orientation: Int = 1, isAnimated: Bool? = nil) throws {
        try Task.checkCancellation()
        guard [.avif, .jxl].contains(format), width > 0, height > 0, width <= 65535, height <= 65535,
              Int64(width)*Int64(height) <= 52_000_000, frameCount > 0, frameCount <= 100000,
              timeScale > 0, timeScale <= Int(UInt32.max), loops >= 0, loops <= Int(Int32.max),
              (0...100).contains(quality), (1...8).contains(orientation) else {
            throw EngineError.invalid("AVIF/JPEG XL 인코딩 설정 범위 오류")
        }
        var info = RingModernInfo()
        info.format = format == .avif ? 1 : 2; info.width = Int32(width); info.height = Int32(height)
        info.depth = 8; info.has_alpha = 1; info.frame_count = Int32(frameCount); info.orientation = Int32(orientation)
        info.is_animated = (isAnimated ?? (frameCount > 1)) ? 1 : 0
        info.timescale_num = UInt32(timeScale); info.timescale_den = 1; info.loops = UInt32(loops)
        var error = [CChar](repeating: 0, count: 512)
        let handle = icc.withUnsafeBytes { profile in exif.withUnsafeBytes { metadata in
            ring_modern_encoder_create(&info, profile.bindMemory(to: UInt8.self).baseAddress, profile.count,
                metadata.bindMemory(to: UInt8.self).baseAddress, metadata.count,
                Int32(quality), Int32(ThermalPolicy.threads), &error, error.count)
        } }
        guard let handle else { throw EngineError.io("AVIF/JPEG XL 인코딩 시작 실패: \(String(cString: error))") }
        self.handle = handle; self.width = width; self.height = height
    }
    deinit { ring_modern_encoder_close(handle) }
    func add(_ image: CGImage, durationTicks: Int) throws {
        guard !finished, image.width == width, image.height == height, image.bitsPerComponent <= 8,
              image.colorSpace?.model == .rgb, durationTicks >= 0 else { throw EngineError.invalid("프레임 크기·깊이·시간 오류") }
        try addRGBA(ExternalCodecs.straightRGBA8(image), durationTicks: durationTicks)
    }
    func addRGBA(_ rgba: Data, durationTicks: Int) throws {
        try Task.checkCancellation()
        guard !finished, durationTicks >= 0, rgba.count == width*height*4 else { throw EngineError.invalid("RGBA 프레임 버퍼 오류") }
        var error = [CChar](repeating: 0, count: 512)
        let result = rgba.withUnsafeBytes { bytes in
            ring_modern_encoder_add(handle, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count,
                UInt64(durationTicks), &error, error.count)
        }
        try Task.checkCancellation()
        guard result == 1 else { throw EngineError.io("AVIF/JPEG XL 프레임 인코딩 실패: \(String(cString: error))") }
    }
    func finish() throws -> Data {
        try Task.checkCancellation()
        guard !finished else { throw EngineError.invalid("이미 완료된 인코더예요.") }
        finished = true
        var output: UnsafeMutablePointer<UInt8>?, size = 0, error = [CChar](repeating: 0, count: 512)
        let result = ring_modern_encoder_finish(handle, &output, &size, &error, error.count)
        defer { ring_modern_free(output) }
        try Task.checkCancellation()
        guard result == 1, let output, size > 0 else { throw EngineError.io("AVIF/JPEG XL 저장 실패: \(String(cString: error))") }
        return Data(bytes: output, count: size)
    }
}

enum ModernImageCodec {
    static func encode(_ image: CGImage, format: ImageFormat, icc: Data, exif: Data,
                       orientation: Int, quality: Int = 100) throws -> Data {
        let writer = try ModernImageWriter(format: format, width: image.width, height: image.height,
            frameCount: 1, timeScale: 1, loops: 1, icc: icc, exif: exif,
            quality: quality, orientation: orientation)
        try writer.add(image, durationTicks: 1)
        return try writer.finish()
    }
}

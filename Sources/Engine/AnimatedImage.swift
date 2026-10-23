import Foundation
import CoreGraphics
import ImageIO

/// Header-only inspection: an extension never decides whether a picture moves.
struct AnimatedImageInfo {
    let format: String
    let width: Int
    let height: Int
    let frameCount: Int
    let durationsMS: [Int]
    /// Total plays, matching WebP; zero means forever. GIF stores repeats after the first play.
    let loopCount: Int
    let orientation: Int
    var exactTicks: [Int]? = nil
    var timeScale: Int = 1000

    var duration: Double { Double((exactTicks ?? durationsMS).reduce(0, +)) / Double(timeScale) }
    var size: CGSize { orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height) }
    var summary: String { String(format: "%@ 움짤 · %.2f초 · %d프레임", format, duration, frameCount) }
    var editingIssue: String? {
        if frameCount > 10_000 { return "10,000프레임을 넘는 움짤은 아직 편집할 수 없어요." }
        if width < 1 || height < 1 || Int64(width) * Int64(height) > 52_000_000 { return "프레임 크기는 52MP 이하여야 해요." }
        if durationsMS.count != frameCount || durationsMS.contains(where: { $0 <= 0 || $0 > 0xffffff }) {
            return "재생 시간이 없거나 너무 긴 프레임이 있어요. 현재는 이 움짤의 재생 시간을 보존할 수 없어요."
        }
        if !(0...Int(UInt32.max)).contains(loopCount) { return "이 움짤의 반복 횟수를 보존할 수 없어요." }
        return nil
    }

    static func inspect(_ url: URL) -> AnimatedImageInfo? {
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe), ModernImageReader.sniff(data) != nil {
            guard let reader = try? ModernImageReader(data: data), reader.isAnimated else { return nil }
            return AnimatedImageInfo(format: reader.format.uppercased(), width: reader.width, height: reader.height,
                frameCount: reader.frameCount, durationsMS: reader.durationTicks.map { max(1, Int((Double($0)*1000/Double(reader.timeScale)).rounded())) },
                loopCount: reader.loops, orientation: reader.orientation, exactTicks: reader.durationTicks, timeScale: reader.timeScale)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return inspect(source)
    }

    static func inspect(_ source: CGImageSource) -> AnimatedImageInfo? {
        guard let type = CGImageSourceGetType(source) as String?, ["com.compuserve.gif", ImageFormat.webp.uti].contains(type),
              CGImageSourceGetCount(source) > 1 else { return nil }
        let gif = type == "com.compuserve.gif", count = CGImageSourceGetCount(source)
        let key = gif ? kCGImagePropertyGIFDictionary : kCGImagePropertyWebPDictionary
        let loopKey = gif ? kCGImagePropertyGIFLoopCount : kCGImagePropertyWebPLoopCount
        let delayKey = gif ? kCGImagePropertyGIFDelayTime : kCGImagePropertyWebPDelayTime
        let unclampedKey = gif ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyWebPUnclampedDelayTime
        let global = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let animation = global[key] as? [CFString: Any] ?? [:]
        let loops = animation[loopKey] as? Int
        let plays = gif ? loops.map { $0 == 0 ? 0 : $0 + 1 } ?? 1 : loops ?? 1
        let durations: [Int] = count <= 10_000 ? (0..<count).map { index in
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let frame = props[key] as? [CFString: Any] ?? [:]
            let seconds = frame[unclampedKey] as? Double ?? frame[delayKey] as? Double ?? 0
            return seconds.isFinite && seconds >= 0 && seconds <= 16_777.215 ? Int((seconds * 1000).rounded()) : 0
        } : []
        return AnimatedImageInfo(format: gif ? "GIF" : "WEBP", width: first[kCGImagePropertyPixelWidth] as? Int ?? 0,
                                 height: first[kCGImagePropertyPixelHeight] as? Int ?? 0, frameCount: count,
                                 durationsMS: durations, loopCount: plays, orientation: first[kCGImagePropertyOrientation] as? Int ?? 1)
    }

    func time(at frame: Int) -> Double { Double((exactTicks ?? durationsMS).prefix(max(0, frame)).reduce(0, +)) / Double(timeScale) }
}

/// One composited frame at a time: ImageIO for GIF, libwebp's animation decoder
/// for WebP, whose partial frames must be blended onto the preceding canvas.
final class AnimatedImageDecoder {
    private var source: CGImageSource?
    private var modern: ModernImageReader?
    private let url: URL
    private var lastIndex = -1
    private var previewMode: Bool?
    private var webpDecoder: UnsafeMutableRawPointer?
    private var webpSpace: CGColorSpace?
    let info: AnimatedImageInfo
    init(_ url: URL) throws {
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe), ModernImageReader.sniff(data) != nil {
            let reader = try ModernImageReader(data: data)
            guard reader.isAnimated, let info = AnimatedImageInfo.inspect(url) else { throw EngineError.invalid("정지 이미지예요. 이미지 편집 경로를 이용해 주세요.") }
            if let issue = info.editingIssue { throw EngineError.unsupported(issue) }
            self.url = url; self.info = info; self.modern = reader; self.source = nil
            return
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let info = AnimatedImageInfo.inspect(source) else { throw EngineError.invalid("움직이는 GIF 또는 WebP를 선택해 주세요.") }
        if let issue = info.editingIssue { throw EngineError.unsupported(issue) }
        guard CGImageSourceGetStatus(source) == .statusComplete else { throw EngineError.invalid("움짤 파일이 손상되었거나 끝까지 읽히지 않았어요.") }
        self.source = source; self.info = info; self.url = url
        if info.format == "WEBP" {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            var width: Int32 = 0, height: Int32 = 0, frames: Int32 = 0, loops: Int32 = 0
            let native = data.withUnsafeBytes {
                ring_webp_image_decoder_create($0.bindMemory(to: UInt8.self).baseAddress, data.count, Int32(ThermalPolicy.threads), &width, &height, &frames, &loops)
            }
            guard let native else { throw EngineError.invalid("움직이는 WebP를 읽을 수 없어요.") }
            guard width == info.width, height == info.height, frames == info.frameCount, loops == info.loopCount else {
                ring_webp_image_decoder_destroy(native)
                throw EngineError.invalid("WebP의 프레임·반복 정보를 일관되게 읽을 수 없어요.")
            }
            webpDecoder = native
            webpSpace = CGImageSourceCreateImageAtIndex(source, 0, nil)?.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        }
    }
    deinit { ring_webp_image_decoder_destroy(webpDecoder) }
    func frame(_ index: Int, preview: Bool = false) throws -> CGImage {
        try Task.checkCancellation()
        guard (0..<info.frameCount).contains(index) else { throw EngineError.invalid("프레임 번호를 확인해 주세요.") }
        if let modern {
            let image = try PDFEngine.oriented(modern.frame(index), info.orientation)
            return preview ? try ImageResampler.fit(image, maxDimension: 840) : image
        }
        if let native = webpDecoder { return try webpFrame(index, preview: preview, native: native) }
        // Start GIF composition from a fresh canvas when seeking backwards.
        if index <= lastIndex || (previewMode != nil && previewMode != preview) {
            guard let fresh = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw EngineError.io("움짤을 다시 읽을 수 없어요.")
            }
            source = fresh
            lastIndex = -1
        }
        previewMode = preview
        func decode(_ frame: Int) -> CGImage? {
            if preview {
                return CGImageSourceCreateThumbnailAtIndex(source!, frame, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 840, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            }
            return CGImageSourceCreateImageAtIndex(source!, frame, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        // Disposal can depend on earlier frames. Decode intervening frames
        // without retaining their rasters when seeking forwards.
        for skipped in (lastIndex + 1)..<index {
            try Task.checkCancellation()
            try autoreleasepool {
                guard decode(skipped) != nil else { throw EngineError.invalid("\(skipped + 1)번째 프레임을 읽을 수 없어요.") }
            }
            lastIndex = skipped
        }
        let decoded = decode(index)
        lastIndex = index
        guard let decoded, decoded.bitsPerComponent <= 8, let space = decoded.colorSpace,
              !space.isHDR(), !CGColorSpaceUsesExtendedRange(space) else { throw EngineError.unsupported("이 움짤 프레임을 보존해서 읽을 수 없어요.") }
        let image: CGImage
        if space.model == .indexed || space.model == .monochrome {
            let base = space.model == .indexed ? space.baseColorSpace : space
            let target = base?.model == .rgb ? base! : CGColorSpace(name: CGColorSpace.sRGB)!
            let context = try PDFEngine.bitmap(width: decoded.width, height: decoded.height, space: target)
            context.setBlendMode(.copy); context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
            guard let expanded = context.makeImage() else { throw EngineError.io("움짤 팔레트를 펼칠 수 없어요.") }
            image = expanded
        } else {
            guard space.model == .rgb else { throw EngineError.unsupported("RGB 움짤만 편집할 수 있어요.") }
            image = decoded
        }
        if preview { return image }
        guard image.width == info.width, image.height == info.height else { throw EngineError.unsupported("프레임 합성이 필요한 이 움짤은 아직 안전하게 편집할 수 없어요.") }
        return try PDFEngine.oriented(image, info.orientation)
    }

    private func webpFrame(_ index: Int, preview: Bool, native: UnsafeMutableRawPointer) throws -> CGImage {
        if index <= lastIndex { ring_webp_image_decoder_reset(native); lastIndex = -1 }
        var pixels: UnsafePointer<UInt8>?
        for frame in (lastIndex + 1)...index {
            try Task.checkCancellation()
            guard ring_webp_image_decoder_next(native, &pixels) == 1 else { throw EngineError.invalid("\(frame + 1)번째 WebP 프레임을 읽을 수 없어요.") }
            lastIndex = frame
        }
        guard let pixels, let space = webpSpace, space.model == .rgb, !space.isHDR(), !CGColorSpaceUsesExtendedRange(space) else {
            throw EngineError.unsupported("이 WebP의 색상 프로필을 보존할 수 없어요.")
        }
        // The native buffer changes on the next decode; give every CGImage its
        // own immutable bytes so scrubbing cannot mutate a displayed frame.
        let data = Data(bytes: pixels, count: info.width * info.height * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: info.width, height: info.height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: info.width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw EngineError.io("WebP 프레임 버퍼 오류") }
        let oriented = try PDFEngine.oriented(image, info.orientation)
        return preview ? try ImageResampler.fit(oriented, maxDimension: 840) : oriented
    }
}

enum AnimatedImageEdit {
    case webp, crop(CGRect), resize(width: Int, height: Int), speed(Double), frame(Int, format: ImageFormat = .png)
    /// Backend-only output selection, with an optional frame range and the same crop/resize transforms.
    indirect case output(format: AnimationFormat, edit: AnimatedImageEdit, frames: Range<Int>? = nil)
    var fileExtension: String {
        if case .frame(_, let format) = self { return format.rawValue }
        if case .output(let format, _, _) = self { return format.rawValue }
        return "webp"
    }
}

enum AnimatedImageEngine {
    static func retimedDurations(_ durations: [Int], rate: Double) throws -> [Int] {
        guard rate.isFinite, (0.25...4).contains(rate) else { throw EngineError.invalid("재생 속도는 0.25~4배여야 해요.") }
        var source = 0, previous = 0
        return try durations.map { duration in
            source += duration
            let end = Int((Double(source) / rate).rounded()), delay = end - previous
            guard (1...0xffffff).contains(delay) else { throw EngineError.invalid("이 속도에서는 프레임 재생 시간을 보존할 수 없어요.") }
            previous = end
            return delay
        }
    }

    /// ANMF duration is a 24-bit little-endian value at byte 12 of its header.
    /// Keep the compressed frames, their blending/disposal, and all metadata intact.
    static func retimeWebP(_ input: Data, durations: [Int]) throws -> Data {
        var data = input
        try data.withUnsafeMutableBytes { raw in
            let b = raw.bindMemory(to: UInt8.self), n = b.count
            func u32(_ p: Int) -> Int { (0..<4).reduce(0) { $0 | Int(b[p+$1]) << ($1*8) } }
            guard n >= 12, Array(b[0..<4]) == Array("RIFF".utf8), Array(b[8..<12]) == Array("WEBP".utf8), u32(4) == n-8 else {
                throw EngineError.invalid("WebP 컨테이너 길이가 올바르지 않아요.")
            }
            var p = 12, frame = 0
            while p + 8 <= n {
                let size = u32(p+4), start = p+8
                guard size <= n-start else { throw EngineError.invalid("WebP 청크가 잘렸어요.") }
                if Array(b[p..<p+4]) == Array("ANMF".utf8) {
                    guard size >= 16, frame < durations.count, (1...0xffffff).contains(durations[frame]) else {
                        throw EngineError.invalid("WebP 프레임 시간을 바꿀 수 없어요.")
                    }
                    for k in 0..<3 { b[start+12+k] = UInt8((durations[frame] >> (k*8)) & 255) }
                    frame += 1
                }
                p = start+size+(size & 1)
            }
            guard p == n, frame == durations.count else { throw EngineError.invalid("WebP 프레임 수가 맞지 않아요.") }
        }
        return data
    }

    static func transform(_ image: CGImage, edit: AnimatedImageEdit) throws -> CGImage {
        switch edit {
        case .crop(let region):
            let rect = try ImageEdits.rawRect(region, image: image, orientation: 1)
            guard let result = image.cropping(to: rect) else { throw EngineError.invalid("자르기 범위를 확인해 주세요.") }
            return result
        case .resize(let width, let height):
            let resized = try ImageResampler.resize(image, width: width, height: height)
            // vImage resamples premultiplied components independently. Complete
            // that resize with one straight-RGBA8 quantization, the WebP raster,
            // before checking that the lossless encoder preserves it exactly.
            let rgba = try ExternalCodecs.straightRGBA8(resized)
            guard let provider = CGDataProvider(data: rgba as CFData),
                  let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                      bytesPerRow: width * 4, space: resized.colorSpace!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                throw EngineError.io("크기 조절한 프레임의 픽셀 버퍼를 만들 수 없어요.")
            }
            return result
        case .output(_, let edit, _): return try transform(image, edit: edit)
        case .webp, .speed, .frame: return image
        }
    }

    static func run(_ source: URL, to output: URL, edit: AnimatedImageEdit) throws -> String {
        if case .output(let format, let transform, let range) = edit {
            guard format.isModern else { throw EngineError.unsupported("이 출력 선택 경로는 AVIF/JPEG XL용이에요. 기존 WebP 편집은 해당 작업을 사용해 주세요.") }
            return try modern(source, to: output, format: format, edit: transform, frames: range)
        }
        let decoder = try AnimatedImageDecoder(source), info = decoder.info
        if case .frame(let index, let format) = edit {
            guard [.png, .jpg, .webp, .avif, .jxl].contains(format) else { throw EngineError.invalid("지원하지 않는 한 장 저장 형식이에요.") }
            let image = try decoder.frame(index)
            let props: [CFString: Any] = [kCGImagePropertyOrientation: 1]
            if format == .png {
                try ImageCodec.write(image, properties: props, format: .png, to: output)
                try ImageCodec.verify(image, properties: props, output: output, exact: true)
            } else {
                let intermediate = output.deletingLastPathComponent().appendingPathComponent("frame-" + UUID().uuidString + ".tiff")
                defer { try? FileManager.default.removeItem(at: intermediate) }
                let raster = format == .jpg ? try ImageCodec.flattenWhite(image) : image
                // TIFF keeps this decoded 8-bit raster and alpha without PNG's
                // deliberate 16-bit alpha promotion in the shared writer.
                try ImageCodec.write(raster, properties: props, format: .tiff, to: intermediate)
                if format == .webp || format.isModern { _ = try ImageCodec.convert(intermediate, to: output, format: format) }
                else { _ = try TargetSizeCodec.encode(intermediate, to: output, format: .jpg, intent: .quality(1)) }
            }
            return "\(index + 1)번째 프레임 · \(format.rawValue.uppercased()) · \(format == .jpg ? "최고 품질·투명 영역은 흰색" : "무손실·저장 픽셀 일치")"
        }
        if let ticks = info.exactTicks, ticks.contains(where: { ($0*1000) % info.timeScale != 0 }) {
            throw EngineError.unsupported("WebP의 밀리초 단위로 원본 프레임 시각을 정확히 보존할 수 없어요. AVIF 또는 JPEG XL로 저장해 주세요.")
        }
        guard info.loopCount <= 65535 else { throw EngineError.unsupported("원본 반복 횟수가 WebP 한도를 넘어요. AVIF 또는 JPEG XL로 저장해 주세요.") }
        if case .webp = edit, info.format == "WEBP" {
            try FileIntegrity.copy(source, to: output)
            return "움직이는 WebP · 원본 바이트 그대로"
        }
        let durations: [Int]
        if case .speed(let rate) = edit { durations = try retimedDurations(info.durationsMS, rate: rate) }
        else { durations = info.durationsMS }
        if case .speed = edit, info.format == "WEBP" {
            try retimeWebP(Data(contentsOf: source), durations: durations).write(to: output)
            return try verify(source, output: output, edit: edit, info: info, durations: durations)
        }
        let first = try autoreleasepool { try transform(decoder.frame(0), edit: edit) }
        guard first.width <= 16383, first.height <= 16383 else { throw EngineError.unsupported("WebP 크기는 가로·세로 16,383px 이하여야 해요.") }
        let icc = first.colorSpace?.copyICCData() as Data? ?? Data()
        let mux = icc.withUnsafeBytes {
            ring_webp_lossless_mux_create(Int32(first.width), Int32(first.height), Int32(info.loopCount), $0.bindMemory(to: UInt8.self).baseAddress, icc.count)
        }
        guard let mux else { throw EngineError.io("움짤 저장을 시작하지 못했어요.") }
        defer { ring_webp_mux_destroy(mux) }
        var encodedBytes = 0
        // Bound the extra delta reference; large canvases retain the full-frame
        // lossless path instead of allocating an unbounded additional raster.
        var previousRGBA: Data?
        let keepReference = first.width*first.height*4 <= 32*1024*1024
        for index in 0..<info.frameCount {
            try Task.checkCancellation()
            try autoreleasepool {
                let image = try transform(decoder.frame(index), edit: edit)
                guard image.colorSpace?.copyICCData() == first.colorSpace?.copyICCData() else { throw EngineError.unsupported("프레임마다 색상 프로필이 달라요. 보존을 확인할 수 없어 저장하지 않아요.") }
                let rgba = try ExternalCodecs.straightRGBA8(image)
                var bytes = 0
                let ok = rgba.withUnsafeBytes { current in
                    (previousRGBA ?? Data()).withUnsafeBytes { previous in
                        ring_webp_lossless_mux_add_delta(mux, current.bindMemory(to: UInt8.self).baseAddress!,
                            previous.isEmpty ? nil:previous.bindMemory(to: UInt8.self).baseAddress, Int32(image.width), Int32(image.height),
                            Int32(durations[index]), Int32(ThermalPolicy.threads), &bytes)
                    }
                }
                if keepReference { previousRGBA = rgba }
                guard ok == 1 else { throw EngineError.io("\(index + 1)번째 프레임을 저장하지 못했어요.") }
                encodedBytes += bytes
                guard encodedBytes <= 256 * 1024 * 1024 else { throw EngineError.unsupported("움짤 결과가 256MB를 넘어요. 크기나 자를 영역을 줄여 주세요.") }
            }
            EngineProgress.report(0.05 + 0.55 * Double(index + 1) / Double(info.frameCount))
        }
        var buffer: UnsafeMutablePointer<UInt8>?, count = 0
        let ok = ring_webp_mux_finish(mux, &buffer, &count)
        defer { ring_buffer_free(buffer) }
        guard ok == 1, let buffer else { throw EngineError.io("움짤 저장을 마무리하지 못했어요.") }
        try Task.checkCancellation()
        try Data(bytes: buffer, count: count).write(to: output)
        return try verify(source, output: output, edit: edit, info: info, durations: durations)
    }

    private static func modern(_ source: URL, to output: URL, format: AnimationFormat,
                               edit: AnimatedImageEdit, frames: Range<Int>?) throws -> String {
        let decoder = try AnimatedImageDecoder(source), info = decoder.info
        let range = frames ?? 0..<info.frameCount
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= info.frameCount else { throw EngineError.invalid("저장할 프레임 구간을 확인해 주세요.") }
        if case .frame = edit { throw EngineError.invalid("한 장 저장에는 frame 작업을 사용해 주세요.") }
        if case .output = edit { throw EngineError.invalid("중첩된 출력 형식은 지원하지 않아요.") }
        var ticks = Array((info.exactTicks ?? info.durationsMS)[range])
        if case .speed(let rate) = edit {
            guard rate.isFinite, (0.25...4).contains(rate) else { throw EngineError.invalid("재생 속도 범위 오류") }
            var sum = 0, end = 0
            ticks = try ticks.map { value in
                sum += value; let next = Int((Double(sum)/rate).rounded()); defer { end = next }
                guard next > end else { throw EngineError.unsupported("원본 시간 단위로 이 재생 속도를 보존할 수 없어요.") }
                return next-end
            }
        }
        let first = try transform(decoder.frame(range.lowerBound), edit: edit)
        let icc = first.colorSpace?.copyICCData() as Data? ?? Data()
        var exif = Data()
        if ["AVIF", "JXL"].contains(info.format) {
            let original = try ModernImageReader(source)
            if !original.exif.isEmpty {
                let carrier = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(carrier, ImageFormat.tiff.uti as CFString, 1, nil) else { throw EngineError.io("메타데이터 직렬화 실패") }
                let tiny = try PDFEngine.bitmap(width: 1, height: 1, space: first.colorSpace!)
                var properties = original.properties; properties[kCGImagePropertyOrientation] = 1
                CGImageDestinationAddImage(destination, tiny.makeImage()!, properties as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw EngineError.io("메타데이터 직렬화 실패") }
                exif = try TIFFMetadataEnvelope.sanitize(carrier as Data, width: first.width, height: first.height)
            }
        }
        let writer = try ModernImageWriter(format: format == .avif ? .avif : .jxl, width: first.width, height: first.height,
            frameCount: range.count, timeScale: info.timeScale, loops: info.loopCount, icc: icc, exif: exif, quality: 100, isAnimated: true)
        for (offset, index) in range.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let frame = try transform(decoder.frame(index), edit: edit)
                guard frame.colorSpace?.copyICCData() == first.colorSpace?.copyICCData() else { throw EngineError.unsupported("프레임별 색상 프로필이 달라요.") }
                try writer.add(frame, durationTicks: ticks[offset])
            }
            EngineProgress.report(0.05+0.55*Double(offset+1)/Double(range.count))
        }
        let bytes = try writer.finish(), result = try ModernImageReader(data: bytes)
        guard result.isAnimated, result.frameCount == range.count, result.timeScale == info.timeScale,
              result.durationTicks == ticks, result.loops == info.loopCount else { throw EngineError.quality("움짤 프레임·시각·반복 횟수가 달라요.") }
        for (offset, index) in range.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let reference = try transform(decoder.frame(index), edit: edit), actual = try result.frame(offset)
                guard actual.colorSpace?.copyICCData() == reference.colorSpace?.copyICCData(),
                      try PixelCheck.compare(reference, actual).exact else { throw EngineError.quality("움짤 픽셀·투명도·색상 보존 검증 실패") }
            }
            EngineProgress.report(0.60+0.30*Double(offset+1)/Double(range.count))
        }
        try Task.checkCancellation(); try bytes.write(to: output)
        return "\(format.rawValue.uppercased()) 무손실 움짤 · \(range.count)프레임 · 픽셀·시각·반복 검증"
    }

    private static func verify(_ source: URL, output: URL, edit: AnimatedImageEdit, info: AnimatedImageInfo, durations: [Int]) throws -> String {
        let written = try AnimatedImageDecoder(output)
        let referenceDecoder = try AnimatedImageDecoder(source)
        guard written.info.frameCount == info.frameCount, written.info.durationsMS == durations,
              written.info.loopCount == info.loopCount else { throw EngineError.quality("프레임·재생 시간·반복 보존 검사 실패. 결과를 저장하지 않았어요.") }
        for index in 0..<info.frameCount {
            try Task.checkCancellation()
            try autoreleasepool {
                let reference = try transform(referenceDecoder.frame(index), edit: edit), actual = try written.frame(index)
                guard actual.colorSpace?.copyICCData() == reference.colorSpace?.copyICCData(),
                      try PixelCheck.compare(reference, actual).exact else { throw EngineError.quality("\(index + 1)번째 프레임의 픽셀·투명도·색상 보존 검사 실패. 결과를 저장하지 않았어요.") }
            }
            EngineProgress.report(0.60 + 0.30 * Double(index + 1) / Double(info.frameCount))
        }
        return "움직이는 WebP 무손실 · \(info.frameCount)프레임 · 재생 시간·반복·픽셀 일치"
    }
}

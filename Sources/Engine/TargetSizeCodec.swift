import Foundation
import CoreGraphics
import ImageIO

enum TargetSizeCodec {
    static func encode(_ source: URL, to output: URL, format: ImageFormat, intent: CompressionIntent) throws -> String {
        if intent == .lossless {
            let input=try ImageInput(source)
            if [.jpg,.heic].contains(format),input.type != format.uti { throw EngineError.unsupported("JPEG/HEIC 교차 변환에는 품질을 명시해 주세요. 무손실 인코딩을 보장할 수 없어요.") }
            return try ImageCodec.convert(source, to: output, format: format)
        }
        let input = try ImageInput(source)
        guard [.jpg, .webp, .heic, .png].contains(format) else { throw EngineError.unsupported("이 형식은 목표 용량 압축을 지원하지 않아요.") }
        let target: Int64?
        let quality: Double
        switch intent {
        case .lossless: fatalError("handled above")
        case .quality(let q):
            guard q.isFinite, (0...1).contains(q) else { throw EngineError.invalid("품질은 0~1 범위여야 해요.") }
            quality = q; target = nil
        case .targetBytes(let bytes):
            guard bytes > 0, bytes <= Int64(Int.max) else { throw EngineError.invalid("목표 바이트 범위를 확인해 주세요.") }
            quality = 1; target = bytes
        }
        guard input.image.bitsPerComponent <= 8 || format == .png else { throw EngineError.unsupported("손실 압축의 16비트 입력은 먼저 명시적으로 8비트로 변환해 주세요.") }
        let hasAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(input.image.alphaInfo)
        let image = format == .jpg && hasAlpha ? try ImageCodec.flattenWhite(input.image) : input.image
        let rgba: Data
        if [.jpg, .webp].contains(format) {
            guard image.colorSpace?.model == .rgb else { throw EngineError.unsupported("JPEG/WebP 압축은 RGB 입력을 사용해 주세요.") }
            guard format != .webp || max(image.width, image.height) <= 16383 else { throw EngineError.unsupported("WebP 최대 크기는 16,383px예요.") }
            rgba = try ExternalCodecs.straightRGBA8(image)
        } else { rgba = Data() }
        let icc = image.colorSpace?.copyICCData() as Data? ?? Data()
        let exif = [.jpg, .webp].contains(format) ? try MetadataEnvelope.exif(source, input: input) : Data()
        func candidate(_ q: Int, nativeTarget: Int = 0) throws -> Data {
            try Task.checkCancellation()
            if format == .jpg || format == .webp {
                return try memoryEncode(rgba, width: image.width, height: image.height, icc: icc, exif: exif,
                                        webp: format == .webp, quality: q, target: nativeTarget)
            }
            let memory = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(memory, format.uti as CFString, 1, nil) else { throw EngineError.unsupported("이 OS에서 인코딩을 지원하지 않아요.") }
            var properties = input.properties
            properties[kCGImageDestinationLossyCompressionQuality] = Double(q) / 100
            properties[kCGImageDestinationEmbedThumbnail] = false
            CGImageDestinationAddImage(dest, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw EngineError.io("메모리 인코딩 실패") }
            return memory as Data
        }
        let bytes: Data
        if let target {
            if format == .png {
                // PNG keeps all pixels; an impossible target must never silently lower precision.
                let lossless = try candidate(100)
                guard lossless.count <= target else { throw EngineError.quality("PNG 무손실 결과가 목표 용량보다 커요. JPEG/WebP/HEIC를 선택해 주세요.") }
                bytes = lossless
            } else {
                var best: Data?
                if format == .webp {
                    let overhead = icc.count + exif.count + 64
                    let hint = max(1, min(Int(Int32.max), Int(target) - overhead))
                    let native = try candidate(100, nativeTarget: hint)
                    if native.count <= target { best = native }
                }
                var low = 0, high = 100
                while low <= high {
                    let mid = (low + high) / 2
                    let trial = try candidate(mid)
                    if trial.count <= target { best = trial; low = mid + 1 }
                    else { high = mid - 1 }
                }
                guard let best else { throw EngineError.quality("최저 품질에서도 목표 용량을 충족할 수 없어요. 목표 용량이나 크기를 조절해 주세요.") }
                bytes = best
            }
        } else { bytes = try candidate(Int((quality * 100).rounded())) }
        guard !bytes.isEmpty, target == nil || Int64(bytes.count) <= target! else { throw EngineError.quality("목표 용량 검사 실패") }
        try bytes.write(to: output)
        let written = try ImageInput(output)
        guard written.type == format.uti, written.image.width == image.width, written.image.height == image.height,
              written.orientation == input.orientation, written.image.colorSpace?.copyICCData() == image.colorSpace?.copyICCData() else { throw EngineError.quality("압축 결과의 크기·방향·ICC 검증 실패") }
        if hasAlpha && format != .jpg {
            // Verify alpha values independently of intentionally lossy RGB samples.
            let a = try ExternalCodecs.straightRGBA8(image), b = try ExternalCodecs.straightRGBA8(written.image)
            guard stride(from: 3, to: a.count, by: 4).allSatisfy({ a[$0] == b[$0] }) else { throw EngineError.quality("알파 채널 보존 검사 실패") }
        }
        return "\(format.rawValue.uppercased()) · \(bytes.count)바이트" + (target == nil ? "" : " · 목표 이하 검증") + (hasAlpha && format == .jpg ? " · 흰 배경 합성" : "")
    }

    static func memoryEncode(_ rgba: Data, width: Int, height: Int, icc: Data = Data(), exif: Data = Data(), webp: Bool = false, quality: Int = 85, target: Int = 0) throws -> Data {
        var buffer: UnsafeMutablePointer<UInt8>?, count = 0, error = [CChar](repeating: 0, count: 512)
        let ok = rgba.withUnsafeBytes { pixels in icc.withUnsafeBytes { profile in exif.withUnsafeBytes { metadata in
            ring_image_encode_memory(pixels.bindMemory(to: UInt8.self).baseAddress!, Int32(width), Int32(height), Int32(width * 4),
                profile.bindMemory(to: UInt8.self).baseAddress, icc.count, metadata.bindMemory(to: UInt8.self).baseAddress, exif.count,
                webp ? 1 : 0, Int32(quality), Int32(target), Int32(ThermalPolicy.threads), &buffer, &count, &error, error.count)
        } } }
        defer { ring_buffer_free(buffer) }
        guard ok == 1, let buffer, count > 0 else { throw EngineError.io("메모리 인코딩 실패: \(String(cString: error))") }
        return Data(bytes: buffer, count: count)
    }
}

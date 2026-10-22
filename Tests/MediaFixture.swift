import Foundation
import AVFoundation

/// Deterministic local inputs shared by the VFR checks and resource benchmark.
enum MediaFixture {
    static func write(_ url: URL, codec: AVVideoCodecType = .h264, width: Int = 320, height: Int = 180,
                      times: [Double], duration: Double, transform: CGAffineTransform = .identity,
                      colorProperties: [String: Any] = [:]) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mov" ? .mov : .mp4)
        var settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height]
        if codec == .h264 || codec == .hevc {
            settings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: width * height * 6]
        }
        if !colorProperties.isEmpty { settings[AVVideoColorPropertiesKey] = colorProperties }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        input.mediaTimeScale = 60000
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        guard writer.canAdd(input) else { throw EngineError.io("fixture input \(codec.rawValue)") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EngineError.io("fixture start") }
        writer.startSession(atSourceTime: .zero)
        for (index, time) in times.enumerated() {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? EngineError.io("fixture writer failed") }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            try autoreleasepool {
                var pixel: CVPixelBuffer?
                guard let pool = adaptor.pixelBufferPool,
                      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else {
                    throw EngineError.io("fixture buffer")
                }
                CVPixelBufferLockBaseAddress(pixel, [])
                defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
                let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
                let row = CVPixelBufferGetBytesPerRow(pixel)
                for y in 0..<height { for x in 0..<width {
                    let p = y * row + x * 4, shift = index * 11
                    bytes[p] = UInt8((x + shift) % 256)
                    bytes[p + 1] = UInt8((y * 2 + shift) % 256)
                    bytes[p + 2] = UInt8((x + y + shift) % 256)
                    bytes[p + 3] = 255
                } }
                guard adaptor.append(pixel, withPresentationTime: CMTime(seconds: time, preferredTimescale: 60000)) else {
                    throw writer.error ?? EngineError.io("fixture append")
                }
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60000))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? EngineError.io("fixture finish") }
    }
}

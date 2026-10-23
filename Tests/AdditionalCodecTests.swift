import Foundation
import AVFoundation
import CryptoKit

@main struct AdditionalCodecTests {
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw EngineError.quality("TEST: " + message) }
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ring-extra-codecs-"+UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mp4")
        let times = [0.0,0.033,0.077,0.12,0.2,0.21,0.3,0.39]
        try await MediaFixture.write(source, width: 128, height: 96, times: times, duration: 0.45,
            colorProperties: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2], bitrate: 2_000_000)
        let original = SHA256.hash(data: try Data(contentsOf: source))
        try require(SoftwareVideo.isEncoderFailure(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.encoderTemporarilyUnavailable.rawValue)), "real encoder failure permits fallback")
        for code in [AVError.Code.failedToLoadSampleData.rawValue, AVError.Code.segmentStartedWithNonSyncSample.rawValue] {
            try require(!SoftwareVideo.isEncoderFailure(NSError(domain: AVFoundationErrorDomain, code: code)), "damaged sample never encoder fallback")
        }
        for codec in [VideoCodec.h264, .hevc, .av1] {
            let output = root.appendingPathComponent("software-\(codec).mp4")
            try SoftwareVideo.encode(source, to: output, codec: codec, container: .mp4, bitrate: 2_000_000)
            try SoftwareVideo.verify(source, output, codec: codec, audio: .preserve)
            let quality = try SoftwareVideo.compare(source, output, duration: 0.45)
            try require(quality.acceptable, "unchanged final quality gate: \(codec) \(quality.summary)")
            print("PASS bundled software", codec, quality.summary)
        }
        for container in [VideoContainer.mp4, .webm] {
            let result = try await RingEngine.shared.run(.init(source: source,
                operation: .video(.convert(.init(container: container, codec: .av1)))))
            try require(result.url.pathExtension == container.rawValue, "published actual extension")
            let info = try SoftwareVideo.inspect(result.url, allFrames: true)
            try require(info.frame_count == times.count && info.video_codec == 3, "real AV1 reopen")
            print("PASS AV1 transaction", container)
        }
        for format in [AnimationFormat.avif, .jxl] {
            let options = AnimationOptions(format: format, fps: 30, maxDimension: 128)
            let result = try await RingEngine.shared.run(.init(source: source, operation: .video(.animation(options))))
            let decoded = try AnimatedImageDecoder(result.url)
            try require(decoded.info.frameCount == times.count, "video animation displayed frames")
            try require(decoded.info.exactTicks != nil, "native timing retained")
            let cropped = try await RingEngine.shared.run(.init(source: result.url, operation: .animatedImage(
                .output(format: format, edit: .crop(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)), frames: 1..<4))))
            let crop = try AnimatedImageDecoder(cropped.url)
            try require(crop.info.frameCount == 3 && crop.info.size.width == 64 && crop.info.size.height == 48, "animation crop/trim")
            let resized = try await RingEngine.shared.run(.init(source: result.url, operation: .animatedImage(
                .output(format: format, edit: .resize(width: 64, height: 48)))))
            let reopened = try AnimatedImageDecoder(resized.url)
            try require(reopened.info.frameCount == times.count && reopened.info.size.width == 64, "animation resize/reopen")
            let still = try await RingEngine.shared.run(.init(source: result.url, operation: .animatedImage(.frame(1, format: format == .avif ? .avif : .jxl))))
            try require(AnimatedImageInfo.inspect(still.url) == nil && (try ImageInput(still.url)).image.width == 128, "same extension still/animation sniff")
            print("PASS video/animation/crop/trim/resize/frame", format)
        }
        let pcmURL = root.appendingPathComponent("audio.caf")
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 9600)!
        pcm.frameLength = pcm.frameCapacity
        for i in 0..<Int(pcm.frameLength) { pcm.floatChannelData![0][i] = Float(0.06*sin(Double(i)*2*Double.pi*440/48000)) }
        do { let file = try AVAudioFile(forWriting: pcmURL, settings: audioFormat.settings); try file.write(from: pcm) }
        let m4a = root.appendingPathComponent("audio.m4a")
        let audioExport = AVAssetExportSession(asset: AVURLAsset(url: pcmURL), presetName: AVAssetExportPresetAppleM4A)!
        try await audioExport.export(to: m4a, as: .m4a)
        let composition = AVMutableComposition(), videoAsset = AVURLAsset(url: source), audioAsset = AVURLAsset(url: m4a)
        let videoTrack = try await videoAsset.loadTracks(withMediaType: .video)[0]
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio)[0]
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(
            CMTimeRange(start: .zero, duration: CMTime(seconds: 0.45, preferredTimescale: 60000)), of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(
            CMTimeRange(start: .zero, duration: CMTime(seconds: 0.2, preferredTimescale: 60000)), of: audioTrack,
            at: CMTime(seconds: 0.1, preferredTimescale: 60000))
        let soundVideo = root.appendingPathComponent("sound.mov")
        try await AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!.export(to: soundVideo, as: .mov)
        let availability = try SoftwareVideo.availability(soundVideo, container: .webm)
        try require(availability.audioConversionRequired, "AAC WebM requires explicit audio opt-in")
        let refused = root.appendingPathComponent("refused.webm")
        do {
            _ = try await MediaEngine.convertVideo(soundVideo, to: refused, options: .init(container: .webm, codec: .av1))
            throw EngineError.quality("TEST: silently converted AAC")
        } catch EngineError.unsupported { }
        try require(!FileManager.default.fileExists(atPath: refused.path), "no result without opt-in")
        let soundResult = try await RingEngine.shared.run(.init(source: soundVideo, operation: .video(.convert(
            .init(container: .webm, codec: .av1, audioPolicy: .convertToOpus)))))
        try SoftwareVideo.verify(soundVideo, soundResult.url, codec: .av1, audio: .convertToOpus)
        print("PASS WebM AAC consent, Opus conversion, delayed audio sync")
        try require(SHA256.hash(data: try Data(contentsOf: source)) == original, "original unchanged")
        let cancelled = Task {
            try Task.checkCancellation()
            try SoftwareVideo.encode(source, to: root.appendingPathComponent("cancelled.mp4"), codec: .av1, container: .mp4, bitrate: 1_000_000)
        }
        cancelled.cancel()
        do { try await cancelled.value; throw EngineError.quality("TEST: cancellation accepted") }
        catch is CancellationError { print("PASS cooperative cancellation") }
        print("PASS additional codec backend flows")
    }
}

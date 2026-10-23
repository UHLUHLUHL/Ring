import Foundation
import AVFoundation
import VideoToolbox
import CoreGraphics

extension AnimationPlan {
    /// Read compressed sample metadata only. Matching the source FPS means
    /// retain its displayed frames, including VFR and short boundary frames.
    static func source(asset: AVAsset, start: Double, duration: Double,
                       fps: Double, format: AnimationFormat) async throws -> AnimationPlan {
        let keepNativeTiming: Bool
        if format.isModern { keepNativeTiming = true }
        else { keepNativeTiming = try await MediaEngine.sourceFrameRate(asset).map { abs($0-fps) < 0.005 } == true }
        guard keepNativeTiming,
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            return AnimationPlan(duration: duration, fps: fps, format: format)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError.unsupported("원본 프레임 시각을 읽을 수 없어요.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EngineError.io("프레임 시각 읽기 실패") }
        defer { reader.cancelReading() }
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            if (attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay as String] as? NSNumber)?.boolValue == true { continue }
            let time = CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds
            guard time.isFinite else { throw EngineError.invalid("유효하지 않은 영상 프레임 시각") }
            // Retain one frame preceding the trim start; compressed samples
            // arrive in decode order, so sort before selecting displayed frames.
            if time < start + duration { times.append(time) }
        }
        guard reader.status == .completed else { throw reader.error ?? EngineError.io("프레임 시각 읽기 중단") }
        times.sort()
        let first = times.lastIndex(where: { $0 <= start }) ?? 0
        let selected = Array(times.dropFirst(first))
        guard !selected.isEmpty, selected.count <= AnimationOptions.maximumFrames else {
            throw EngineError.invalid("선택 구간은 최대 1,800프레임이어야 해요.")
        }
        return try AnimationPlan(sourceOffsets: selected.map { $0 - start }, duration: duration, format: format)
    }
}

/// Full-size, upright SDR frames can be read sequentially without repeatedly
/// seeking the image generator. Other transforms/color formats retain the
/// established generator path. Only two decoded samples are held here.
final class SequentialAnimationReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var current: CMSampleBuffer?
    private var next: CMSampleBuffer?
    private var cachedTime: CMTime?
    private var cachedImage: CGImage?

    static func make(asset: AVAsset) async throws -> SequentialAnimationReader? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              try await track.load(.preferredTransform) == .identity else { return nil }
        let descriptions = try await track.load(.formatDescriptions)
        for description in descriptions {
            let encoded=CMVideoFormatDescriptionGetDimensions(description)
            let displayed=CMVideoFormatDescriptionGetPresentationDimensions(description,usePixelAspectRatio:true,useCleanAperture:true)
            // The generator already handles anamorphic pixels and clean
            // apertures. Do not silently change their displayed geometry.
            guard abs(displayed.width-Double(encoded.width))<0.001,
                  abs(displayed.height-Double(encoded.height))<0.001 else { return nil }
            let extensions = CMFormatDescriptionGetExtensions(description) as? [String:Any] ?? [:]
            let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String ||
                transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String { return nil }
        }
        return try SequentialAnimationReader(asset: asset, track: track)
    }

    private init(asset: AVAsset, track: AVAssetTrack) throws {
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: track, outputSettings:
            [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EngineError.unsupported("순차 프레임 디코딩을 지원하지 않아요.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? EngineError.io("영상 디코딩 시작 실패") }
    }
    deinit { reader.cancelReading() }

    private func readSample() throws -> CMSampleBuffer? {
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            if (attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay as String] as? NSNumber)?.boolValue == true { continue }
            if CMSampleBufferGetImageBuffer(sample) != nil { return sample }
        }
        guard reader.status == .completed else { throw reader.error ?? EngineError.io("영상 프레임 읽기 실패") }
        return nil
    }
    func image(at time: Double) throws -> CGImage {
        try Task.checkCancellation()
        if current == nil { current = try readSample(); next = try readSample() }
        while let following = next, CMSampleBufferGetOutputPresentationTimeStamp(following).seconds <= time + 1e-8 {
            current = following; next = try readSample()
        }
        guard let current else { throw EngineError.io("표시할 영상 프레임이 없어요.") }
        let sample: CMSampleBuffer
        if let next, abs(CMSampleBufferGetOutputPresentationTimeStamp(next).seconds-time) <
            abs(CMSampleBufferGetOutputPresentationTimeStamp(current).seconds-time) - 1e-8 { sample = next }
        else { sample = current }
        let stamp = CMSampleBufferGetOutputPresentationTimeStamp(sample)
        if stamp == cachedTime, let cachedImage { return cachedImage }
        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { throw EngineError.io("영상 픽셀 읽기 실패") }
        var image: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(pixel, options: nil, imageOut: &image) == noErr, let image else {
            throw EngineError.io("영상 색상 변환 실패")
        }
        cachedTime = stamp; cachedImage = image
        return image
    }
}

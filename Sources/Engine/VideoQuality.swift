import Foundation
@preconcurrency import AVFoundation
import CoreVideo

/// An engineering guard, not a perceptual-losslessness claim. Every displayed
/// frame is decoded in presentation order; spatial measurements use a rotating,
/// bounded grid of native-resolution blocks. Squared error covers every pixel
/// in all three Y/U/V components, including the image edges.
struct VideoQualityReport {
    private static let averageErrorFloor = 46.0, frameErrorFloor = 42.0
    private(set) var frames = 0
    private var sumSSIM = 0.0, sumMSE = 0.0, sumChromaMSE = 0.0
    private(set) var worstSSIM = 1.0, worstPSNR = 99.0, worstChromaPSNR = 99.0, worstTailSSIM = 1.0
    private var histogram = [Int](repeating: 0, count: 1001)
    var meanSSIM: Double { sumSSIM / Double(max(1, frames)) }
    var psnr: Double { Self.psnr(sumMSE / Double(max(1, frames))) }
    var chromaPSNR: Double { Self.psnr(sumChromaMSE / Double(max(1, frames))) }
    var fifthPercentileSSIM: Double {
        var remaining = max(1, Int(ceil(Double(frames) * 0.05)))
        for index in histogram.indices {
            remaining -= histogram[index]
            if remaining <= 0 { return Double(index) / 1000 }
        }
        return 0
    }
    var acceptable: Bool {
        // At native resolution a tiny error in a nearly flat block can strongly
        // affect SSIM. Use both structure and absolute error budgets, including
        // worst-frame and worst-block-tail guards; never rely on an average alone.
        frames > 0 && meanSSIM >= 0.985 && fifthPercentileSSIM >= 0.980 && worstSSIM >= 0.970 &&
        psnr >= Self.averageErrorFloor && worstPSNR >= Self.frameErrorFloor &&
        chromaPSNR >= Self.averageErrorFloor && worstChromaPSNR >= Self.frameErrorFloor && worstTailSSIM >= 0.920
    }
    /// Automatic compression uses this more conservative quality goal;
    /// `acceptable` remains the safety floor for an explicit byte limit.
    var preferredForAutomatic: Bool {
        acceptable && psnr>=48 && chromaPSNR>=48 && worstPSNR>=44 && worstChromaPSNR>=44
    }
    /// Mean squared error over the actual 4:2:0 pixel counts. Lower means a
    /// closer decoded result. Used to rank candidates under an explicit cap.
    var distortion: Double { (2*sumMSE+sumChromaMSE)/Double(3*max(1,frames)) }
    /// A search coordinate, not an acceptance test. Log error ratios let the
    /// most restrictive structural or pixel-error guard drive the next probe.
    /// No monotonic rate/quality relationship is assumed by the final gate.
    func rateMargin(preferred:Bool) -> Double {
        guard frames>0 else { return -99 }
        func structure(_ value:Double,_ floor:Double) -> Double {
            10*log10((1-floor)/max(1e-12,1-value))
        }
        let average=preferred ? 48:Self.averageErrorFloor,minimum=preferred ? 44:Self.frameErrorFloor
        return min(psnr-average,chromaPSNR-average,worstPSNR-minimum,worstChromaPSNR-minimum,
            structure(meanSSIM,0.985),structure(fifthPercentileSSIM,0.980),
            structure(worstSSIM,0.970),structure(worstTailSSIM,0.920))
    }
    var summary: String {
        String(format: "SSIM %.5f · 하위 5%% %.3f · 최저 %.5f · PSNR %.2f/%.2f dB · %d프레임", meanSSIM, fifthPercentileSSIM, worstSSIM, psnr, chromaPSNR, frames)
    }
    private static func psnr(_ mse: Double) -> Double { min(99, 10 * log10(65025 / max(mse, 1e-12))) }
    mutating func include(luma: RingVideoPlaneQuality, u: RingVideoPlaneQuality, v: RingVideoPlaneQuality) {
        frames += 1; sumSSIM += luma.ssim; sumMSE += luma.mse; sumChromaMSE += (u.mse + v.mse) / 2
        worstSSIM = min(worstSSIM, luma.ssim); worstTailSSIM = min(worstTailSSIM, luma.tail_ssim)
        worstPSNR = min(worstPSNR, Self.psnr(luma.mse))
        worstChromaPSNR = min(worstChromaPSNR, Self.psnr(max(u.mse, v.mse)))
        histogram[min(1000, max(0, Int(luma.ssim * 1000)))] += 1
    }
}

enum VideoQuality {
    private final class Frames {
        let reader: AVAssetReader, output: AVAssetReaderTrackOutput
        let emptyEdits: [CMTimeRange]
        init(asset: AVAsset, track: AVAssetTrack, fullRange: Bool) async throws {
            emptyEdits = try await MediaEngine.emptyVideoEdits(track)
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw EngineError.unsupported("화질 검증용 디코더를 사용할 수 없어요.") }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? EngineError.io("화질 검증 시작 실패") }
        }
        deinit { if reader.status == .reading { reader.cancelReading() } }
        func next() throws -> CMSampleBuffer? {
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                // The decoder emits a black placeholder for an empty movie edit.
                // It is not a compressed picture; compare every actual picture
                // and let the independent compressed-timeline check verify gaps.
                if MediaEngine.isEmptyVideoEdit(sample, ranges: emptyEdits) { continue }
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
                if (attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay as String] as? NSNumber)?.boolValue == true { continue }
                guard CMSampleBufferGetImageBuffer(sample) != nil else { throw EngineError.quality("검증 중 영상 프레임을 읽지 못했어요.") }
                return sample
            }
            guard reader.status == .completed else { throw reader.error ?? EngineError.quality("화질 검증이 끝나지 않았어요.") }
            return nil
        }
    }

    static func compare(source: AVAsset, video: AVAssetTrack, output: AVAsset, track: AVAssetTrack,
                        width: Int, height: Int, natural: CGSize, transform: CGAffineTransform,
                        crop: CGRect?, fullRange: Bool, duration: Double) async throws -> VideoQualityReport {
        let reference = try await Frames(asset: source, track: video, fullRange: fullRange)
        let encoded = try await Frames(asset: output, track: track, fullRange: fullRange)
        // Match the exact crop/resampling used before encoding, so a user's
        // intentional geometry change is not counted as codec damage.
        let renderer = try MediaEngine.frameRenderer(crop: crop, width: width, height: height,
            natural: natural, transform: transform, fullRange: fullRange)
        var report = VideoQualityReport()
        while true {
            try Task.checkCancellation()
            let more: Bool = try autoreleasepool {
                let a = try reference.next(), b = try encoded.next()
                guard let a, let b else {
                    guard a == nil && b == nil else { throw EngineError.quality("프레임 누락·추가가 감지되어 저장하지 않았어요.") }
                    return false
                }
                let time = CMSampleBufferGetOutputPresentationTimeStamp(a).seconds
                let outTime = CMSampleBufferGetOutputPresentationTimeStamp(b).seconds
                guard time.isFinite, outTime.isFinite, abs(time - outTime) <= 0.000001 else {
                    throw EngineError.quality("프레임 재생 시각이 달라져 저장하지 않았어요.")
                }
                let prepared = try renderer?.render(a) ?? a
                let pixels = CMSampleBufferGetImageBuffer(prepared)!, result = CMSampleBufferGetImageBuffer(b)!
                guard CVPixelBufferGetWidth(pixels) == width, CVPixelBufferGetHeight(pixels) == height,
                      CVPixelBufferGetWidth(result) == width, CVPixelBufferGetHeight(result) == height,
                      CVPixelBufferGetPlaneCount(pixels) == 2, CVPixelBufferGetPlaneCount(result) == 2 else {
                    throw EngineError.quality("화질 검증 프레임의 해상도·색상 구조가 달라요.")
                }
                guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { throw EngineError.io("원본 검증 픽셀 읽기 실패") }
                defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
                guard CVPixelBufferLockBaseAddress(result, .readOnly) == kCVReturnSuccess else { throw EngineError.io("출력 검증 픽셀 읽기 실패") }
                defer { CVPixelBufferUnlockBaseAddress(result, .readOnly) }
                func measure(_ plane: Int, component: Int = 0) throws -> RingVideoPlaneQuality {
                    guard let a = CVPixelBufferGetBaseAddressOfPlane(pixels, plane), let b = CVPixelBufferGetBaseAddressOfPlane(result, plane) else {
                        throw EngineError.io("화질 검증 색상 평면 읽기 실패")
                    }
                    var value = RingVideoPlaneQuality()
                    guard ring_video_plane_quality(a.assumingMemoryBound(to: UInt8.self) + component, CVPixelBufferGetBytesPerRowOfPlane(pixels, plane),
                        b.assumingMemoryBound(to: UInt8.self) + component, CVPixelBufferGetBytesPerRowOfPlane(result, plane),
                        Int32(CVPixelBufferGetWidthOfPlane(pixels, plane)), Int32(CVPixelBufferGetHeightOfPlane(pixels, plane)),
                        plane == 0 ? 1 : 2, Int32(report.frames % 1_000_000), &value) == 1 else { throw EngineError.quality("화질 비교 계산 실패") }
                    return value
                }
                let y = try measure(0), u = try measure(1), v = try measure(1, component: 1)
                report.include(luma: y, u: u, v: v)
                EngineProgress.report(max(0, time) / max(0.001, duration))
                return true
            }
            if !more { break }
        }
        guard report.frames > 0 else { throw EngineError.quality("검증 가능한 프레임이 없어요.") }
        return report
    }
}

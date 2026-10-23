import Foundation
@preconcurrency import AVFoundation
import VideoToolbox

/// Bundled static codecs. The ring keeps its current choices; this API is also
/// available to tools without making the user choose an encoder implementation.
enum SoftwareVideo {
    static var capabilities: RingSoftwareVideoCapabilities { ring_video_capabilities() }
    private static let cancelled: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { _ in Task.isCancelled ? 1 : 0 }
    private final class Progress {
        let handler = EngineProgress.handler
    }
    private static let progress: @convention(c) (Double, UnsafeMutableRawPointer?) -> Void = { value, context in
        guard let context else { return }
        Unmanaged<Progress>.fromOpaque(context).takeUnretainedValue().handler?(value)
    }
    static func checked(_ status: Int32, _ error: [CChar]) throws {
        if status == 3 || Task.isCancelled { throw CancellationError() }
        let message = String(cString: error)
        switch status {
        case 0: return
        case 1: throw EngineError.unsupported(message)
        case 2: throw EngineError.invalid(message)
        default: throw EngineError.io(message)
        }
    }
    static func inspect(_ url: URL, allFrames: Bool = false) throws -> RingSoftwareVideoInfo {
        try Task.checkCancellation()
        var value = RingSoftwareVideoInfo(), error = [CChar](repeating: 0, count: 512)
        let status = url.path.withCString { ring_video_inspect($0, allFrames ? 1 : 0, &value, cancelled, nil, &error) }
        try checked(status, error)
        return value
    }
    static func supported(_ codec: VideoCodec) -> Bool {
        let c = capabilities
        return codec == .h264 ? c.h264 != 0 : codec == .hevc ? c.hevc != 0 : c.av1 != 0
    }
    static func appleAvailable(_ codec: VideoCodec, width: Int, height: Int) -> Bool {
        guard codec != .av1 else { return false }
        var properties: CFDictionary?
        return VTCopySupportedPropertyDictionaryForEncoder(width: Int32(width), height: Int32(height),
            codecType: codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary,
            encoderIDOut: nil, supportedPropertiesOut: &properties) == noErr
    }
    /// Only hardware encoder errors permit one fallback. Bad input, cancellation,
    /// I/O, byte limits and quality rejection never enter another encoder.
    static func isEncoderFailure(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == AVFoundationErrorDomain && [AVError.Code.encoderNotFound.rawValue,
            AVError.Code.encoderTemporarilyUnavailable.rawValue].contains(value.code) { return true }
        if value.domain == NSOSStatusErrorDomain && [Int(kVTCouldNotFindVideoEncoderErr),
            Int(kVTVideoEncoderMalfunctionErr), Int(kVTVideoEncoderNotAvailableNowErr)].contains(value.code) { return true }
        if let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { return isEncoderFailure(underlying) }
        return false
    }
    static func encode(_ source: URL, to output: URL, codec: VideoCodec, container: VideoContainer,
                       bitrate: Int, audio: VideoAudioPolicy = .preserve) throws {
        try Task.checkCancellation()
        guard source.standardizedFileURL != output.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else { throw EngineError.io("원본이나 기존 결과를 덮어쓰지 않아요.") }
        var options = RingSoftwareVideoOptions()
        options.codec = codec == .h264 ? 1 : codec == .hevc ? 2 : 3
        options.container = container == .mp4 ? 1 : container == .mov ? 2 : 3
        options.bitrate = Int64(bitrate); options.allow_opus_transcode = audio == .convertToOpus ? 1 : 0
        let box = Progress(), context = Unmanaged.passUnretained(box).toOpaque()
        var error = [CChar](repeating: 0, count: 512)
        let status = withExtendedLifetime(box) {
            source.path.withCString { input in output.path.withCString { result in
                ring_video_encode(input, result, &options, progress, cancelled, context, &error)
            } }
        }
        try checked(status, error)
    }
    private final class Frames {
        let decoder: OpaquePointer
        init(_ url: URL) throws {
            var error = [CChar](repeating: 0, count: 512)
            guard let value = url.path.withCString({ ring_video_decoder_create($0, cancelled, nil, &error) }) else {
                if Task.isCancelled { throw CancellationError() }
                throw EngineError.invalid(String(cString: error))
            }
            decoder = value
        }
        deinit { ring_video_decoder_destroy(decoder) }
        func next() throws -> RingSoftwareVideoFrame? {
            try Task.checkCancellation()
            var frame = RingSoftwareVideoFrame(), error = [CChar](repeating: 0, count: 512)
            let result = ring_video_decoder_next(decoder, &frame, &error)
            if result < 0 { try checked(-result, error) }
            return result == 1 ? frame : nil
        }
    }
    /// Every displayed frame, every Y/U/V pixel: same report and unchanged
    /// acceptance gates as the Apple path, with bundled decoding for AV1/WebM.
    static func compare(_ source: URL, _ output: URL, duration: Double) throws -> VideoQualityReport {
        let reference = try Frames(source), encoded = try Frames(output)
        var report = VideoQualityReport()
        while true {
            let a = try reference.next(), b = try encoded.next()
            guard let a, let b else {
                guard a == nil && b == nil else { throw EngineError.quality("프레임 누락·추가가 감지되어 저장하지 않았어요.") }
                break
            }
            let at = Double(a.pts)*Double(a.time_base_num)/Double(a.time_base_den)
            let bt = Double(b.pts)*Double(b.time_base_num)/Double(b.time_base_den)
            guard a.width == b.width, a.height == b.height, abs(at-bt) <= 0.000001,
                  a.color_range == b.color_range, a.color_primaries == b.color_primaries,
                  a.color_transfer == b.color_transfer, a.color_space == b.color_space else {
                throw EngineError.quality("영상 프레임의 해상도·표시 시각·색상 정보가 달라요.")
            }
            func plane(_ x: UnsafePointer<UInt8>?, _ xs: Int32, _ y: UnsafePointer<UInt8>?, _ ys: Int32,
                       width: Int32, height: Int32) throws -> RingVideoPlaneQuality {
                var value = RingVideoPlaneQuality()
                guard let x, let y, ring_video_plane_quality(x, Int(xs), y, Int(ys), width, height,
                    1, Int32(report.frames % 1_000_000), &value) == 1 else { throw EngineError.quality("화질 비교 계산 실패") }
                return value
            }
            let y = try plane(a.y, a.y_stride, b.y, b.y_stride, width: a.width, height: a.height)
            let u = try plane(a.u, a.u_stride, b.u, b.u_stride, width: (a.width+1)/2, height: (a.height+1)/2)
            let v = try plane(a.v, a.v_stride, b.v, b.v_stride, width: (a.width+1)/2, height: (a.height+1)/2)
            report.include(luma: y, u: u, v: v)
            EngineProgress.report(max(0, at)/max(0.001, duration))
        }
        guard report.frames > 0 else { throw EngineError.quality("검증할 영상 프레임이 없어요.") }
        return report
    }
    private static func bytes<T>(_ value: T) -> Data { var copy = value; return withUnsafeBytes(of: &copy) { Data($0) } }
    static func verify(_ source: URL, _ output: URL, codec: VideoCodec, audio: VideoAudioPolicy) throws {
        let a = try inspect(source, allFrames: true), b = try inspect(output, allFrames: true)
        let expected: Int32 = codec == .h264 ? 1 : codec == .hevc ? 2 : 3
        guard b.video_codec == expected, a.width == b.width, a.height == b.height,
              a.frame_count == b.frame_count, abs(a.duration-b.duration) <= 0.001,
              bytes(a.decoded_timeline_sha256) == bytes(b.decoded_timeline_sha256),
              a.color_range == b.color_range, a.color_primaries == b.color_primaries,
              a.color_transfer == b.color_transfer, a.color_space == b.color_space,
              a.has_display_matrix == b.has_display_matrix,
              bytes(a.display_matrix) == bytes(b.display_matrix), a.audio_tracks == b.audio_tracks else {
            throw EngineError.quality("출력 코덱·프레임·타이밍·색·회전 보존 검증 실패")
        }
        if audio == .preserve, a.audio_tracks > 0 {
            guard a.audio_codec == b.audio_codec, a.audio_channels == b.audio_channels,
                  a.audio_sample_rate == b.audio_sample_rate, bytes(a.audio_sha256) == bytes(b.audio_sha256),
                  bytes(a.audio_timing_sha256) == bytes(b.audio_timing_sha256) else {
                throw EngineError.quality("원본 음성의 바이트·재생 시각 보존 검증 실패")
            }
        } else if a.audio_tracks > 0 {
            guard a.audio_channels == b.audio_channels, abs(a.audio_start-b.audio_start) <= 0.001,
                  abs(a.audio_duration-b.audio_duration) < 0.02 else {
                throw EngineError.quality("명시적으로 변환한 음성의 길이·채널 보존 검증 실패")
            }
        }
    }
    struct Availability {
        let codecs: [VideoConversionCodec]
        let audioConversionRequired: Bool
        let message: String?
    }
    static func availability(_ source: URL, container: VideoContainer) throws -> Availability {
        let info = try inspect(source), c = capabilities
        guard info.restricted == 0 else { return Availability(codecs: [], audioConversionRequired: false,
            message: withUnsafeBytes(of: info.restriction) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }) }
        let codecs: [VideoConversionCodec] = container == .webm ? (c.av1 != 0 && c.webm != 0 ? [.av1] : []) :
            [(c.h264 != 0 ? VideoConversionCodec.h264 : nil), (c.hevc != 0 ? .hevc : nil),
             (container == .mp4 && c.av1 != 0 ? .av1 : nil)].compactMap { $0 }
        let needs = container == .webm && info.audio_tracks > 0 && info.webm_audio_copy == 0
        return Availability(codecs: codecs, audioConversionRequired: needs,
            message: needs ? "WebM에는 이 원본 음성을 그대로 담을 수 없어요. Opus 변환에 명시적으로 동의해야 저장할 수 있어요." : nil)
    }
    static func convert(_ source: URL, to output: URL, options: VideoConversionOptions) throws -> String {
        let before = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if let bytes = options.sourceBytes, bytes != Int64(before.fileSize ?? 0) { throw EngineError.invalid("원본이 변경됐어요.") }
        if let date = options.sourceModified, date != before.contentModificationDate { throw EngineError.invalid("원본이 변경됐어요.") }
        let available = try availability(source, container: options.container)
        guard available.codecs.contains(options.codec) else { throw EngineError.unsupported(available.message ?? "이 포맷·코덱 조합을 지원하지 않아요.") }
        if available.audioConversionRequired && options.audioPolicy == .preserve { throw EngineError.unsupported(available.message!) }
        let info = try inspect(source)
        guard info.duration.isFinite, info.duration > 0 else { throw EngineError.unsupported("영상 길이를 확정하지 못해 프레임·음성 싱크를 검증할 수 없어요.") }
        // Container conversion has no byte target. A quality-oriented request
        // avoids treating the source codec's bitrate as another codec's quality.
        try encode(source, to: output, codec: options.codec.encodingCodec, container: options.container, bitrate: 0, audio: options.audioPolicy)
        let quality = try compare(source, output, duration: info.duration)
        guard quality.acceptable else { throw EngineError.quality("변환 화질 검증 실패 · \(quality.summary)") }
        try verify(source, output, codec: options.codec.encodingCodec, audio: options.audioPolicy)
        let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw EngineError.invalid("처리 중 원본이 변경됐어요.") }
        return "\(options.container.title) · \(options.codec.title) · 전체 프레임·시각·색상·회전 검증 · " + (available.audioConversionRequired ? "명시적 Opus 변환" : "원본 음성 유지")
    }

    static func compress(_ source: URL, to output: URL, options: VideoCompressionOptions) throws -> String {
        let info = try inspect(source)
        guard info.duration.isFinite, info.duration > 0 else { throw EngineError.unsupported("영상 길이를 확정하지 못해 원본 타이밍을 검증할 수 없어요.") }
        guard options.crop.isFull, options.maxDimension == nil else {
            throw EngineError.unsupported("소프트웨어 인코더의 자르기·크기 변경 보존은 아직 지원하지 않아요. 원본 크기로 저장하거나 Apple 인코더를 사용해 주세요.")
        }
        if let target = options.targetBytes, !(1...1_000_000_000_000).contains(target) { throw EngineError.invalid("목표 비디오 용량 오류") }
        let resource = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let limit = min(options.targetBytes ?? Int64(Double(resource.fileSize ?? 0)*0.99), Int64(Double(resource.fileSize ?? 0)*0.99))
        let budget = VideoCropGeometry.videoBitrate(targetBytes: limit, duration: info.duration, audioBytes: info.audio_bytes)
        guard budget.isFinite, budget >= 100_000, budget < Double(Int32.max) else { throw EngineError.quality("원본 음성·프레임·해상도를 유지하기에는 목표 용량이 너무 작아요.") }
        let work = try StagingWorkspace(beside: output); defer { work.cleanup() }
        let automatic = options.targetBytes == nil
        let initial = Double(info.width)*Double(info.height)*max(1,info.frame_rate)*(options.codec == .h264 ? 0.10 : 0.06)
        var rate = Int(max(100_000, min(budget, automatic ? initial : budget)))
        let best = work.directory.appendingPathComponent("best.mp4")
        var bestQuality: VideoQualityReport?, bestBytes = Int.max
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let candidate = work.directory.appendingPathComponent("candidate-\(attempt).mp4")
            try encode(source, to: candidate, codec: options.codec, container: .mp4, bitrate: rate)
            let count = try candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            var quality: VideoQualityReport?
            if count > 0, count <= limit {
                let measured = try compare(source, candidate, duration: info.duration); quality = measured
                if (automatic ? measured.preferredForAutomatic : measured.acceptable),
                   MediaEngine.preferVideoCandidate(measured, bytes: count, over: bestQuality, previousBytes: bestBytes, limit: limit, automatic: automatic) {
                    try verify(source, candidate, codec: options.codec, audio: .preserve)
                    if FileManager.default.fileExists(atPath: best.path) { try FileManager.default.removeItem(at: best) }
                    try FileManager.default.moveItem(at: candidate, to: best)
                    bestQuality = measured; bestBytes = count
                }
            }
            if bestQuality != nil && (automatic || Double(bestBytes) >= Double(limit)*0.90) { break }
            if attempt == 0 {
                let available = max(1,Double(limit-info.audio_bytes-4096))
                let actual = max(1,Double(count)-Double(info.audio_bytes)-4096)
                let sizeRate = Double(rate)*available/actual*0.98
                if let quality, !(automatic ? quality.preferredForAutomatic : quality.acceptable) {
                    rate = Int(max(100_000,min(budget,sizeRate,Double(rate)*min(4,max(1.1,pow(10,-quality.rateMargin(preferred:automatic)/10))))))
                } else { rate = Int(max(100_000,min(budget,sizeRate))) }
            }
        }
        let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard resource.fileSize == after.fileSize, resource.contentModificationDate == after.contentModificationDate else { throw EngineError.invalid("처리 중 원본이 변경됐어요.") }
        try Task.checkCancellation()
        guard let quality = bestQuality else {
            let codec: Int32 = options.codec == .h264 ? 1 : options.codec == .hevc ? 2 : 3
            if automatic, info.video_codec == codec { throw NoCompressionSavings(reason: "화질을 지키며 더 줄이기 어려워요 · 원본 유지") }
            throw EngineError.quality("목표 용량과 기존 화질 기준을 함께 만족하지 못했어요. 원본은 유지했어요.")
        }
        try FileManager.default.moveItem(at: best, to: output)
        return "소프트웨어 압축 · \(bestBytes)바이트 · \(quality.summary) · 원본 프레임·오디오 유지"
    }
}

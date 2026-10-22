import Foundation
@preconcurrency import AVFoundation
import VideoToolbox
import CryptoKit

enum VideoContainer: String, CaseIterable, Hashable {
    case mp4, mov
    var title: String { rawValue.uppercased() }
    var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

enum VideoConversionCodec: String, Hashable {
    case h264, hevc, passthrough
    var title: String {
        switch self { case .h264: return "H.264"; case .hevc: return "HEVC"; case .passthrough: return "원본 유지" }
    }
    var encodingCodec: VideoCodec { self == .hevc ? .hevc : .h264 }
}

struct VideoConversionOptions {
    var container: VideoContainer
    var codec: VideoConversionCodec
    var sourceBytes: Int64? = nil
    var sourceModified: Date? = nil
}

struct VideoEncodingPlan {
    let videoBitrate: Int
}

struct VideoSourceInfo {
    let duration: Double
    let videoDuration: Double
    let audioDuration: Double
    let width: Int
    let height: Int
    let frameRate: Double
    let videoBitrate: Double
    let audioBitrate: Double
    let videoBytes: Int64
    let audioBytes: Int64
    let sourceBytes: Int64
    let modified: Date?
    let hasAudio: Bool
    let audioChannels: Int
    let audioSampleRate: Double
    let colorProperties: [String: Any]
    let fullRange: Bool
    let reencodeRestriction: String?
    let codecs: [VideoContainer: [VideoConversionCodec]]
    let copyAudio: [VideoContainer: Bool]

    static func inspect(_ url: URL) async throws -> VideoSourceInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard duration.isFinite, duration > 0, videos.count == 1, audios.count <= 1,
              try await !asset.load(.hasProtectedContent) else {
            throw EngineError.unsupported("보호되지 않은 비디오 1트랙·음성 최대 1트랙만 변환해요.")
        }
        let track = videos[0]
        let descriptions = try await track.load(.formatDescriptions)
        guard !descriptions.isEmpty else { throw EngineError.invalid("영상 정보를 읽지 못했어요.") }
        let natural = try await track.load(.naturalSize)
        guard natural.width.isFinite, natural.height.isFinite, natural.width >= 2, natural.height >= 2,
              natural.width <= 16384, natural.height <= 16384 else { throw EngineError.unsupported("이 해상도는 변환하지 못해요.") }
        let width = Int(natural.width.rounded()), height = Int(natural.height.rounded())
        let fps = Double(try await track.load(.nominalFrameRate))
        let videoRate = Double(try await track.load(.estimatedDataRate))
        let videoTime = try await track.load(.timeRange).duration.seconds
        guard videoTime.isFinite, videoTime > 0 else { throw EngineError.invalid("유효한 영상 길이가 없어요.") }
        let videoBytes = try await track.load(.totalSampleDataLength)
        let resource = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        var restriction: String?
        var colors: [String: Any] = [:]
        var fullRange: Bool?
        for d in descriptions {
            let ext = (CMFormatDescriptionGetExtensions(d) as NSDictionary?) ?? [:]
            let range = (ext[kCMFormatDescriptionExtension_FullRangeVideo] as? NSNumber)?.boolValue ?? false
            if let previous = fullRange, previous != range { restriction = "도중에 색상 범위가 달라지는 영상은 원본 유지만 가능해요." }
            fullRange = range
            let dimensions = CMVideoFormatDescriptionGetDimensions(d)
            if Int(dimensions.width) != width || Int(dimensions.height) != height {
                restriction = "별도 표시 해상도가 있는 영상은 원본 유지만 가능해요."
            }
            let transfer = ext[kCMFormatDescriptionExtension_TransferFunction] as? String
            if [kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
                kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String].contains(transfer ?? "") {
                restriction = "HDR은 재압축 없이 원본 유지만 가능해요."
            }
            let subtype = CMFormatDescriptionGetMediaSubType(d)
            let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? [String: Any]
            let hvcC = atoms?["hvcC"] as? Data
            let avcC = atoms?["avcC"] as? Data
            let bits = (ext[kCMFormatDescriptionExtension_BitsPerComponent] as? NSNumber)?.intValue ?? 8
            let highHEVC = hvcC.map { $0.count > 1 && ($0[1] & 31) != 1 } ?? false
            let highAVC = avcC.map { $0.count > 1 && [110,122,244,44].contains(Int($0[1])) } ?? false
            if restriction == nil && (bits > 8 || highHEVC || highAVC || [kCMVideoCodecType_AppleProRes422,
                kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT,
                kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes4444,
                kCMVideoCodecType_AppleProRes4444XQ].contains(subtype)) {
                restriction = "고비트 심도 영상은 원본 유지만 가능해요. 8비트로 낮추지 않아요."
            }
            if (ext[kCMFormatDescriptionExtension_ContainsAlphaChannel] as? NSNumber)?.boolValue == true {
                restriction = "투명 영상은 원본 유지만 가능해요."
            }
            if width % 2 != 0 || height % 2 != 0 { restriction = "홀수 해상도는 원본 유지만 가능해요. 해상도를 바꾸지 않아요." }
            for (key, value) in [(AVVideoColorPrimariesKey, ext[kCMFormatDescriptionExtension_ColorPrimaries]),
                                 (AVVideoTransferFunctionKey, ext[kCMFormatDescriptionExtension_TransferFunction]),
                                 (AVVideoYCbCrMatrixKey, ext[kCMFormatDescriptionExtension_YCbCrMatrix])] {
                if let value = value as? String {
                    if let existing = colors[key] as? String, existing != value { restriction = "도중에 색상 정보가 달라지는 영상은 원본 유지만 가능해요." }
                    colors[key] = value
                }
            }
            if let aspect = ext[kCMFormatDescriptionExtension_PixelAspectRatio] as? NSDictionary,
               let h = aspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] as? NSNumber,
               let v = aspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] as? NSNumber, h != v {
                restriction = "비정방형 픽셀은 원본 유지만 가능해요."
            }
            if let aperture = ext[kCMFormatDescriptionExtension_CleanAperture] as? NSDictionary,
               let w = aperture[kCMFormatDescriptionKey_CleanApertureWidth] as? NSNumber,
               let h = aperture[kCMFormatDescriptionKey_CleanApertureHeight] as? NSNumber,
               (abs(w.doubleValue - Double(width)) > 0.5 || abs(h.doubleValue - Double(height)) > 0.5) {
                restriction = "별도 표시 영역이 있는 영상은 원본 유지만 가능해요."
            }
            if let aperture = ext[kCMFormatDescriptionExtension_CleanAperture] as? NSDictionary,
               [kCMFormatDescriptionKey_CleanApertureHorizontalOffset,kCMFormatDescriptionKey_CleanApertureVerticalOffset]
                .contains(where: { abs((aperture[$0] as? NSNumber)?.doubleValue ?? 0) > 0.001 }) {
                restriction = "이동된 표시 영역이 있는 영상은 원본 유지만 가능해요."
            }
        }
        if !colors.isEmpty && colors.count != 3 { restriction = "색상 태그가 불완전해 원본 유지만 가능해요." }
        if (!fps.isFinite || fps <= 0) && (!videoRate.isFinite || videoRate <= 0) {
            restriction = "비트레이트·프레임률을 읽지 못해 원본 유지만 가능해요."
        }
        var audioRate = 0.0, audioTime = 0.0, audioBytes: Int64 = 0, channels = 0, sampleRate = 0.0
        var audioDescription: CMFormatDescription?
        if let audio = audios.first {
            audioRate = Double(try await audio.load(.estimatedDataRate))
            audioTime = try await audio.load(.timeRange).duration.seconds
            guard audioTime.isFinite, audioTime > 0 else { throw EngineError.invalid("유효한 음성 길이가 없어요.") }
            audioBytes = try await audio.load(.totalSampleDataLength)
            audioDescription = try await audio.load(.formatDescriptions).first
            if let d = audioDescription, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d) {
                channels = Int(asbd.pointee.mChannelsPerFrame); sampleRate = asbd.pointee.mSampleRate
            }
        }
        var codecs: [VideoContainer: [VideoConversionCodec]] = [:], copyAudio: [VideoContainer: Bool] = [:]
        for container in VideoContainer.allCases {
            try Task.checkCancellation()
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ring-capability-\(UUID().uuidString).\(container.rawValue)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let writer = try AVAssetWriter(outputURL: scratch, fileType: container.fileType)
            let audioPass = audioDescription.map {
                writer.canAdd(AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: $0))
            } ?? true
            copyAudio[container] = audioPass
            var supported: [VideoConversionCodec] = []
            if restriction == nil && audioPass {
                for codec in [VideoConversionCodec.h264, .hevc] {
                    var settings: [String: Any] = [AVVideoCodecKey: codec == .h264 ? AVVideoCodecType.h264 : .hevc,
                        AVVideoWidthKey: width, AVVideoHeightKey: height]
                    if !colors.isEmpty { settings[AVVideoColorPropertiesKey] = colors }
                    var encoderProperties: CFDictionary?
                    let hardware: CFDictionary = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
                    let status = VTCopySupportedPropertyDictionaryForEncoder(width: Int32(width), height: Int32(height),
                        codecType: codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
                        encoderSpecification: hardware, encoderIDOut: nil, supportedPropertiesOut: &encoderProperties)
                    guard status == noErr else { continue }
                    if writer.canApply(outputSettings: settings, forMediaType: .video),
                       writer.canAdd(AVAssetWriterInput(mediaType: .video, outputSettings: settings)) {
                        supported.append(codec)
                    }
                }
            }
            if await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: container.fileType) {
                supported.append(.passthrough)
            }
            codecs[container] = supported
        }
        try Task.checkCancellation()
        return VideoSourceInfo(duration: duration, videoDuration: videoTime, audioDuration: audioTime, width: width, height: height,
            frameRate: fps, videoBitrate: videoRate, audioBitrate: audioRate, videoBytes: videoBytes, audioBytes: audioBytes,
            sourceBytes: Int64(resource.fileSize ?? 0), modified: resource.contentModificationDate, hasAudio: !audios.isEmpty,
            audioChannels: channels, audioSampleRate: sampleRate, colorProperties: colors, fullRange: fullRange ?? false, reencodeRestriction: restriction,
            codecs: codecs, copyAudio: copyAudio)
    }

    func plan(_ options: VideoConversionOptions) throws -> VideoEncodingPlan {
        guard codecs[options.container]?.contains(options.codec) == true else { throw EngineError.unsupported("이 입력과 출력 조합은 지원하지 않아요.") }
        if options.codec == .passthrough {
            return VideoEncodingPlan(videoBitrate: 0)
        }
        // Format conversion keeps the source bitrate budget. Size reduction is
        // a separate tool; changing a codec never applies a guessed discount.
        let rate = videoBitrate.isFinite && videoBitrate > 0 ? videoBitrate : Double(videoBytes)*8/videoDuration
        guard rate.isFinite, rate > 0, rate < Double(Int.max) else { throw EngineError.invalid("원본 영상 비트레이트를 읽지 못했어요.") }
        return VideoEncodingPlan(videoBitrate: max(100_000,Int(rate.rounded())))
    }
}

extension MediaEngine {
    static func convertVideo(_ source: URL, to output: URL, options: VideoConversionOptions) async throws -> String {
        let info = try await VideoSourceInfo.inspect(source)
        if let bytes = options.sourceBytes, bytes != info.sourceBytes { throw EngineError.invalid("원본이 바뀌었어요. 링을 다시 열어 주세요.") }
        if let date = options.sourceModified, date != info.modified { throw EngineError.invalid("원본이 바뀌었어요. 링을 다시 열어 주세요.") }
        let plan = try info.plan(options)
        let asset = AVURLAsset(url: source)
        let videos = try await asset.loadTracks(withMediaType: .video), audios = try await asset.loadTracks(withMediaType: .audio)
        let track = videos[0]
        let duration = try await asset.load(.duration), transform = try await track.load(.preferredTransform)
        if options.codec == .passthrough {
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw EngineError.unsupported("원본 유지 내보내기를 지원하지 않아요.") }
            try Task.checkCancellation()
            // This async AVFoundation API follows Task cancellation directly.
            try await session.export(to: output, as: options.container.fileType)
        } else {
            try await encode(asset, to: output, video: track, audio: audios.first, duration: duration,
                width: info.width, height: info.height, transform: transform,
                natural: CGSize(width: info.width, height: info.height), crop: nil,
                bitrate: plan.videoBitrate, codec: options.codec.encodingCodec,
                fileType: options.container.fileType, colorProperties: info.colorProperties, fullRange: info.fullRange)
        }
        try Task.checkCancellation()
        EngineProgress.report(0.88)
        try await verify(output, duration: info.duration, videos: 1, audios: audios.count, width: info.width, height: info.height)
        let result = AVURLAsset(url: output)
        let outVideo = try await result.loadTracks(withMediaType: .video)[0]
        let outDescription = try await outVideo.load(.formatDescriptions)[0]
        let sourceDescription = try await track.load(.formatDescriptions)[0]
        let expected: FourCharCode = options.codec == .passthrough ? CMFormatDescriptionGetMediaSubType(sourceDescription)
            : options.codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        guard CMFormatDescriptionGetMediaSubType(outDescription) == expected else { throw EngineError.quality("출력 영상 코덱이 선택과 달라요.") }
        let actualTransform = try await outVideo.load(.preferredTransform)
        let expectedTransform = options.codec == .passthrough ? transform : normalizedTransform(transform, width: info.width, height: info.height)
        guard zip([actualTransform.a,actualTransform.b,actualTransform.c,actualTransform.d,actualTransform.tx,actualTransform.ty],
                  [expectedTransform.a,expectedTransform.b,expectedTransform.c,expectedTransform.d,expectedTransform.tx,expectedTransform.ty]).allSatisfy({ abs($0 - $1) < 0.01 }) else {
            throw EngineError.quality("출력 영상의 회전·위치가 원본과 달라요.")
        }
        try await verifyVideoColor(outVideo, colors: info.colorProperties, fullRange: info.fullRange)
        try verifyFrameTiming(source: asset, video: track, output: result, track: outVideo, copyPayload: options.codec == .passthrough)
        if let audio = audios.first {
            let outAudio = try await result.loadTracks(withMediaType: .audio)[0]
            let audioDescription = try await outAudio.load(.formatDescriptions).first
            guard let audioDescription, let stream = CMAudioFormatDescriptionGetStreamBasicDescription(audioDescription),
                  Int(stream.pointee.mChannelsPerFrame) == info.audioChannels,
                  abs(stream.pointee.mSampleRate - info.audioSampleRate) < 0.01 else {
                throw EngineError.quality("출력 음성의 채널·샘플률이 원본과 달라요.")
            }
            try await verifyOriginalAudio(source: asset, audio: audio, output: result, track: outAudio)
        }
        return "\(options.container.title) · \(options.codec.title) · 원본 해상도·프레임·오디오 유지"
    }

    static func verifyVideoColor(_ track: AVAssetTrack, colors: [String: Any], fullRange: Bool) async throws {
        let description = try await track.load(.formatDescriptions)[0]
        let ext = (CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? [:]
        for (key, cmKey) in [(AVVideoColorPrimariesKey,kCMFormatDescriptionExtension_ColorPrimaries),
                             (AVVideoTransferFunctionKey,kCMFormatDescriptionExtension_TransferFunction),
                             (AVVideoYCbCrMatrixKey,kCMFormatDescriptionExtension_YCbCrMatrix)] {
            if let color = colors[key] as? String, ext[cmKey] as? String != color { throw EngineError.quality("출력 색상 정보가 원본과 달라요.") }
        }
        guard ((ext[kCMFormatDescriptionExtension_FullRangeVideo] as? NSNumber)?.boolValue ?? false) == fullRange else {
            throw EngineError.quality("출력 영상의 색상 범위가 원본과 달라요.")
        }
    }

    static func verifyFrameTiming(source: AVAsset, video: AVAssetTrack, output: AVAsset, track: AVAssetTrack, copyPayload: Bool = false) throws {
        let a = try streamSignature(asset: source, track: video, payload: copyPayload)
        let b = try streamSignature(asset: output, track: track, payload: copyPayload)
        guard a.count == b.count, a.times == b.times else { throw EngineError.quality("영상 프레임 타이밍이 원본과 달라요.") }
        if copyPayload, a.payload != b.payload { throw EngineError.quality("원본 유지 결과의 영상 데이터가 달라요.") }
    }

    static func verifyOriginalAudio(source: AVAsset, audio: AVAssetTrack, output: AVAsset, track: AVAssetTrack) async throws {
        let a = try streamSignature(asset: source, track: audio, payload: true)
        let b = try streamSignature(asset: output, track: track, payload: true)
        let sourceRange = try await audio.load(.timeRange), resultRange = try await track.load(.timeRange)
        guard a.payload == b.payload, abs(sourceRange.start.seconds - resultRange.start.seconds) < 0.001,
              abs(sourceRange.end.seconds - resultRange.end.seconds) < 0.001 else { throw EngineError.quality("원본 음성의 데이터·타이밍이 달라요.") }
    }

    /// Constant-memory sample verification. The commutative timestamp digest
    /// tolerates decode-order differences while detecting dropped/retimed frames.
    private static func streamSignature(asset: AVAsset, track: AVAssetTrack, payload: Bool) throws -> (count: Int, times: [UInt64], payload: Data) {
        let reader = try AVAssetReader(asset: asset), out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw EngineError.unsupported("출력 스트림 검증 경로를 지원하지 않아요.") }
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? EngineError.io("검증 읽기 실패") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var count = 0, times = [UInt64](repeating: 0, count: 4), hash = SHA256()
        while let sample = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            // Empty edit/flush markers aren't frames and can have invalid times.
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            try autoreleasepool {
                // Raw PTS can include a composition offset (B frames) or omit an
                // edit-list audio delay. Output PTS is the actual playback time.
                let time = CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds
                guard time.isFinite, abs(time) < Double(Int64.max) / 1_000_000 else { throw EngineError.quality("유효하지 않은 프레임 시간이 있어요.") }
                // Compressed streams can contain decoder preroll/postroll that
                // is explicitly excluded from display by an edit list. It must
                // not be counted as a frame lost by the decoder/encoder.
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
                let hidden = (attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay as String] as? NSNumber)?.boolValue ?? false
                if !hidden {
                    var micros = Int64((time * 1_000_000).rounded()).littleEndian
                    let digest = withUnsafeBytes(of: &micros) { SHA256.hash(data: Data($0)) }
                    let bytes = Array(digest)
                    for word in 0..<4 {
                        var value: UInt64 = 0
                        for byte in 0..<8 { value |= UInt64(bytes[word * 8 + byte]) << (byte * 8) }
                        times[word] &+= value
                    }
                    count += 1
                }
                if payload, let block = CMSampleBufferGetDataBuffer(sample) {
                    let size = CMBlockBufferGetDataLength(block)
                    var bytes = Data(count: size)
                    let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
                    guard status == kCMBlockBufferNoErr else { throw EngineError.io("스트림 검증 데이터 읽기 실패") }
                    hash.update(data: bytes)
                }
            }
        }
        guard reader.status == .completed, count > 0 else { throw reader.error ?? EngineError.quality("스트림 검증이 끝나지 않았어요.") }
        return (count, times, Data(hash.finalize()))
    }
}

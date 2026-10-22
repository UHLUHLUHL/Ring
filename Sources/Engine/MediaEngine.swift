import Foundation
@preconcurrency import AVFoundation
import VideoToolbox
import CoreVideo
import AudioToolbox
import ImageIO

enum MediaEngine {
    static func run(_ source:URL,to output:URL,operation:VideoOperation) async throws -> String {
        switch operation {
        case .convert(let options): return try await convertVideo(source,to:output,options:options)
        case .trim(let start,let end): return try await trim(source,to:output,start:start,end:end)
        case .compress(let options): return try await compress(source,to:output,options:options)
        case .animation(let options): return try await animate(source,to:output,options:options)
        }
    }
    static func trim(_ source:URL,to output:URL,start:Double,end:Double) async throws -> String {
        let asset=AVURLAsset(url:source),duration=try await asset.load(.duration)
        guard start.isFinite,end.isFinite,start>=0,end>start,end<=duration.seconds+0.001 else { throw EngineError.invalid("트림 시작·종료 시간 오류") }
        let composition=AVMutableComposition(),tracks=try await asset.load(.tracks)
        var videos=0,audios=0
        let range=CMTimeRange(start:CMTime(seconds:start,preferredTimescale:60000),end:CMTime(seconds:end,preferredTimescale:60000))
        for track in tracks where track.mediaType == .video || track.mediaType == .audio {
            guard let inserted=composition.addMutableTrack(withMediaType:track.mediaType,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw EngineError.io("트림 트랙 생성 실패") }
            let available=try await track.load(.timeRange),intersection=CMTimeRangeGetIntersection(range,otherRange:available)
            guard intersection.duration.seconds>0 else { continue }
            try inserted.insertTimeRange(intersection,of:track,at:CMTimeSubtract(intersection.start,range.start))
            if track.mediaType == .video { videos+=1;inserted.preferredTransform=try await track.load(.preferredTransform) } else { audios+=1 }
        }
        guard videos>0,let export=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetPassthrough) else { throw EngineError.unsupported("패스스루 비디오 트림을 지원하지 않아요.") }
        try Task.checkCancellation()
        try await export.export(to:output,as:.mov)
        try Task.checkCancellation()
        try await verify(output,duration:end-start,videos:videos,audios:audios)
        return "패스스루 트림 · 재인코딩 없음 · \(String(format:"%.3f",end-start))초 · 샘플 경계 컷"
    }

    static func compress(_ source:URL,to output:URL,options:VideoCompressionOptions) async throws -> String {
        let targetBytes = options.targetBytes, codec = options.codec
        guard targetBytes>0,targetBytes<=1_000_000_000_000 else { throw EngineError.invalid("목표 비디오 용량 오류") }
        if let maxDimension = options.maxDimension, !(16...8192).contains(maxDimension) {
            throw EngineError.invalid("최대 영상 변은 16~8,192px이어야 해요.")
        }
        let asset=AVURLAsset(url:source),duration=try await asset.load(.duration)
        let video=try await asset.loadTracks(withMediaType:.video),audio=try await asset.loadTracks(withMediaType:.audio)
        guard duration.seconds.isFinite,duration.seconds>0,video.count==1,audio.count<=1 else { throw EngineError.unsupported("비디오 1트랙·오디오 최대 1트랙만 압축해요.") }
        let track=video[0],natural=try await track.load(.naturalSize),transform=try await track.load(.preferredTransform)
        let descriptions=try await track.load(.formatDescriptions)
        for description in descriptions {
            let extensions=(CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? [:]
            if let transfer=extensions[kCMFormatDescriptionExtension_TransferFunction] as? String,
               [kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String].contains(transfer) { throw EngineError.unsupported("HDR 비디오는 톤 매핑을 명시하기 전까지 압축하지 않아요.") }
        }
        let audioRate=audio.isEmpty ? 0:96000
        let budget=VideoCropGeometry.videoBitrate(targetBytes:targetBytes,duration:duration.seconds,audio:!audio.isEmpty)
        guard budget>=100000,budget<=Double(Int.max),natural.width.isFinite,natural.height.isFinite,natural.width>=2,natural.height>=2 else { throw EngineError.quality("이 길이의 비디오에는 목표 용량이 너무 작아요.") }
        var rate=Int(min(budget,100_000_000)),lastSize=0
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let display=natural.applying(transform)
            let shownWidth=abs(Double(display.width)),shownHeight=abs(Double(display.height))
            let shown=VideoCropGeometry.compressedSize(width:shownWidth,height:shownHeight,crop:options.crop,maxDimension:options.maxDimension,bitrate:rate)
            let displayWidth=shown.width,displayHeight=shown.height
            // A crop is composed in upright pixels and written without a track
            // transform; an uncropped video keeps the sensor axes and rotation.
            let region=options.crop.isFull ? nil:options.crop.pixelRect(width:max(1,Int(shownWidth.rounded())),height:max(1,Int(shownHeight.rounded())))
            let swapsAxes=region == nil && (abs(transform.b)>0.5 || abs(transform.c)>0.5)
            let width=swapsAxes ? displayHeight:displayWidth
            let height=swapsAxes ? displayWidth:displayHeight
            try await encode(asset,to:output,video:track,audio:audio.first,duration:duration,width:width,height:height,transform:transform,natural:natural,crop:region,bitrate:rate,audioRate:audioRate,codec:codec)
            lastSize=try output.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            if lastSize>0,Int64(lastSize)<=targetBytes {
                try await verify(output,duration:duration.seconds,videos:1,audios:audio.isEmpty ? 0:1,width:width,height:height)
                return "\(codec == .hevc ? "HEVC":"H.264") 하드웨어 압축 · \(displayWidth)×\(displayHeight) · \(lastSize)바이트 · 목표 이하 검증"
            }
            try FileManager.default.removeItem(at:output)
            if attempt==0 { rate=max(100000,Int(Double(rate)*Double(targetBytes)/Double(max(lastSize,1))*0.90)) }
        }
        throw EngineError.quality("하드웨어 인코더 결과 \(lastSize)바이트가 목표 용량을 초과했어요.")
    }

    static func encode(_ asset:AVAsset,to output:URL,video:AVAssetTrack,audio:AVAssetTrack?,duration:CMTime,width:Int,height:Int,transform:CGAffineTransform,natural:CGSize,crop:CGRect?,bitrate:Int,audioRate:Int,codec:VideoCodec,
                       fileType:AVFileType = .mp4,colorProperties:[String:Any] = [:],copyAudio:Bool = false) async throws {
        let reader=try AVAssetReader(asset:asset),writer=try AVAssetWriter(outputURL:output,fileType:fileType)
        let pixels=[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let videoOutput:AVAssetReaderOutput
        if let crop {
            // Upright frame → move the chosen region to the origin → scale it to
            // the output size. Render coordinates are top-left based.
            let upright=normalizedTransform(transform,width:Int(natural.width.rounded()),height:Int(natural.height.rounded()))
            let placed=upright.concatenating(CGAffineTransform(translationX:-crop.minX,y:-crop.minY))
                .concatenating(CGAffineTransform(scaleX:CGFloat(width)/crop.width,y:CGFloat(height)/crop.height))
            var layer=AVVideoCompositionLayerInstruction.Configuration(assetTrack:video)
            layer.setTransform(placed,at:.zero)
            let instruction=AVVideoCompositionInstruction(configuration:.init(layerInstructions:[AVVideoCompositionLayerInstruction(configuration:layer)],
                timeRange:CMTimeRange(start:.zero,duration:duration)))
            let minimum=try await video.load(.minFrameDuration)
            let composition=AVVideoComposition(configuration:.init(frameDuration:minimum.isValid && minimum.seconds>0 ? minimum:CMTime(value:1,timescale:60),
                instructions:[instruction],renderSize:CGSize(width:width,height:height)))
            let composed=AVAssetReaderVideoCompositionOutput(videoTracks:[video],videoSettings:pixels)
            composed.videoComposition=composition;composed.alwaysCopiesSampleData=false
            videoOutput=composed
        } else {
            let direct=AVAssetReaderTrackOutput(track:video,outputSettings:pixels)
            direct.alwaysCopiesSampleData=false
            videoOutput=direct
        }
        guard reader.canAdd(videoOutput) else { throw EngineError.unsupported("비디오 디코딩 경로를 지원하지 않아요.") };reader.add(videoOutput)
        var settings:[String:Any]=[
            AVVideoCodecKey:codec == .hevc ? AVVideoCodecType.hevc:AVVideoCodecType.h264,
            AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoScalingModeKey:AVVideoScalingModeResizeAspectFill,
            AVVideoEncoderSpecificationKey:[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String:true],
            AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:bitrate,AVVideoAllowFrameReorderingKey:false,
                AVVideoMaxKeyFrameIntervalDurationKey:2,kVTCompressionPropertyKey_DataRateLimits as String:[Double(bitrate)/8*1.2,1]]]
        if !colorProperties.isEmpty { settings[AVVideoColorPropertiesKey]=colorProperties }
        guard writer.canApply(outputSettings:settings,forMediaType:.video) else { throw EngineError.unsupported("선택한 출력 설정을 지원하지 않아요.") }
        let videoInput=AVAssetWriterInput(mediaType:.video,outputSettings:settings)
        videoInput.mediaTimeScale=try await video.load(.naturalTimeScale)
        videoInput.transform=crop == nil ? normalizedTransform(transform,width:width,height:height):.identity
        guard writer.canAdd(videoInput) else { throw EngineError.unsupported("하드웨어 비디오 인코딩을 지원하지 않아요.") };writer.add(videoInput)
        var pairs:[(AVAssetReaderOutput,AVAssetWriterInput)]=[(videoOutput,videoInput)]
        if let audio {
            let out=AVAssetReaderTrackOutput(track:audio,outputSettings:copyAudio ? nil : [AVFormatIDKey:kAudioFormatLinearPCM,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false,AVLinearPCMIsNonInterleaved:false])
            out.alwaysCopiesSampleData=false
            let descriptions=try await audio.load(.formatDescriptions)
            guard let description=descriptions.first,let stream=CMAudioFormatDescriptionGetStreamBasicDescription(description),copyAudio || stream.pointee.mChannelsPerFrame<=2 else { throw EngineError.unsupported("모노·스테레오 오디오만 압축해요.") }
            let input=AVAssetWriterInput(mediaType:.audio,outputSettings:copyAudio ? nil : [AVFormatIDKey:kAudioFormatMPEG4AAC,AVEncoderBitRateKey:audioRate,AVSampleRateKey:stream.pointee.mSampleRate,AVNumberOfChannelsKey:stream.pointee.mChannelsPerFrame],sourceFormatHint:copyAudio ? description : nil)
            guard reader.canAdd(out),writer.canAdd(input) else { throw EngineError.unsupported("AAC 오디오 경로를 지원하지 않아요.") }
            reader.add(out);writer.add(input);pairs.append((out,input))
        }
        // Cancellation is cooperative. Calling cancelReading concurrently with
        // startReading can race AVFoundation's extractor initialization.
        do {
            try Task.checkCancellation()
            guard writer.startWriting(),reader.startReading() else { throw writer.error ?? reader.error ?? EngineError.io("미디어 입출력 시작 실패") }
            writer.startSession(atSourceTime:.zero)
            do {
                try await withThrowingTaskGroup(of:Void.self) { group in
                    for (out,input) in pairs {
                        group.addTask {
                            while true {
                                try Task.checkCancellation()
                                var waited=0
                                while !input.isReadyForMoreMediaData {
                                    guard writer.status == .writing,reader.status == .reading || reader.status == .completed,waited<30000 else { throw writer.error ?? reader.error ?? EngineError.io("하드웨어 인코더 응답 시간 초과") }
                                    try await Task.sleep(nanoseconds:2_000_000);waited+=2
                                }
                                let hasSample:Bool=try autoreleasepool {
                                    guard let sample=out.copyNextSampleBuffer() else { return false }
                                    guard input.append(sample) else { throw writer.error ?? EngineError.io("비디오 샘플 쓰기 실패") }
                                    let time=CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds
                                    if input.mediaType == .video,time.isFinite { EngineProgress.report(0.05+0.8*time/duration.seconds) }
                                    return true
                                }
                                if !hasSample { input.markAsFinished();break }
                                if ThermalPolicy.threads==1 { try await Task.sleep(nanoseconds:1_000_000) }
                            }
                        }
                    }
                    try await group.waitForAll()
                }
                guard reader.status == .completed else { throw reader.error ?? EngineError.io("미디어 읽기가 끝나지 않았어요.") }
                writer.endSession(atSourceTime:duration)
                await writer.finishWriting()
                guard writer.status == .completed else { throw writer.error ?? EngineError.io("비디오 마감 실패") }
            } catch { reader.cancelReading();writer.cancelWriting();throw error }
        } catch { reader.cancelReading();writer.cancelWriting();throw error }
    }

    static func normalizedTransform(_ source:CGAffineTransform,width:Int,height:Int)->CGAffineTransform {
        let linear=CGAffineTransform(a:source.a,b:source.b,c:source.c,d:source.d,tx:0,ty:0)
        let bounds=CGRect(x:0,y:0,width:width,height:height).applying(linear)
        var result=linear
        result.tx = -bounds.minX
        result.ty = -bounds.minY
        return result
    }

    static func verify(_ url:URL,duration:Double,videos:Int,audios:Int,width:Int? = nil,height:Int? = nil) async throws {
        let asset=AVURLAsset(url:url)
        let playable=try await asset.load(.isPlayable),actual=try await asset.load(.duration)
        let video=try await asset.loadTracks(withMediaType:.video),audio=try await asset.loadTracks(withMediaType:.audio)
        guard playable,video.count==videos,audio.count==audios,actual.seconds.isFinite,abs(actual.seconds-duration)<0.1,
              (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0)>0 else { throw EngineError.quality("비디오 재생·트랙·길이 검증 실패") }
        if let width,let height,let track=video.first {
            let size=try await track.load(.naturalSize)
            guard Int(size.width)==width,Int(size.height)==height else { throw EngineError.quality("비디오 해상도 검증 실패") }
        }
        if let track=video.first {
            // Read and decode an actual frame; container playability alone is insufficient.
            let generator=AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true
            _ = try await generator.image(at:CMTime(seconds:min(0.05,duration/2),preferredTimescale:600))
            _ = track
        }
    }
}

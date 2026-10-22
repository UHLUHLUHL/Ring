import Foundation
@preconcurrency import AVFoundation
import VideoToolbox
import CoreVideo
import AudioToolbox
import ImageIO
import CoreImage

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
        let info=try await VideoSourceInfo.inspect(source)
        if let restriction=info.reencodeRestriction { throw EngineError.unsupported(restriction) }
        guard info.copyAudio[.mp4] == true else { throw EngineError.unsupported("MP4에 원본 음성을 그대로 담을 수 없어요. 음성을 낮추지 않고 작업을 중단했어요.") }
        let asset=AVURLAsset(url:source),duration=try await asset.load(.duration)
        let video=try await asset.loadTracks(withMediaType:.video),audio=try await asset.loadTracks(withMediaType:.audio)
        let track=video[0],natural=try await track.load(.naturalSize),transform=try await track.load(.preferredTransform)
        let display=natural.applying(transform)
        let shownWidth=abs(Double(display.width)),shownHeight=abs(Double(display.height))
        let maximum=Int(max(shownWidth,shownHeight).rounded())
        if let limit=options.maxDimension, !(16...max(16,maximum)).contains(limit) {
            throw EngineError.invalid("긴 변은 16px부터 원본 \(maximum)px까지 선택할 수 있어요.")
        }
        let budget=VideoCropGeometry.videoBitrate(targetBytes:targetBytes,duration:duration.seconds,audioBytes:info.audioBytes)
        guard budget.isFinite,budget>=100000,budget<Double(Int.max) else {
            throw EngineError.quality("원본 오디오·해상도·프레임을 유지하기에는 목표 용량이 너무 작아요. 목표를 높여 주세요.")
        }
        // Fix geometry once. Retrying a byte target may only adjust video bits,
        // never resolution, sample timing, or audio quality.
        let shown=VideoCropGeometry.compressedSize(width:shownWidth,height:shownHeight,crop:options.crop,maxDimension:options.maxDimension)
        let region=options.crop.isFull ? nil:options.crop.pixelRect(width:max(1,Int(shownWidth.rounded())),height:max(1,Int(shownHeight.rounded())))
        let swapsAxes=region == nil && (abs(transform.b)>0.5 || abs(transform.c)>0.5)
        let width=swapsAxes ? shown.height:shown.width,height=swapsAxes ? shown.width:shown.height
        var rate=Int(min(budget,info.videoBitrate.isFinite && info.videoBitrate>0 ? info.videoBitrate:budget)),lastSize=0
        for attempt in 0..<3 {
            try Task.checkCancellation()
            try await encode(asset,to:output,video:track,audio:audio.first,duration:duration,width:width,height:height,
                transform:transform,natural:natural,crop:region,bitrate:rate,codec:codec,
                colorProperties:info.colorProperties,fullRange:info.fullRange)
            lastSize=try output.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            if lastSize>0,Int64(lastSize)<=targetBytes {
                try await verify(output,duration:duration.seconds,videos:1,audios:audio.count,width:width,height:height)
                let result=AVURLAsset(url:output),outVideo=try await result.loadTracks(withMediaType:.video)[0]
                try verifyFrameTiming(source:asset,video:track,output:result,track:outVideo)
                try await verifyVideoColor(outVideo,colors:info.colorProperties,fullRange:info.fullRange)
                if let audio=audio.first {
                    try await verifyOriginalAudio(source:asset,audio:audio,output:result,track:try await result.loadTracks(withMediaType:.audio)[0])
                }
                return "\(codec == .hevc ? "HEVC":"H.264") · \(shown.width)×\(shown.height) · 원본 프레임·오디오 유지 · \(lastSize)바이트 · 목표 이하 검증"
            }
            try FileManager.default.removeItem(at:output)
            // Exclude unchanged audio before correcting the video bitrate.
            if attempt<2 {
                let available=Double(targetBytes)-Double(info.audioBytes)-4096
                let measured=max(1,Double(lastSize)-Double(info.audioBytes)-4096)
                rate=max(100000,Int(Double(rate)*min(0.95,available/measured*0.97)))
            }
        }
        throw EngineError.quality("원본 해상도·프레임·오디오를 유지한 결과가 목표 용량을 초과했어요. 목표를 높여 주세요.")
    }

    static func encode(_ asset:AVAsset,to output:URL,video:AVAssetTrack,audio:AVAssetTrack?,duration:CMTime,width:Int,height:Int,transform:CGAffineTransform,natural:CGSize,crop:CGRect?,bitrate:Int,codec:VideoCodec,
                       fileType:AVFileType = .mp4,colorProperties:[String:Any] = [:],fullRange:Bool = false) async throws {
        let reader=try AVAssetReader(asset:asset),writer=try AVAssetWriter(outputURL:output,fileType:fileType)
        let pixels=[kCVPixelBufferPixelFormatTypeKey as String:fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        // One decoded sample in, one encoded sample out. A video composition
        // would resample VFR onto a fixed cadence when cropping.
        let videoOutput=AVAssetReaderTrackOutput(track:video,outputSettings:pixels)
        videoOutput.alwaysCopiesSampleData=false
        let cropper=try crop.map { try VideoCropRenderer(crop:$0,width:width,height:height,natural:natural,transform:transform,fullRange:fullRange) }
        guard reader.canAdd(videoOutput) else { throw EngineError.unsupported("비디오 디코딩 경로를 지원하지 않아요.") };reader.add(videoOutput)
        var settings:[String:Any]=[
            AVVideoCodecKey:codec == .hevc ? AVVideoCodecType.hevc:AVVideoCodecType.h264,
            AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoScalingModeKey:AVVideoScalingModeResizeAspectFill,
            AVVideoEncoderSpecificationKey:[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String:true],
            AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:bitrate,AVVideoAllowFrameReorderingKey:true,
                AVVideoMaxKeyFrameIntervalDurationKey:2,
                AVVideoProfileLevelKey:codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel as String:AVVideoProfileLevelH264HighAutoLevel]]
        if !colorProperties.isEmpty { settings[AVVideoColorPropertiesKey]=colorProperties }
        guard writer.canApply(outputSettings:settings,forMediaType:.video) else { throw EngineError.unsupported("선택한 출력 설정을 지원하지 않아요.") }
        let videoInput=AVAssetWriterInput(mediaType:.video,outputSettings:settings)
        videoInput.mediaTimeScale=try await video.load(.naturalTimeScale)
        videoInput.transform=crop == nil ? normalizedTransform(transform,width:width,height:height):.identity
        guard writer.canAdd(videoInput) else { throw EngineError.unsupported("하드웨어 비디오 인코딩을 지원하지 않아요.") };writer.add(videoInput)
        var pairs:[(AVAssetReaderOutput,AVAssetWriterInput)]=[(videoOutput,videoInput)]
        if let audio {
            let out=AVAssetReaderTrackOutput(track:audio,outputSettings:nil)
            out.alwaysCopiesSampleData=false
            guard let description=try await audio.load(.formatDescriptions).first else { throw EngineError.unsupported("원본 음성 정보를 읽지 못했어요.") }
            let input=AVAssetWriterInput(mediaType:.audio,outputSettings:nil,sourceFormatHint:description)
            guard reader.canAdd(out),writer.canAdd(input) else { throw EngineError.unsupported("이 포맷에 원본 음성을 그대로 저장할 수 없어요.") }
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
                                    let written = input.mediaType == .video ? try cropper?.render(sample) ?? sample : sample
                                    guard input.append(written) else { throw writer.error ?? EngineError.io("비디오 샘플 쓰기 실패") }
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

/// Crop pixels without generating a new frame cadence or changing color space.
private final class VideoCropRenderer {
    private let context=CIContext(options:[.cacheIntermediates:false,.workingColorSpace:NSNull()])
    private let pool:CVPixelBufferPool
    private let mapping:CGAffineTransform
    private let bounds:CGRect
    init(crop:CGRect,width:Int,height:Int,natural:CGSize,transform:CGAffineTransform,fullRange:Bool) throws {
        let upright=MediaEngine.normalizedTransform(transform,width:Int(natural.width),height:Int(natural.height))
        let display=CGRect(origin:.zero,size:natural).applying(upright)
        // Track transforms and crop coordinates use top-left pixels; CI uses
        // bottom-left pixels. Flip on both sides of the source orientation.
        let toTop=CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:natural.height)
        let toBottom=CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:display.height)
        mapping=toTop.concatenating(upright).concatenating(toBottom)
            .concatenating(CGAffineTransform(translationX:-crop.minX,y:-(display.height-crop.maxY)))
            .concatenating(CGAffineTransform(scaleX:CGFloat(width)/crop.width,y:CGFloat(height)/crop.height))
        bounds=CGRect(x:0,y:0,width:width,height:height)
        var created:CVPixelBufferPool?
        let attributes:[String:Any]=[kCVPixelBufferPixelFormatTypeKey as String:fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,
            kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
        guard CVPixelBufferPoolCreate(nil,nil,attributes as CFDictionary,&created)==kCVReturnSuccess,let created else { throw EngineError.io("자르기 픽셀 버퍼 생성 실패") }
        pool=created
    }
    func render(_ sample:CMSampleBuffer) throws -> CMSampleBuffer {
        guard let source=CMSampleBufferGetImageBuffer(sample) else { throw EngineError.io("원본 프레임 읽기 실패") }
        var pixel:CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&pixel)==kCVReturnSuccess,let pixel else { throw EngineError.io("자르기 프레임 메모리 오류") }
        CVBufferPropagateAttachments(source,pixel)
        let image=CIImage(cvPixelBuffer:source).transformed(by:mapping).cropped(to:bounds)
        context.render(image,to:pixel,bounds:bounds,colorSpace:nil)
        var description:CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator:nil,imageBuffer:pixel,formatDescriptionOut:&description)==noErr,let description else { throw EngineError.io("자르기 영상 정보 오류") }
        var timing=CMSampleTimingInfo(duration:CMSampleBufferGetOutputDuration(sample),presentationTimeStamp:CMSampleBufferGetOutputPresentationTimeStamp(sample),decodeTimeStamp:.invalid)
        var output:CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator:nil,imageBuffer:pixel,formatDescription:description,sampleTiming:&timing,sampleBufferOut:&output)==noErr,let output else { throw EngineError.io("자르기 프레임 생성 실패") }
        return output
    }
}

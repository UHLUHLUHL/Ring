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
        if let targetBytes, !(1...1_000_000_000_000).contains(targetBytes) { throw EngineError.invalid("목표 비디오 용량 오류") }
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
        // Fix geometry once. Retrying a byte target may only adjust video bits,
        // never resolution, sample timing, or audio quality.
        let shown=VideoCropGeometry.compressedSize(width:shownWidth,height:shownHeight,crop:options.crop,maxDimension:options.maxDimension)
        let region=options.crop.isFull ? nil:options.crop.pixelRect(width:max(1,Int(shownWidth.rounded())),height:max(1,Int(shownHeight.rounded())))
        let swapsAxes=region == nil && (abs(transform.b)>0.5 || abs(transform.c)>0.5)
        let width=swapsAxes ? shown.height:shown.width,height=swapsAxes ? shown.width:shown.height
        // A byte target is an upper bound, never permission to lower the frame
        // rate, audio quality, geometry or the automatic quality floor.
        let savingLimit=Int64(Double(info.sourceBytes)*0.99)
        let byteLimit=min(targetBytes ?? savingLimit,savingLimit)
        let budget=VideoCropGeometry.videoBitrate(targetBytes:byteLimit,duration:duration.seconds,audioBytes:info.audioBytes)
        guard budget.isFinite,budget>=100000,budget<Double(Int.max) else {
            throw EngineError.quality("원본 오디오·해상도·프레임을 유지하기에는 목표 용량이 너무 작아요. 목표를 높여 주세요.")
        }
        let scratch=try StagingWorkspace(beside:output),workspace=scratch.directory
        defer { scratch.cleanup() }
        let automatic=targetBytes == nil
        let best=workspace.appendingPathComponent("best.mp4")
        let maximumRate=Int(Int32.max)
        var bestQuality:VideoQualityReport?,bestBytes=0,attempts=0
        let fps=info.frameRate.isFinite && info.frameRate>0 ? info.frameRate:30
        let initial=automatic ? Double(width)*Double(height)*fps*(codec == .hevc ? 0.06:0.10):budget
        var rate=Int(max(100000,min(Double(maximumRate),budget,initial)))
        let progress=EngineProgress.handler
        var calibration=VideoRateCalibration(rate:rate,samples:[],constrained:automatic)
        if duration.seconds>=1 {
            calibration=try await calibratedVideoRate(track:track,duration:duration.seconds,workspace:workspace,
                rate:rate,maximumRate:maximumRate,width:width,height:height,natural:natural,transform:transform,
                crop:region,codec:codec,colors:info.colorProperties,fullRange:info.fullRange,
                targetVideoBytes:automatic ? nil:max(1,Double(byteLimit)-Double(info.audioBytes)-4096),
                maximumVideoBytes:max(1,Double(byteLimit)-Double(info.audioBytes)-4096))
            rate=calibration.rate
        }
        // Short probes choose requests; only fully measured and independently
        // verified full-file outputs can be published. At most two full encodes.
        for attempt in 0..<2 {
            try Task.checkCancellation()
            attempts+=1
            let candidate=workspace.appendingPathComponent("candidate-\(attempt).mp4")
            let base=0.05+0.40*Double(attempt),span=0.40
            try await EngineProgress.$handler.withValue({ value in progress?(base+span*0.75*value) }) {
                try await encode(asset,to:candidate,video:track,audio:audio.first,duration:duration,width:width,height:height,
                    transform:transform,natural:natural,crop:region,bitrate:rate,codec:codec,
                    colorProperties:info.colorProperties,fullRange:info.fullRange,constrainedRate:calibration.constrained)
            }
            let bytes=try candidate.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard bytes>0 else { throw EngineError.quality("비디오 인코딩 결과가 비어 있어요.") }
            let available=max(1,Double(byteLimit)-Double(info.audioBytes)-4096)
            let measured=max(1,Double(bytes)-Double(info.audioBytes)-4096)
            var fullQuality:VideoQualityReport?
            if Int64(bytes)<=byteLimit {
                let encoded=AVURLAsset(url:candidate),outTrack=try await encoded.loadTracks(withMediaType:.video)[0]
                let quality=try await EngineProgress.$handler.withValue({ value in progress?(base+span*(0.75+0.25*value)) }) {
                    try await VideoQuality.compare(source:asset,video:track,output:encoded,track:outTrack,width:width,height:height,
                        natural:natural,transform:transform,crop:region,fullRange:info.fullRange,duration:duration.seconds)
                }
                fullQuality=quality
                if preferVideoCandidate(quality,bytes:bytes,over:bestQuality,previousBytes:bestBytes,limit:byteLimit,automatic:automatic) {
                    if FileManager.default.fileExists(atPath:best.path) { try FileManager.default.removeItem(at:best) }
                    try FileManager.default.moveItem(at:candidate,to:best)
                    bestQuality=quality;bestBytes=bytes
                }
            }
            if FileManager.default.fileExists(atPath:candidate.path) { try FileManager.default.removeItem(at:candidate) }
            progress?(base+span)
            if automatic ? bestQuality != nil:bestQuality != nil && Double(bestBytes)>=Double(byteLimit)*0.90 { break }
            guard attempt==0 else { break }
            if automatic {
                if let quality=fullQuality {
                    // Learn optimism from this full encode rather than applying
                    // the old unconditional >=1.4 jump to every quality miss.
                    let nearby=calibration.samples.min { abs(log(Double($0.rate)/Double(rate))) < abs(log(Double($1.rate)/Double(rate))) }
                    let bias=max(0,(nearby?.quality.rateMargin(preferred:true) ?? 0)-quality.rateMargin(preferred:true))
                    let full=VideoRateSample(rate:rate,bytesPerSecond:measured/duration.seconds,quality:quality)
                    var corrected=calibration.samples.map { VideoRateSample(rate:$0.rate,bytesPerSecond:$0.bytesPerSecond,quality:$0.quality,bias:bias) }
                    corrected.removeAll { $0.rate==rate };corrected.append(full)
                    rate=qualityVideoRate(corrected,target:0.35,maximumRate:maximumRate,explore:false)
                    if rate<=full.rate { rate=Int(min(Double(maximumRate),ceil(Double(full.rate)*min(4,max(1.1,pow(10,-quality.rateMargin(preferred:true)/10)))))) }
                    rate=min(rate,Int(min(Double(maximumRate),Double(full.rate)*available/measured*0.98)))
                } else {
                    rate=max(100000,Int(Double(rate)*available/measured*0.98))
                }
            } else {
                // Correct the measured video payload, never copied audio. For
                // sparse/VFR material a single linear correction can miss a
                // bitrate-control jump; nearby probes resolve that cheaply.
                let desired=Int(max(100000,min(Double(maximumRate),Double(rate)*available/measured*0.975)))
                if duration.seconds>=1 {
                    let calibrated=try await calibratedVideoRate(track:track,duration:duration.seconds,workspace:workspace,
                        rate:desired,maximumRate:maximumRate,width:width,height:height,natural:natural,transform:transform,
                        crop:region,codec:codec,colors:info.colorProperties,fullRange:info.fullRange,
                        targetVideoBytes:available,fullRate:rate,fullVideoBytes:measured,fullConstrained:calibration.constrained)
                    calibration=calibrated
                    rate=calibrated.rate
                } else { rate=desired }
            }
        }
        guard let quality=bestQuality else {
            throw EngineError.quality(targetBytes == nil || targetBytes!>=savingLimit
                ? "원본 프레임·해상도·오디오와 화질 기준을 지키면서 줄일 수 있는 결과가 없어요. 원본을 유지했어요."
                : "목표 용량과 화질 기준을 함께 만족하는 결과를 찾지 못했어요. 원본은 유지했어요. 목표를 높이거나 비워 주세요.")
        }
        try Task.checkCancellation()
        EngineProgress.report(0.90)
        try await verify(best,duration:duration.seconds,videos:1,audios:audio.count,width:width,height:height)
        EngineProgress.report(0.92)
        let result=AVURLAsset(url:best),outVideo=try await result.loadTracks(withMediaType:.video)[0]
        try verifyFrameTiming(source:asset,video:track,output:result,track:outVideo)
        EngineProgress.report(0.94)
        let originalRange=try await track.load(.timeRange),outputRange=try await outVideo.load(.timeRange)
        let outTransform=try await outVideo.load(.preferredTransform)
        let expected=region == nil ? normalizedTransform(transform,width:width,height:height):.identity
        guard abs(originalRange.start.seconds-outputRange.start.seconds)<0.001,
              abs(originalRange.end.seconds-outputRange.end.seconds)<0.001,
              abs(expected.a-outTransform.a)<0.001,abs(expected.b-outTransform.b)<0.001,
              abs(expected.c-outTransform.c)<0.001,abs(expected.d-outTransform.d)<0.001,
              abs(expected.tx-outTransform.tx)<0.01,abs(expected.ty-outTransform.ty)<0.01 else {
            throw EngineError.quality("영상의 시작·끝 시각 또는 회전이 달라져 저장하지 않았어요.")
        }
        try await verifyVideoColor(outVideo,colors:info.colorProperties,fullRange:info.fullRange)
        EngineProgress.report(0.96)
        if let audio=audio.first {
            try await verifyOriginalAudio(source:asset,audio:audio,output:result,track:try await result.loadTracks(withMediaType:.audio)[0])
        }
        EngineProgress.report(0.98)
        let current=try source.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
        guard Int64(current.fileSize ?? 0)==info.sourceBytes,current.contentModificationDate==info.modified else {
            throw EngineError.invalid("작업 중 원본이 바뀌었어요. 새 원본으로 다시 열어 주세요.")
        }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at:best,to:output)
        EngineProgress.report(0.99)
        return "\(codec == .hevc ? "HEVC":"H.264") · \(shown.width)×\(shown.height) · 원본 프레임·오디오 유지 · \(bestBytes)바이트 · \(automatic ? "자동 화질 우선":"상한 내 화질 우선") · \(quality.summary) · 후보 \(attempts)회"
    }

    static func preferVideoCandidate(_ quality:VideoQualityReport,bytes:Int,over previous:VideoQualityReport?,
        previousBytes:Int,limit:Int64,automatic:Bool) -> Bool {
        guard bytes>0,Int64(bytes)<=limit,automatic ? quality.preferredForAutomatic:quality.acceptable else { return false }
        guard let previous else { return true }
        if automatic { return bytes<previousBytes }
        // First stay within the requested 90-100% band, then maximize actual
        // measured quality. Keep an underfilled safe fallback if no result fits.
        let fills=Double(bytes)>=Double(limit)*0.90,previousFills=Double(previousBytes)>=Double(limit)*0.90
        if fills != previousFills { return fills }
        return quality.distortion<previous.distortion || (quality.distortion==previous.distortion && bytes<previousBytes)
    }

    private struct VideoRateSample {
        let rate:Int,bytesPerSecond:Double,quality:VideoQualityReport
        var bias:Double=0
        var constrained:Bool=true
        var margin:Double { quality.rateMargin(preferred:true)-bias }
    }
    private struct VideoRateCalibration {
        let rate:Int,samples:[VideoRateSample]
        var constrained:Bool=true
    }

    /// Interpolate only a locally improving measured pair. A reversal cannot
    /// turn a failed probe into a pass: every candidate is decoded and measured.
    private static func qualityVideoRate(_ samples:[VideoRateSample],target:Double,maximumRate:Int,explore:Bool) -> Int {
        func bounded(_ value:Double) -> Int { Int(max(100000,min(Double(maximumRate),value.isFinite ? value:Double(maximumRate)))) }
        let passing=samples.filter { $0.margin>=target }.min { $0.bytesPerSecond<$1.bytesPerSecond }
        if let pass=passing {
            if let low=samples.filter({ $0.rate<pass.rate && $0.margin<target }).max(by:{ $0.rate<$1.rate }) {
                let weight=max(0,min(1,(target-low.margin)/(pass.margin-low.margin)))
                return bounded(exp(log(Double(low.rate))+(log(Double(pass.rate))-log(Double(low.rate)))*weight))
            }
            if !explore,let higher=samples.filter({ $0.rate>pass.rate && $0.margin>pass.margin+0.05 }).min(by:{ $0.rate<$1.rate }) {
                let slope=(higher.margin-pass.margin)/log(Double(higher.rate)/Double(pass.rate))
                return bounded(Double(pass.rate)*max(0.75,exp((target-pass.margin)/slope)))
            }
            return explore ? bounded(Double(pass.rate)*0.55):pass.rate
        }
        guard let best=samples.max(by:{ $0.margin<$1.margin }) else { return 100000 }
        if let lower=samples.filter({ $0.rate<best.rate && $0.margin<best.margin-0.05 }).max(by:{ $0.rate<$1.rate }) {
            let slope=(best.margin-lower.margin)/log(Double(best.rate)/Double(lower.rate))
            let factor=exp(min(log(4),max(log(1.1),(target-best.margin)/slope)))
            return bounded(Double(best.rate)*factor)
        }
        return bounded(Double(best.rate)*max(1.15,min(4,pow(10,(target-best.margin)/10))))
    }

    /// Distributed native-resolution windows also cover short clips and H.264.
    /// These are scheduling hints; the original quality policy is applied to
    /// every displayed picture of the selected full file, never to a prediction.
    private static func calibratedVideoRate(track:AVAssetTrack,duration:Double,workspace:URL,rate:Int,
        maximumRate:Int,width:Int,height:Int,natural:CGSize,transform:CGAffineTransform,crop:CGRect?,
        codec:VideoCodec,colors:[String:Any],fullRange:Bool,targetVideoBytes:Double? = nil,
        fullRate:Int? = nil,fullVideoBytes:Double? = nil,fullConstrained:Bool = true,
        maximumVideoBytes:Double? = nil) async throws -> VideoRateCalibration {
        let composition=AVMutableComposition()
        guard let sampled=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else {
            return .init(rate:rate,samples:[],constrained:targetVideoBytes == nil)
        }
        sampled.preferredTransform=transform
        var observations=[VideoRateSample](),next=fullRate ?? rate,constrained=targetVideoBytes == nil || fullRate != nil && fullConstrained
        var scales=[Bool:Double]()
        func bounded(_ value:Double)->Int { Int(max(100000,min(Double(maximumRate),value.isFinite ? value:Double(maximumRate)))) }
        func predicted(_ point:VideoRateSample)->Double { point.bytesPerSecond*(scales[point.constrained] ?? 1)*duration }
        do {
            let count=4,window=min(0.75,duration*0.45/Double(count))
            var position=CMTime.zero
            for index in 0..<count {
                try Task.checkCancellation()
                let start=(duration-window)*Double(index)/Double(count-1)
                let range=CMTimeRange(start:CMTime(seconds:start,preferredTimescale:600000),duration:CMTime(seconds:window,preferredTimescale:600000))
                try sampled.insertTimeRange(range,of:track,at:position);position=CMTimeAdd(position,range.duration)
            }
            for index in 0..<3 {
                try Task.checkCancellation()
                let url=workspace.appendingPathComponent("rate-probe-\(index)-\(UUID().uuidString).mp4")
                defer { try? FileManager.default.removeItem(at:url) }
                let observation:VideoRateSample=try await EngineProgress.$handler.withValue(nil) {
                    try await encode(composition,to:url,video:sampled,audio:nil,duration:position,width:width,height:height,
                        transform:transform,natural:natural,crop:crop,bitrate:next,codec:codec,colorProperties:colors,
                        fullRange:fullRange,constrainedRate:constrained)
                    let encoded=AVURLAsset(url:url),out=try await encoded.loadTracks(withMediaType:.video)[0]
                    let quality=try await VideoQuality.compare(source:composition,video:sampled,output:encoded,track:out,
                        width:width,height:height,natural:natural,transform:transform,crop:crop,fullRange:fullRange,duration:position.seconds)
                    let bytes=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                    return .init(rate:next,bytesPerSecond:Double(max(1,bytes))/position.seconds,quality:quality,constrained:constrained)
                }
                observations.append(observation)
                if let target=targetVideoBytes {
                    if index==0,let fullVideoBytes { scales[constrained]=(fullVideoBytes/duration)/observation.bytesPerSecond }
                    let size=predicted(observation)
                    // The distributed sample's rate can differ from the full
                    // file by about 10%. Near the budget, keep the measured
                    // request instead of scaling it into an encoder plateau.
                    // Only actual full-file bytes decide the 90-100% result.
                    if size>=target*0.85,size<=target*1.05,observation.quality.acceptable,
                       index>0 || observation.quality.preferredForAutomatic { break }
                    if index==0,fullRate==nil {
                        // Compare real outputs from the two hardware rate-control
                        // modes. A burst cap is efficient for some camera clips
                        // but is not universally better for screen recordings.
                        constrained=true;next=rate
                    } else if index==0 {
                        next=rate
                        if next==observation.rate { constrained = !constrained }
                    } else {
                        let fitting=observations.filter { predicted($0)<=target*0.98 }
                        let basis=(fitting.isEmpty ? observations:fitting).min { $0.quality.distortion<$1.quality.distortion }!
                        constrained=basis.constrained
                        let desired=target*0.955
                        if let other=observations.filter({ $0.constrained==constrained && $0.rate != basis.rate &&
                            (predicted($0)-predicted(basis))*Double($0.rate-basis.rate)>0 }).min(by:{ abs(predicted($0)-desired)<abs(predicted($1)-desired) }) {
                            let fraction=max(-1,min(2,(desired-predicted(basis))/(predicted(other)-predicted(basis))))
                            next=bounded(exp(log(Double(basis.rate))+fraction*log(Double(other.rate)/Double(basis.rate))))
                        } else { next=bounded(Double(basis.rate)*max(0.5,min(4,desired/predicted(basis)))) }
                    }
                } else {
                    // Observed optimism was about 0.28 dB with these windows.
                    // The extra 0.35 is a scheduling guard, not a policy change.
                    if index==1,observations.allSatisfy({$0.margin>=0.35}) {
                        next=qualityVideoRate(observations,target:0.35,maximumRate:maximumRate,explore:false)
                        break
                    }
                    next=qualityVideoRate(observations,target:0.35,maximumRate:maximumRate,explore:index<2)
                }
                if observations.contains(where:{ $0.rate==next && $0.constrained==constrained }) { break }
            }
            if let target=targetVideoBytes {
                let eligible=observations.filter { predicted($0)>=target*0.85 && predicted($0)<=target*1.05 && $0.quality.acceptable }
                if let best=eligible.min(by:{$0.quality.distortion<$1.quality.distortion}) {
                    next=best.rate;constrained=best.constrained
                } else {
                    let fitting=observations.filter { predicted($0)<=target*0.98 }
                    let basis=(fitting.isEmpty ? observations:fitting).min(by:{$0.quality.distortion<$1.quality.distortion})!
                    constrained=basis.constrained
                    // Use a locally increasing measured size pair when possible;
                    // a flat/descending response cannot justify interpolation.
                    let desired=target*0.955
                    if let other=observations.filter({ $0.constrained==constrained && $0.rate != basis.rate &&
                        (predicted($0)-predicted(basis))*Double($0.rate-basis.rate)>0 }).min(by:{ abs(predicted($0)-desired)<abs(predicted($1)-desired) }) {
                        let fraction=max(-1,min(2,(desired-predicted(basis))/(predicted(other)-predicted(basis))))
                        next=bounded(exp(log(Double(basis.rate))+fraction*log(Double(other.rate)/Double(basis.rate))))
                    } else { next=bounded(Double(basis.rate)*max(0.5,min(4,desired/predicted(basis)))) }
                }
            } else if let limit=maximumVideoBytes {
                // Do not spend a full encode on a probe-predicted file larger
                // than the source. This is only a request bound, never a quality
                // rejection: the bounded full file is still actually measured.
                if let closest=observations.min(by:{abs(log(Double($0.rate)/Double(next)))<abs(log(Double($1.rate)/Double(next)))}) {
                    let size=closest.bytesPerSecond*duration*Double(next)/Double(closest.rate)
                    if size>limit*0.98 { next=bounded(Double(next)*limit*0.98/size) }
                }
            }
            return .init(rate:next,samples:observations,constrained:constrained)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            return .init(rate:rate,samples:[],constrained:targetVideoBytes == nil)
        }
    }

    static func encode(_ asset:AVAsset,to output:URL,video:AVAssetTrack,audio:AVAssetTrack?,duration:CMTime,width:Int,height:Int,transform:CGAffineTransform,natural:CGSize,crop:CGRect?,bitrate:Int,codec:VideoCodec,
                       fileType:AVFileType = .mp4,colorProperties:[String:Any] = [:],fullRange:Bool = false,constrainedRate:Bool = false) async throws {
        let reader=try AVAssetReader(asset:asset),writer=try AVAssetWriter(outputURL:output,fileType:fileType)
        // Movie edit offsets otherwise default to a coarse timescale (often
        // 600), even when mediaTimeScale preserves individual sample intervals.
        var movieScale: Int64 = 1
        var scales = [duration.timescale, try await video.load(.naturalTimeScale)]
        if let audio { scales.append(try await audio.load(.naturalTimeScale)) }
        for scale in scales where scale > 0 {
            var a=movieScale,b=Int64(scale)
            while b != 0 { (a,b)=(b,a%b) }
            let combined=movieScale/a*Int64(scale)
            guard combined<=Int32.max else { throw EngineError.unsupported("원본 시간 정밀도를 유지하는 출력 시간 단위를 지원하지 않아요.") }
            movieScale=combined
        }
        writer.movieTimeScale=CMTimeScale(movieScale)
        let emptyEdits=try await emptyVideoEdits(video)
        let pixels=[kCVPixelBufferPixelFormatTypeKey as String:fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        // One decoded sample in, one encoded sample out. A video composition
        // would resample VFR onto a fixed cadence when cropping.
        let videoOutput=AVAssetReaderTrackOutput(track:video,outputSettings:pixels)
        videoOutput.alwaysCopiesSampleData=false
        let cropper=try frameRenderer(crop:crop,width:width,height:height,natural:natural,transform:transform,fullRange:fullRange)
        guard reader.canAdd(videoOutput) else { throw EngineError.unsupported("비디오 디코딩 경로를 지원하지 않아요.") };reader.add(videoOutput)
        var settings:[String:Any]=[
            AVVideoCodecKey:codec == .hevc ? AVVideoCodecType.hevc:AVVideoCodecType.h264,
            AVVideoWidthKey:width,AVVideoHeightKey:height,AVVideoScalingModeKey:AVVideoScalingModeResizeAspectFill,
            AVVideoEncoderSpecificationKey:[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String:true],
            AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:bitrate,AVVideoAllowFrameReorderingKey:true,
                AVVideoMaxKeyFrameIntervalDurationKey:2,
                AVVideoProfileLevelKey:codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel as String:AVVideoProfileLevelH264HighAutoLevel]]
        if constrainedRate {
            var compression=settings[AVVideoCompressionPropertiesKey] as! [String:Any]
            // AverageBitRate is a soft target. A bounded one-second reservoir
            // also avoids the inefficient low-rate ABR path on tested hardware.
            // This limits bursts, not the final muxed file; check actual bytes.
            compression[kVTCompressionPropertyKey_DataRateLimits as String]=[ceil(Double(bitrate)*1.4/8),1.0]
            settings[AVVideoCompressionPropertiesKey]=compression
            if !writer.canApply(outputSettings:settings,forMediaType:.video) {
                compression.removeValue(forKey:kVTCompressionPropertyKey_DataRateLimits as String)
                settings[AVVideoCompressionPropertiesKey]=compression
            }
        }
        if !colorProperties.isEmpty { settings[AVVideoColorPropertiesKey]=colorProperties }
        guard writer.canApply(outputSettings:settings,forMediaType:.video) else { throw EngineError.unsupported("선택한 출력 설정을 지원하지 않아요.") }
        let videoInput=AVAssetWriterInput(mediaType:.video,outputSettings:settings)
        videoInput.expectsMediaDataInRealTime=false
        videoInput.mediaTimeScale=CMTimeScale(movieScale)
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
                                    if input.mediaType == .video,isEmptyVideoEdit(sample,ranges:emptyEdits) { return true }
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

    static func emptyVideoEdits(_ track:AVAssetTrack) async throws -> [CMTimeRange] {
        try await track.load(.segments).filter(\.isEmpty).map { $0.timeMapping.target }
    }

    static func isEmptyVideoEdit(_ sample:CMSampleBuffer,ranges:[CMTimeRange]) -> Bool {
        let time=CMSampleBufferGetOutputPresentationTimeStamp(sample)
        return ranges.contains { CMTimeRangeContainsTime($0,time:time) }
    }

    static func frameRenderer(crop:CGRect?,width:Int,height:Int,natural:CGSize,transform:CGAffineTransform,fullRange:Bool) throws -> VideoCropRenderer? {
        if let crop { return try VideoCropRenderer(crop:crop,width:width,height:height,natural:natural,transform:transform,fullRange:fullRange) }
        guard width != Int(natural.width) || height != Int(natural.height) else { return nil }
        return try VideoCropRenderer(crop:CGRect(origin:.zero,size:natural),width:width,height:height,natural:natural,transform:.identity,fullRange:fullRange)
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
final class VideoCropRenderer {
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

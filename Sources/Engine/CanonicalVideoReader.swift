import Foundation
import AVFoundation
import CoreVideo

/// Actual decoded pictures and ISO-container PTS, excluding decoder preroll and
/// framework-generated black placeholders. Pixel transfer keeps Y/U/V intact;
/// VideoToolbox still performs the Apple hardware encode.
final class CanonicalVideoReader {
    private let frames:SoftwareVideo.Frames
    private var pending:RingSoftwareVideoFrame?
    private let pool:CVPixelBufferPool
    private let colors:[String:Any]
    let timeScale:CMTimeScale
    private(set) var endTime=CMTime.zero
    init(_ source:URL,fullRange:Bool,colors:[String:Any] = [:]) throws {
        frames=try SoftwareVideo.Frames(source)
        guard let first=try frames.next(),first.time_base_den>0 else { throw EngineError.quality("표시할 원본 프레임이 없어요.") }
        pending=first;timeScale=first.time_base_den;self.colors=colors
        let attributes:[String:Any]=[
            kCVPixelBufferWidthKey as String:Int(first.width),kCVPixelBufferHeightKey as String:Int(first.height),
            kCVPixelBufferPixelFormatTypeKey as String:fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String:[:]]
        var value:CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil,nil,attributes as CFDictionary,&value)==kCVReturnSuccess,let value else {
            throw EngineError.io("하드웨어 인코더용 프레임 풀 생성 실패")
        }
        pool=value
    }
    func next() throws -> CMSampleBuffer? {
        try Task.checkCancellation()
        let next:RingSoftwareVideoFrame?
        if let first=pending { next=first;pending=nil } else { next=try frames.next() }
        guard var frame=next else { return nil }
        var pixel:CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&pixel)==kCVReturnSuccess,let pixel,
              CVPixelBufferGetWidth(pixel)==Int(frame.width),CVPixelBufferGetHeight(pixel)==Int(frame.height),
              CVPixelBufferLockBaseAddress(pixel,[])==kCVReturnSuccess else { throw EngineError.io("원본 프레임 픽셀 버퍼 생성 실패") }
        let copied=ring_video_copy_nv12(&frame,
            CVPixelBufferGetBaseAddressOfPlane(pixel,0)?.assumingMemoryBound(to:UInt8.self),Int32(CVPixelBufferGetBytesPerRowOfPlane(pixel,0)),
            CVPixelBufferGetBaseAddressOfPlane(pixel,1)?.assumingMemoryBound(to:UInt8.self),Int32(CVPixelBufferGetBytesPerRowOfPlane(pixel,1)))
        CVPixelBufferUnlockBaseAddress(pixel,[])
        guard copied==1 else { throw EngineError.quality("원본 YUV 프레임 복사 실패") }
        for (key,attachment) in [(AVVideoColorPrimariesKey,kCVImageBufferColorPrimariesKey),
                            (AVVideoTransferFunctionKey,kCVImageBufferTransferFunctionKey),
                            (AVVideoYCbCrMatrixKey,kCVImageBufferYCbCrMatrixKey)] {
            if let value=colors[key] { CVBufferSetAttachment(pixel,attachment,value as CFTypeRef,.shouldPropagate) }
        }
        let pts=CMTimeMultiply(CMTime(value:frame.pts,timescale:frame.time_base_den),multiplier:frame.time_base_num)
        let duration=CMTimeMultiply(CMTime(value:frame.duration,timescale:frame.time_base_den),multiplier:frame.time_base_num)
        guard pts.seconds.isFinite,duration.seconds>0 else { throw EngineError.quality("원본 프레임의 표시 시각·길이가 없어요.") }
        var description:CMVideoFormatDescription?,sample:CMSampleBuffer?
        var timing=CMSampleTimingInfo(duration:duration,presentationTimeStamp:pts,decodeTimeStamp:.invalid)
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixel,formatDescriptionOut:&description)==noErr,
              CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:pixel,formatDescription:description!,sampleTiming:&timing,sampleBufferOut:&sample)==noErr,
              let sample else { throw EngineError.io("원본 시각을 유지한 영상 샘플 생성 실패") }
        endTime=CMTimeAdd(pts,duration)
        return sample
    }
    func seek(to time:Double) throws {
        pending=nil
        try frames.seek(to:max(0,time))
    }
}

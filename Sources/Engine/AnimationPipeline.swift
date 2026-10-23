import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

/// Quantize cumulative timestamps, not each delay: 15fps stays four seconds,
/// instead of rounding sixty independent delays to 0.07s (4.2 seconds).
struct AnimationPlan {
    struct Frame {
        let offset: Double
        let start: Int
        let end: Int
    }
    let scale: Int
    let frames: [Frame]
    var ticks: Int { frames.last!.end }
    var duration: Double { Double(ticks) / Double(scale) }

    init(duration: Double, fps: Double, format: AnimationFormat) {
        scale = format.isModern ? 1_000_000 : format == .gif ? 100 : 1000
        let total = max(format == .gif ? 1 : 2, Int((duration * Double(scale)).rounded()))
        var result: [Frame] = []
        let count = max(1, Int(ceil(duration * fps)))
        for i in 0..<count {
            let offset = Double(i) / fps
            let start = min(total, Int((offset * Double(scale)).rounded()))
            let end = i == count - 1 ? total : min(total, Int((Double(i + 1) / fps * Double(scale)).rounded()))
            if end > start { result.append(Frame(offset: offset, start: start, end: end)) }
        }
        frames = result.isEmpty ? [Frame(offset: 0, start: 0, end: total)] : result
    }

    private init(scale: Int, frames: [Frame]) { self.scale = scale; self.frames = frames }

    init(sourceOffsets: [Double], duration: Double, format: AnimationFormat) throws {
        scale = format.isModern ? 1_000_000 : format == .gif ? 100 : 1000
        let total = Int((duration * Double(scale)).rounded())
        guard !sourceOffsets.isEmpty, total >= sourceOffsets.count else {
            throw EngineError.unsupported("이 포맷의 시간 단위로 모든 프레임을 유지할 수 없어요. WebP나 동영상으로 저장해 주세요.")
        }
        var result: [Frame] = [], tick = 0
        for i in sourceOffsets.indices {
            // Quantize cumulative boundaries, reserving one tick for every
            // remaining frame. Never discard a short first/last VFR frame.
            let end = i == sourceOffsets.count-1 ? total : max(tick+1,
                min(total-(sourceOffsets.count-i-1), Int((sourceOffsets[i+1]*Double(scale)).rounded())))
            result.append(Frame(offset: sourceOffsets[i], start: tick, end: end))
            tick = end
        }
        frames = result
    }

    /// Three short windows retain local motion; a single opening scene is not
    /// representative enough to predict the size of an entire animation.
    var sample: AnimationPlan {
        sampled(window:4)
    }
    func sampled(window:Int) -> AnimationPlan {
        let width = min(window, frames.count)
        let starts = [0, max(0, (frames.count - width) / 2), frames.count - width]
        let indices = Set(starts.flatMap { Array($0..<($0 + width)) }).sorted()
        var tick = 0
        let selected = indices.map { index -> Frame in
            let original = frames[index], length = original.end - original.start
            defer { tick += length }
            return Frame(offset: original.offset, start: tick, end: tick + length)
        }
        return AnimationPlan(scale: scale, frames: selected)
    }
}

/// Shared by simultaneous Ring jobs. No architecture-specific instructions or
/// assumptions about Intel's logical CPUs being physical cores. Existing codec
/// libraries retain their own NEON/SSE runtime dispatch.
final class AnimationResources: @unchecked Sendable {
    static let shared = AnimationResources()
    private let lock = NSLock()
    private var active = 0
    func enter() { lock.lock(); active += 1; lock.unlock() }
    func leave() { lock.lock(); active -= 1; lock.unlock() }
    private var jobs: Int { lock.lock(); defer { lock.unlock() }; return max(1, active) }
    var workers: Int { max(1,ThermalPolicy.threads/jobs) }
    func frameCapacity(width: Int, height: Int, bytesPerPixel: Int = 4) -> Int {
        // 128MiB made a 4K GIF a one-worker job and disabled WebP segments.
        // Bound by RAM and concurrent jobs, with a hard 256MiB pixel allowance.
        // Codec working buffers are additional; high-resolution jobs use at
        // most two encoders instead of multiplying those buffers four times.
        let budget = min(256 * 1024 * 1024, Int(ProcessInfo.processInfo.physicalMemory / 32))
        return max(1, (budget / jobs) / max(1, width * height * bytesPerPixel))
    }
}

private final class AnimationFrameReader {
    let generator: AVAssetImageGenerator
    let recovery: AVAssetImageGenerator
    let start: Double
    let dimension: Int
    let crop: VideoCrop
    let asset: AVAsset
    let fps: Double
    private var size: CGSize?
    /// Seconds added to each output time, and the last time that may be asked for.
    private var timing: (offset: Double, latest: Double)?
    private var sampleTrack: AVAssetTrack?
    private var sampleMapping: CMTimeMapping?
    private var sequential: SequentialAnimationReader?
    private var triedSequential = false
    init(asset: AVAsset, start: Double, fps: Double, dimension: Int, maximumSize: CGSize, crop: VideoCrop) {
        self.start = start; self.dimension = dimension; self.crop = crop; self.asset = asset; self.fps = fps
        generator = AVAssetImageGenerator(asset: asset)
        recovery = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        recovery.appliesPreferredTrackTransform = true
        recovery.maximumSize = generator.maximumSize
        recovery.requestedTimeToleranceBefore = .zero
        recovery.requestedTimeToleranceAfter = .zero
    }

    /// Indexed files expose actual presentation timestamps without decoding
    /// their frames. A nominal-FPS offset cannot choose nearest frames in VFR
    /// clips with irregular intervals or long gaps. Keep the older bounded
    /// offset only for assets that cannot provide precise sample cursors.
    private func prepareTiming() async throws -> (offset: Double, latest: Double) {
        if let timing { return timing }
        if try await asset.load(.providesPreciseDurationAndTiming),
           let track = try await asset.loadTracks(withMediaType: .video).first,
           try await track.load(.canProvideSampleCursors) {
            let segments = try await track.load(.segments).filter { !$0.isEmpty }
            // Cursor timestamps belong to the media timeline. Container edits
            // (including B-frame lead-in) map it onto the displayed timeline.
            // Keep the previous path for compound/multi-edit timelines.
            if segments.count == 1 {
                sampleTrack = track
                sampleMapping = segments[0].timeMapping
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let value = (0.0, 0.0)
                timing = value
                return value
            }
        }
        let sourceFPS = try await MediaEngine.sourceFrameRate(asset) ?? fps
        let interval = 1 / max(1, sourceFPS)
        let end = try await asset.load(.duration).seconds
        generator.requestedTimeToleranceBefore = CMTime(seconds: min(0.002, interval * 0.03), preferredTimescale: 60000)
        generator.requestedTimeToleranceAfter = CMTime(seconds: min(0.01, interval * 0.25), preferredTimescale: 60000)
        let value = (interval * 0.45, max(0, end - 0.001))
        timing = value
        return value
    }

    private func nearestSample(to time: CMTime, track: AVAssetTrack) throws -> CMTime {
        guard let mapping = sampleMapping else { throw EngineError.io("영상 시각 매핑이 없어요.") }
        let mediaTime = CMTimeMapTimeFromRangeToRange(time, fromRange: mapping.target, toRange: mapping.source)
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: mediaTime) else {
            throw EngineError.io("영상 프레임의 시각을 읽을 수 없어요.")
        }
        let before = cursor.presentationTimeStamp
        var selected = before
        if CMTimeCompare(before, mediaTime) <= 0, cursor.stepInPresentationOrder(byCount: 1) == 1 {
            let after = cursor.presentationTimeStamp
            if CMTimeCompare(after, CMTimeRangeGetEnd(mapping.source)) < 0,
               abs(CMTimeSubtract(after, mediaTime).seconds) < abs(CMTimeSubtract(mediaTime, before).seconds) { selected = after }
        }
        selected = CMTimeMaximum(mapping.target.start, CMTimeMapTimeFromRangeToRange(selected, fromRange: mapping.source, toRange: mapping.target))
        guard selected.isNumeric else { throw EngineError.io("영상 프레임 시각이 올바르지 않아요.") }
        // Round into this sample, never a fraction before it. One common scale
        // also lets duplicate source-frame requests share a single decode.
        return CMTimeConvertScale(selected, timescale: 600_000_000, method: .roundTowardPositiveInfinity)
    }
    deinit { generator.cancelAllCGImageGeneration(); recovery.cancelAllCGImageGeneration() }

    private func fitted(_ image: CGImage) throws -> CGImage {
        let result = try autoreleasepool { () throws -> CGImage in
            let rect = crop.pixelRect(width: image.width, height: image.height)
            guard let cropped = image.cropping(to: rect) else { throw EngineError.io("비디오 프레임 자르기 실패") }
            return try ImageResampler.fit(cropped, maxDimension: dimension)
        }
        let current = CGSize(width: result.width, height: result.height)
        if let size, size != current { throw EngineError.unsupported("프레임별 해상도가 바뀌는 영상은 변환하지 않아요.") }
        size = current
        return result
    }

    func read(_ frames: ArraySlice<AnimationPlan.Frame>) async throws -> [CGImage] {
        try Task.checkCancellation()
        if !triedSequential {
            triedSequential = true
            sequential=try await SequentialAnimationReader.make(asset:asset,canonical:true)
            if sequential == nil,dimension>1280 { sequential=try await SequentialAnimationReader.make(asset:asset) }
        }
        if let sequential {
            return try frames.map { frame in
                try autoreleasepool {
                    let image = try sequential.image(at: start + frame.offset)
                    let extracted = try ImageResampler.fit(image, maxDimension: Int(max(generator.maximumSize.width, generator.maximumSize.height).rounded()))
                    return try fitted(extracted)
                }
            }
        }
        let timing = try await prepareTiming()
        // Near the end the shifted time may pass the last frame; keep t there.
        let times = try frames.map { frame -> CMTime in
            let t = start + frame.offset
            if let sampleTrack { return try nearestSample(to: CMTime(seconds: t, preferredTimescale: 600_000_000), track: sampleTrack) }
            return CMTime(seconds: t + timing.offset <= timing.latest ? t + timing.offset : t, preferredTimescale: 600_000_000)
        }
        // Slots near the end can share a time; ask for each time once.
        let slots = Dictionary(grouping: times.indices, by: { times[$0].value })
        let unique = times.indices.filter { slots[times[$0].value]![0] == $0 }.map { times[$0] }
        // Submit only the bounded window, so AVFoundation cannot prefetch all
        // 1,800 full-sized CGImages behind our bounded processing queue.
        return try await withTaskCancellationHandler {
            var ordered = [CGImage?](repeating: nil, count: times.count)
            var failed: [Int] = []
            for await result in generator.images(for: unique) {
                try Task.checkCancellation()
                let requested = CMTimeConvertScale(result.requestedTime, timescale: 600_000_000, method: .roundHalfAwayFromZero).value
                guard let shared = slots[requested], ordered[shared[0]] == nil else { throw EngineError.io("애니메이션 프레임 순서 오류") }
                let image: CGImage
                do { image = try result.image } catch {
                    try Task.checkCancellation()
                    failed.append(contentsOf: shared)
                    continue
                }
                let frame = try fitted(image)
                for index in shared { ordered[index] = frame }
            }
            // AVFoundation's batch decoder can reject repeated source frames
            // when upsampling (e.g. 30 -> 60fps). Individual exact-time requests
            // succeed; retry only those slots, without guessing a CFR timeline.
            for index in failed.sorted() {
                try Task.checkCancellation()
                ordered[index] = try fitted(await recovery.image(at: times[index]).image)
            }
            try Task.checkCancellation()
            guard ordered.allSatisfy({ $0 != nil }) else { throw EngineError.io("애니메이션 프레임 추출이 끝나지 않았어요.") }
            return ordered.map { $0! }
        } onCancel: { [generator, recovery] in
            generator.cancelAllCGImageGeneration(); recovery.cancelAllCGImageGeneration()
        }
    }
}

private final class WebPAnimationWriter {
    private let pointer: UnsafeMutableRawPointer
    init(width: Int, height: Int) throws {
        guard let value = ring_webp_animation_create(Int32(width), Int32(height)) else { throw EngineError.io("WebP 애니메이션 생성 실패") }
        pointer = value
    }
    deinit { ring_webp_animation_destroy(pointer) }
    static func frame(_ image:CGImage,quality:Int,threads:Int,effort:Int) throws -> Data {
        try Task.checkCancellation()
        let rgba=try AdaptivePalette.sRGB(image)
        var buffer:UnsafeMutablePointer<UInt8>?,count=0
        let ok=rgba.withUnsafeBytes {
            ring_webp_frame_encode($0.bindMemory(to:UInt8.self).baseAddress!,Int32(image.width),Int32(image.height),Int32(quality),Int32(threads),Int32(effort),&buffer,&count)
        }
        defer { ring_buffer_free(buffer) }
        guard ok==1,let buffer else { throw EngineError.io("WebP 프레임 압축 실패") }
        try Task.checkCancellation()
        return Data(bytes:buffer,count:count)
    }
    func add(_ image: CGImage, timestamp: Int, quality: Int, threads: Int, effort: Int = 4) throws {
        try Task.checkCancellation()
        try autoreleasepool {
            let rgba = try AdaptivePalette.sRGB(image)
            let ok = rgba.withUnsafeBytes {
                ring_webp_animation_add_tuned(pointer, $0.bindMemory(to: UInt8.self).baseAddress!, Int32(image.width), Int32(image.height), Int32(timestamp), Int32(quality), Int32(threads), Int32(effort))
            }
            guard ok == 1 else { throw EngineError.io("WebP 프레임 쓰기 실패") }
        }
        try Task.checkCancellation()
    }
    func finish(at timestamp: Int) throws -> Data {
        try Task.checkCancellation()
        var buffer: UnsafeMutablePointer<UInt8>?, count = 0
        let ok = ring_webp_animation_finish(pointer, Int32(timestamp), &buffer, &count)
        defer { ring_buffer_free(buffer) }
        guard ok == 1, let buffer else { throw EngineError.io("WebP 애니메이션 마감 실패") }
        return Data(bytes: buffer, count: count)
    }
}

private final class WebPAnimationMux {
    private let pointer: UnsafeMutableRawPointer
    init(width: Int, height: Int) throws {
        guard let value = ring_webp_mux_create(Int32(width), Int32(height)) else { throw EngineError.io("WebP 컨테이너 생성 실패") }
        pointer = value
    }
    deinit { ring_webp_mux_destroy(pointer) }
    func append(_ data: Data, frames: ArraySlice<AnimationPlan.Frame>) throws {
        try Task.checkCancellation()
        let durations=frames.map { Int32($0.end-$0.start) },duration=durations.reduce(0,+)
        let ok = durations.withUnsafeBufferPointer { timing in data.withUnsafeBytes {
            ring_webp_mux_append(pointer, $0.bindMemory(to: UInt8.self).baseAddress!, data.count, duration,timing.baseAddress!,Int32(durations.count))
        } }
        guard ok == 1 else { throw EngineError.io("WebP 구간 결합 실패") }
    }
    func finish() throws -> Data {
        try Task.checkCancellation()
        var buffer: UnsafeMutablePointer<UInt8>?, count = 0
        let ok = ring_webp_mux_finish(pointer, &buffer, &count)
        defer { ring_buffer_free(buffer) }
        guard ok == 1, let buffer else { throw EngineError.io("WebP 컨테이너 마감 실패") }
        return Data(bytes: buffer, count: count)
    }
}

struct AnimationEncoding {
    let bytes: Data
    let width: Int
    let height: Int
    let parallelWebP: Bool
}

/// Sequential composition avoids asking ImageIO to repeatedly reconstruct a
/// dependent WebP canvas during all-frame verification. Pixel/colour comparison
/// remains identical; the decoder also powers the app's WebP editing path.
private final class AnimationDecodedFrames {
    private let source:CGImageSource
    private var webp:UnsafeMutableRawPointer?
    private let width:Int,height:Int
    private var position = -1
    init(_ encoded:AnimationEncoding,format:AnimationFormat) throws {
        guard let source=CGImageSourceCreateWithData(encoded.bytes as CFData,nil) else { throw EngineError.quality("움짤 화질 검사 디코딩 실패") }
        self.source=source;width=encoded.width;height=encoded.height
        if format == .webp {
            var w:Int32=0,h:Int32=0,frames:Int32=0,loops:Int32=0
            webp=encoded.bytes.withUnsafeBytes { ring_webp_image_decoder_create($0.bindMemory(to:UInt8.self).baseAddress,encoded.bytes.count,Int32(ThermalPolicy.threads),&w,&h,&frames,&loops) }
            guard webp != nil,w==width,h==height,frames==CGImageSourceGetCount(source) else {
                ring_webp_image_decoder_destroy(webp);webp=nil
                throw EngineError.quality("WebP 순차 디코딩 검사 실패")
            }
        }
    }
    deinit { ring_webp_image_decoder_destroy(webp) }
    func image(_ index:Int) throws -> CGImage {
        if let webp {
            guard index==position+1 else { throw EngineError.quality("WebP 프레임 순서 검사 실패") }
            var pixels:UnsafePointer<UInt8>?
            guard ring_webp_image_decoder_next(webp,&pixels)==1,let pixels else { throw EngineError.quality("WebP 프레임 읽기 실패") }
            position=index
            let data=Data(bytes:pixels,count:width*height*4)
            guard let provider=CGDataProvider(data:data as CFData),let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { throw EngineError.quality("WebP 화질 검사 버퍼 오류") }
            return image
        }
        guard let image=CGImageSourceCreateImageAtIndex(source,index,nil) else { throw EngineError.quality("움짤 화질 검사 프레임 읽기 실패") }
        return image
    }
}

enum AnimationPipeline {
    /// Decode three distributed rasters once and reuse them across at most
    /// three measured codec requests. This only chooses the full-file request;
    /// every output frame still has to pass the final fidelity/timing checks.
    static func webPQuality(asset:AVAsset,start:Double,fps:Double,dimension:Int,extractionSize:CGSize,
                            crop:VideoCrop,plan:AnimationPlan,targetBytes:Int64?) async throws -> Int {
        guard plan.frames.count>=24 else { return targetBytes == nil ? 88:96 }
        let reader=AnimationFrameReader(asset:asset,start:start,fps:fps,dimension:dimension,maximumSize:extractionSize,crop:crop)
        let sample=plan.sampled(window:1)
        let capacity=max(1,min(sample.frames.count,AnimationResources.shared.frameCapacity(width:dimension,height:dimension)/2))
        let indices=capacity==1 ? [sample.frames.count/2]:(0..<capacity).map { $0*(sample.frames.count-1)/(capacity-1) }
        var images=[CGImage]()
        for index in indices { images+=try await reader.read(sample.frames[index..<(index+1)]) }
        var quality=targetBytes == nil ? 80:96
        var passing:(quality:Int,bytes:Int)?
        for attempt in 0..<(targetBytes == nil ? 2:3) {
            try Task.checkCancellation()
            var bytes=0,error=0.0,count=0,worst=Double.infinity
            for image in images {
                try autoreleasepool {
                    let data=try WebPAnimationWriter.frame(image,quality:quality,threads:AnimationResources.shared.workers,effort:2)
                    bytes+=data.count
                    guard let source=CGImageSourceCreateWithData(data as CFData,nil),let decoded=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw EngineError.quality("WebP 샘플 읽기 실패") }
                    let metrics=try PixelCheck.compare(image,decoded)
                    error+=metrics.squaredError;count+=metrics.sampleCount;worst=min(worst,metrics.psnr)
                }
            }
            let mean=error==0 ? 99:10*log10(65535.0*65535*Double(count)/error)
            if let targetBytes {
                let estimate=Double(bytes)*Double(plan.frames.count)/Double(images.count)
                if estimate<=Double(targetBytes)*0.94 { return quality }
                let step=max(1,Int(ceil((quality>80 ? 8.0:16.0)*log2(estimate/(Double(targetBytes)*0.94)))))
                quality=max(0,quality-step)
            } else {
                if mean>=40,worst>=36 {
                    if passing == nil || bytes<passing!.bytes { passing=(quality,bytes) }
                    if attempt>0 || mean<42 { break }
                    quality=72
                } else {
                    if passing != nil { break }
                    quality=96
                }
            }
        }
        return targetBytes == nil ? passing?.quality ?? 100:quality
    }

    /// Broad motion benefits from independent segments. Keep small changed
    /// rectangles in one encoder so screen recordings retain delta compression.
    static func motionFraction(_ first: CGImage, _ last: CGImage) throws -> Double {
        try changes(first,last).motion
    }
    private static func changes(_ first:CGImage,_ last:CGImage) throws -> (motion:Double,coverage:Double) {
        let resized=try ImageResampler.fit(first,maxDimension:64)
        let a = try AdaptivePalette.sRGB(resized)
        let b = try AdaptivePalette.sRGB(ImageResampler.fit(last, maxDimension: 64))
        guard a.count == b.count, !a.isEmpty else { return (1,1) }
        let width=resized.width,height=resized.height
        return a.withUnsafeBytes { ar in b.withUnsafeBytes { br in
            let x = ar.bindMemory(to: UInt8.self), y = br.bindMemory(to: UInt8.self)
            var changed = 0,subtleChanged=0,left=width,right = -1,top=height,bottom = -1
            for p in stride(from: 0, to: a.count, by: 4) {
                let difference=max(abs(Int(x[p])-Int(y[p])),abs(Int(x[p+1])-Int(y[p+1])),abs(Int(x[p+2])-Int(y[p+2])))
                if difference>12 {changed+=1}
                if difference>3 {
                    subtleChanged+=1
                    let px=(p/4)%width,py=(p/4)/width
                    left=min(left,px);right=max(right,px);top=min(top,py);bottom=max(bottom,py)
                }
            }
            // Isolated quantization noise must not turn a small moving cursor
            // into full-screen motion merely because its bounding box is wide.
            let coverage=right<left || Double(subtleChanged)/Double(width*height)<0.10 ? 0:Double((right-left+1)*(bottom-top+1))/Double(width*height)
            return (Double(changed)/Double(a.count/4),coverage)
        } }
    }
    private static func prefersParallel(_ first:CGImage,_ last:CGImage) throws -> Bool {
        let change=try changes(first,last)
        return change.motion>0.15 || change.coverage>0.65
    }

    static func encode(asset: AVAsset, start: Double, fps: Double, dimension: Int, extractionSize:CGSize? = nil,
                       crop: VideoCrop = .full, plan: AnimationPlan, format: AnimationFormat, quality: Int,
                       allowParallelWebP: Bool, maximumBytes: Int? = nil, webpEffort: Int = 4, stableGIF: Bool = false, progress: (Double) -> Void) async throws -> AnimationEncoding {
        let resources = AnimationResources.shared
        let reader = AnimationFrameReader(asset: asset, start: start, fps: fps, dimension: dimension,
                                          maximumSize:extractionSize ?? CGSize(width:dimension,height:dimension),crop: crop)
        if format.isModern {
            let first = try await reader.read(plan.frames[0..<1])[0]
            let writer = try ModernImageWriter(format: format == .avif ? .avif : .jxl,
                width: first.width, height: first.height, frameCount: plan.frames.count,
                timeScale: plan.scale, loops: 0, icc: first.colorSpace?.copyICCData() as Data? ?? Data(),
                exif: Data(), quality: 100, isAnimated: true)
            for index in plan.frames.indices {
                try Task.checkCancellation()
                let image = index == 0 ? first : try await reader.read(plan.frames[index..<(index+1)])[0]
                try writer.add(image, durationTicks: plan.frames[index].end-plan.frames[index].start)
                progress(Double(index+1)/Double(plan.frames.count))
            }
            let bytes = try writer.finish()
            if let maximumBytes, bytes.count > maximumBytes { throw EngineError.quality("움짤 결과가 허용한 용량을 넘어요. 크기·프레임은 자동으로 낮추지 않았어요.") }
            let decoded = try ModernImageReader(data: bytes)
            guard decoded.frameCount == plan.frames.count, decoded.timeScale == plan.scale,
                  decoded.durationTicks == plan.frames.map({ $0.end-$0.start }), decoded.loops == 0 else {
                throw EngineError.quality("움짤의 프레임·재생 시각·반복 검증 실패")
            }
            // Lossless encoding is checked against each actual extracted raster.
            let reference = AnimationFrameReader(asset: asset, start: start, fps: fps, dimension: dimension,
                maximumSize: extractionSize ?? CGSize(width:dimension,height:dimension), crop: crop)
            for index in plan.frames.indices {
                try Task.checkCancellation()
                let image = try await reference.read(plan.frames[index..<(index+1)])[0]
                let actual = try decoded.frame(index)
                guard actual.colorSpace?.copyICCData() == image.colorSpace?.copyICCData(),
                      try PixelCheck.compare(image, actual).exact else { throw EngineError.quality("움짤 프레임의 픽셀·색상·투명도 보존 검증 실패") }
            }
            return AnimationEncoding(bytes: bytes, width: first.width, height: first.height, parallelWebP: false)
        }
        var palette:AdaptivePalette.StablePalette?
        if format == .gif,stableGIF {
            let sampleReader=AnimationFrameReader(asset:asset,start:start,fps:fps,dimension:320,maximumSize:extractionSize ?? CGSize(width:dimension,height:dimension),crop:crop)
            let samples=try await sampleReader.read(plan.sample.frames[...])
            palette=try AdaptivePalette.StablePalette(images:samples,quality:quality)
        } else { palette=nil }
        let initialLimit = format == .gif ? resources.workers : 4
        let initialCount = min(plan.frames.count, min(initialLimit, max(1, resources.frameCapacity(width: dimension, height: dimension, bytesPerPixel: format == .gif ? 12 : 4) / 2)))
        var images = try await reader.read(plan.frames[0..<initialCount])
        let width = images[0].width, height = images[0].height
        var parallelWebP = false
        if format == .webp, allowParallelWebP, resources.workers > 1, plan.frames.count >= 8 {
            parallelWebP = try prefersParallel(images[0], images[images.count - 1])
        }
        let memory = NSMutableData()
        let gif: CGImageDestination?
        if format == .gif {
            gif = CGImageDestinationCreateWithData(memory, "com.compuserve.gif" as CFString, plan.frames.count, nil)
            guard let gif else { throw EngineError.io("GIF 인코더 생성 실패") }
            CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0, kCGImagePropertyGIFHasGlobalColorMap: false]] as CFDictionary)
        } else { gif = nil }
        let mux = format == .webp ? try WebPAnimationMux(width: width, height: height) : nil
        var continuous: WebPAnimationWriter?
        var continuousOrigin = 0
        var continuousPosition = 0
        var usedParallelWebP = false
        var previousGIF: GIFDeltaFrame?
        var gifRegions: [CGRect] = []
        var position = 0
        while position < plan.frames.count {
            try Task.checkCancellation()
            let prefetchEnabled = width * height <= 1280 * 720
            let capacity = max(1, resources.frameCapacity(width: width, height: height, bytesPerPixel: format == .gif ? 12 : 4) / (prefetchEnabled ? 2 : 1))
            let workers = min(resources.workers, capacity, width*height>1920*1080 ? 2:Int.max)
            let chunkSize = 4
            // Decode ahead within the byte budget. Tiny extraction requests
            // repeatedly restart AVFoundation's batch decoder and lose most of
            // the parallel encoder's gain, especially on low-motion clips.
            let desired = gif != nil ? min(workers * 4, capacity) :
                (parallelWebP ? min(workers * (prefetchEnabled ? 8:chunkSize),capacity) : min(32, capacity))
            let count = min(plan.frames.count - position, max(images.count, desired))
            if images.count < count {
                images += try await reader.read(plan.frames[(position + images.count)..<(position + count)])
            }
            let batch = images
            if let current=palette {
                // Keep a palette until the scene's colours actually outgrow
                // it. This avoids per-frame palette flicker without forcing a
                // dark or newly saturated scene into the opening palette.
                let probe=try ImageResampler.fit(batch[0],maxDimension:160)
                let mapped=try AdaptivePalette.indexed(probe,quality:quality,stable:current)
                if try PixelCheck.compare(probe,mapped).psnr<34 {
                    let indices=Set([0,batch.count/2,batch.count-1]).sorted()
                    let local=try indices.map {try ImageResampler.fit(batch[$0],maxDimension:320)}
                    palette=try AdaptivePalette.StablePalette(images:local,quality:quality)
                }
            }
            let batchPalette=palette
            // Re-evaluate local motion after decode-ahead. A quiet opening
            // must not force the rest of a moving clip through a serial encoder.
            if format == .webp {
                parallelWebP = try allowParallelWebP && workers > 1 && batch.count >= 4 &&
                    prefersParallel(batch[0],batch[batch.count-1])
                if parallelWebP {
                    if let writer = continuous {
                        let end = plan.frames[position].start
                        try mux!.append(writer.finish(at:end-continuousOrigin),frames:plan.frames[continuousPosition..<position])
                        continuous = nil
                    }
                    usedParallelWebP = true
                } else if continuous == nil {
                    continuous = try WebPAnimationWriter(width:width,height:height)
                    continuousOrigin = plan.frames[position].start
                    continuousPosition = position
                }
            }
            // One reader owns the generator; it prepares the next bounded
            // window while the current window is encoded. Both windows share
            // the RAM-bounded pixel allowance across active animation jobs.
            let nextPosition = position + count
            let nextCount = min(desired, plan.frames.count - nextPosition)
            let prefetch: Task<[CGImage], Error>? = prefetchEnabled && nextCount > 0 ? Task {
                try await reader.read(plan.frames[nextPosition..<(nextPosition + nextCount)])
            } : nil
            try await withTaskCancellationHandler {
                do {
                    if let gif {
                        let prepared = try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
                            // The first extraction window may be larger than the current
                            // thermal worker limit. Admit new work only after a result.
                            var next = 0, values: [(Int, CGImage)] = []
                            func submit(_ index: Int) {
                                let image = batch[index]
                                group.addTask { try Task.checkCancellation(); return try autoreleasepool { (index, try AdaptivePalette.indexed(image,quality:quality,stable:batchPalette)) } }
                            }
                            while next < min(workers, batch.count) { submit(next); next += 1 }
                            while let value = try await group.next() {
                                values.append(value)
                                if next < batch.count { submit(next); next += 1 }
                            }
                            return values.sorted { $0.0 < $1.0 }
                        }
                        for (index, image) in prepared {
                            try Task.checkCancellation()
                            let frame = plan.frames[position + index]
                            let delay = Double(frame.end - frame.start) / Double(plan.scale)
                            let prepared = try GIFDeltaFrame(image)
                            let region = try prepared.changedRegion(after:previousGIF)
                            let delta = try prepared.cropped(to:region)
                            gifRegions.append(region)
                            CGImageDestinationAddImage(gif, delta, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
                            if let maximumBytes, memory.length > maximumBytes { throw EngineError.quality("GIF가 250MB를 넘어 중단했어요. 크기·구간을 줄이거나 큰 파일 저장을 직접 허용해 주세요.") }
                            previousGIF = prepared
                        }
                    } else if let continuous {
                        for (index, image) in batch.enumerated() {
                            try continuous.add(image, timestamp: plan.frames[position + index].start - continuousOrigin, quality: quality, threads: resources.workers, effort: webpEffort)
                        }
                    } else if let mux {
                        let base = position
                        // Two 4K encoders may each use the codec's two-thread
                        // path, within the same four-worker thermal allowance.
                        let encoderThreads = width*height>1920*1080 ? max(1,resources.workers/workers):1
                        let parts = try await withThrowingTaskGroup(of: (Int, Data, Int).self) { group in
                            let offsets = Array(stride(from: 0, to: batch.count, by: chunkSize))
                            func submit(_ offset: Int) {
                                let chunk = Array(batch[offset..<min(offset + chunkSize, batch.count)])
                                let timing = Array(plan.frames[(base + offset)..<(base + offset + chunk.count)])
                                group.addTask {
                                    let writer = try WebPAnimationWriter(width: width, height: height)
                                    let origin = timing[0].start
                                    for (i, image) in chunk.enumerated() {
                                        try writer.add(image, timestamp: timing[i].start - origin, quality: quality, threads: encoderThreads, effort: webpEffort)
                                    }
                                    let duration = timing.last!.end - origin
                                    return (offset, try writer.finish(at: duration), duration)
                                }
                            }
                            var next = 0, values: [(Int, Data, Int)] = []
                            while next < min(workers, offsets.count) { submit(offsets[next]); next += 1 }
                            while let value = try await group.next() {
                                values.append(value)
                                if next < offsets.count { submit(offsets[next]); next += 1 }
                            }
                            return values.sorted { $0.0 < $1.0 }
                        }
                        for (offset, bytes, _) in parts {
                            try mux.append(bytes, frames:plan.frames[(base+offset)..<min(base+offset+chunkSize,base+count)])
                        }
                    }
                    position = nextPosition
                    images = try await prefetch?.value ?? []
                } catch {
                    prefetch?.cancel()
                    _ = try? await prefetch?.value
                    throw error
                }
            } onCancel: { prefetch?.cancel() }
            progress(Double(position) / Double(plan.frames.count))
        }
        try Task.checkCancellation()
        let bytes: Data
        if let gif {
            guard CGImageDestinationFinalize(gif) else { throw EngineError.io("GIF 마감 실패") }
            bytes = try opaqueGIF(memory as Data,regions:gifRegions)
        } else if let mux {
            if let continuous { try mux.append(continuous.finish(at: plan.ticks-continuousOrigin), frames:plan.frames[continuousPosition..<plan.frames.count]) }
            bytes = try mux.finish()
        } else { throw EngineError.io("애니메이션 인코더 없음") }
        try Task.checkCancellation()
        if let maximumBytes, bytes.count > maximumBytes { throw EngineError.quality("움짤이 250MB를 넘어 저장하지 않았어요. 크기·구간을 줄이거나 큰 파일 저장을 직접 허용해 주세요.") }
        return AnimationEncoding(bytes: bytes, width: width, height: height, parallelWebP: usedParallelWebP)
    }

    /// Store only changed rectangles. Identical frames keep a 1px image and
    /// their original delay; no frame or playback time is removed.
    struct GIFDeltaFrame {
        let image: CGImage
        let indices: CFData
        let colors: [UInt32]
        init(_ image: CGImage) throws {
            guard image.bitsPerPixel == 8, let indices=image.dataProvider?.data,
                  CFDataGetLength(indices)>=image.bytesPerRow*image.height,
                  let palette=image.colorSpace?.colorTable else { throw EngineError.io("GIF 팔레트 읽기 실패") }
            self.image=image;self.indices=indices
            var colors=[UInt32](repeating:0,count:256)
            for i in 0..<(palette.count/3) {
                colors[i]=UInt32(palette[i*3])<<16 | UInt32(palette[i*3+1])<<8 | UInt32(palette[i*3+2])
            }
            self.colors=colors
        }
        func cropped(to region: CGRect) throws -> CGImage {
            let x=Int(region.minX),y=Int(region.minY),width=Int(region.width),height=Int(region.height)
            if x==0 && y==0 && width==image.width && height==image.height { return image }
            // A cropped indexed CGImage can retain its parent's row stride and
            // provider offset. Give ImageIO tightly packed, owned rows so the
            // final scanline is encoded exactly, including odd-width regions.
            var pixels=Data(count:width*height)
            pixels.withUnsafeMutableBytes { bytes in
                let source=CFDataGetBytePtr(indices)!,destination=bytes.bindMemory(to:UInt8.self).baseAddress!
                for row in 0..<height {
                    destination.advanced(by:row*width).update(from:source.advanced(by:(y+row)*image.bytesPerRow+x),count:width)
                }
            }
            guard let provider=CGDataProvider(data:pixels as CFData),let space=image.colorSpace,
                  let result=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:width,
                    space:space,bitmapInfo:image.bitmapInfo,provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {
                throw EngineError.io("GIF 변경 영역 생성 실패")
            }
            return result
        }
        func changedRegion(after previous: GIFDeltaFrame?) throws -> CGRect {
            guard let previous else { return CGRect(x:0,y:0,width:image.width,height:image.height) }
            let a=CFDataGetBytePtr(indices)!,b=CFDataGetBytePtr(previous.indices)!
            var left=image.width,right = -1,top=image.height,bottom = -1
            for y in 0..<image.height {
                if y & 31 == 0 { try Task.checkCancellation() }
                for x in 0..<image.width where colors[Int(a[y*image.bytesPerRow+x])] != previous.colors[Int(b[y*previous.image.bytesPerRow+x])] {
                    left=min(left,x);right=max(right,x);top=min(top,y);bottom=y
                    if left == 0 && right == image.width-1 { break }
                }
            }
            return right < left ? CGRect(x:0,y:0,width:1,height:1):
                CGRect(x:left,y:top,width:right-left+1,height:bottom-top+1)
        }
    }

    /// ImageIO supplies the LZW payload and local palette. Set each cropped
    /// image's placement and retain the preceding canvas (opaque disposal 1).
    static func opaqueGIF(_ data: Data,regions:[CGRect] = []) throws -> Data {
        var data = data
        try data.withUnsafeMutableBytes { raw in
            let b = raw.bindMemory(to: UInt8.self), n = b.count
            guard n >= 13, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 else { throw EngineError.quality("GIF 헤더 검사 실패") }
            b[3] = 0x38; b[4] = 0x39; b[5] = 0x61
            var p = 13, frameIndex = 0
            if b[10] & 0x80 != 0 { p += 3 << (Int(b[10] & 7) + 1) }
            func skipSubBlocks() throws {
                while true {
                    guard p < n else { throw EngineError.quality("GIF 블록 검사 실패") }
                    let length = Int(b[p]); p += 1
                    if length == 0 { return }
                    p += length
                }
            }
            while p < n {
                switch b[p] {
                case 0x21:
                    guard p + 2 < n else { throw EngineError.quality("GIF 블록 검사 실패") }
                    // Keep the reserved and user-input bits; disposal 1, no transparency.
                    if b[p + 1] == 0xF9, b[p + 2] == 4, p + 3 < n { b[p + 3] = b[p + 3] & 0xE2 | 0x04 }
                    p += 2
                    try skipSubBlocks()
                case 0x2C:
                    guard p + 10 < n else { throw EngineError.quality("GIF 블록 검사 실패") }
                    let canvasWidth=Int(b[6]) | Int(b[7])<<8,canvasHeight=Int(b[8]) | Int(b[9])<<8
                    let width=Int(b[p+5]) | Int(b[p+6])<<8,height=Int(b[p+7]) | Int(b[p+8])<<8
                    let region: CGRect
                    if regions.isEmpty { region=CGRect(x:0,y:0,width:canvasWidth,height:canvasHeight) }
                    else {
                        guard frameIndex<regions.count else { throw EngineError.quality("GIF 프레임 수 검사 실패") }
                        region=regions[frameIndex]
                    }
                    guard width==Int(region.width),height==Int(region.height),region.minX>=0,region.minY>=0,
                          region.maxX<=Double(canvasWidth),region.maxY<=Double(canvasHeight),
                          frameIndex>0 || (width==canvasWidth && height==canvasHeight) else { throw EngineError.quality("GIF 프레임 영역 검사 실패") }
                    b[p+1]=UInt8(Int(region.minX)&255);b[p+2]=UInt8(Int(region.minX)>>8)
                    b[p+3]=UInt8(Int(region.minY)&255);b[p+4]=UInt8(Int(region.minY)>>8)
                    frameIndex += 1
                    let flags = b[p + 9]
                    p += 10
                    if flags & 0x80 != 0 { p += 3 << (Int(flags & 7) + 1) }
                    p += 1
                    try skipSubBlocks()
                case 0x3B:
                    guard regions.isEmpty || frameIndex==regions.count else { throw EngineError.quality("GIF 프레임 수 검사 실패") }
                    return
                default:
                    throw EngineError.quality("GIF 블록 검사 실패")
                }
            }
            throw EngineError.quality("GIF 끝 표시 없음")
        }
        return data
    }

    /// Measure every selected, composited frame against its actual extracted
    /// raster. Timing/geometry are independently checked above; a cap is never
    /// permission to drop frames or conceal a size reduction.
    static func verifyQuality(_ encoded:AnimationEncoding,asset:AVAsset,start:Double,fps:Double,dimension:Int,
        extractionSize:CGSize,crop:VideoCrop,plan:AnimationPlan,format:AnimationFormat,automatic:Bool) async throws -> String {
        let decoder=try AnimationDecodedFrames(encoded,format:format)
        let reference=AnimationFrameReader(asset:asset,start:start,fps:fps,dimension:dimension,maximumSize:extractionSize,crop:crop)
        let meanFloor:Double = format == .gif ? (automatic ? 30:27):(automatic ? 36:32)
        let frameFloor=meanFloor-4
        var error=0.0,samples=0,worst=Double.infinity
        for index in plan.frames.indices {
            try Task.checkCancellation()
            let original=try await reference.read(plan.frames[index..<(index+1)])[0]
            let metrics=try autoreleasepool { () throws -> PixelMetrics in
                let decoded=try decoder.image(index)
                guard format != .gif || [.none,.noneSkipLast,.noneSkipFirst].contains(decoded.alphaInfo) else {
                    throw EngineError.quality("GIF 프레임의 불투명도 보존 검사 실패")
                }
                return try PixelCheck.compare(original,decoded)
            }
            error+=metrics.squaredError;samples+=metrics.sampleCount;worst=min(worst,metrics.psnr)
            EngineProgress.report(0.82+0.12*Double(index+1)/Double(plan.frames.count))
        }
        let average=error == 0 ? 99:10*log10(65535.0*65535*Double(samples)/error)
        guard average>=meanFloor,worst>=frameFloor else {
            throw AnimationQualityFailure(average:average,worst:worst)
        }
        return String(format:"전체 %d프레임 검증 · PSNR %.2f / 최저 %.2f dB",plan.frames.count,average,worst)
    }

    static func verify(_ encoded: AnimationEncoding, plan: AnimationPlan, format: AnimationFormat) throws {
        if format.isModern {
            let reader = try ModernImageReader(data: encoded.bytes)
            guard reader.frameCount == plan.frames.count, reader.width == encoded.width,
                  reader.height == encoded.height, reader.timeScale == plan.scale,
                  reader.durationTicks == plan.frames.map({ $0.end-$0.start }) else { throw EngineError.quality("움짤 크기·타이밍 검증 실패") }
            return
        }
        guard let source = CGImageSourceCreateWithData(encoded.bytes as CFData, nil), CGImageSourceGetStatus(source) == .statusComplete else { throw EngineError.quality("애니메이션 디코딩 검사 실패") }
        let count = CGImageSourceGetCount(source)
        // A one-frame WebP needs two identical holds to prevent libwebp's mux
        // from converting it to a still image and discarding its duration.
        let singleWebPHold = format == .webp && plan.frames.count == 1 && count == 2
        guard count == plan.frames.count || singleWebPHold else { throw EngineError.quality("애니메이션 프레임 수 검사 실패 (\(count)/\(plan.frames.count))") }
        var duration = 0.0
        for index in 0..<count {
            try Task.checkCancellation()
            // Decode representative frames including both ends; inspect every
            // frame's dimensions and timing without an expensive full replay.
            if index == 0 || index == count / 2 || index == count - 1 {
                try autoreleasepool {
                    guard let image = CGImageSourceCreateImageAtIndex(source, index, nil), image.width == encoded.width, image.height == encoded.height else { throw EngineError.quality("애니메이션 프레임 디코딩 실패") }
                    // Video frames are opaque; a GIF that decodes with alpha shows holes.
                    guard format != .gif || [.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo) else { throw EngineError.quality("GIF 투명 픽셀 검사 실패") }
                }
            }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { throw EngineError.quality("애니메이션 프레임 속성 검사 실패") }
            if let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int {
                guard w == encoded.width, h == encoded.height else { throw EngineError.quality("애니메이션 프레임 크기 검사 실패") }
            }
            let dictionary = properties[format == .gif ? kCGImagePropertyGIFDictionary : kCGImagePropertyWebPDictionary] as? [CFString: Any]
            let unclamped = format == .gif ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyWebPUnclampedDelayTime
            let fallback = format == .gif ? kCGImagePropertyGIFDelayTime : kCGImagePropertyWebPDelayTime
            guard let delay = dictionary?[unclamped] as? Double ?? dictionary?[fallback] as? Double, delay.isFinite, delay > 0 else { throw EngineError.quality("애니메이션 프레임 시간 검사 실패") }
            if !singleWebPHold {
                let expected=Double(plan.frames[index].end-plan.frames[index].start)/Double(plan.scale)
                guard abs(delay-expected)<0.0001 else { throw EngineError.quality("애니메이션 개별 프레임 시간 검사 실패") }
            }
            duration += delay
        }
        guard abs(duration - plan.duration) < 0.0025 else { throw EngineError.quality("애니메이션 재생 길이 검사 실패") }
    }
}

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
        scale = format == .gif ? 100 : 1000
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

    /// Three short windows retain local motion; a single opening scene is not
    /// representative enough to predict the size of an entire animation.
    var sample: AnimationPlan {
        let width = min(4, frames.count)
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
    var workers: Int { max(1, ThermalPolicy.threads / jobs) }
    func frameCapacity(width: Int, height: Int, bytesPerPixel: Int = 4) -> Int {
        max(1, (128 * 1024 * 1024 / jobs) / max(1, width * height * bytesPerPixel))
    }
}

private final class AnimationFrameReader {
    let generator: AVAssetImageGenerator
    let recovery: AVAssetImageGenerator
    let start: Double
    let dimension: Int
    let cropRatio: VideoCropRatio
    private var size: CGSize?
    init(asset: AVAsset, start: Double, fps: Double, dimension: Int, maximumSize: CGSize, cropRatio: VideoCropRatio) {
        self.start = start; self.dimension = dimension; self.cropRatio = cropRatio
        generator = AVAssetImageGenerator(asset: asset)
        recovery = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        recovery.appliesPreferredTrackTransform = true
        recovery.maximumSize = generator.maximumSize
        recovery.requestedTimeToleranceBefore = .zero
        recovery.requestedTimeToleranceAfter = .zero
        let tolerance = CMTime(seconds: min(0.01, 0.25 / fps), preferredTimescale: 60000)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
    }
    deinit { generator.cancelAllCGImageGeneration(); recovery.cancelAllCGImageGeneration() }

    private func fitted(_ image: CGImage) throws -> CGImage {
        let result = try autoreleasepool { () throws -> CGImage in
            let rect = VideoCropGeometry.centeredRect(width: image.width, height: image.height, ratio: cropRatio)
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
        let times = frames.map { CMTime(seconds: start + $0.offset, preferredTimescale: 60000) }
        let indices = Dictionary(uniqueKeysWithValues: times.enumerated().map { ($0.element.value, $0.offset) })
        // Submit only the bounded window, so AVFoundation cannot prefetch all
        // 1,800 full-sized CGImages behind our bounded processing queue.
        return try await withTaskCancellationHandler {
            var ordered = [CGImage?](repeating: nil, count: times.count)
            var failed: [Int] = []
            for await result in generator.images(for: times) {
                try Task.checkCancellation()
                let requested = CMTimeConvertScale(result.requestedTime, timescale: 60000, method: .roundHalfAwayFromZero).value
                guard let index = indices[requested], ordered[index] == nil else { throw EngineError.io("애니메이션 프레임 순서 오류") }
                let image: CGImage
                do { image = try result.image } catch {
                    try Task.checkCancellation()
                    failed.append(index)
                    continue
                }
                ordered[index] = try fitted(image)
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
    func add(_ image: CGImage, timestamp: Int, quality: Int, threads: Int) throws {
        try Task.checkCancellation()
        try autoreleasepool {
            let rgba = try AdaptivePalette.sRGB(image)
            let ok = rgba.withUnsafeBytes {
                ring_webp_animation_add(pointer, $0.bindMemory(to: UInt8.self).baseAddress!, Int32(image.width), Int32(image.height), Int32(timestamp), Int32(quality), Int32(threads))
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
    func append(_ data: Data, duration: Int) throws {
        try Task.checkCancellation()
        let ok = data.withUnsafeBytes { ring_webp_mux_append(pointer, $0.bindMemory(to: UInt8.self).baseAddress!, data.count, Int32(duration)) }
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

enum AnimationPipeline {
    /// Broad motion benefits from independent segments. Keep small changed
    /// rectangles in one encoder so screen recordings retain delta compression.
    static func motionFraction(_ first: CGImage, _ last: CGImage) throws -> Double {
        let a = try AdaptivePalette.sRGB(ImageResampler.fit(first, maxDimension: 64))
        let b = try AdaptivePalette.sRGB(ImageResampler.fit(last, maxDimension: 64))
        guard a.count == b.count, !a.isEmpty else { return 1 }
        return a.withUnsafeBytes { ar in b.withUnsafeBytes { br in
            let x = ar.bindMemory(to: UInt8.self), y = br.bindMemory(to: UInt8.self)
            var changed = 0
            for p in stride(from: 0, to: a.count, by: 4) {
                if (0..<3).contains(where: { abs(Int(x[p + $0]) - Int(y[p + $0])) > 12 }) { changed += 1 }
            }
            return Double(changed) / Double(a.count / 4)
        } }
    }

    static func encode(asset: AVAsset, start: Double, fps: Double, dimension: Int, extractionSize:CGSize? = nil,
                       cropRatio: VideoCropRatio = .free, plan: AnimationPlan, format: AnimationFormat, quality: Int,
                       allowParallelWebP: Bool, progress: (Double) -> Void) async throws -> AnimationEncoding {
        let resources = AnimationResources.shared
        let reader = AnimationFrameReader(asset: asset, start: start, fps: fps, dimension: dimension,
                                          maximumSize:extractionSize ?? CGSize(width:dimension,height:dimension),cropRatio: cropRatio)
        let initialLimit = format == .gif ? resources.workers : 4
        let initialCount = min(plan.frames.count, min(initialLimit, max(1, resources.frameCapacity(width: dimension, height: dimension, bytesPerPixel: format == .gif ? 12 : 4) / 2)))
        var images = try await reader.read(plan.frames[0..<initialCount])
        let width = images[0].width, height = images[0].height
        var parallelWebP = false
        if format == .webp, allowParallelWebP, resources.workers > 1, plan.frames.count >= 16 {
            parallelWebP = try motionFraction(images[0], images[images.count - 1]) > 0.15
        }
        let memory = NSMutableData()
        let gif: CGImageDestination?
        if format == .gif {
            gif = CGImageDestinationCreateWithData(memory, "com.compuserve.gif" as CFString, plan.frames.count, nil)
            guard let gif else { throw EngineError.io("GIF 인코더 생성 실패") }
            CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0, kCGImagePropertyGIFHasGlobalColorMap: false]] as CFDictionary)
        } else { gif = nil }
        let mux = format == .webp ? try WebPAnimationMux(width: width, height: height) : nil
        let continuous = format == .webp && !parallelWebP ? try WebPAnimationWriter(width: width, height: height) : nil
        var position = 0
        while position < plan.frames.count {
            try Task.checkCancellation()
            let capacity = max(1, resources.frameCapacity(width: width, height: height, bytesPerPixel: format == .gif ? 12 : 4) / 2)
            let workers = min(resources.workers, capacity)
            let chunkSize = max(1, min(8, capacity / workers))
            // Decode ahead within the byte budget. Tiny extraction requests
            // repeatedly restart AVFoundation's batch decoder and lose most of
            // the parallel encoder's gain, especially on low-motion clips.
            let desired = gif != nil ? min(workers * 4, capacity) : (parallelWebP ? workers * chunkSize : min(32, capacity))
            let count = min(plan.frames.count - position, max(images.count, desired))
            if images.count < count {
                images += try await reader.read(plan.frames[(position + images.count)..<(position + count)])
            }
            let batch = images
            // One reader owns the generator; it prepares the next bounded
            // window while the current window is encoded. Both windows share
            // the 128MiB pixel-buffer allowance across active animation jobs.
            let nextPosition = position + count
            let nextCount = min(desired, plan.frames.count - nextPosition)
            let prefetch: Task<[CGImage], Error>? = nextCount > 0 ? Task {
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
                                group.addTask { try Task.checkCancellation(); return try autoreleasepool { (index, try AdaptivePalette.indexed(image)) } }
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
                            CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
                        }
                    } else if let continuous {
                        for (index, image) in batch.enumerated() {
                            try continuous.add(image, timestamp: plan.frames[position + index].start, quality: quality, threads: resources.workers)
                        }
                    } else if let mux {
                        let base = position
                        let parts = try await withThrowingTaskGroup(of: (Int, Data, Int).self) { group in
                            let offsets = Array(stride(from: 0, to: batch.count, by: chunkSize))
                            func submit(_ offset: Int) {
                                let chunk = Array(batch[offset..<min(offset + chunkSize, batch.count)])
                                let timing = Array(plan.frames[(base + offset)..<(base + offset + chunk.count)])
                                group.addTask {
                                    let writer = try WebPAnimationWriter(width: width, height: height)
                                    let origin = timing[0].start
                                    for (i, image) in chunk.enumerated() {
                                        try writer.add(image, timestamp: timing[i].start - origin, quality: quality, threads: 1)
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
                        for (_, bytes, duration) in parts { try mux.append(bytes, duration: duration) }
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
            bytes = memory as Data
        } else if let mux {
            if let continuous { try mux.append(continuous.finish(at: plan.ticks), duration: plan.ticks) }
            bytes = try mux.finish()
        } else { throw EngineError.io("애니메이션 인코더 없음") }
        try Task.checkCancellation()
        return AnimationEncoding(bytes: bytes, width: width, height: height, parallelWebP: parallelWebP)
    }

    static func verify(_ encoded: AnimationEncoding, plan: AnimationPlan, format: AnimationFormat) throws {
        guard let source = CGImageSourceCreateWithData(encoded.bytes as CFData, nil), CGImageSourceGetStatus(source) == .statusComplete else { throw EngineError.quality("애니메이션 디코딩 검사 실패") }
        let count = CGImageSourceGetCount(source)
        guard count > 0, format != .gif || count == plan.frames.count else { throw EngineError.quality("애니메이션 프레임 수 검사 실패") }
        var duration = 0.0
        for index in 0..<count {
            try Task.checkCancellation()
            // Decode representative frames including both ends; inspect every
            // frame's dimensions and timing without an expensive full replay.
            if index == 0 || index == count / 2 || index == count - 1 {
                try autoreleasepool {
                    guard let image = CGImageSourceCreateImageAtIndex(source, index, nil), image.width == encoded.width, image.height == encoded.height else { throw EngineError.quality("애니메이션 프레임 디코딩 실패") }
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
            duration += delay
        }
        guard abs(duration - plan.duration) < 0.0025 else { throw EngineError.quality("애니메이션 재생 길이 검사 실패") }
    }
}

import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import CryptoKit

@main struct AnimationTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw EngineError.quality("TEST: " + message) }
    }
    static func fixture(_ root: URL, name: String, kind: Int, rate: CMTime = CMTime(value: 1, timescale: 30), rotated: Bool = false) async throws -> URL {
        let url = root.appendingPathComponent(name + ".mp4"), w = 320, h = 180
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000]])
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
        writer.add(input)
        try require(writer.startWriting(), "fixture writer")
        writer.startSession(atSourceTime: .zero)
        for i in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            try autoreleasepool {
                var pixel: CVPixelBuffer?
                try require(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel) == kCVReturnSuccess, "fixture buffer")
                let buffer = pixel!
                CVPixelBufferLockBaseAddress(buffer, [])
                let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let row = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<h { for x in 0..<w {
                    let p = y * row + x * 4
                    let shift = kind == 0 ? i * 11 : 0
                    bytes[p] = UInt8((x + shift) % 256)
                    bytes[p + 1] = UInt8((y * 2 + shift) % 256)
                    bytes[p + 2] = UInt8((x + y + shift) % 256)
                    bytes[p + 3] = 255
                    if kind == 2 && x >= i * 3 && x < i * 3 + 15 && y < 15 { bytes[p] = 255; bytes[p + 1] = 0 }
                } }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                try require(adaptor.append(buffer, withPresentationTime: CMTimeMultiply(rate, multiplier: Int32(i))), "fixture append")
            }
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTimeMultiply(rate, multiplier: 60))
        await writer.finishWriting()
        try require(writer.status == .completed, "fixture finish")
        return url
    }
    static func inspect(_ url: URL, expectedDuration: Double, frames: Int? = nil, width: Int? = nil, height: Int? = nil) throws {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let count = CGImageSourceGetCount(source)
        if let frames { try require(count == frames, "frame count \(count) != \(frames)") }
        var duration = 0.0
        for index in 0..<count {
            try autoreleasepool {
                guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw EngineError.quality("TEST: corrupt frame \(index)") }
                if let width, let height { try require(image.width == width && image.height == height, "frame dimensions") }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as! [CFString: Any]
                let gif = url.pathExtension == "gif"
                let dict = properties[gif ? kCGImagePropertyGIFDictionary : kCGImagePropertyWebPDictionary] as! [CFString: Any]
                let delay = dict[gif ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyWebPUnclampedDelayTime] as! Double
                try require(delay > 0, "zero delay")
                duration += delay
            }
        }
        try require(abs(duration - expectedDuration) < 0.0025, "duration \(duration) != \(expectedDuration)")
    }
    static func timing() throws {
        for format in [AnimationFormat.gif, .webp] {
            for fps in [15.0, 24, 29.97, 30, 59.94, 60] {
                for duration in [0.001, 0.005, 1.0, 1.017, 4.0] {
                    let plan = AnimationPlan(duration: duration, fps: fps, format: format)
                    var end = 0
                    for frame in plan.frames {
                        try require(frame.start == end && frame.end > frame.start, "non-contiguous timeline")
                        end = frame.end
                    }
                    try require(abs(plan.duration - duration) < 0.0101, "cumulative timing drift")
                }
            }
        }
        try require(AnimationOptions.frameRateText(29.9700298) == "29.97", "NTSC label")
        try require(AnimationOptions.frameRateText(60.000001) == "60", "integer label")
        print("PASS cumulative GIF/WebP timing, fractional FPS, short final frames")
    }
    static func main() async {
        setbuf(stdout, nil)
        do {
            try timing()
            let root = URL(fileURLWithPath: ".work/animation-tests-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let moving = try await fixture(root, name: "moving", kind: 0)
            let still = try await fixture(root, name: "still", kind: 1)
            let subtle = try await fixture(root, name: "subtle", kind: 2)
            let rotated = try await fixture(root, name: "rotated", kind: 0, rate: CMTime(value: 1001, timescale: 30000), rotated: true)
            let sources = [moving, still, subtle, rotated]
            let hashes = try sources.map { Data(SHA256.hash(data: try Data(contentsOf: $0))) }
            let detected = try await MediaEngine.sourceFrameRate(AVURLAsset(url: rotated))!
            try require(abs(detected - 30000.0 / 1001) < 0.01, "source nominal FPS")
            for format in [AnimationFormat.gif, .webp] {
                for fps in [15.0, 24, 30, 60] {
                    print("CHECK", format.rawValue, fps)
                    let plan = AnimationPlan(duration: 1, fps: fps, format: format)
                    let result = try await RingEngine.shared.run(.init(source: moving, operation: .video(.animation(.init(format: format, fps: fps, maxDimension: 160, duration: 1)))))
                    try inspect(result.url, expectedDuration: plan.duration, frames: format == .gif ? plan.frames.count : nil, width: 160, height: 90)
                }
                let turned = try await RingEngine.shared.run(.init(source: rotated, operation: .video(.animation(.init(format: format, fps: detected, maxDimension: 160, start: 0.2, duration: 1.017)))))
                try inspect(turned.url, expectedDuration: AnimationPlan(duration: 1.017, fps: detected, format: format).duration, width: 90, height: 160)
                let limited = try await RingEngine.shared.run(.init(source: moving, operation: .video(.animation(.init(format: format, fps: 30, maxDimension: 320, targetBytes: 50_000, duration: 2)))))
                try require(try Data(contentsOf: limited.url).count <= 50_000, "target exceeded")
                print("PASS", format.rawValue, "15/24/30/60fps, rotation, fractional FPS/trim, sampled target", limited.detail)
            }
            let frozen = try await RingEngine.shared.run(.init(source: still, operation: .video(.animation(.init(format: .webp, fps: 60, maxDimension: 160, duration: 1)))))
            try inspect(frozen.url, expectedDuration: 1)
            let single = try await RingEngine.shared.run(.init(source: still, operation: .video(.animation(.init(format: .webp, fps: 1, maxDimension: 160, duration: 0.2)))))
            try inspect(single.url, expectedDuration: 0.2)
            // The default animation must retain the q90/method4/sharp-YUV
            // still-frame reference, including the 2x + vImage resize path.
            let qualityReference=AVAssetImageGenerator(asset:AVURLAsset(url:still))
            qualityReference.appliesPreferredTrackTransform=true
            qualityReference.maximumSize=CGSize(width:320,height:320)
            let full=try await qualityReference.image(at:.zero).image
            let fitted=try ImageResampler.fit(full,maxDimension:160)
            let rgba=try AdaptivePalette.sRGB(fitted)
            let expectedBytes=try TargetSizeCodec.memoryEncode(rgba,width:160,height:90,webp:true,quality:90)
            let expectedSource=CGImageSourceCreateWithData(expectedBytes as CFData,nil)!
            let actualSource=CGImageSourceCreateWithURL(single.url as CFURL,nil)!
            let expectedPixels=try AdaptivePalette.sRGB(CGImageSourceCreateImageAtIndex(expectedSource,0,nil)!)
            let actualPixels=try AdaptivePalette.sRGB(CGImageSourceCreateImageAtIndex(actualSource,0,nil)!)
            try require(expectedPixels==actualPixels,"default animation quality/resize differs from q90 sharp-YUV reference")
            print("PASS default WebP decoded pixels match q90/method4/sharp-YUV + vImage reference")
            print("PASS still WebP and single sampled frame retain animation duration")

            // Exercise adaptive choice and inspect every decoded frame after mux.
            for (source, expectedMotion) in [(moving, true), (subtle, false)] {
                let plan = AnimationPlan(duration: 2, fps: 30, format: .webp)
                let encoded = try await AnimationPipeline.encode(asset: AVURLAsset(url: source), start: 0, fps: 30, dimension: 160, plan: plan, format: .webp, quality: 90, allowParallelWebP: true) { _ in }
                if AnimationResources.shared.workers > 1 { try require(encoded.parallelWebP == expectedMotion, "adaptive motion path") }
                try AnimationPipeline.verify(encoded, plan: plan, format: .webp)
                let url = root.appendingPathComponent(expectedMotion ? "parallel.webp" : "delta.webp")
                try encoded.bytes.write(to: url); try inspect(url, expectedDuration: 2)
                if expectedMotion {
                    let decoded = CGImageSourceCreateWithData(encoded.bytes as CFData, nil)!
                    try require(CGImageSourceGetCount(decoded) == 60, "moving WebP frame count")
                    let reference = AVAssetImageGenerator(asset: AVURLAsset(url: source))
                    reference.maximumSize = CGSize(width: 160, height: 160)
                    reference.appliesPreferredTrackTransform = true
                    reference.requestedTimeToleranceBefore = .zero
                    reference.requestedTimeToleranceAfter = .zero
                    for index in [0, 7, 8, 15, 16, 31, 32, 39, 40, 55, 56, 59] {
                        let original = try await reference.image(at: CMTime(value: Int64(index), timescale: 30)).image
                        let a = try AdaptivePalette.sRGB(original)
                        let b = try AdaptivePalette.sRGB(CGImageSourceCreateImageAtIndex(decoded, index, nil)!)
                        try require(a.count == b.count, "WebP boundary canvas")
                        let squaredError = a.withUnsafeBytes { ar in b.withUnsafeBytes { br -> Double in
                            let x = ar.bindMemory(to: UInt8.self), y = br.bindMemory(to: UInt8.self)
                            var total = 0.0
                            for p in stride(from: 0, to: a.count, by: 4) { for c in 0..<3 {
                                let difference = Double(x[p + c]) - Double(y[p + c])
                                total += difference * difference
                            } }
                            return total / Double(a.count / 4 * 3)
                        } }
                        try require(sqrt(squaredError) < 15, "WebP content/order at chunk boundary \(index)")
                    }
                }
            }
            // Parallel completion must not reorder the GIF's images.
            let ordered = try await RingEngine.shared.run(.init(source: moving, operation: .video(.animation(.init(format: .gif, fps: 30, maxDimension: 160, duration: 1)))))
            let output = CGImageSourceCreateWithURL(ordered.url as CFURL, nil)!
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: moving))
            generator.maximumSize = CGSize(width: 320, height: 320)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.008, preferredTimescale: 60000)
            generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
            for index in [0, 14, 29] {
                let reference = try ImageResampler.fit(await generator.image(at: CMTime(seconds: Double(index) / 30, preferredTimescale: 60000)).image,maxDimension:160)
                // Compare after the same GIF round trip: ImageIO assigns the
                // decoded palette a color space that can differ from CGImage's.
                let memory = NSMutableData()
                let serial = CGImageDestinationCreateWithData(memory, "com.compuserve.gif" as CFString, 1, nil)!
                CGImageDestinationAddImage(serial, try AdaptivePalette.indexed(reference), nil)
                try require(CGImageDestinationFinalize(serial), "serial GIF reference")
                let referenceSource = CGImageSourceCreateWithData(memory, nil)!
                let expected = try AdaptivePalette.sRGB(CGImageSourceCreateImageAtIndex(referenceSource, 0, nil)!)
                let actual = try AdaptivePalette.sRGB(CGImageSourceCreateImageAtIndex(output, index, nil)!)
                try require(expected == actual, "GIF palette/order changed at \(index)")
            }
            print("PASS adaptive parallel/delta WebP and GIF pixel/order preservation")

            let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
            for format in [AnimationFormat.gif, .webp] {
                let task = Task { try await RingEngine.shared.run(.init(source: moving, operation: .video(.animation(.init(format: format, fps: 60, maxDimension: 320, targetBytes: 100_000, duration: 2))))) }
                try await Task.sleep(nanoseconds: 10_000_000); task.cancel()
                do { _ = try await task.value; throw EngineError.quality("TEST: cancelled animation published") } catch is CancellationError { }
                do {
                    _ = try await RingEngine.shared.run(.init(source: moving, operation: .video(.animation(.init(format: format, fps: 15, maxDimension: 160, targetBytes: 1, duration: 0.5)))))
                    throw EngineError.quality("TEST: impossible target succeeded")
                } catch { if error.localizedDescription.contains("TEST:") { throw error } }
            }
            try require(before == Set(FileManager.default.contentsOfDirectory(atPath: root.path)), "cancel/failure leaked output")
            for (index, source) in sources.enumerated() { try require(Data(SHA256.hash(data: try Data(contentsOf: source))) == hashes[index], "source mutated") }
            print("PASS cancellation, impossible target rollback, original source hashes")
            print("PASS all animation tests", root.path)
        } catch { print("FAIL", error.localizedDescription); exit(1) }
    }
}

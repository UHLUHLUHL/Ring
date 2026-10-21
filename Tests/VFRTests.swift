import Foundation
import AVFoundation
import VideoToolbox
import ImageIO
import CryptoKit

@main struct VFRTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw EngineError.quality("TEST: " + message) }
    }
    // Sequential decoded samples are an independent oracle for the generator:
    // use actual presentation timestamps, including B-frame reordering.
    static func originals(_ url: URL, crop: VideoCrop) async throws -> [(Double, Data)] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        try require(reader.startReading(), "oracle start")
        var frames: [(Double, Data)] = []
        while let sample = output.copyNextSampleBuffer() {
            try autoreleasepool {
                var image: CGImage?
                let status = VTCreateCGImageFromCVPixelBuffer(CMSampleBufferGetImageBuffer(sample)!, options: nil, imageOut: &image)
                try require(status == noErr && image != nil, "oracle image")
                let rect = crop.pixelRect(width: image!.width, height: image!.height)
                let fitted = try ImageResampler.fit(image!.cropping(to: rect)!, maxDimension: 160)
                frames.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, try AdaptivePalette.sRGB(fitted)))
            }
        }
        try require(reader.status == .completed, "oracle complete")
        return frames.sorted { $0.0 < $1.0 }
    }
    static func error(_ a: Data, _ b: Data) -> Double {
        a.withUnsafeBytes { ar in b.withUnsafeBytes { br in
            let x = ar.bindMemory(to: UInt8.self), y = br.bindMemory(to: UInt8.self)
            guard x.count == y.count else { return .infinity }
            var sum = 0.0
            for p in stride(from: 0, to: x.count, by: 4) { for c in 0..<3 { sum += abs(Double(x[p+c]) - Double(y[p+c])) } }
            return sum / Double(x.count / 4 * 3)
        } }
    }
    static func main() async {
        setbuf(stdout, nil)
        do {
            let root = URL(fileURLWithPath: ".work/vfr-tests-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let times = [0.0, 0.030, 0.120, 0.133, 0.180, 0.410, 0.420, 0.900, 0.933, 1.010, 1.080, 1.700, 1.850, 2.480]
            for (name, codec, ext) in [("h264", AVVideoCodecType.h264, "mp4"), ("hevc", .hevc, "mp4"), ("prores", .proRes422, "mov")] {
                let source = root.appendingPathComponent("\(name).\(ext)")
                try await MediaFixture.write(source, codec: codec, times: times, duration: 2.6)
                let hash = Data(SHA256.hash(data: try Data(contentsOf: source)))
                for format in [AnimationFormat.gif, .webp] {
                    // Include a trim inside a long gap, a crop, and the final sample.
                    let start = 0.35, duration = 2.25
                    let crop = VideoCrop(rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
                    let references = try await originals(source, crop: crop)
                    try require(references.count == times.count, "oracle sample count")
                    try require(zip(references, times).allSatisfy { abs($0.0.0 - $0.1) < 0.002 }, "fixture PTS")
                    let result = try await RingEngine.shared.run(.init(source: source, operation: .video(.animation(.init(format: format, fps: 30, maxDimension: 160, start: start, duration: duration, crop: crop)))))
                    let decoded = try AnimatedImageDecoder(result.url), info = decoded.info
                    let plan = AnimationPlan(duration: duration, fps: 30, format: format)
                    try require(abs(info.duration - duration) < 0.011, "VFR duration")
                    try require(info.size == CGSize(width: 160, height: 90), "VFR crop size")
                    var offset = 0.0
                    for index in 0..<info.frameCount {
                        let pixels = try AdaptivePalette.sRGB(decoded.frame(index))
                        // GIF rounds cumulative presentation times to 10ms.
                        // Compare to the requested video sample, not that rounding.
                        let tick = Int((offset * Double(plan.scale)).rounded())
                        guard let planned = plan.frames.first(where: { $0.start == tick }) else { throw EngineError.quality("TEST: unexpected frame time") }
                        let target = start + planned.offset
                        let expected = references.indices.min { abs(references[$0].0 - target) < abs(references[$1].0 - target) }!
                        let best = references.indices.min { error(pixels, references[$0].1) < error(pixels, references[$1].1) }!
                        try require(best == expected, "\(name) \(format.rawValue) frame \(index) at \(start+offset): source \(best), expected \(expected)")
                        try require(error(pixels, references[expected].1) < 16, "VFR pixel quality")
                        offset += Double(info.durationsMS[index]) / 1000
                    }
                    print("PASS \(name) \(format.rawValue) irregular PTS, long gaps, trim/crop, last frame, \(info.frameCount) decoded frames")
                }
                try require(hash == Data(SHA256.hash(data: try Data(contentsOf: source))), "original preserved")
            }
            // An input truncated before the container metadata cannot publish a file.
            let broken = root.appendingPathComponent("truncated.mp4")
            try Data(contentsOf: root.appendingPathComponent("h264.mp4")).prefix(128).write(to: broken)
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
            do {
                _ = try await RingEngine.shared.run(.init(source: broken, operation: .video(.animation(.init(format: .webp, fps: 30, maxDimension: 160)))))
                throw EngineError.quality("TEST: corrupt video succeeded")
            } catch { if error.localizedDescription.contains("TEST:") { throw error } }
            try require(before == Set(FileManager.default.contentsOfDirectory(atPath: root.path)), "corrupt input leaked output")
            print("PASS corrupt-video rollback and original hashes", root.path)
        } catch { print("FAIL", error.localizedDescription); exit(1) }
    }
}

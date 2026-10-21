import Foundation
import CoreGraphics
import ImageIO

@main struct AnimatedImageTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw EngineError.invalid("TEST: " + message) }
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: ".work/animated-image-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let gif = root.appendingPathComponent("transparent.gif")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let destination = CGImageDestinationCreateWithURL(gif as CFURL, "com.compuserve.gif" as CFString, 4, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 2]] as CFDictionary)
        for index in 0..<4 {
            let context = try PDFEngine.bitmap(width: 64, height: 48, space: space)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 8, y: 8, width: 24, height: 24))
            if index >= 2 {
                context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
                context.fill(CGRect(x: 32, y: index == 2 ? 0 : 24, width: 32, height: 24))
            }
            let delay = [0.04, 0.07, 0.13, 0.09][index]
            CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
        }
        try require(CGImageDestinationFinalize(destination), "GIF fixture encoding")
        let original = try Data(contentsOf: gif)
        let info = AnimatedImageInfo.inspect(gif)!
        try require(info.frameCount == 4 && info.durationsMS == [40, 70, 130, 90] && info.loopCount == 3, "GIF timing/finite repeat semantics")
        let seeking = try AnimatedImageDecoder(gif)
        for index in [3, 0, 1, 3, 2, 0] {
            try require(try PixelCheck.compare(seeking.frame(index), AnimatedImageDecoder(gif).frame(index)).exact, "GIF backwards seek/disposal")
            try require(try PixelCheck.compare(seeking.frame(index, preview: true), AnimatedImageDecoder(gif).frame(index)).exact, "GIF preview matches exported frame")
        }
        let file = FileInfo(url: gif)
        try require(file.kind == .animatedImage && file.editActions.map(\.id) == ["crop", "resize"], "animated GIF routes to working animation tools")
        try require(file.convertActions.map(\.id) == ["WEBP", "frame"], "still export is explicit, no destructive static conversion menu")
        let renamed = root.appendingPathComponent("renamed.png")
        try original.write(to: renamed)
        try require(FileInfo(url: renamed).kind == .animatedImage, "detect by content, not suffix")
        do { _ = try ImageInput(gif); throw EngineError.invalid("TEST: still engine accepted animation") }
        catch EngineError.unsupported(let message) { try require(message.contains("움짤"), "specific animation error") }

        for edit in [AnimatedImageEdit.webp, .crop(CGRect(x: 0.125, y: 0.25, width: 0.5, height: 0.5)), .resize(width: 32, height: 24)] {
            let result = try await RingEngine.shared.run(EngineJob(source: gif, operation: .animatedImage(edit)))
            let input = try AnimatedImageDecoder(gif), output = try AnimatedImageDecoder(result.url)
            try require(output.info.frameCount == 4 && output.info.durationsMS == info.durationsMS && output.info.loopCount == 3, "all frames, variable timing and finite looping preserved")
            for frame in 0..<4 {
                let reference = try AnimatedImageEngine.transform(input.frame(frame), edit: edit)
                try require(try PixelCheck.compare(reference, output.frame(frame)).exact, "frame \(frame): color/alpha/crop/resize preservation")
            }
            let copied = try await RingEngine.shared.run(EngineJob(source: result.url, operation: .animatedImage(.webp)))
            try require(try Data(contentsOf: copied.url) == Data(contentsOf: result.url), "same-WebP conversion retains original bytes")
            print("PASS animated edit", result.detail)
        }
        let frame = try await RingEngine.shared.run(EngineJob(source: gif, operation: .animatedImage(.frame(2))))
        let still = try ImageInput(frame.url)
        try require(try PixelCheck.compare(AnimatedImageDecoder(gif).frame(2), still.image).exact, "extract selected frame, not silently first frame")
        try require(FileInfo(url: frame.url).kind == .image, "single PNG remains a still image")
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        do {
            _ = try await RingEngine.shared.run(EngineJob(source: gif, operation: .animatedImage(.frame(99))))
            throw EngineError.invalid("TEST: invalid frame accepted")
        } catch EngineError.invalid(let message) { try require(message.contains("프레임 번호"), "invalid frame is rejected") }
        try require(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == before, "failed operation publishes no result and cleans staging")
        try require(try Data(contentsOf: gif) == original, "original GIF untouched")
        print("PASS selected PNG frame, still routing, failure cleanup, original preservation")

        if CommandLine.arguments.count > 1 {
            let source = URL(fileURLWithPath: CommandLine.arguments[1]), copied = root.appendingPathComponent("real.webp")
            let bytes = try Data(contentsOf: source); try bytes.write(to: copied)
            let input = try AnimatedImageDecoder(copied)
            for index in [min(2, input.info.frameCount - 1), 0, 1, min(2, input.info.frameCount - 1), 0, 1] {
                try require(try PixelCheck.compare(input.frame(index), AnimatedImageDecoder(copied).frame(index)).exact, "WebP backwards seek/composition")
            }
            let result = try await RingEngine.shared.run(EngineJob(source: copied, operation: .animatedImage(.crop(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)))))
            let output = try AnimatedImageDecoder(result.url)
            try require(output.info.frameCount == input.info.frameCount && output.info.durationsMS == input.info.durationsMS && output.info.loopCount == input.info.loopCount, "real WebP metadata preserved")
            try require(try Data(contentsOf: source) == bytes && Data(contentsOf: copied) == bytes, "real original and test input unchanged")
            print("PASS real WebP", input.info.summary, result.seconds, result.url.path)
        }
        print("PASS all animated-image checks", root.path)
    }
}

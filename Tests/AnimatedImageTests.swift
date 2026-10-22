import Foundation
import CoreGraphics
import ImageIO

@main struct AnimatedImageTests {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw EngineError.invalid("TEST: " + message) }
    }
    static func nativeDeltaChecks() throws {
        let width=17,height=13
        var frames=[[UInt8]](),pixels=[UInt8](repeating:0,count:width*height*4)
        for i in 0..<(width*height) { pixels[i*4]=20;pixels[i*4+1]=60;pixels[i*4+2]=100;pixels[i*4+3]=255 }
        frames.append(pixels)
        let odd=(5*width+3)*4
        pixels.replaceSubrange(odd..<(odd+4),with:[200,100,20,128]);frames.append(pixels)
        pixels.replaceSubrange(odd..<(odd+4),with:[0,0,0,0])
        pixels.replaceSubrange((pixels.count-4)..<pixels.count,with:[255,0,80,255]);frames.append(pixels)
        frames.append(pixels)
        guard let mux=ring_webp_lossless_mux_create(Int32(width),Int32(height),2,nil,0) else { throw EngineError.io("test mux") }
        defer { ring_webp_mux_destroy(mux) }
        for i in frames.indices {
            var count=0
            let ok=frames[i].withUnsafeBufferPointer { current in
                if i==0 { return ring_webp_lossless_mux_add_delta(mux,current.baseAddress,nil,Int32(width),Int32(height),40,1,&count) }
                return frames[i-1].withUnsafeBufferPointer { previous in
                    ring_webp_lossless_mux_add_delta(mux,current.baseAddress,previous.baseAddress,Int32(width),Int32(height),40,1,&count)
                }
            }
            try require(ok==1,"lossless delta encode")
        }
        var bytes:UnsafeMutablePointer<UInt8>?,count=0
        try require(ring_webp_mux_finish(mux,&bytes,&count)==1,"lossless delta mux")
        defer { ring_buffer_free(bytes) }
        var w:Int32=0,h:Int32=0,n:Int32=0,loops:Int32=0
        guard let decoder=ring_webp_image_decoder_create(bytes,count,1,&w,&h,&n,&loops) else { throw EngineError.io("test decoder") }
        defer { ring_webp_image_decoder_destroy(decoder) }
        try require(w==width && h==height && n==frames.count && loops==2,"delta canvas, frames, loop")
        for i in frames.indices {
            var pixels:UnsafePointer<UInt8>?
            try require(ring_webp_image_decoder_next(decoder,&pixels)==1 && pixels != nil,"delta frame decode")
            try require(Array(UnsafeBufferPointer(start:pixels,count:width*height*4))==frames[i],"delta changed RGBA at frame \(i)")
        }
        let source=CGImageSourceCreateWithData(Data(bytes:bytes!,count:count) as CFData,nil)!
        try require(AnimatedImageInfo.inspect(source)?.durationsMS == [40,40,40,40],"delta frame timing")
        print("PASS lossless delta: odd offsets, canvas edge, partial alpha, erased pixels, identical frames")
    }
    static func main() async throws {
        setbuf(stdout, nil)
        try nativeDeltaChecks()
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
            try require(FileInfo(url: result.url).convertActions.map(\.id) == ["speed", "frame"], "WebP replaces redundant conversion with speed")
            let copied = try await RingEngine.shared.run(EngineJob(source: result.url, operation: .animatedImage(.webp)))
            try require(try Data(contentsOf: copied.url) == Data(contentsOf: result.url), "same-WebP conversion retains original bytes")
            print("PASS animated edit", result.detail)
        }
        let frame = try await RingEngine.shared.run(EngineJob(source: gif, operation: .animatedImage(.frame(2))))
        let still = try ImageInput(frame.url)
        try require(try PixelCheck.compare(AnimatedImageDecoder(gif).frame(2), still.image).exact, "extract selected frame, not silently first frame")
        try require(FileInfo(url: frame.url).kind == .image, "single PNG remains a still image")
        for format in [ImageFormat.png, .jpg, .webp] {
            let result = try await RingEngine.shared.run(.init(source: gif, operation: .animatedImage(.frame(2, format: format))))
            let actual = try ImageInput(result.url)
            let expected = try AnimatedImageDecoder(gif).frame(2)
            try require(result.url.pathExtension == format.rawValue && FileInfo(url: result.url).kind == .image, "selected still format and routing")
            let reference = format == .jpg ? try ImageCodec.flattenWhite(expected) : expected
            let metrics = try PixelCheck.compare(reference, actual.image)
            try require(format == .jpg ? metrics.psnr >= 45 : metrics.exact, "selected frame quality and alpha policy")
        }
        for rate in [0.5, 1.5, 2.0] {
            let result = try await RingEngine.shared.run(.init(source: gif, operation: .animatedImage(.speed(rate))))
            let actual = try AnimatedImageDecoder(result.url), expected = try AnimatedImageDecoder(gif)
            let durations = try AnimatedImageEngine.retimedDurations(info.durationsMS, rate: rate)
            try require(actual.info.durationsMS == durations && actual.info.loopCount == 3 && actual.info.frameCount == 4, "speed changes only timeline")
            try require(abs(actual.info.duration - info.duration / rate) <= 0.001, "cumulative speed timing")
            for index in 0..<4 { try require(try PixelCheck.compare(actual.frame(index), expected.frame(index)).exact, "speed retains every frame's pixels/alpha") }
        }
        print("PASS PNG/JPG/WebP selected frame formats and lossless variable-timing speed changes")
        let webp = root.appendingPathComponent("transparent.webp")
        let speedResult = try await RingEngine.shared.run(.init(source: webp, operation: .animatedImage(.speed(2))))
        let fastInput = try AnimatedImageDecoder(webp), fastOutput = try AnimatedImageDecoder(speedResult.url)
        try require(fastOutput.info.durationsMS == [20, 35, 65, 45], "WebP timing-only speed change")
        let beforeBytes = try Data(contentsOf: webp), afterBytes = try Data(contentsOf: speedResult.url)
        try require(beforeBytes.count == afterBytes.count, "speed does not re-encode WebP")
        for i in 0..<4 { try require(try PixelCheck.compare(fastInput.frame(i), fastOutput.frame(i)).exact, "native WebP speed pixel preservation") }
        let restored = try AnimatedImageEngine.retimeWebP(afterBytes, durations: info.durationsMS)
        try require(restored == beforeBytes, "speed changes only duration fields; compressed pixels and metadata identical")
        print("PASS WebP speed changes only frame durations; original encoded pixels and metadata retained")
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
            let retimed = try await RingEngine.shared.run(.init(source: copied, operation: .animatedImage(.speed(1.5))))
            try require(try AnimatedImageEngine.retimeWebP(Data(contentsOf: retimed.url), durations: input.info.durationsMS) == bytes, "real WebP speed preserves encoded frames and metadata")
            print("PASS real WebP timing-only speed", retimed.seconds)
            let result = try await RingEngine.shared.run(EngineJob(source: copied, operation: .animatedImage(.crop(CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)))))
            let output = try AnimatedImageDecoder(result.url)
            try require(output.info.frameCount == input.info.frameCount && output.info.durationsMS == input.info.durationsMS && output.info.loopCount == input.info.loopCount, "real WebP metadata preserved")
            try require(try Data(contentsOf: source) == bytes && Data(contentsOf: copied) == bytes, "real original and test input unchanged")
            print("PASS real WebP", input.info.summary, result.seconds, result.url.path)
        }
        print("PASS all animated-image checks", root.path)
    }
}

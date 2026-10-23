import Foundation
import CoreGraphics
import ImageIO

@main struct ModernImageTests {
    static func require(_ ok: @autoclosure () -> Bool, _ text: String) throws {
        guard ok() else { throw EngineError.quality(text) }
    }
    static func main() throws {
        setbuf(stdout, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ring-modern-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = try PDFEngine.bitmap(width: 16, height: 12, space: space)
        context.setFillColor(CGColor(colorSpace: space, components: [0.2, 0.4, 0.7, 0.5])!)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        context.setFillColor(CGColor(colorSpace: space, components: [0.9, 0.2, 0.1, 1])!)
        context.fill(CGRect(x: 4, y: 4, width: 8, height: 4))
        let image = context.makeImage()!, rgba = try ExternalCodecs.straightRGBA8(image)
        let icc = space.copyICCData()! as Data
        let png = directory.appendingPathComponent("fixture.png")
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Ring EXIF fixture"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Ring tests"]]
        guard let pngDestination = CGImageDestinationCreateWithURL(png as CFURL, ImageFormat.png.uti as CFString, 1, nil) else {
            throw EngineError.io("fixture destination")
        }
        CGImageDestinationAddImage(pngDestination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(pngDestination) else { throw EngineError.io("fixture write") }
        let input = try ImageInput(png), exif = try MetadataEnvelope.exif(png, input: input)
        for format in [ImageFormat.avif, .jxl] {
            for animated in [false, true] {
                for orientation in 1...8 {
                    let writer = try ModernImageWriter(format: format, width: 16, height: 12,
                        frameCount: animated ? 2 : 1, timeScale: 1000, loops: 3,
                        icc: icc, exif: exif, orientation: orientation, isAnimated: animated)
                    try writer.addRGBA(rgba, durationTicks: 67)
                    if animated { try writer.addRGBA(rgba, durationTicks: 133) }
                    let data = try writer.finish()
                    try require(ModernImageReader.sniff(data) == format.rawValue, "content sniff \(format)")
                    let reader = try ModernImageReader(data: data)
                    try require(reader.frameCount == (animated ? 2 : 1) && reader.isAnimated == animated,
                                "\(format) frame count/type")
                    try require(reader.orientation == orientation, "\(format) orientation \(orientation)")
                    try require(reader.icc == icc && reader.exif == exif, "\(format) raw ICC/EXIF preservation")
                    try require(reader.width == 16 && reader.height == 12, "\(format) dimensions")
                    if animated {
                        try require(reader.timeScale == 1000 && reader.durationTicks == [67, 133] && reader.loops == 3,
                                    "\(format) exact ticks/loop count")
                    }
                    for index in 0..<reader.frameCount {
                        let decoded = try reader.frame(index)
                        let decodedRGBA = try tryExternal(decoded)
                        try require(decodedRGBA == rgba, "\(format) exact RGBA frame \(index)")
                    }
                    if !animated && orientation == 6 {
                        let mislabeled = directory.appendingPathComponent("\(format.rawValue)-input.dat")
                        try data.write(to: mislabeled)
                        let read = try ImageInput(mislabeled)
                        try require(read.type == format.uti && read.orientation == 6, "\(format) content routing")
                        let target = directory.appendingPathComponent("roundtrip.\(format.rawValue)")
                        _ = try ExternalCodecs.convert(png, to: target, format: format)
                        let converted = try ModernImageReader(target)
                        try require(converted.icc == icc && converted.orientation == 6, "\(format) full still integration")
                        let lossy = directory.appendingPathComponent("quality.\(format.rawValue)")
                        _ = try TargetSizeCodec.encode(png, to: lossy, format: format, intent: .quality(0.8))
                        let decoded = try ImageInput(lossy)
                        let outputRGBA = try ExternalCodecs.straightRGBA8(decoded.image)
                        try require(stride(from: 3, to: rgba.count, by: 4).allSatisfy { rgba[$0] == outputRGBA[$0] },
                                    "\(format) lossy alpha preservation")
                        let budget = directory.appendingPathComponent("budget.\(format.rawValue)")
                        _ = try TargetSizeCodec.encode(png, to: budget, format: format, intent: .targetBytes(50000))
                        let budgetData = try Data(contentsOf: budget)
                        try require(budgetData.count <= 50000, "\(format) target budget")
                    }
                }
            }
            let deep = try PDFEngine.bitmap(width: 2, height: 2, space: space, depth: 16).makeImage()!
            do {
                try ImageCodec.write(deep, properties: [:], format: format, to: directory.appendingPathComponent("deep.\(format.rawValue)"))
                throw EngineError.quality("\(format) silently reduced high-bit input")
            } catch EngineError.unsupported { }
            print("PASS \(format.rawValue) still/animated RGBA ICC EXIF 8 orientations exact ticks loops quality target high-bit guard")
        }
        if CommandLine.arguments.count > 1 {
            let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
            for ext in ["avif", "jxl"] {
                let data = try Data(contentsOf: fixtures.appendingPathComponent("highbit.\(ext)"))
                do { _ = try ModernImageReader(data: data); throw EngineError.quality("High-bit \(ext) accepted as RGBA8") }
                catch EngineError.unsupported { }
            }
            print("PASS real 10-bit AVIF/JXL decoder rejection")
        }
        for data in [Data(), Data([0xff, 0x0a]), Data("not an image".utf8)] {
            do { _ = try ModernImageReader(data: data); throw EngineError.quality("Invalid image accepted") }
            catch EngineError.unsupported { }
        }
        print("PASS malformed/truncated modern input rejection")
    }
    static func tryExternal(_ image: CGImage) throws -> Data { try ExternalCodecs.straightRGBA8(image) }
}

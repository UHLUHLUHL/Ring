import Foundation
import CoreGraphics
import ImageIO
import Darwin

@main struct EngineTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw EngineError.invalid("TEST FAIL: " + message) }
    }
    static func fixture(_ url: URL, width: Int = 512, height: Int = 384, depth: Int = 8,
                        orientation: Int = 1, p3: Bool = true, alpha: Bool = false) throws {
        let space = CGColorSpace(name: p3 ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        let info = (depth == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0) | (alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)
        let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:depth,bytesPerRow:0,space:space,bitmapInfo:info)!
        let colors = [CGColor(colorSpace:space,components:[0.05,0.15,0.75,alpha ? 0.4 : 1])!,CGColor(colorSpace:space,components:[0.95,0.85,0.25,1])!]
        ctx.drawLinearGradient(CGGradient(colorsSpace:space,colors:colors as CFArray,locations:[0,1])!,start:.zero,end:CGPoint(x:width,y:height),options:[])
        let props: [CFString:Any] = [kCGImagePropertyOrientation:orientation,kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:37.5,kCGImagePropertyGPSLatitudeRef:"N",kCGImagePropertyGPSLongitude:127.0,kCGImagePropertyGPSLongitudeRef:"E"]]
        try ImageCodec.write(ctx.makeImage()!, properties:props, format:url.pathExtension == "tiff" ? .tiff : .png,to:url)
    }
    static func main() async {
        setbuf(stdout, nil)
        do { try await run() } catch { print("FAIL", error.localizedDescription); exit(1) }
    }
    static func run() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".work/tests",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        if CommandLine.arguments.contains("--prepare") {
            try fixture(root.appendingPathComponent("fixture.png"))
            for depth in [8,16] { for orientation in [1,6] {
                try fixture(root.appendingPathComponent("p3-\(depth)-\(orientation).tiff"),depth:depth,orientation:orientation,alpha:true)
            } }
            for orientation in 1...8 { try fixture(root.appendingPathComponent("orientation-\(orientation).png"),orientation:orientation) }
            _=try ImageCodec.convert(root.appendingPathComponent("fixture.png"),to:root.appendingPathComponent("fixture.jpg"),format:.jpg)
            let large=URL(fileURLWithPath:".work/stage1-final2",isDirectory:true)
            try FileManager.default.createDirectory(at:large,withIntermediateDirectories:true)
            try fixture(large.appendingPathComponent("12mp.png"),width:4000,height:3000)
            let probe=URL(fileURLWithPath:".work/probe",isDirectory:true)
            try FileManager.default.createDirectory(at:probe,withIntermediateDirectories:true)
            let input=try ImageInput(root.appendingPathComponent("fixture.png"))
            let destination=CGImageDestinationCreateWithURL(probe.appendingPathComponent("probe-0.95.jpg") as CFURL,ImageFormat.jpg.uti as CFString,1,nil)!
            CGImageDestinationAddImage(destination,input.image,[kCGImageDestinationLossyCompressionQuality:0.95] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw EngineError.io("JPEG420 fixture 생성 실패") }
            _=try PDFEngine.imageToPDF(root.appendingPathComponent("fixture.jpg"),to:root.appendingPathComponent("fixture.pdf"))
            print("PASS native fixtures");return
        }
        if CommandLine.arguments.contains("--prepare-scan") {
            let source=URL(fileURLWithPath:".work/pdf-fixtures/text.pdf")
            let document=try PDFEngine.open(source),page=document.page(at:0)!
            let image=try PDFEngine.renderWithAnnotations(page)
            var box=page.bounds(for:.mediaBox)
            let context=CGContext(URL(fileURLWithPath:".work/pdf-fixtures/scan.pdf") as CFURL,mediaBox:&box,nil)!
            context.beginPDFPage(nil);context.draw(image,in:box);context.endPDFPage();context.closePDF()
            print("PASS scan fixture");return
        }
        let input = root.appendingPathComponent("fixture.png")
        try fixture(input)
        let original = try Data(contentsOf:input)
        for format in [ImageFormat.png,.tiff,.jpg,.heic] {
            let r = try await RingEngine.shared.run(EngineJob(source:input,operation:.convert(format)))
            print("PASS",format.rawValue,r.detail,r.seconds)
            try require(r.url != input,"original overwritten")
        }
        let srgb = root.appendingPathComponent("srgb.png")
        try fixture(srgb,p3:false)
        let bmp = try await RingEngine.shared.run(EngineJob(source:srgb,operation:.convert(.bmp)))
        print("PASS BMP",bmp.detail)
        let gps = try await RingEngine.shared.run(EngineJob(source:input,operation:.removeLocation))
        print("PASS GPS",gps.detail)
        for depth in [8,16] {
            for orientation in [1,6] {
                let file = root.appendingPathComponent("p3-\(depth)-\(orientation).tiff")
                try fixture(file,depth:depth,orientation:orientation,alpha:true)
                let r = try await RingEngine.shared.run(EngineJob(source:file,operation:.convert(.png)))
                print("PASS depth/orientation/alpha",depth,orientation,r.detail)
            }
        }
        let bad = root.appendingPathComponent("broken.png")
        try Data("broken".utf8).write(to:bad)
        do {
            _ = try await RingEngine.shared.run(EngineJob(source:bad,operation:.convert(.tiff)))
            throw EngineError.invalid("TEST FAIL: corrupt accepted")
        } catch EngineError.unsupported { print("PASS corrupt rejected") }
        let after = try Data(contentsOf:input)
        try require(after == original,"source changed")
        let jpgMeta = try await RingEngine.shared.run(EngineJob(source:root.appendingPathComponent("fixture.jpg"),operation:.removeLocation))
        print("PASS JPEG metadata coding bytes",jpgMeta.detail)
        if CommandLine.arguments.contains("--quick") { return }
        let large = root.appendingPathComponent("12mp.png")
        try fixture(large,width:4000,height:3000)
        for format in [ImageFormat.tiff,.jpg,.heic] {
            var times: [Double] = []
            for _ in 0..<5 {
                let r = try await RingEngine.shared.run(EngineJob(source:large,operation:.convert(format)))
                times.append(r.seconds)
                print("sample",format.rawValue,r.seconds,r.detail)
            }
            print("MEDIAN 12MP",format.rawValue,times.sorted()[2])
        }
        print("PASS all stage 1 tests")
    }
}

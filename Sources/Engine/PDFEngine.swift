import Foundation
import AppKit
import PDFKit
import Vision
import ImageIO

struct PDFNote {
    let page: Int
    let rect: CGRect // PDF points, bottom-left origin
    let text: String
}

struct PDFMetadata {
    let title: String
    let author: String
    let subject: String
}

enum PDFEngine {
    static func open(_ url:URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url:url), !doc.isEncrypted, doc.pageCount > 0 else {
            throw EngineError.unsupported("손상되었거나 암호화된 PDF는 처리할 수 없어요.")
        }
        return doc
    }
    static func imageToPDF(_ source:URL,to output:URL) throws -> String {
        let input = try ImageInput(source)
        let image: CGImage
        if input.type == ImageFormat.jpg.uti, let provider = CGDataProvider(url:source as CFURL),
           let original = CGImage(jpegDataProviderSource:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) {
            image = original
        } else { image = input.image }
        let rotated = input.orientation >= 5
        var box = CGRect(x:0,y:0,width:rotated ? image.height:image.width,height:rotated ? image.width:image.height)
        guard let ctx = CGContext(output as CFURL,mediaBox:&box,nil) else { throw EngineError.io("PDF 생성 실패") }
        ctx.beginPDFPage(nil)
        ctx.concatenate(orientationTransform(input.orientation,width:image.width,height:image.height))
        ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        ctx.endPDFPage(); ctx.closePDF()
        let written = try open(output)
        guard written.pageCount == 1, let page = written.page(at:0)?.pageRef else { throw EngineError.quality("PDF 페이지 검증 실패") }
        let actual = try render(page,scale:1,space:image.colorSpace!,depth:image.bitsPerComponent,transparent:true)
        let expected = try oriented(image,input.orientation)
        let metrics = try PixelCheck.compare(expected,actual)
        guard metrics.exact else { throw EngineError.quality("PDF 렌더 픽셀 보존 검사 실패") }
        if input.type == ImageFormat.jpg.uti {
            guard try Data(contentsOf:output).range(of:Data(contentsOf:source)) != nil else { throw EngineError.quality("JPEG PDF 패스스루 검사 실패") }
            return "JPEG 원본 바이트 포함 · 렌더 픽셀 일치"
        }
        return "무손실 PDF · 렌더 픽셀 일치"
    }
    static func orientationTransform(_ orientation:Int,width:Int,height:Int) -> CGAffineTransform {
        let w = CGFloat(width), h = CGFloat(height)
        switch orientation {
        case 2:return CGAffineTransform(a:-1,b:0,c:0,d:1,tx:w,ty:0)
        case 3:return CGAffineTransform(a:-1,b:0,c:0,d:-1,tx:w,ty:h)
        case 4:return CGAffineTransform(a:1,b:0,c:0,d:-1,tx:0,ty:h)
        case 5:return CGAffineTransform(a:0,b:-1,c:-1,d:0,tx:h,ty:w)
        case 6:return CGAffineTransform(a:0,b:-1,c:1,d:0,tx:0,ty:w)
        case 7:return CGAffineTransform(a:0,b:1,c:1,d:0,tx:0,ty:0)
        case 8:return CGAffineTransform(a:0,b:1,c:-1,d:0,tx:h,ty:0)
        default:return .identity
        }
    }
    static func oriented(_ image:CGImage,_ orientation:Int) throws -> CGImage {
        if orientation == 1 { return image }
        let swap = orientation >= 5, w = swap ? image.height:image.width, h = swap ? image.width:image.height
        let ctx = try bitmap(width:w,height:h,space:image.colorSpace!,depth:image.bitsPerComponent)
        ctx.concatenate(orientationTransform(orientation,width:image.width,height:image.height))
        ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        return ctx.makeImage()!
    }
    static func bitmap(width:Int,height:Int,space:CGColorSpace,depth:Int = 8) throws -> CGContext {
        guard width > 0,height > 0,Int64(width)*Int64(height) <= 52_000_000 else { throw EngineError.unsupported("페이지가 메모리 예산을 초과해요.") }
        let bits = depth > 8 ? 16 : 8, components = space.model == .rgb ? 4:2
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | (bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue:0)
        guard let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:bits,bytesPerRow:width*components*bits/8,space:space,bitmapInfo:info) else { throw EngineError.io("페이지 버퍼 생성 실패") }
        ctx.interpolationQuality = .none
        return ctx
    }
    static func render(_ page:CGPDFPage,scale:CGFloat = 300.0/72,space:CGColorSpace = CGColorSpace(name:CGColorSpace.sRGB)!,depth:Int = 8,transparent:Bool = false) throws -> CGImage {
        let bounds = page.getBoxRect(.cropBox), rotated = page.rotationAngle % 180 != 0
        let width = Int(ceil((rotated ? bounds.height:bounds.width)*scale)), height = Int(ceil((rotated ? bounds.width:bounds.height)*scale))
        let ctx = try bitmap(width:width,height:height,space:space,depth:depth)
        if !transparent { ctx.setFillColor(CGColor(gray:1,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:width,height:height)) }
        ctx.scaleBy(x:scale,y:scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox,rect:CGRect(x:0,y:0,width:rotated ? bounds.height:bounds.width,height:rotated ? bounds.width:bounds.height),rotate:0,preserveAspectRatio:true))
        ctx.drawPDFPage(page)
        return ctx.makeImage()!
    }
    static func export(_ source:URL,to output:URL,format:ImageFormat) throws -> String {
        let doc = try open(source)
        if format == .txt { return try text(doc,to:output) }
        guard [.png,.jpg,.webp].contains(format) else { throw EngineError.unsupported("이 PDF 변환은 아직 연결되지 않았어요.") }
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
        var extracted = 0
        for index in 0..<doc.pageCount { defer { EngineProgress.step(index, of: doc.pageCount) }
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = doc.page(at:index) else { throw EngineError.invalid("페이지 읽기 실패") }
                let target = output.appendingPathComponent(String(format:"%04d.%@",index+1,format.rawValue))
                if format == .jpg, let bytes = try singleJPEG(page) {
                    try bytes.write(to:target)
                    extracted += 1
                    return
                }
                // Render annotations as well; PDFPage.draw uses the requested display box.
                let image = try renderWithAnnotations(page)
                if format == .webp {
                    let rgba = try ExternalCodecs.straightRGBA8(image)
                    // Fixed high quality WebP for rendered pages; no external CLI.
                    let bytes = try TargetSizeCodec.memoryEncode(rgba,width:image.width,height:image.height,icc:image.colorSpace?.copyICCData() as Data? ?? Data(),webp:true,quality:95)
                    try bytes.write(to:target)
                    let written = try ImageInput(target)
                    guard written.image.width == image.width,written.image.height == image.height else { throw EngineError.quality("PDF WebP 크기 검사 실패") }
                    return
                }
                try ImageCodec.write(image,properties:[kCGImagePropertyOrientation:1],format:format,to:target)
                try ImageCodec.verify(image,properties:[kCGImagePropertyOrientation:1],output:target,exact:format == .png)
                if format == .jpg { try JPEGStructure.require444(target) }
            }
        }
        return "\(doc.pageCount)페이지 · 원본 추출 \(extracted)페이지 · 나머지 300 dpi · \(format == .png ? "픽셀 일치":"손실 인코딩 최대 1회")"
    }
    /// Only pages whose content language is one image plus matrix/save/restore operators.
    /// Visual comparison at the image's native resolution additionally rejects crops/flips.
    static func singleJPEG(_ page:PDFPage) throws -> Data? {
        guard page.annotations.isEmpty, let reference = page.pageRef, reference.rotationAngle == 0,
              let dictionary = reference.dictionary else { return nil }
        var contents:CGPDFStreamRef?, resources:CGPDFDictionaryRef?, objects:CGPDFDictionaryRef?
        guard CGPDFDictionaryGetStream(dictionary,"Contents",&contents),let contents,
              CGPDFDictionaryGetDictionary(dictionary,"Resources",&resources),let resources,
              CGPDFDictionaryGetDictionary(resources,"XObject",&objects),let objects else { return nil }
        var encoding = CGPDFDataFormat.raw
        guard let streamData = CGPDFStreamCopyData(contents,&encoding),encoding == .raw,
              let commands = String(data:streamData as Data,encoding:.ascii) else { return nil }
        let tokens = commands.split(whereSeparator:{$0.isWhitespace}).map(String.init)
        let names = tokens.indices.filter{$0+1 < tokens.count && tokens[$0+1] == "Do"}.map{tokens[$0]}
        guard names.count == 1,tokens.filter({$0 == "Do"}).count == 1,
              tokens.allSatisfy({ Double($0) != nil || ["q","Q","cm","Do","ri","/Perceptual","/RelativeColorimetric","/Saturation","/AbsoluteColorimetric"].contains($0) || $0 == names[0] }) else { return nil }
        var stream:CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(objects,String(names[0].dropFirst()),&stream),let stream,
              let dict = CGPDFStreamGetDictionary(stream) else { return nil }
        var object:CGPDFObjectRef?
        guard !CGPDFDictionaryGetObject(dict,"SMask",&object),!CGPDFDictionaryGetObject(dict,"Mask",&object),
              !CGPDFDictionaryGetObject(dict,"Decode",&object) else { return nil }
        var format = CGPDFDataFormat.raw
        guard let bytes = CGPDFStreamCopyData(stream,&format),format == .jpegEncoded,
              let imageSource = CGImageSourceCreateWithData(bytes,nil),CGImageSourceGetCount(imageSource) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(imageSource,0,nil) as? [CFString:Any],
              (props[kCGImagePropertyOrientation] as? Int ?? 1) == 1,
              let image = CGImageSourceCreateImageAtIndex(imageSource,0,nil),let space = image.colorSpace,space.model == .rgb else { return nil }
        let bounds = reference.getBoxRect(.cropBox),scale = CGFloat(image.width)/bounds.width
        guard abs(bounds.height*scale-CGFloat(image.height)) < 0.001 else { return nil }
        let rendered = try render(reference,scale:scale,space:space)
        guard try PixelCheck.compare(image,rendered).exact else { return nil }
        return bytes as Data
    }
    static func renderWithAnnotations(_ page:PDFPage,scale:CGFloat = 300.0/72,depth:Int = 8,space:CGColorSpace = CGColorSpace(name:CGColorSpace.sRGB)!) throws -> CGImage {
        guard let reference = page.pageRef else { throw EngineError.invalid("페이지 참조 없음") }
        let bounds = reference.getBoxRect(.cropBox), rotated = reference.rotationAngle % 180 != 0
        let w = Int(ceil((rotated ? bounds.height:bounds.width)*scale)), h = Int(ceil((rotated ? bounds.width:bounds.height)*scale))
        let ctx = try bitmap(width:w,height:h,space:space,depth:depth)
        ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(CGRect(x:0,y:0,width:w,height:h))
        ctx.scaleBy(x:scale,y:scale)
        ctx.concatenate(reference.getDrawingTransform(.cropBox,rect:CGRect(x:0,y:0,width:rotated ? bounds.height:bounds.width,height:rotated ? bounds.width:bounds.height),rotate:0,preserveAspectRatio:true))
        ctx.drawPDFPage(reference)
        for annotation in page.annotations where annotation.shouldDisplay { annotation.draw(with:.cropBox,in:ctx) }
        return ctx.makeImage()!
    }
    static func text(_ doc:PDFDocument,to output:URL) throws -> String {
        let file = FileManager.default.createFile(atPath:output.path,contents:nil)
        guard file else { throw EngineError.io("텍스트 파일 생성 실패") }
        let handle = try FileHandle(forWritingTo:output); defer { try? handle.close() }
        var ocrPages = 0
        for i in 0..<doc.pageCount { defer { EngineProgress.step(i, of: doc.pageCount) }
            try Task.checkCancellation()
            let string: String = try autoreleasepool {
                guard let page = doc.page(at:i) else { throw EngineError.invalid("페이지 읽기 실패") }
                if let text = page.string, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { return text }
                ocrPages += 1
                let box = page.bounds(for:.cropBox)
                let image = try renderWithAnnotations(page,scale:min(300.0/72,4096/max(box.width,box.height)))
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["ko-KR","en-US"]
                request.usesLanguageCorrection = true
                try VNImageRequestHandler(cgImage:image).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator:"\n")
            }
            try handle.write(contentsOf:Data(((i == 0 ? "":"\n\u{000c}\n")+string).utf8))
        }
        guard let _ = String(data:try Data(contentsOf:output),encoding:.utf8) else { throw EngineError.quality("UTF-8 검증 실패") }
        return "\(doc.pageCount)페이지 · OCR \(ocrPages)페이지\(ocrPages > 0 ? "(인식 오류 가능)":"")"
    }
    static func metadata(_ source:URL,to output:URL,value:PDFMetadata) throws -> String {
        var doc = try open(source)
        if (doc.documentAttributes ?? [:]).isEmpty {
            // PDFKit (OS27) silently omits new attributes when the trailer has no Info.
            let prepared = output.deletingLastPathComponent().appendingPathComponent("metadata-info.pdf")
            let ok = source.path.withCString { input in prepared.path.withCString { ring_pdf_add_info(input,$0) } }
            guard ok == 1 else { throw EngineError.io("PDF 정보 사전 준비 실패") }
            doc = try open(prepared)
        }
        var attrs = doc.documentAttributes ?? [:]
        attrs[PDFDocumentAttribute.titleAttribute] = value.title
        attrs[PDFDocumentAttribute.authorAttribute] = value.author
        attrs[PDFDocumentAttribute.subjectAttribute] = value.subject
        doc.documentAttributes = attrs
        guard doc.write(to:output) else { throw EngineError.io("PDF 메타데이터 쓰기 실패") }
        let written = try open(output)
        try validateUnchanged(source,written)
        guard (written.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? "") == value.title,
              (written.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String ?? "") == value.author else { throw EngineError.quality("PDF 메타데이터 검증 실패") }
        return "메타데이터 저장 · 페이지 렌더·텍스트 일치"
    }
    static func annotate(_ source:URL,to output:URL,note:PDFNote) throws -> String {
        if !Thread.isMainThread {
            return try DispatchQueue.main.sync { try autoreleasepool { try annotate(source,to:output,note:note) } }
        }
        let doc = try open(source)
        guard note.page >= 0, let page = doc.page(at:note.page), !note.text.isEmpty,
              page.bounds(for:.cropBox).contains(note.rect), note.rect.width > 0,note.rect.height > 0 else { throw EngineError.invalid("주석의 페이지·영역·내용을 확인해 주세요.") }
        let annotation = PDFAnnotation(bounds:note.rect,forType:.freeText,withProperties:nil)
        annotation.contents = note.text; annotation.font = NSFont.systemFont(ofSize:14)
        annotation.fontColor = .systemBlue; annotation.color = .clear
        page.addAnnotation(annotation)
        guard doc.write(to:output) else { throw EngineError.io("PDF 주석 쓰기 실패") }
        let result = try open(output)
        guard result.page(at:note.page)?.annotations.contains(where:{$0.contents == note.text}) == true,
              result.string == doc.string else { throw EngineError.quality("PDF 주석 검증 실패") }
        try validateImageStreams(source,output)
        return "벡터 주석 저장 · 원본 이미지 스트림 보존"
    }
    static func hasNonPageContent(_ source:URL) -> Bool {
        guard let pdf=CGPDFDocument(source as CFURL),let catalog=pdf.catalog else { return true }
        for key in ["AcroForm","Names","OpenAction","AA","OCProperties","Collection","StructTreeRoot","PieceInfo","Perms","AF","Metadata"] {
            var object:CGPDFObjectRef?
            if CGPDFDictionaryGetObject(catalog,key,&object) { return true }
        }
        return false
    }
    static func compress(_ source:URL,to output:URL) throws -> String {
        let doc=try open(source)
        let originalSize=try source.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        // Complex interactive documents have preservation contracts beyond page pixels.
        // Keep bytes rather than silently discarding forms, outlines or annotations.
        let interactive=hasNonPageContent(source) || doc.outlineRoot != nil || (0..<doc.pageCount).contains { !(doc.page(at:$0)?.annotations.isEmpty ?? true) }
        if !interactive,doc.write(to:output),
           (try output.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? originalSize) < originalSize {
            do {
                let written=try open(output)
                try validateUnchanged(source,written)
                for index in 0..<doc.pageCount { defer { EngineProgress.step(index, of: doc.pageCount) }
                    try Task.checkCancellation()
                    try autoreleasepool {
                        let a=try renderWithAnnotations(doc.page(at:index)!,depth:16,space:CGColorSpace(name:CGColorSpace.displayP3)!)
                        let b=try renderWithAnnotations(written.page(at:index)!,depth:16,space:CGColorSpace(name:CGColorSpace.displayP3)!)
                        guard try PixelCheck.compare(a,b).exact else { throw EngineError.quality("PDF 압축 고정밀 렌더 불일치") }
                    }
                }
                let newSize=try output.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? originalSize
                return "무손실 PDF 재정리 · 이미지 스트림·텍스트·300dpi 렌더 일치 · \(originalSize-newSize) bytes 절감"
            } catch is CancellationError { throw CancellationError() }
            catch { /* Native rewrites that fail preservation are never published. */ }
        }
        if FileManager.default.fileExists(atPath:output.path) { try FileManager.default.removeItem(at:output) }
        try FileIntegrity.copy(source,to:output)
        return "원본 바이트 그대로 · 무손실 절감 없음"
    }
    static func validateUnchanged(_ source:URL,_ written:PDFDocument) throws {
        let original = try open(source)
        guard original.pageCount == written.pageCount, original.string == written.string else { throw EngineError.quality("PDF 텍스트·페이지 보존 실패") }
        for i in 0..<original.pageCount { defer { EngineProgress.step(i, of: original.pageCount) }
            try Task.checkCancellation()
            try autoreleasepool {
                let a = try renderWithAnnotations(original.page(at:i)!,scale:1)
                let b = try renderWithAnnotations(written.page(at:i)!,scale:1)
                guard try PixelCheck.compare(a,b).exact else { throw EngineError.quality("PDF 렌더 보존 실패") }
            }
        }
        if let url = written.documentURL { try validateImageStreams(source,url) }
    }
    static func imageStreams(_ source:URL) throws -> [Data] {
        guard let doc = CGPDFDocument(source as CFURL) else { throw EngineError.invalid("PDF 열기 실패") }
        var streams: [Data] = []
        func visit(_ resources:CGPDFDictionaryRef,depth:Int) {
            guard depth < 32 else { return }
            var objects:CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources,"XObject",&objects), let objects else { return }
            let collector = PDFStreamCollector(depth:depth,collect:{ streams.append($0) },recurse:visit)
            CGPDFDictionaryApplyFunction(objects,{ _,object,context in
                let c = Unmanaged<PDFStreamCollector>.fromOpaque(context!).takeUnretainedValue()
                var stream:CGPDFStreamRef?
                guard CGPDFObjectGetValue(object,.stream,&stream), let stream else { return }
                guard let dict = CGPDFStreamGetDictionary(stream) else { return }
                var subtype:UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(dict,"Subtype",&subtype), let subtype, String(cString:subtype) == "Image" {
                    var format = CGPDFDataFormat.raw
                    if let data = CGPDFStreamCopyData(stream,&format) { c.collect(data as Data) }
                }
                var nested:CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dict,"Resources",&nested), let nested { c.recurse(nested,c.depth+1) }
            },Unmanaged.passUnretained(collector).toOpaque())
        }
        for index in 1...doc.numberOfPages {
            var resources:CGPDFDictionaryRef?
            if let page = doc.page(at:index),CGPDFDictionaryGetDictionary(page.dictionary!,"Resources",&resources),let resources { visit(resources,depth:0) }
        }
        return streams.sorted { $0.lexicographicallyPrecedes($1) }
    }
    static func validateImageStreams(_ source:URL,_ output:URL) throws {
        guard try imageStreams(source) == imageStreams(output) else { throw EngineError.quality("PDF 이미지 스트림 보존 실패") }
    }
}
private final class PDFStreamCollector {
    let depth:Int
    let collect:(Data)->Void
    let recurse:(CGPDFDictionaryRef,Int)->Void
    init(depth:Int,collect:@escaping (Data)->Void,recurse:@escaping (CGPDFDictionaryRef,Int)->Void) { self.depth=depth;self.collect=collect;self.recurse=recurse }
}

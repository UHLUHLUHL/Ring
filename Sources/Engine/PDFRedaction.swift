import Foundation
import AppKit
import PDFKit
import ImageIO

struct PDFRedaction {
    let page:Int
    let rect:CGRect // PDF points, bottom-left origin
}

/// Conservative support: flat unrotated pages, no annotations/forms/attachments/layers.
/// Text/vector removal uses PDFKit's Redact subtype. Single-JPEG pages replace pixels
/// losslessly at their original resolution. Both paths rebuild only page content.
enum PDFRedactor {
    static func run(_ source:URL,to output:URL,selection:PDFRedaction) throws -> String {
        let original=try PDFEngine.open(source)
        guard selection.page >= 0,selection.page < original.pageCount,
              [selection.rect.minX,selection.rect.minY,selection.rect.width,selection.rect.height].allSatisfy({$0.isFinite}),
              selection.rect.width > 0,selection.rect.height > 0,
              !PDFEngine.hasNonPageContent(source),original.outlineRoot == nil else {
            throw EngineError.unsupported("이 PDF의 구조는 안전한 가리기 지원 범위를 벗어나요. 양식·첨부·레이어·구조 정보가 있는 문서는 저장하지 않아요.")
        }
        let target=original.page(at:selection.page)!,box=target.bounds(for:.mediaBox)
        guard box.contains(selection.rect) else { throw EngineError.invalid("가리기 영역이 페이지 밖에 있어요.") }
        for index in 0..<original.pageCount { try inspect(original.page(at:index)!) }
        var rect=selection.rect
        // Remove complete glyphs at a boundary, not pieces of recoverable characters.
        let spans=try textSpans(target)
        for (text,bounds) in spans where !text.allSatisfy({$0.isWhitespace}) {
            if !bounds.isEmpty,bounds.intersects(selection.rect) { rect=rect.union(bounds) }
        }
        rect=rect.integral.intersection(box)
        let expectedText=spans.filter { $0.0.allSatisfy({$0.isWhitespace}) || !$0.1.intersects(rect) }.map { $0.0 }.joined()
        let directory=output.deletingLastPathComponent()
        let intermediate=directory.appendingPathComponent("redacted-native.pdf")
        let jpeg=try PDFEngine.singleJPEG(target)
        let replacement:CGImage?
        let sanitized:PDFDocument
        if let jpeg {
            let input=directory.appendingPathComponent("redaction-input.jpg"),png=directory.appendingPathComponent("redaction-pixels.png")
            try jpeg.write(to:input)
            let normalized=CGRect(x:rect.minX/box.width,y:1-rect.maxY/box.height,width:rect.width/box.width,height:rect.height/box.height)
            _=try ImageEdits.run(input,to:png,edit:.redact(normalized))
            replacement=try ImageInput(png).image
            sanitized=original
        } else {
            guard !hasImages(target) else { throw EngineError.unsupported("그림과 글이 섞인 PDF 페이지는 가리기 후 원본 데이터 제거를 검증하지 못해요. 저장하지 않았어요.") }
            let working=try PDFEngine.open(source),page=working.page(at:selection.page)!
            let annotation=PDFAnnotation(bounds:rect,forType:PDFAnnotationSubtype(rawValue:"Redact"),withProperties:nil)
            annotation.markupType = .redact;annotation.color = .black
            page.addAnnotation(annotation)
            // Native Redact removes content on write. Do not burn the annotation's
            // preview cross into the page; final black fill follows sanitization.
            guard working.write(to:intermediate) else { throw EngineError.io("PDF 콘텐츠 제거 실패") }
            sanitized=try PDFEngine.open(intermediate);replacement=nil
            guard normalizedText(sanitized.page(at:selection.page)?.string ?? "") == normalizedText(expectedText) else {
                throw EngineError.quality("가리기 콘텐츠 제거 검증 실패. 결과를 저장하지 않았어요.")
            }
        }
        // Rebuild only the sanitized page. PDFKit/Quartz changed untouched text
        // antialiasing on OS27; qpdf preserves those pages without replaying them.
        let pageFile=directory.appendingPathComponent("redacted-page.pdf")
        var media=box
        guard let context=CGContext(pageFile as CFURL,mediaBox:&media,nil) else { throw EngineError.io("PDF 재구성 실패") }
        context.beginPDFPage(nil)
        if let replacement { context.interpolationQuality = .none;context.draw(replacement,in:box) }
        else {
            guard let reference=sanitized.page(at:selection.page)?.pageRef else { throw EngineError.invalid("PDF 페이지 참조 오류") }
            context.drawPDFPage(reference)
            context.setFillColor(CGColor(gray:0,alpha:1));context.fill(rect)
        }
        context.endPDFPage();context.closePDF()
        let ok=source.path.withCString { input in pageFile.path.withCString { page in output.path.withCString { result in
            ring_pdf_replace_page(input,page,Int32(selection.page+1),Int32(original.pageCount),result)
        } } }
        guard ok == 1 else { throw EngineError.quality("PDF 페이지 조립 검증 실패. 결과를 저장하지 않았어요.") }
        let result=try PDFEngine.open(output)
        guard result.pageCount == original.pageCount,
              normalizedText(result.page(at:selection.page)?.string ?? "") == normalizedText(expectedText),
              result.page(at:selection.page)!.annotations.isEmpty else { throw EngineError.quality("PDF 가리기 텍스트·주석 검증 실패") }
        let space=CGColorSpace(name:CGColorSpace.displayP3)!,scale:CGFloat=300.0/72
        for index in 0..<original.pageCount { defer { EngineProgress.step(index, of: original.pageCount) }
            try Task.checkCancellation()
            try autoreleasepool {
                let a=try PDFEngine.renderWithAnnotations(original.page(at:index)!,depth:16,space:space)
                let b=try PDFEngine.renderWithAnnotations(result.page(at:index)!,depth:16,space:space)
                if index == selection.page {
                    let mask=CGRect(x:rect.minX*scale,y:rect.minY*scale,width:rect.width*scale,height:rect.height*scale).integral
                    guard try PixelCheck.compare(masked(a,rect:mask),masked(b,rect:mask)).exact else {
                        throw EngineError.quality("가린 영역 밖 픽셀이 달라졌어요. 결과를 저장하지 않았어요.")
                    }
                    let inside=CGRect(x:ceil(mask.minX)+2,y:CGFloat(b.height)-floor(mask.maxY)+2,width:floor(mask.width)-4,height:floor(mask.height)-4)
                    guard inside.width > 0,inside.height > 0,let block=b.cropping(to:inside),
                          try PixelCheck.compare(block,masked(block,rect:CGRect(x:0,y:0,width:block.width,height:block.height))).exact else {
                        throw EngineError.quality("PDF 가리기 불투명 영역 검증 실패")
                    }
                } else {
                    guard original.page(at:index)!.string == result.page(at:index)!.string,
                          try PixelCheck.compare(a,b).exact else { throw EngineError.quality("다른 PDF 페이지 보존 검증 실패") }
                }
            }
        }
        return "콘텐츠 제거 · 영역 밖 300dpi 픽셀 일치 · 메타데이터 제외 · 실제 영역 \(rect)pt"
    }
    static func normalizedText(_ text:String) -> String { String(text.filter{!$0.isWhitespace}) }
    static func textSpans(_ page:PDFPage) throws -> [(String,CGRect)] {
        let text=page.string ?? ""
        guard text.utf16.count <= 200_000 else { throw EngineError.unsupported("페이지의 텍스트가 가리기 검증 예산을 초과해요.") }
        var result:[(String,CGRect)]=[]
        // characterBounds(at:) and page.string indices differ at line breaks on OS27.
        // Selection ranges follow NSString offsets; validate each non-whitespace span.
        var invalid=false
        text.enumerateSubstrings(in:text.startIndex..<text.endIndex,options:.byComposedCharacterSequences) { substring,range,_,_ in
            let value=substring ?? ""
            if value.allSatisfy({$0.isWhitespace}) { result.append((value,.zero));return }
            guard let selected=page.selection(for:NSRange(range,in:text)),selected.string == value else { invalid=true;return }
            result.append((value,selected.bounds(for:page)))
        }
        guard !invalid else { throw EngineError.unsupported("문자 위치 대응을 검증하지 못한 PDF는 가리지 않아요.") }
        return result
    }
    static func masked(_ image:CGImage,rect:CGRect) throws -> CGImage {
        let c=try PDFEngine.bitmap(width:image.width,height:image.height,space:image.colorSpace!,depth:16)
        c.setBlendMode(.copy);c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        c.setFillColor(CGColor(gray:0,alpha:1));c.fill(rect)
        return c.makeImage()!
    }
    static func hasImages(_ page:PDFPage) -> Bool {
        guard let d=page.pageRef?.dictionary else { return true }
        var resources:CGPDFDictionaryRef?,objects:CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(d,"Resources",&resources),let resources else { return false }
        return CGPDFDictionaryGetDictionary(resources,"XObject",&objects) && objects.map{CGPDFDictionaryGetCount($0)>0} == true
    }
    static func inspect(_ page:PDFPage) throws {
        let box=page.bounds(for:.mediaBox)
        guard page.rotation == 0,box.origin == .zero,box == page.bounds(for:.cropBox),page.annotations.isEmpty,
              let dictionary=page.pageRef?.dictionary else { throw EngineError.unsupported("회전·다른 CropBox·기존 주석이 있는 PDF는 안전한 가리기를 지원하지 않아요.") }
        for key in ["Metadata","Thumb","PieceInfo","AA","PresSteps","AF","B","StructParents","UserUnit"] {
            var object:CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dictionary,key,&object) { throw EngineError.unsupported("부가 구조가 있는 PDF는 가리기 보존 검증 범위 밖이에요.") }
        }
        var resources:CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary,"Resources",&resources),let resources else { throw EngineError.unsupported("상속 리소스 PDF는 가리기 지원 범위 밖이에요.") }
        for key in ["Pattern","Properties","Shading","ExtGState"] {
            var object:CGPDFObjectRef?
            if CGPDFDictionaryGetObject(resources,key,&object) { throw EngineError.unsupported("패턴·마스크·레이어가 있는 PDF는 안전한 가리기를 지원하지 않아요.") }
        }
        var fonts:CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources,"Font",&fonts),let fonts {
            let flag=RedactionFlag()
            CGPDFDictionaryApplyFunction(fonts,{_,object,info in
                let flag=Unmanaged<RedactionFlag>.fromOpaque(info!).takeUnretainedValue()
                var font:CGPDFDictionaryRef?,subtype:UnsafePointer<CChar>?,base:UnsafePointer<CChar>?,unused:CGPDFObjectRef?
                let standard=["Helvetica","Helvetica-Bold","Helvetica-Oblique","Helvetica-BoldOblique","Times-Roman","Times-Bold","Times-Italic","Times-BoldItalic","Courier","Courier-Bold","Courier-Oblique","Courier-BoldOblique","Symbol","ZapfDingbats"]
                guard CGPDFObjectGetValue(object,.dictionary,&font),let font,
                      CGPDFDictionaryGetName(font,"Subtype",&subtype),let subtype,String(cString:subtype)=="Type1",
                      CGPDFDictionaryGetName(font,"BaseFont",&base),let base,standard.contains(String(cString:base)),
                      !CGPDFDictionaryGetObject(font,"ToUnicode",&unused),!CGPDFDictionaryGetObject(font,"FontDescriptor",&unused) else { flag.unsafe=true;return }
                var encoding:CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(font,"Encoding",&encoding) { flag.unsafe=true }
            },Unmanaged.passUnretained(flag).toOpaque())
            if flag.unsafe { throw EngineError.unsupported("이 PDF의 내장·사용자 정의 글꼴 데이터까지 안전하게 가리는 경로는 아직 검증하지 못했어요.") }
        }
        guard let reference=page.pageRef,let table=CGPDFOperatorTableCreate() else { throw EngineError.invalid("PDF 콘텐츠 검사 실패") }
        defer { CGPDFOperatorTableRelease(table) }
        let content=CGPDFContentStreamCreateWithPage(reference)
        defer { CGPDFContentStreamRelease(content) }
        let flag=RedactionFlag()
        let reject:CGPDFOperatorCallback={_,info in Unmanaged<RedactionFlag>.fromOpaque(info!).takeUnretainedValue().unsafe=true }
        for name in ["BDC","BMC","BI"] { CGPDFOperatorTableSetCallback(table,name,reject) }
        let scanner=CGPDFScannerCreate(content,table,Unmanaged.passUnretained(flag).toOpaque())
        defer { CGPDFScannerRelease(scanner) }
        guard CGPDFScannerScan(scanner),!flag.unsafe else { throw EngineError.unsupported("마크된 텍스트·인라인 이미지 PDF는 가리기 지원 범위 밖이에요.") }
        var objects:CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources,"XObject",&objects),let objects {
            let flag=RedactionFlag()
            CGPDFDictionaryApplyFunction(objects,{_,object,info in
                let flag=Unmanaged<RedactionFlag>.fromOpaque(info!).takeUnretainedValue()
                var stream:CGPDFStreamRef?,name:UnsafePointer<CChar>?
                guard CGPDFObjectGetValue(object,.stream,&stream),let stream,let streamDictionary=CGPDFStreamGetDictionary(stream),
                      CGPDFDictionaryGetName(streamDictionary,"Subtype",&name),let name,String(cString:name)=="Image" else { flag.unsafe=true;return }
            },Unmanaged.passUnretained(flag).toOpaque())
            if flag.unsafe { throw EngineError.unsupported("Form XObject가 있는 PDF는 안전한 가리기 지원 범위 밖이에요.") }
        }
    }
}
private final class RedactionFlag { var unsafe=false }

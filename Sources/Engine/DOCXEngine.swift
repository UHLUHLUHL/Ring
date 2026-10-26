import Foundation
import AppKit
import ImageIO
import PDFKit
import Vision

/// Conversion has two explicit representations for PDF: a page view and editable text.
/// Word cannot represent arbitrary PDF graphics losslessly as native Word objects.
enum DOCXEngine {
    static func xml(_ text:String) -> String {
        String(text.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || ($0.value >= 32 && $0.value != 0xfffe && $0.value != 0xffff) })
            .replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")
    }
    static func paragraph(_ text:String) -> String {
        "<w:p><w:pPr><w:spacing w:after=\"120\"/></w:pPr><w:r><w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:eastAsia=\"Apple SD Gothic Neo\"/><w:sz w:val=\"22\"/></w:rPr><w:t xml:space=\"preserve\">\(xml(text))</w:t></w:r></w:p>"
    }
    static let pageBreak="<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
    static func convert(_ source:URL,to output:URL) async throws -> String {
        let folder=output.deletingLastPathComponent().appendingPathComponent("docx-media",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:folder) }
        var body="",media:[DOCXArchive.Entry]=[],relationships="",types=""
        func addImage(_ file:URL,width:Int,height:Int,orientation:Int=1) throws {
            let index=media.count+1,ext=file.pathExtension.lowercased(),name="image\(index).\(ext)",id="rId\(index)"
            media.append(.init("word/media/"+name,file:file))
            relationships += "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>"
            types += "<Override PartName=\"/word/media/\(name)\" ContentType=\"image/\(ext == "jpg" || ext == "jpeg" ? "jpeg":"png")\"/>"
            body += picture(width:width,height:height,orientation:orientation,index:index,name:name)
        }
        var ocrCount=0,pageCount=1
        if source.pathExtension.lowercased() == "pdf" {
            let doc=try PDFEngine.open(source);pageCount=doc.pageCount
            for i in 0..<doc.pageCount { defer { EngineProgress.step(i, of: doc.pageCount) }
                try Task.checkCancellation()
                let file=folder.appendingPathComponent("page\(i+1).png")
                if i > 0 { body += pageBreak }
                body += paragraph("\(i+1)페이지 원본 보기")
                if let bytes=try PDFEngine.singleJPEG(doc.page(at:i)!),let imageSource=CGImageSourceCreateWithData(bytes as CFData,nil),let image=CGImageSourceCreateImageAtIndex(imageSource,0,nil) {
                    let jpeg=folder.appendingPathComponent("page\(i+1).jpg");try bytes.write(to:jpeg)
                    try addImage(jpeg,width:image.width,height:image.height)
                } else {
                    let dimensions:CGSize=try autoreleasepool {
                        let image=try PDFEngine.renderWithAnnotations(doc.page(at:i)!,depth:16,space:CGColorSpace(name:CGColorSpace.displayP3)!)
                        try ImageCodec.write(image,properties:[kCGImagePropertyOrientation:1],format:.png,to:file)
                        try ImageCodec.verify(image,properties:[kCGImagePropertyOrientation:1],output:file,exact:true)
                        return CGSize(width:image.width,height:image.height)
                    }
                    try addImage(file,width:Int(dimensions.width),height:Int(dimensions.height))
                }
                body += pageBreak + paragraph("\(i+1)페이지 편집 텍스트")
                let page=doc.page(at:i)!
                let hasText = !(page.string ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
                if !hasText { ocrCount += 1 }
                let scan=try autoreleasepool { () throws -> CGImage in
                    let box=page.bounds(for:.cropBox)
                    return try PDFEngine.renderWithAnnotations(page,scale:min(300.0/72,4096/max(box.width,box.height)))
                }
                let recognized = try await recognize(scan,nativePage:hasText ? page : nil)
                body += recognized.isEmpty && hasText ? attributed(page.attributedString!) : recognized
            }
        } else {
            try autoreleasepool {
                let input=try ImageInput(source)
                if [ImageFormat.png.uti,ImageFormat.jpg.uti].contains(input.type) {
                    try addImage(source,width:input.image.width,height:input.image.height,orientation:input.orientation)
                } else {
                    let file=folder.appendingPathComponent("image.png")
                    try ImageCodec.write(input.image,properties:input.properties,format:.png,to:file)
                    try ImageCodec.verify(input.image,properties:input.properties,output:file,exact:true)
                    try addImage(file,width:input.image.width,height:input.image.height,orientation:input.orientation)
                }
            }
        }
        let entries:[DOCXArchive.Entry] = [
            .init("[Content_Types].xml","<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>\(types)</Types>"),
            .init("_rels/.rels","<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"),
            .init("word/_rels/document.xml.rels","<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(relationships)</Relationships>"),
            .init("word/document.xml","<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>\(body)<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"720\" w:right=\"720\" w:bottom=\"720\" w:left=\"720\"/></w:sectPr></w:body></w:document>")
        ] + media
        try DOCXArchive.write(entries,to:output)
        return source.pathExtension.lowercased() == "pdf" ? "\(pageCount)페이지 보기+편집 텍스트 · OCR \(ocrCount)페이지(인식 오류 가능) · Word 재배치" : "원본 해상도 · 포함 이미지 바이트 검증"
    }
    static func picture(width:Int,height:Int,orientation:Int,index:Int,name:String) -> String {
        let swapped=orientation >= 5
        let displayW=Double(swapped ? height:width),displayH=Double(swapped ? width:height)
        let scale=min(6.5*914400/displayW,8.5*914400/displayH)
        let w=Int64(Double(width)*scale),h=Int64(Double(height)*scale),dw=swapped ? h:w,dh=swapped ? w:h
        // The embedded file retains EXIF orientation; tested image loaders apply it.
        // Applying DrawingML rotation a second time yields blank output in LibreOffice.
        return """
        <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(dw)" cy="\(dh)"/><wp:docPr id="\(index)" name="\(xml(name))" descr="변환 원본 이미지"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(index)" name="\(xml(name))"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rId\(index)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(dw)" cy="\(dh)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """
    }
    static func attributed(_ text:NSAttributedString) -> String {
        var result="<w:p>"
        text.enumerateAttributes(in:NSRange(location:0,length:text.length)) { attrs,range,_ in
            let font=attrs[.font] as? NSFont,size=Int(((font?.pointSize ?? 11)*2).rounded())
            var properties="<w:sz w:val=\"\(max(2,min(size,400)))\"/>"
            if let font {
                properties += "<w:rFonts w:ascii=\"\(xml(font.familyName ?? "Arial"))\" w:hAnsi=\"\(xml(font.familyName ?? "Arial"))\"/>"
                let traits=NSFontManager.shared.traits(of:font)
                if traits.contains(.boldFontMask) { properties += "<w:b/>" }
                if traits.contains(.italicFontMask) { properties += "<w:i/>" }
            }
            if let color=(attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) {
                properties += String(format:"<w:color w:val=\"%02X%02X%02X\"/>",Int(color.redComponent*255),Int(color.greenComponent*255),Int(color.blueComponent*255))
            }
            let parts=text.attributedSubstring(from:range).string.components(separatedBy:.newlines)
            for (i,line) in parts.enumerated() {
                if i > 0 { result += "</w:p><w:p>" }
                result += "<w:r><w:rPr>\(properties)</w:rPr><w:t xml:space=\"preserve\">\(xml(line))</w:t></w:r>"
            }
        }
        return result+"</w:p>"
    }
    static func recognize(_ image:CGImage,nativePage:PDFPage? = nil) async throws -> String {
        if #available(macOS 26, *) { return try await recognizeDocument(image,nativePage:nativePage) }
        return try recognizeLines(image,nativePage:nativePage)
    }
    /// macOS 15 fallback: line-level text recognition. No table or paragraph
    /// structure is available, so each recognized line becomes a paragraph.
    static func recognizeLines(_ image:CGImage,nativePage:PDFPage?) throws -> String {
        let request=VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages=["ko-KR","en-US"]
        request.usesLanguageCorrection=true
        try VNImageRequestHandler(cgImage:image).perform([request])
        var blocks:[(CGRect,String)]=[]
        for line in request.results ?? [] {
            guard var transcript=line.topCandidates(1).first?.string else { continue }
            let box=line.boundingBox
            if let page=nativePage,page.rotation == 0 {
                let bounds=page.bounds(for:.cropBox)
                let rect=CGRect(x:bounds.minX+box.minX*bounds.width,y:bounds.minY+box.minY*bounds.height,width:box.width*bounds.width,height:box.height*bounds.height).insetBy(dx:-1,dy:-1)
                if let text=page.selection(for:rect)?.string,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { transcript=text }
            }
            blocks.append((box,paragraph(transcript)))
        }
        return reflow(blocks).map(\.1).joined()
    }
    @available(macOS 26, *)
    static func recognizeDocument(_ image:CGImage,nativePage:PDFPage?) async throws -> String {
        var request=RecognizeDocumentsRequest()
        request.barcodeDetectionOptions.enabled=false
        request.textRecognitionOptions.recognitionLanguages=[Locale.Language(identifier:"ko"),Locale.Language(identifier:"en")]
        request.textRecognitionOptions.useLanguageCorrection=true
        let observations=try await request.perform(on:image)
        var result=""
        for observation in observations {
            let container=observation.document
            let tables=container.tables
            var blocks:[(CGRect,String)]=[]
            for p in container.paragraphs {
                let box=p.boundingRegion.boundingBox.cgRect
                if !tables.contains(where:{$0.boundingRegion.boundingBox.cgRect.contains(CGPoint(x:box.midX,y:box.midY))}) {
                    var transcript = p.transcript
                    if let page=nativePage,page.rotation == 0 {
                        let bounds=page.bounds(for:.cropBox)
                        let rect=CGRect(x:bounds.minX+box.minX*bounds.width,y:bounds.minY+box.minY*bounds.height,width:box.width*bounds.width,height:box.height*bounds.height).insetBy(dx:-1,dy:-1)
                        if let text=page.selection(for:rect)?.string,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { transcript=text }
                    }
                    blocks.append((box,paragraph(transcript)))
                }
            }
            for table in tables {
                var rendered="<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>"
                for edge in ["top","left","bottom","right","insideH","insideV"] { rendered += "<w:\(edge) w:val=\"single\" w:sz=\"4\" w:color=\"D9D9D9\"/>" }
                rendered += "</w:tblBorders></w:tblPr>"
                // Flatten spans into a rectangular editable table; do not duplicate merged text.
                var seen=Set<String>()
                for row in table.rows {
                    rendered += "<w:tr>"
                    for cell in row {
                        let key="\(cell.rowRange)-\(cell.columnRange)"
                        rendered += "<w:tc>"+paragraph(seen.insert(key).inserted ? cell.content.text.transcript:"")+"</w:tc>"
                    }
                    rendered += "</w:tr>"
                }
                rendered += "</w:tbl><w:p/>";blocks.append((table.boundingRegion.boundingBox.cgRect,rendered))
            }
            if blocks.isEmpty { result += paragraph(container.text.transcript) }
            else {
                // Recursive whitespace cuts keep columns together; spanning headings/tables
                // split horizontal bands before each band is read left to right.
                result += reflow(blocks).map(\.1).joined()
            }
        }
        return result
    }
    static func reflow(_ blocks:[(CGRect,String)]) -> [(CGRect,String)] {
        guard blocks.count>1 else { return blocks }
        for vertical in [false,true] {
            let sorted=blocks.sorted { vertical ? $0.0.minX<$1.0.minX : $0.0.minY<$1.0.minY }
            var edge=vertical ? sorted[0].0.maxX : sorted[0].0.maxY
            for i in 1..<sorted.count {
                let start=vertical ? sorted[i].0.minX : sorted[i].0.minY
                if start-edge > (vertical ? 0.035:0.012) {
                    let a=reflow(Array(sorted[..<i])),b=reflow(Array(sorted[i...]))
                    return vertical ? a+b : b+a
                }
                edge=max(edge,vertical ? sorted[i].0.maxX : sorted[i].0.maxY)
            }
        }
        return blocks.sorted { abs($0.0.maxY-$1.0.maxY)>0.01 ? $0.0.maxY>$1.0.maxY : $0.0.minX<$1.0.minX }
    }
}

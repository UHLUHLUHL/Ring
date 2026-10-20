import Foundation
import PDFKit
import ImageIO
@main struct DOCXTests {
 static func main() async {
  setbuf(stdout,nil)
  do {
   var outputs:[[String:String]]=[]
   for path in [".work/stage1-check/fixture.jpg",".work/stage1-check/fixture.png",".work/stage1-check/p3-16-6.tiff",".work/pdf-fixtures/text.pdf",".work/pdf-fixtures/scan.pdf"] {
    let source=URL(fileURLWithPath:path)
    let original=try Data(contentsOf:source)
    let r=try await RingEngine.shared.run(.init(source:source,operation:.convert(.docx)))
    guard try Data(contentsOf:source) == original else { throw EngineError.quality("DOCX 원본 변경") }
    outputs.append(["source":source.path,"output":r.url.path])
    print("PASS DOCX",path,r.url.path,r.detail,r.seconds)
   }
   let table=try PDFEngine.open(URL(fileURLWithPath:".work/docx-fixtures/table.pdf"))
   let scanImage=URL(fileURLWithPath:".work/docx-fixtures/table.png")
   try ImageCodec.write(PDFEngine.renderWithAnnotations(table.page(at:0)!),properties:[:],format:.png,to:scanImage)
   let scan=URL(fileURLWithPath:".work/docx-fixtures/table-scan.pdf")
   var box=CGRect(x:0,y:0,width:600,height:600)
   let ctx=CGContext(scan as CFURL,mediaBox:&box,nil)!
   ctx.beginPDFPage(nil)
   let image=CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(scanImage as CFURL,nil)!,0,nil)!
   ctx.draw(image,in:box);ctx.endPDFPage();ctx.closePDF()
   let tableResult=try await RingEngine.shared.run(.init(source:scan,operation:.convert(.docx)))
   print("PASS structured OCR fallback",tableResult.url.path,tableResult.detail,tableResult.seconds)
   outputs.append(["source":scan.path,"output":tableResult.url.path])
   try JSONSerialization.data(withJSONObject:outputs,options:.prettyPrinted).write(to:URL(fileURLWithPath:".work/docx-test-outputs.json"))
   for path in [".work/pdf-fixtures/text.pdf",".work/stage1-check/fixture.pdf"] {
    let source=URL(fileURLWithPath:path),original=try Data(contentsOf:source)
    let r=try await RingEngine.shared.run(.init(source:source,operation:.compress))
    try PDFEngine.validateUnchanged(source,PDFEngine.open(r.url))
    guard try Data(contentsOf:source) == original else { throw EngineError.quality("원본 변경") }
    print("PASS PDF compression",r.detail,r.seconds)
   }
  } catch { print("FAIL",error.localizedDescription);exit(1) }
 }
}

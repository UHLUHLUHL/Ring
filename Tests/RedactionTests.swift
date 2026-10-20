import Foundation
import PDFKit
@main struct RedactionTests {
 static func main() async {
  setbuf(stdout,nil)
  do {
   let text=URL(fileURLWithPath:".work/pdf-fixtures/text.pdf")
   let original=try Data(contentsOf:text)
   let result=try await RingEngine.shared.run(.init(source:text,operation:.pdfRedact(.init(page:0,rect:CGRect(x:15,y:200,width:240,height:30)))))
   guard try Data(contentsOf:text)==original else { throw EngineError.quality("원본 변경") }
   print("PASS text redact",result.url.path,result.detail,result.seconds)
   let jpg=URL(fileURLWithPath:".work/stage1-check/fixture.jpg")
   let pdf=try await RingEngine.shared.run(.init(source:jpg,operation:.convert(.pdf)))
   let edited=try await RingEngine.shared.run(.init(source:pdf.url,operation:.pdfRedact(.init(page:0,rect:CGRect(x:100,y:100,width:100,height:100)))))
   print("PASS JPEG PDF redact",edited.url.path,edited.detail,edited.seconds)
   let annotated=try await RingEngine.shared.run(.init(source:text,operation:.pdfNote(.init(page:0,rect:CGRect(x:20,y:20,width:100,height:20),text:"unsafe structure test"))))
   do {
    _=try await RingEngine.shared.run(.init(source:annotated.url,operation:.pdfRedact(.init(page:0,rect:CGRect(x:20,y:200,width:200,height:30)))))
    throw EngineError.quality("기존 주석 PDF 허용됨")
   } catch EngineError.unsupported { print("PASS unsupported annotation PDF rejected") }
   try JSONSerialization.data(withJSONObject:["text":result.url.path,"image":edited.url.path],options:.prettyPrinted).write(to:URL(fileURLWithPath:".work/redaction-results.json"))
  } catch { print("FAIL",error.localizedDescription);exit(1) }
 }
}

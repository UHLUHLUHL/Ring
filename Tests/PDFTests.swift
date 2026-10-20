import Foundation
import ImageIO
import PDFKit
@main struct PDFTests {
 static func main() async {
  setbuf(stdout,nil)
  do {
   if CommandLine.arguments.contains("--benchmark") { try await benchmark() } else { try await run() }
  } catch { print("FAIL",error.localizedDescription); exit(1) }
 }
 static func benchmark() async throws {
  for format in [ImageFormat.png,.txt] {
   let r = try await RingEngine.shared.run(EngineJob(source:URL(fileURLWithPath:".work/pdf-fixtures/hundred.pdf"),operation:.convert(format)))
   print("BENCH 100 pages",format,r.seconds,r.detail)
  }
 }
 static func run() async throws {
  let root = URL(fileURLWithPath:".work/pdf-fixtures",isDirectory:true)
  for name in ["fixture.png","fixture.jpg","p3-16-6.tiff"] {
   let input = URL(fileURLWithPath:".work/stage1-check/"+name)
   let result = try await RingEngine.shared.run(EngineJob(source:input,operation:.convert(.pdf)))
   print("PASS image PDF",name,result.detail,result.seconds)
   if name == "fixture.jpg" {
    let exported = try await RingEngine.shared.run(EngineJob(source:result.url,operation:.convert(.jpg)))
    guard try Data(contentsOf:exported.url.appendingPathComponent("0001.jpg")) == Data(contentsOf:input) else { throw EngineError.quality("JPEG 추출 바이트 불일치") }
    print("PASS single JPEG original bytes",exported.seconds)
   }
  }
  let text = root.appendingPathComponent("text.pdf")
  for format in [ImageFormat.png,.jpg,.txt] {
   let result = try await RingEngine.shared.run(EngineJob(source:text,operation:.convert(format)))
   print("PASS PDF export",format,result.detail,result.seconds)
   if format == .txt {
    let value = try String(contentsOf:result.url,encoding:.utf8)
    guard value.contains("Ring PDF page 1"),value.contains("Ring PDF page 2") else { throw EngineError.quality("텍스트 누락") }
   }
  }
  let meta = try await RingEngine.shared.run(EngineJob(source:text,operation:.pdfMetadata(PDFMetadata(title:"Ring 새 제목",author:"Ring",subject:"test"))))
  print("PASS metadata",meta.detail,meta.seconds)
  let note = try await RingEngine.shared.run(EngineJob(source:text,operation:.pdfNote(PDFNote(page:0,rect:CGRect(x:160,y:50,width:200,height:50),text:"Ring 주석"))))
  print("PASS annotation",note.detail,note.seconds)
  let jpgpdf = URL(fileURLWithPath:".work/stage1-check/fixture.pdf")
  if FileManager.default.fileExists(atPath:jpgpdf.path) {
   let r = try await RingEngine.shared.run(EngineJob(source:jpgpdf,operation:.pdfMetadata(PDFMetadata(title:"preserve",author:"",subject:""))))
   print("PASS image stream metadata",r.detail)
  }
  let original = try PDFEngine.open(text)
  let scanned = root.appendingPathComponent("scan.png")
  try ImageCodec.write(PDFEngine.renderWithAnnotations(original.page(at:0)!),properties:[:],format:.png,to:scanned)
  let scanPDF = try await RingEngine.shared.run(EngineJob(source:scanned,operation:.convert(.pdf)))
  let ocr = try await RingEngine.shared.run(EngineJob(source:scanPDF.url,operation:.convert(.txt)))
  guard try String(contentsOf:ocr.url,encoding:.utf8).contains("Ring PDF page") else { throw EngineError.quality("OCR 테스트 문구 누락") }
  print("PASS OCR",ocr.detail,ocr.seconds)
  print("PASS all PDF tests")
 }
}

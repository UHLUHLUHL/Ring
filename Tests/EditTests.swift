import Foundation
import CoreGraphics
import ImageIO
@main struct EditTests {
 static func main() async {
  setbuf(stdout,nil)
  do { try await run() } catch { print("FAIL",error.localizedDescription);exit(1) }
 }
 static func run() async throws {
  let root = URL(fileURLWithPath:".work/stage1-check",isDirectory:true)
  let base = root.appendingPathComponent("fixture.png"),normal = CGRect(x:0.125,y:0.25,width:0.5,height:0.375)
  for orientation in 1...8 {
   let src = root.appendingPathComponent("orientation-\(orientation).png")
   let input = try ImageInput(base)
   var props = input.properties;props[kCGImagePropertyOrientation] = orientation
   try ImageCodec.write(input.image,properties:props,format:.png,to:src)
   let crop = try await RingEngine.shared.run(EngineJob(source:src,operation:.edit(.crop(normal))))
   let output = try ImageInput(crop.url),shown = try PDFEngine.oriented(output.image,output.orientation)
   let expected = try PDFEngine.oriented(input.image,orientation)
   let expectedRect = try ImageEdits.rawRect(normal,image:expected,orientation:1)
   guard let expectedCrop = expected.cropping(to:expectedRect),try PixelCheck.compare(expectedCrop,shown).exact else { throw EngineError.quality("방향 \(orientation) 자르기 불일치") }
   print("PASS crop orientation",orientation,crop.seconds,crop.detail)
  }
  for file in [base,root.appendingPathComponent("p3-16-6.tiff")] {
   for edit in [ImageEdit.redact(normal),.annotate(normal,"Ring 주석"),.adjust(exposure:0.3,contrast:1,saturation:1)] {
    let result = try await RingEngine.shared.run(EngineJob(source:file,operation:.edit(edit)))
    if case .redact = edit {
     let out = try ImageInput(result.url),raw = try ImageEdits.rawRect(normal,image:out.image,orientation:out.orientation)
     let block = out.image.cropping(to:raw)!
     let black = try PDFEngine.bitmap(width:block.width,height:block.height,space:block.colorSpace!,depth:16)
     black.setFillColor(CGColor(gray:0,alpha:1));black.fill(CGRect(x:0,y:0,width:block.width,height:block.height))
     guard try PixelCheck.compare(block,black.makeImage()!).exact,out.properties[kCGImagePropertyGPSDictionary] == nil else { throw EngineError.quality("가리기 영역·GPS 검사 실패") }
    }
    print("PASS edit",file.lastPathComponent,result.seconds,result.detail)
   }
  }
  let unchanged = try await RingEngine.shared.run(EngineJob(source:base,operation:.edit(.adjust(exposure:0,contrast:1,saturation:1))))
  guard try Data(contentsOf:base) == Data(contentsOf:unchanged.url) else { throw EngineError.quality("0 보정 바이트 불일치") }
  print("PASS zero adjustment bytes")
  let white = RGBAColor(red:1,green:1,blue:1,alpha:1)
  let bg = try await RingEngine.shared.run(EngineJob(source:base,operation:.edit(.background(BackgroundOptions(colors:[white],padding:32,corner:0,shadow:0,ratio:nil)))))
  let a = try ImageInput(base),b = try ImageInput(bg.url)
  guard b.image.width == a.image.width+64,b.image.height == a.image.height+64,
        let content = b.image.cropping(to:CGRect(x:32,y:32,width:a.image.width,height:a.image.height)),try PixelCheck.compare(a.image,content).exact else { throw EngineError.quality("배경 1:1 원본 픽셀 불일치") }
  print("PASS background 1:1 pixels",bg.seconds)
  let fancy = try await RingEngine.shared.run(EngineJob(source:base,operation:.edit(.background(BackgroundOptions(colors:[white,RGBAColor(red:0.2,green:0.4,blue:1,alpha:1)],padding:64,corner:24,shadow:24,ratio:1)))))
  print("PASS gradient rounded shadow",fancy.seconds)
  if CommandLine.arguments.contains("--quick") { print("PASS all functional edit tests");return }
  let large = URL(fileURLWithPath:".work/stage1-final2/12mp.png")
  for edit in [ImageEdit.crop(normal),.redact(normal),.adjust(exposure:0.3,contrast:1,saturation:1)] {
   let result = try await RingEngine.shared.run(EngineJob(source:large,operation:.edit(edit)))
   print("BENCH 12MP edit",result.seconds,result.detail)
  }
  print("PASS all edit tests")
 }
}

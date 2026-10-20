import Foundation
import ImageIO
@main struct CodecTests {
 static func main() async {
  setbuf(stdout,nil)
  do { try await run() } catch { print("FAIL",error.localizedDescription);exit(1) }
 }
 static func run() async throws {
  if CommandLine.arguments.contains("--avif-bench") {
   let r=try await RingEngine.shared.run(EngineJob(source:URL(fileURLWithPath:".work/stage1-final2/12mp.png"),operation:.convert(.avif)))
   print("BENCH AVIF grid",r.seconds,r.detail);return
  }
  if CommandLine.arguments.contains("--bench-only") {
   let large=URL(fileURLWithPath:".work/stage1-final2/12mp.png")
   for format in [ImageFormat.webp,.avif] {
    var times:[Double]=[]
    for _ in 0..<5 {
     let r=try await RingEngine.shared.run(EngineJob(source:large,operation:.convert(format)))
     times.append(r.seconds);print("sample 12MP",format,r.seconds,r.detail)
    }
    print("MEDIAN 12MP",format,times.sorted()[2])
   }
   return
  }
  let root=URL(fileURLWithPath:".work/stage1-check",isDirectory:true)
  for name in ["fixture.png","orientation-6.png","p3-8-1.tiff"] {
   let input=root.appendingPathComponent(name)
   for format in [ImageFormat.webp,.avif] {
    let r=try await RingEngine.shared.run(EngineJob(source:input,operation:.convert(format)))
    print("PASS codec",name,format,r.seconds,r.detail)
   }
  }
  let grid=root.appendingPathComponent("grid-alpha-6.png")
  let space=CGColorSpace(name:CGColorSpace.displayP3)!
  let context=try PDFEngine.bitmap(width:2061,height:1601,space:space)
  let gradient=CGGradient(colorsSpace:space,colors:[CGColor(colorSpace:space,components:[0.1,0.3,0.7,0.4])!,CGColor(colorSpace:space,components:[0.9,0.8,0.2,1])!] as CFArray,locations:[0,1])!
  context.drawLinearGradient(gradient,start:.zero,end:CGPoint(x:2061,y:1601),options:[])
  let destination=CGImageDestinationCreateWithURL(grid as CFURL,ImageFormat.png.uti as CFString,1,nil)!
  CGImageDestinationAddImage(destination,context.makeImage()!,[kCGImagePropertyOrientation:6] as CFDictionary)
  guard CGImageDestinationFinalize(destination) else { throw EngineError.io("그리드 fixture 생성 실패") }
  let gridResult=try await RingEngine.shared.run(EngineJob(source:grid,operation:.convert(.avif)))
  print("PASS odd grid alpha orientation6",gridResult.seconds,gridResult.detail)
  for orientation in 2...8 {
   let r=try await RingEngine.shared.run(EngineJob(source:root.appendingPathComponent("orientation-\(orientation).png"),operation:.convert(.avif)))
   print("PASS AVIF orientation",orientation,r.detail)
  }
  let palette=try ImageInput(root.appendingPathComponent("palette.png")),paletteRef=try ImageInput(root.appendingPathComponent("palette-reference.png"))
  guard try PixelCheck.compare(palette.image,paletteRef.image).exact else { throw EngineError.quality("팔레트 색상 펼치기 오류") }
  for format in [ImageFormat.tiff,.webp,.avif] {
   let r=try await RingEngine.shared.run(EngineJob(source:root.appendingPathComponent("palette.png"),operation:.convert(format)))
   print("PASS indexed palette",format,r.detail)
  }
  let white=try await RingEngine.shared.run(EngineJob(source:grid,operation:.convert(.jpg)))
  print("PASS alpha JPEG white",white.detail)
  let alphaCompression=try await RingEngine.shared.run(EngineJob(source:grid,operation:.compress))
  print("PASS alpha PNG compression",alphaCompression.detail)
  let jpg=root.appendingPathComponent("fixture.jpg")
  let crop=try await RingEngine.shared.run(EngineJob(source:jpg,operation:.edit(.crop(CGRect(x:0.12,y:0.2,width:0.6,height:0.5)))))
  let cropInput=try ImageInput(crop.url)
  if let exif=cropInput.properties[kCGImagePropertyExifDictionary] as? [CFString:Any],let width=exif[kCGImagePropertyExifPixelXDimension] as? Int {
   guard width==cropInput.image.width else { throw EngineError.quality("자르기 EXIF 크기 불일치") }
  }
  print("PASS JPEG crop",crop.seconds,crop.detail)
  let sampled=try await RingEngine.shared.run(EngineJob(source:URL(fileURLWithPath:".work/probe/probe-0.95.jpg"),operation:.edit(.crop(CGRect(x:0.1,y:0.2,width:0.6,height:0.5)))))
  print("PASS JPEG 420 crop",sampled.detail)
  let compression=try await RingEngine.shared.run(EngineJob(source:jpg,operation:.compress))
  print("PASS JPEG compression",compression.seconds,compression.detail)
  let png=root.appendingPathComponent("fixture.png")
  let compressed=try await RingEngine.shared.run(EngineJob(source:png,operation:.compress))
  print("PASS PNG compression",compressed.seconds,compressed.detail)
  if CommandLine.arguments.contains("--quick") { return }
  let large=URL(fileURLWithPath:".work/stage1-final2/12mp.png")
  for format in [ImageFormat.webp,.avif] {
   var times:[Double]=[]
   for _ in 0..<5 {
    let r=try await RingEngine.shared.run(EngineJob(source:large,operation:.convert(format)))
    times.append(r.seconds);print("sample 12MP",format,r.seconds,r.detail)
   }
   print("MEDIAN 12MP",format,times.sorted()[2])
  }
 }
}

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
print("OS", ProcessInfo.processInfo.operatingSystemVersionString)
print("destinations", CGImageDestinationCopyTypeIdentifiers())
print("sources", CGImageSourceCopyTypeIdentifiers())
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
for y in 0..<256 { for x in 0..<256 { ctx.setFillColor(CGColor(colorSpace: cs, components: [CGFloat(x)/255, CGFloat(y)/255, CGFloat((x+y)%256)/255, 1])!); ctx.fill(CGRect(x:x,y:y,width:1,height:1)) } }
let image = ctx.makeImage()!
for (ext, type) in [("jpg", "public.jpeg"), ("heic", "public.heic"), ("png", "public.png"), ("tiff", "public.tiff"), ("bmp", "com.microsoft.bmp"), ("avif", "public.avif"), ("webp", "org.webmproject.webp")] {
 for q in (ext == "jpg" ? [0.95, 1.0] : [1.0]) {
  let url = root.appendingPathComponent("probe-\(q).\(ext)")
  guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { print(ext,"NO destination"); continue }
  CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality:q] as CFDictionary)
  print(ext, q, CGImageDestinationFinalize(dest))
 }
}
let jpg = root.appendingPathComponent("probe-1.0.jpg")
let jimg = CGImage(jpegDataProviderSource: CGDataProvider(url: jpg as CFURL)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
var box = CGRect(x:0,y:0,width:256,height:256)
let pdf = CGContext(root.appendingPathComponent("jpeg.pdf") as CFURL, mediaBox: &box, nil)!
pdf.beginPDFPage(nil); pdf.draw(jimg, in:box); pdf.endPDFPage(); pdf.closePDF()
let raw = try Data(contentsOf: jpg), pdfData = try Data(contentsOf: root.appendingPathComponent("jpeg.pdf"))
print("Quartz complete JPEG passthrough", pdfData.range(of:raw) != nil)

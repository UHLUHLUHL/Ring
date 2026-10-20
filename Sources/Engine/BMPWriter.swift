import Foundation
import CoreGraphics

enum BMPWriter {
    /// Use sRGB V5 BMP. The system decoder rejects embedded ICC profiles in our probe.
    static func write(_ image:CGImage,to url:URL) throws {
        guard image.bitsPerComponent <= 8, let cs = image.colorSpace, cs.model == .rgb, cs.name == CGColorSpace.sRGB,
              [.none,.noneSkipFirst,.noneSkipLast].contains(image.alphaInfo) else {
            throw EngineError.unsupported("BMP는 현재 불투명 sRGB 8비트 입력만 보존할 수 있어요.")
        }
        let width = image.width, height = image.height, row = width*4
        guard let ctx = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:row,space:cs,
                                  bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw EngineError.io("BMP 버퍼 생성 실패") }
        ctx.setBlendMode(.copy); ctx.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        let icc = Data()
        let pixelBytes = row*height, profileOffset = 124+pixelBytes
        var header = Data(count:138)
        func put(_ value:Int,_ offset:Int,_ size:Int = 4) { for i in 0..<size { header[offset+i] = UInt8((value >> (8*i))&255) } }
        header[0] = 0x42; header[1] = 0x4d
        put(138+pixelBytes+icc.count,2); put(138,10); put(124,14)
        put(width,18); put(height,22); put(1,26,2); put(32,28,2); put(3,30)
        put(pixelBytes,34); put(0x00ff0000,54); put(0x0000ff00,58); put(0x000000ff,62)
        put(icc.isEmpty ? 0x73524742 : 0x4d424544,70); put(4,122)
        if !icc.isEmpty { put(profileOffset,126); put(icc.count,130) }
        try header.write(to:url)
        let file = try FileHandle(forWritingTo:url); defer { try? file.close() }
        try file.seekToEnd()
        // CGBitmapContext storage is top to bottom; a positive DIB height stores bottom first.
        for y in (0..<height).reversed() { try file.write(contentsOf:Data(bytes:ctx.data!.advanced(by:y*row),count:row)) }
        try file.write(contentsOf:icc)
    }
}

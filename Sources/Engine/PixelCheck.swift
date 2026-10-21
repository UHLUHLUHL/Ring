import Foundation
import CoreGraphics

struct PixelMetrics {
    var squaredError: Double = 0
    var sampleCount: Int = 0
    var maxDifference: UInt16 = 0
    var psnr: Double { squaredError == 0 ? .infinity : 10 * log10(65535.0 * 65535 * Double(sampleCount) / squaredError) }
    var exact: Bool { maxDifference == 0 }
}

enum PixelCheck {
    /// Compare in the source color space, at 16-bit precision in bounded strips.
    /// This measures decoded premultiplied components, not compressed-file equivalence.
    static func compare(_ a: CGImage, _ b: CGImage) throws -> PixelMetrics {
        guard a.width == b.width, a.height == b.height else { throw EngineError.quality("검증 실패: 픽셀 크기가 달라요.") }
        guard let space = a.colorSpace, space.model == .rgb || space.model == .monochrome else {
            throw EngineError.unsupported("이 색상 모델은 무손실 검증을 지원하지 않아요.")
        }
        let components = space.model == .rgb ? 4 : 2
        var result = PixelMetrics()
        let stripRows = min(1024,max(1,(32*1024*1024)/(a.width*components*2)))
        for y in stride(from: 0, to: a.height, by: stripRows) {
            try Task.checkCancellation()
            let height = min(stripRows, a.height-y)
            let row = a.width * components * 2
            let info = CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            guard let ca = CGContext(data:nil, width:a.width, height:height, bitsPerComponent:16, bytesPerRow:row, space:space, bitmapInfo:info),
                  let cb = CGContext(data:nil, width:a.width, height:height, bitsPerComponent:16, bytesPerRow:row, space:space, bitmapInfo:info) else {
                throw EngineError.quality("픽셀 검증 버퍼를 만들 수 없어요.")
            }
            // Draw matching strips without resampling; Core Graphics uses bottom-left coordinates.
            for (ctx, img) in [(ca,a),(cb,b)] {
                ctx.setBlendMode(.copy); ctx.interpolationQuality = .none
                ctx.draw(img, in:CGRect(x:0,y:-y,width:a.width,height:a.height))
            }
            let count = row * height / 2
            let pa = ca.data!.bindMemory(to:UInt16.self, capacity:count)
            let pb = cb.data!.bindMemory(to:UInt16.self, capacity:count)
            var largest:UInt16=0
            let squared=ring_compare_pixels16(pa,pb,count,a.bitsPerComponent <= 8 ? 1:0,&largest)
            result.maxDifference=max(result.maxDifference,largest)
            result.squaredError+=Double(squared)
            result.sampleCount += count
        }
        return result
    }
}

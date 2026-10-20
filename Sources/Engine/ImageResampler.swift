import Foundation
import CoreGraphics
import Accelerate

enum ImageResampler {
    static func resize(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0, width <= 65535, height <= 65535,
              Int64(width) * Int64(height) <= 52_000_000,
              let space = image.colorSpace, space.model == .rgb else { throw EngineError.invalid("RGB 이미지 크기 또는 메모리 한도를 확인해 주세요.") }
        if width == image.width && height == image.height { return image }
        let depth = image.bitsPerComponent > 8 ? 16 : 8
        let source = try PDFEngine.bitmap(width: image.width, height: image.height, space: space, depth: depth)
        source.setBlendMode(.copy); source.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let target = try PDFEngine.bitmap(width: width, height: height, space: space, depth: depth)
        var a = vImage_Buffer(data: source.data!, height: vImagePixelCount(image.height), width: vImagePixelCount(image.width), rowBytes: source.bytesPerRow)
        var b = vImage_Buffer(data: target.data!, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: target.bytesPerRow)
        let flags = vImage_Flags(kvImageHighQualityResampling | (ThermalPolicy.threads <= 2 ? kvImageDoNotTile : 0))
        let rc = depth == 16 ? vImageScale_ARGB16U(&a, &b, nil, flags) : vImageScale_ARGB8888(&a, &b, nil, flags)
        guard rc == kvImageNoError, let result = target.makeImage() else { throw EngineError.io("vImage 리샘플링 실패: \(rc)") }
        return result
    }
    static func fit(_ image: CGImage, maxDimension: Int) throws -> CGImage {
        let factor = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        return try resize(image, width: max(1, Int((Double(image.width) * factor).rounded())), height: max(1, Int((Double(image.height) * factor).rounded())))
    }
}

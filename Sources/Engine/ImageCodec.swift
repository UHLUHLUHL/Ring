import Foundation
import CoreGraphics
import ImageIO

struct ImageInput {
    let source: CGImageSource
    let image: CGImage
    let properties: [CFString: Any]
    let type: String
    let orientation: Int
    init(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache:false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString:Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int,
              let h = properties[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0,
              w <= 65535, h <= 65535, Int64(w)*Int64(h) <= 52_000_000 else {
            throw EngineError.unsupported("손상·다중 프레임 이미지 또는 52MP 초과 이미지는 처리하지 않아요.")
        }
        for kind in [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity] {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kind) != nil {
                throw EngineError.unsupported("HDR 게인맵·깊이 정보가 있어요. 보존을 검증하지 못한 변환은 저장하지 않아요.")
            }
        }
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately:true, kCGImageSourceShouldAllowFloat:true] as CFDictionary),
              decoded.bitsPerComponent <= 16, !decoded.bitmapInfo.contains(.floatComponents),
              let cs = decoded.colorSpace, !CGColorSpaceUsesExtendedRange(cs), !cs.isHDR(),
              cs.model == .rgb || cs.model == .monochrome || cs.model == .indexed else {
            throw EngineError.unsupported("HDR·부동소수·CMYK 입력은 보존 검증 경로가 아직 없어요.")
        }
        let image:CGImage
        if cs.model == .indexed,let base=cs.baseColorSpace,base.model == .rgb || base.model == .monochrome {
            let context=try PDFEngine.bitmap(width:decoded.width,height:decoded.height,space:base)
            context.setBlendMode(.copy);context.interpolationQuality = .none
            context.draw(decoded,in:CGRect(x:0,y:0,width:decoded.width,height:decoded.height))
            guard let expanded=context.makeImage() else { throw EngineError.io("팔레트 펼치기 실패") }
            image=expanded
        } else { image=decoded }
        self.source = source; self.image = image; self.properties = properties
        self.type = type as String; orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    }
}

enum ImageCodec {
    static func convert(_ input: URL, to output: URL, format: ImageFormat) throws -> String {
        if let header=CGImageSourceCreateWithURL(input as CFURL,nil),CGImageSourceGetCount(header)>0,
           CGImageSourceGetType(header) as String? == format.uti,CGImageSourceGetStatus(header) == .statusComplete {
            try FileIntegrity.copy(input,to:output)
            return "원본 바이트 그대로 · 복사 검증 완료"
        }
        if format == .webp || format == .avif { return try ExternalCodecs.convert(input,to:output,format:format) }
        guard [.png,.jpg,.heic,.tiff,.bmp].contains(format) else { throw EngineError.unsupported("이 변환 엔진은 아직 연결되지 않았어요.") }
        let value = try ImageInput(input)
        if value.type == format.uti {
            try FileIntegrity.copy(input,to:output)
            return "원본 바이트 그대로"
        }
        if format == .bmp && value.orientation != 1 {
            throw EngineError.unsupported("BMP는 EXIF 방향 태그를 보존하지 못해요. PNG 또는 TIFF를 선택해 주세요.")
        }
        // Do not silently quantize 16-bit inputs to an encoder's 8-bit intermediate.
        if value.image.bitsPerComponent > 8 && [.jpg,.heic,.bmp].contains(format) {
            throw EngineError.unsupported("이 인코더의 고비트 보존을 검증하지 못했어요. PNG 또는 TIFF를 선택해 주세요.")
        }
        let removesAlpha = (format == .jpg || format == .bmp) && [.first,.last,.premultipliedFirst,.premultipliedLast].contains(value.image.alphaInfo)
        let reference = removesAlpha ? try flattenWhite(value.image) : value.image
        let encodingImage = format == .png ? try promoteAlpha(reference) : reference
        try write(encodingImage, properties:value.properties, format:format, to:output)
        if format == .jpg { try JPEGStructure.require444(output) }
        let lossy = format == .jpg || format == .heic
        let metrics = try verify(reference, properties:value.properties, output:output, exact:!lossy)
        return (removesAlpha ? "투명도는 흰 배경으로 합성 · ":"") + (lossy ? String(format:"손실 인코딩 1회 · PSNR %.2f dB", metrics.psnr) : "무손실 · 디코딩 픽셀 일치")
    }
    static func flattenWhite(_ image:CGImage) throws -> CGImage {
        let space=image.colorSpace!,info:UInt32=space.model == .rgb ? CGImageAlphaInfo.noneSkipLast.rawValue:CGImageAlphaInfo.none.rawValue
        guard let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:space,bitmapInfo:info) else { throw EngineError.io("흰 배경 합성 버퍼 오류") }
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:image.width,height:image.height))
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        return context.makeImage()!
    }
    static func promoteAlpha(_ image:CGImage) throws -> CGImage {
        guard [.first,.last,.premultipliedFirst,.premultipliedLast].contains(image.alphaInfo),image.bitsPerComponent == 8 else { return image }
        let context = try PDFEngine.bitmap(width:image.width,height:image.height,space:image.colorSpace!,depth:16)
        context.setBlendMode(.copy);context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        return context.makeImage()!
    }
    static func write(_ providedImage: CGImage, properties: [CFString:Any], format: ImageFormat, to output: URL) throws {
        let image = format == .png ? try promoteAlpha(providedImage) : providedImage
        if format == .bmp { try BMPWriter.write(image,to:output); return }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.uti as CFString, 1, nil) else {
            throw EngineError.unsupported("이 OS에서 \(format.rawValue.uppercased()) 저장을 지원하지 않아요.")
        }
        var props = properties
        props[kCGImagePropertyDepth] = image.bitsPerComponent
        props[kCGImageDestinationLossyCompressionQuality] = 1.0
        props[kCGImageDestinationEmbedThumbnail] = false
        if format == .tiff { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression:5] }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EngineError.io("이미지 인코딩에 실패했어요.") }
    }
    @discardableResult
    static func verify(_ image: CGImage, properties: [CFString:Any], output:URL, exact:Bool) throws -> PixelMetrics {
        let written = try ImageInput(output)
        guard written.orientation == (properties[kCGImagePropertyOrientation] as? Int ?? 1),
              written.image.bitsPerComponent >= image.bitsPerComponent,
              written.image.colorSpace?.copyICCData() == image.colorSpace?.copyICCData() else {
            throw EngineError.quality("방향·비트 깊이·ICC 보존 검사 실패 (방향 \(written.orientation)/\(properties[kCGImagePropertyOrientation] as? Int ?? 1), 깊이 \(written.image.bitsPerComponent)/\(image.bitsPerComponent), ICC \(written.image.colorSpace?.copyICCData() == image.colorSpace?.copyICCData())). 결과를 저장하지 않았어요.")
        }
        let m = try PixelCheck.compare(image,written.image)
        guard exact ? m.exact : m.psnr >= 45 else {
            throw EngineError.quality(String(format:"품질 검사 실패(PSNR %.2f dB). 결과를 저장하지 않았어요.",m.psnr))
        }
        return m
    }
    static func removeLocation(_ input: URL, to output: URL) throws -> String {
        let value = try ImageInput(input)
        if value.type == ImageFormat.png.uti {
            try PNGMetadata.stripLocation(input, to:output)
            let result = try ImageInput(output)
            guard result.properties[kCGImagePropertyGPSDictionary] == nil,
                  try PNGMetadata.imageData(input) == PNGMetadata.imageData(output) else { throw EngineError.quality("PNG GPS·원본 스트림 검증 실패") }
            try verify(value.image,properties:value.properties,output:output,exact:true)
            return "GPS·텍스트 메타데이터 제거 · IDAT 원본 바이트 일치"
        }
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, value.type as CFString, 1, nil) else {
            throw EngineError.unsupported("이 형식의 무재압축 메타데이터 편집을 지원하지 않아요.")
        }
        var error: Unmanaged<CFError>?
        let metadata = CGImageSourceCopyMetadataAtIndex(value.source, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        var paths: [CFString] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in
            if (path as String).localizedCaseInsensitiveContains("GPS") { paths.append(path) }
            return true
        }
        for path in paths { CGImageMetadataRemoveTagWithPath(metadata, nil, path) }
        let options = [kCGImageDestinationMetadata:metadata,
                       kCGImageDestinationMergeMetadata:false,
                       kCGImageMetadataShouldExcludeGPS:true,
                       kCGImageMetadataShouldExcludeXMP:true] as CFDictionary
        guard CGImageDestinationCopyImageSource(dest, value.source, options, &error) else {
            throw EngineError.io(error?.takeRetainedValue().localizedDescription ?? "무재압축 복사 실패")
        }
        // CopyImageSource finalizes the destination itself.
        let result = try ImageInput(output)
        guard result.properties[kCGImagePropertyGPSDictionary] == nil else { throw EngineError.quality("GPS 제거 검증 실패") }
        try verify(value.image, properties:value.properties, output:output, exact:true)
        if value.type == ImageFormat.jpg.uti {
            guard try JPEGStructure.codingBytes(Data(contentsOf:input)) == JPEGStructure.codingBytes(Data(contentsOf:output)) else {
                throw EngineError.quality("JPEG 원본 압축 스트림 보존 검사 실패")
            }
        }
        return "GPS·XMP 제거 · 디코딩 픽셀 일치"
    }
}

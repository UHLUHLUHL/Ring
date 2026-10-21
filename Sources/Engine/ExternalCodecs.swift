import Foundation
import CoreGraphics
import ImageIO

struct JPEGSampling {
    let width:Int,height:Int,mcuWidth:Int,mcuHeight:Int
    init(_ data:Data) throws {
        var index=2
        while index+4 <= data.count {
            let marker=data[index+1],n=Int(data[index+2])*256+Int(data[index+3])
            guard n>=2,index+n+2<=data.count else { break }
            if [0xc0,0xc1,0xc2].contains(marker) {
                let count=Int(data[index+9]);guard n>=8+count*3 else { break }
                var maxH=1,maxV=1
                for i in 0..<count { let sample=Int(data[index+11+i*3]);maxH=max(maxH,sample>>4);maxV=max(maxV,sample&15) }
                width=Int(data[index+7])*256+Int(data[index+8]);height=Int(data[index+5])*256+Int(data[index+6]);mcuWidth=maxH*8;mcuHeight=maxV*8;return
            }
            index+=n+2
        }
        throw EngineError.unsupported("지원하지 않는 JPEG 구조예요.")
    }
    func snapped(_ rect:CGRect)->CGRect {
        let x=floor(rect.minX/CGFloat(mcuWidth))*CGFloat(mcuWidth),y=floor(rect.minY/CGFloat(mcuHeight))*CGFloat(mcuHeight)
        let right=min(CGFloat(width),ceil(rect.maxX/CGFloat(mcuWidth))*CGFloat(mcuWidth))
        let bottom=min(CGFloat(height),ceil(rect.maxY/CGFloat(mcuHeight))*CGFloat(mcuHeight))
        return CGRect(x:x,y:y,width:right-x,height:bottom-y)
    }
}

enum MetadataEnvelope {
    static func exif(_ url:URL,input:ImageInput,dimensions:CGSize? = nil) throws -> Data {
        let data=try Data(contentsOf:url,options:.mappedIfSafe)
        if dimensions == nil,input.type == ImageFormat.jpg.uti {
            var index=2
            while index+4 <= data.count {
                let marker=data[index+1],n=Int(data[index+2])*256+Int(data[index+3])
                guard n>=2,index+2+n<=data.count,marker != 0xda else { break }
                let bytes=Data(data[(index+4)..<(index+2+n)])
                if marker == 0xe1,bytes.starts(with:Data("Exif\0\0".utf8)) { return Data(bytes.dropFirst(6)) }
                index+=n+2
            }
        } else if dimensions == nil,input.type == ImageFormat.png.uti {
            var index=8
            while index+12 <= data.count {
                let n=Int(PNGMetadata.read32(data,index));guard n<=data.count-index-12 else { break }
                if data[(index+4)..<(index+8)] == Data("eXIf".utf8) { return Data(data[(index+8)..<(index+8+n)]) }
                index+=n+12
            }
        }
        // Serialize recognized EXIF using a tiny placeholder; its raster never enters the output.
        let memory=NSMutableData()
        let ctx=try PDFEngine.bitmap(width:1,height:1,space:input.image.colorSpace!)
        let dest=CGImageDestinationCreateWithData(memory,ImageFormat.tiff.uti as CFString,1,nil)!
        var props=input.properties;props[kCGImageDestinationEmbedThumbnail]=false
        props[kCGImagePropertyDepth]=8
        CGImageDestinationAddImage(dest,ctx.makeImage()!,props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EngineError.io("EXIF 직렬화 실패") }
        return try TIFFMetadataEnvelope.sanitize(memory as Data,width:Int(dimensions?.width ?? CGFloat(input.image.width)),height:Int(dimensions?.height ?? CGFloat(input.image.height)))
    }
}

enum ExternalCodecs {
    static var threads:Int {
        ThermalPolicy.threads
    }
    static func convert(_ source:URL,to output:URL,format:ImageFormat) throws -> String {
        let prepared=try autoreleasepool { try prepare(source,format:format) }
        EngineProgress.report(0.35)
        let rgba=prepared.rgba,icc=prepared.icc,exif=prepared.exif,image=prepared.image
        var error=[CChar](repeating:0,count:512)
        let ok=rgba.withUnsafeBytes { pixels in icc.withUnsafeBytes { profile in exif.withUnsafeBytes { metadata in
            output.path.withCString { path in
                let args=(pixels.bindMemory(to:UInt8.self).baseAddress!,Int32(image.width),Int32(image.height),Int32(image.width*4),profile.bindMemory(to:UInt8.self).baseAddress,icc.count,metadata.bindMemory(to:UInt8.self).baseAddress,exif.count,Int32(threads),path)
                if format == .webp { return ring_webp_encode(args.0,args.1,args.2,args.3,args.4,args.5,args.6,args.7,args.8,args.9,&error,error.count) }
                return ring_avif_encode(args.0,args.1,args.2,args.3,args.4,args.5,args.6,args.7,args.8,args.9,&error,error.count)
            }
        }}}
        guard ok==1 else { throw EngineError.io("\(format.rawValue.uppercased()) 인코딩 실패: \(String(cString:error))") }
        EngineProgress.report(0.85)
        try ImageCodec.verify(image,properties:prepared.properties,output:output,exact:true)
        return "\(format.rawValue.uppercased()) 무손실 · RGB 4:4:4 · 픽셀·ICC·방향 일치"
    }
    private struct Prepared {
        let rgba:Data,icc:Data,exif:Data
        let image:CGImage
        let properties:[CFString:Any]
    }
    private static func prepare(_ source:URL,format:ImageFormat) throws -> Prepared {
        let input=try ImageInput(source)
        guard input.image.bitsPerComponent<=8,input.image.colorSpace?.model == .rgb else {
            throw EngineError.unsupported("현재 WebP/AVIF 무손실 경로는 RGB 8비트만 지원해요. 고비트 입력은 PNG/TIFF를 선택해 주세요.")
        }
        if format == .webp && (input.image.width>16383 || input.image.height>16383) { throw EngineError.unsupported("WebP 최대 크기는 가로·세로 16,383px예요.") }
        let rgba=try straightRGBA8(input.image)
        let icc=(input.image.colorSpace!.copyICCData() as Data?) ?? Data()
        let exif=try MetadataEnvelope.exif(source,input:input)
        return Prepared(rgba:rgba,icc:icc,exif:exif,image:input.image,properties:input.properties)
    }
    static func straightRGBA8(_ image:CGImage) throws -> Data {
        let width=image.width,height=image.height,space=image.colorSpace!
        var data=Data(count:width*height*4)
        // A 16-bit premultiplied strip avoids introducing an 8-bit premultiply round trip.
        let stripRows=1024
        for y in stride(from:0,to:height,by:stripRows) {
            try Task.checkCancellation()
            let rows=min(stripRows,height-y),context=try PDFEngine.bitmap(width:width,height:rows,space:space,depth:16)
            context.setBlendMode(.copy);context.draw(image,in:CGRect(x:0,y:y+rows-height,width:width,height:height))
            let values=context.data!.bindMemory(to:UInt16.self,capacity:width*rows*4)
            data.withUnsafeMutableBytes { bytes in
                let output=bytes.bindMemory(to:UInt8.self)
                // CGContext strip y is bottom-based; CGImage data is top-down after draw.
                for pixel in 0..<(width*rows) {
                    let alpha=Int(values[pixel*4+3]),offset=(y*width+pixel)*4
                    for c in 0..<3 { output[offset+c]=alpha == 0 ? 0:UInt8(min(255,(Int(values[pixel*4+c])*255+alpha/2)/alpha)) }
                    output[offset+3]=UInt8((alpha+128)/257)
                }
            }
        }
        return data
    }
    static func jpeg(_ source:URL,to output:URL,crop:CGRect?) throws -> String {
        let input=try ImageInput(source),original=try Data(contentsOf:source,options:.mappedIfSafe)
        let sampling=try JPEGSampling(original)
        let rect: CGRect
        if let crop { rect=sampling.snapped(try ImageEdits.rawRect(crop,image:input.image,orientation:input.orientation)) }
        else { rect=CGRect(x:0,y:0,width:input.image.width,height:input.image.height) }
        var error=[CChar](repeating:0,count:512)
        let ok=original.withUnsafeBytes { bytes in output.path.withCString { path in
            ring_jpeg_transform(bytes.bindMemory(to:UInt8.self).baseAddress!,original.count,crop == nil ? 0:1,Int32(rect.minX),Int32(rect.minY),Int32(rect.width),Int32(rect.height),path,&error,error.count)
        }}
        guard ok==1 else { throw EngineError.io("JPEG 무손실 처리 실패: \(String(cString:error))") }
        if crop != nil {
            let exif=try MetadataEnvelope.exif(source,input:input,dimensions:rect.size)
            try JPEGStructure.replacingExif(Data(contentsOf:output),exif:exif).write(to:output)
        }
        let data=try Data(contentsOf:output,options:.mappedIfSafe)
        let same=original.withUnsafeBytes { a in data.withUnsafeBytes { b in
            ring_jpeg_coefficients_equal(a.bindMemory(to:UInt8.self).baseAddress!,original.count,b.bindMemory(to:UInt8.self).baseAddress!,data.count,Int32(rect.minX),Int32(rect.minY),&error,error.count)
        }}
        guard same==1 else { throw EngineError.quality("JPEG DCT 검증 실패: \(String(cString:error))") }
        let written=try ImageInput(output)
        guard written.orientation==input.orientation,written.image.colorSpace?.copyICCData()==input.image.colorSpace?.copyICCData(),written.image.width==Int(rect.width),written.image.height==Int(rect.height) else { throw EngineError.quality("JPEG 크기·방향·ICC 보존 실패") }
        if crop == nil && data.count>=original.count {
            try FileManager.default.removeItem(at:output);try FileIntegrity.copy(source,to:output)
            return "무손실 압축 · 절감 없음 · 원본 바이트 그대로"
        }
        if crop == nil {
            guard try PixelCheck.compare(input.image,written.image).exact else { throw EngineError.quality("JPEG 압축 픽셀 불일치") }
            return "JPEG 무손실 압축 · DCT·양자화표·픽셀 일치 · \(original.count-data.count)바이트 절감"
        }
        return "JPEG 무손실 자르기 · \(Int(rect.width))×\(Int(rect.height)) · MCU \(sampling.mcuWidth)×\(sampling.mcuHeight) · DCT·양자화표 일치"
    }
    static func compress(_ source:URL,to output:URL) throws -> String {
        let header=CGImageSourceCreateWithURL(source as CFURL,nil)
        let type=header.flatMap{CGImageSourceGetType($0)} as String?
        if ![ImageFormat.jpg.uti,ImageFormat.png.uti,ImageFormat.tiff.uti,ImageFormat.webp.uti,ImageFormat.avif.uti].contains(type ?? "") {
            try FileIntegrity.copy(source,to:output)
            return "무손실 압축 · 절감 없음 · 원본 바이트 그대로"
        }
        let input=try ImageInput(source)
        if input.type == ImageFormat.jpg.uti { return try jpeg(source,to:output,crop:nil) }
        let format=ImageFormat.allCases.first{$0.uti==input.type}
        if let format,[ImageFormat.png,.tiff,.webp,.avif].contains(format) {
            if format == .webp || format == .avif { _ = try convert(source,to:output,format:format) }
            else { try ImageCodec.write(input.image,properties:input.properties,format:format,to:output);try ImageCodec.verify(input.image,properties:input.properties,output:output,exact:true) }
            let before=try source.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            let after=try output.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            if after<before { return "무손실 압축 · 픽셀 일치 · \(before-after)바이트 절감" }
            try FileManager.default.removeItem(at:output)
        }
        try FileIntegrity.copy(source,to:output)
        return "무손실 압축 · 절감 없음 · 원본 바이트 그대로"
    }
}

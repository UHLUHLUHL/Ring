import Foundation
import CoreGraphics
import PDFKit
import ImageIO

extension PDFEngine {
    /// Zero-based page indexes in explicit output order, including intentional duplicates.
    static func organize(_ sources: [URL], pages: [Int], to output: URL, uniformWidth: Double? = nil) throws -> String {
        guard !sources.isEmpty, sources.count == pages.count, sources.count <= 10_000,
              uniformWidth == nil || uniformWidth!.isFinite && (0...14400).contains(uniformWidth!) else { throw EngineError.invalid("PDF 페이지·폭 지정 오류") }
        var docs: [URL: PDFDocument] = [:]
        for (source,index) in zip(sources,pages) {
            if docs[source] == nil { docs[source] = try open(source) }
            guard index >= 0, index < docs[source]!.pageCount else { throw EngineError.invalid("PDF 페이지 번호 범위 오류") }
        }
        // Zero requests automatic normalization to the widest selected page.
        let resolvedWidth:Double? = uniformWidth == 0 ? zip(sources,pages).map { source,index in
            let page=docs[source]!.page(at:index)!,box=page.bounds(for:.mediaBox)
            return page.rotation % 180 == 0 ? box.width:box.height
        }.max() : uniformWidth
        let strings = sources.map { strdup($0.path)! }; defer { strings.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) }
        var error = [CChar](repeating:0,count:512)
        let indexes = pages.map(Int32.init)
        let ok = pointers.withUnsafeBufferPointer { paths in indexes.withUnsafeBufferPointer { selection in output.path.withCString {
            ring_pdf_pages(paths.baseAddress,selection.baseAddress,sources.count,resolvedWidth ?? 0,$0,&error,error.count)
        } } }
        guard ok == 1 else { throw EngineError.io("PDF 페이지 처리 실패: \(String(cString:error))") }
        let written = try open(output)
        guard written.pageCount == pages.count else { throw EngineError.quality("PDF 페이지 수 불일치") }
        for i in pages.indices {
            try Task.checkCancellation()
            let before = docs[sources[i]]!.page(at:pages[i])!,after = written.page(at:i)!
            guard before.string == after.string else { throw EngineError.quality("PDF 페이지 텍스트 순서 불일치") }
            if resolvedWidth == nil {
                try autoreleasepool {
                    guard try PixelCheck.compare(renderWithAnnotations(before,scale:1),renderWithAnnotations(after,scale:1)).exact else { throw EngineError.quality("PDF 페이지 렌더 불일치") }
                }
            } else {
                guard abs(after.bounds(for:.mediaBox).width-resolvedWidth!)<0.01 else { throw EngineError.quality("PDF 폭 검증 실패") }
            }
            EngineProgress.step(i,of:pages.count)
        }
        return "\(pages.count)페이지 · qpdf 원본 스트림 보존" + (uniformWidth == nil ? "" : " · 가로폭 균일화")
    }
    static func merge(_ sources: [URL], to output: URL, uniformWidth: Double? = nil) throws -> String {
        var files: [URL] = [],indexes: [Int] = []
        for source in sources {
            let count = try open(source).pageCount
            files += Array(repeating:source,count:count); indexes += Array(0..<count)
        }
        return try organize(files,pages:indexes,to:output,uniformWidth:uniformWidth)
    }
    static func split(_ source: URL, ranges: [ClosedRange<Int>], to output: URL) throws -> String {
        let count = try open(source).pageCount
        guard !ranges.isEmpty,ranges.allSatisfy({ $0.lowerBound>=0 && $0.upperBound<count }) else { throw EngineError.invalid("PDF 분할 범위 오류") }
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
        for (i,range) in ranges.enumerated() {
            let indexes = Array(range),file = output.appendingPathComponent(String(format:"%04d.pdf",i+1))
            _ = try organize(Array(repeating:source,count:indexes.count),pages:indexes,to:file)
        }
        return "\(ranges.count)개 PDF · qpdf 스트림 무손실 분할"
    }
    static func smartCompress(_ source: URL, to output: URL, options: PDFCompressionOptions) throws -> String {
        guard (64...16384).contains(options.maxImageDimension),options.jpegQuality.isFinite,(0.05...1).contains(options.jpegQuality) else { throw EngineError.invalid("PDF 압축 옵션 오류") }
        let context = PDFImageCompressionContext(options)
        var changed: Int32 = 0,error = [CChar](repeating:0,count:512)
        let ok = source.path.withCString { path in output.path.withCString {
            ring_pdf_smart_compress(path,$0,Int32(options.maxImageDimension),{ context,data,size,w,h,channels,jpeg,icc,iccSize,output,count,ow,oh in
                let state = Unmanaged<PDFImageCompressionContext>.fromOpaque(context!).takeUnretainedValue()
                do {
                    try Task.checkCancellation()
                    return try autoreleasepool {
                        let bytes = Data(bytes:data!,count:size),image: CGImage
                        let profile = iccSize>0 ? Data(bytes:icc!,count:iccSize) : Data()
                        let sourceSpace = profile.isEmpty ? nil : CGColorSpace(iccData:profile as CFData)
                        if !profile.isEmpty && sourceSpace == nil { return 0 }
                        if jpeg != 0 {
                            guard let source = CGImageSourceCreateWithData(bytes as CFData,nil),let decoded = CGImageSourceCreateImageAtIndex(source,0,nil) else { return 0 }
                            image = decoded
                        } else {
                            let space = sourceSpace ?? (channels == 3 ? CGColorSpace(name:CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceGray())
                            guard let provider = CGDataProvider(data:bytes as CFData),let decoded = CGImage(width:Int(w),height:Int(h),bitsPerComponent:8,bitsPerPixel:Int(channels)*8,bytesPerRow:Int(w*channels),space:space,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.none.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { return 0 }
                            image = decoded
                        }
                        let outputSpace = channels == 3 ? (sourceSpace ?? CGColorSpace(name:CGColorSpace.sRGB)!) : CGColorSpace(name:CGColorSpace.sRGB)!
                        let rgb = try PDFEngine.bitmap(width:Int(w),height:Int(h),space:outputSpace)
                        rgb.draw(image,in:CGRect(x:0,y:0,width:Int(w),height:Int(h)))
                        let scaled = try ImageResampler.fit(rgb.makeImage()!,maxDimension:state.options.maxImageDimension)
                        let encoded = try TargetSizeCodec.memoryEncode(ExternalCodecs.straightRGBA8(scaled),width:scaled.width,height:scaled.height,icc:outputSpace.copyICCData() as Data? ?? Data(),quality:Int(state.options.jpegQuality*100))
                        guard let pointer = malloc(encoded.count) else { throw EngineError.io("PDF 이미지 메모리 부족") }
                        _ = encoded.withUnsafeBytes { memcpy(pointer,$0.baseAddress!,encoded.count) }
                        output!.pointee = pointer.assumingMemoryBound(to:UInt8.self);count!.pointee = encoded.count
                        ow!.pointee = Int32(scaled.width);oh!.pointee = Int32(scaled.height)
                        return 1
                    }
                } catch { state.error = error;return -1 }
            },Unmanaged.passUnretained(context).toOpaque(),&changed,&error,error.count)
        } }
        if let error = context.error { throw error }
        guard ok == 1 else { throw EngineError.quality("PDF 압축 실패: \(String(cString:error))") }
        let before = try open(source),after = try open(output)
        guard before.pageCount == after.pageCount,before.string == after.string else { throw EngineError.quality("PDF 텍스트·페이지 보존 실패") }
        let oldSize = try source.resourceValues(forKeys:[.fileSizeKey]).fileSize!,newSize = try output.resourceValues(forKeys:[.fileSizeKey]).fileSize!
        if newSize >= oldSize {
            try FileManager.default.removeItem(at:output);try FileIntegrity.copy(source,to:output)
            return "원본 바이트 유지 · 절감 없음"
        }
        return "이미지 \(changed)개 다운샘플링 · 텍스트·벡터·폰트 스트림 원형 보존 · \(oldSize-newSize)바이트 절감"
    }
}
private final class PDFImageCompressionContext {
    let options: PDFCompressionOptions
    var error: Error?
    init(_ options: PDFCompressionOptions) { self.options = options }
}

import Foundation
import AppKit
import CoreGraphics
import PDFKit
import ImageIO
@preconcurrency import AVFoundation
import CryptoKit

@main struct EngineV2Tests {
    static func require(_ value:Bool,_ message:String) throws { if !value { throw EngineError.quality("TEST: "+message) } }
    static func file(_ root:URL,_ name:String) -> URL { root.appendingPathComponent(name) }
    static func main() async {
        setbuf(stdout,nil)
        do {
            let root=URL(fileURLWithPath:".work/v2-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            print("FIXTURES",root.path)
            let groups=CommandLine.arguments.dropFirst(),all=groups.isEmpty
            if all || groups.contains("image") { try await images(root) }
            if all || groups.contains("pdf") { try await pdfs(root) }
            if all || groups.contains("document") { try await documents(root) }
            if all || groups.contains("media") { try await media(root) }
            if groups.contains("media-h264") { try await media(root,codecs:[.h264]) }
            try require(try FileManager.default.contentsOfDirectory(atPath:root.path).allSatisfy { !$0.hasPrefix(".ring-") },"staging leak")
            print("PASS all requested Engine v2 tests")
        } catch { print("FAIL",error.localizedDescription);exit(1) }
    }
    static func image(_ root:URL,name:String="source.png",width:Int=640,height:Int=480,alpha:Bool=false,orientation:Int=1) throws -> URL {
        var pixels=Data(count:width*height*4),state:UInt64=123456
        for y in 0..<height { for x in 0..<width {
            state=state &* 6364136223846793005 &+ 1
            let p=(y*width+x)*4,noise=Int((state>>32)&31)
            pixels[p]=UInt8((x*200/width+noise)%256);pixels[p+1]=UInt8((y*200/height+noise)%256);pixels[p+2]=UInt8((x+y+noise)%256);pixels[p+3]=alpha ? UInt8(80+(x%176)):255
        } }
        let space=CGColorSpace(name:CGColorSpace.displayP3)!,provider=CGDataProvider(data:pixels as CFData)!
        let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:space,bitmapInfo:CGBitmapInfo(rawValue:alpha ? CGImageAlphaInfo.last.rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let url=file(root,name)
        try ImageCodec.write(image,properties:[kCGImagePropertyOrientation:orientation,
            kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:37.5,kCGImagePropertyGPSLatitudeRef:"N"],
            kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFMake:"RingPrivateCamera"],
            kCGImagePropertyExifDictionary:[kCGImagePropertyExifUserComment:"RingPrivateComment"]],format:name.hasSuffix(".tiff") ? .tiff:.png,to:url)
        return url
    }
    static func images(_ root:URL) async throws {
        let source=try image(root),original=try Data(contentsOf:source)
        for format in [ImageFormat.jpg,.webp,.heic] {
            let result=try await RingEngine.shared.run(.init(source:source,operation:.encodeImage(format:format,intent:.targetBytes(32_000))))
            try require(try Data(contentsOf:result.url).count<=32000,"target size \(format)")
            print("PASS target",result.detail)
        }
        let alpha=try image(root,name:"alpha.tiff",width:128,height:96,alpha:true)
        let alphaResult=try await RingEngine.shared.run(.init(source:alpha,operation:.encodeImage(format:.webp,intent:.targetBytes(12000))))
        print("PASS alpha",alphaResult.detail)
        let alpha16=try image(root,name:"alpha16.png",width:128,height:96,alpha:true,orientation:6)
        let resized16=try await RingEngine.shared.run(.init(source:alpha16,operation:.edit(.resize(width:48,height:64))))
        try require(try ImageInput(resized16.url).image.bitsPerComponent==16,"16-bit resize depth lost")
        for format in [ImageFormat.png,.jpg,.heic,.avif,.webp] {
            let url:URL
            if format == .png { url=source }
            else if format == .avif { url=try await RingEngine.shared.run(.init(source:source,operation:.convert(.avif))).url }
            else { url=try await RingEngine.shared.run(.init(source:source,operation:.encodeImage(format:format,intent:.quality(0.9)))).url }
            let r=try await RingEngine.shared.run(.init(source:url,operation:.cleanMetadata))
            let written=try Data(contentsOf:r.url)
            try require(written.range(of:Data("RingPrivate".utf8))==nil,"private metadata remains \(format)")
            if [.heic,.avif].contains(format) { try require(written.count==Data(contentsOf:url).count,"HEIF offsets moved") }
            print("PASS metadata",format,r.detail)
        }
        // A portrait photo must not turn sideways after private metadata is removed.
        let rotated=try image(root,name:"rotated.png",width:96,height:64,orientation:6)
        let rotatedJPEG=try await RingEngine.shared.run(.init(source:rotated,operation:.encodeImage(format:.jpg,intent:.quality(0.9)))).url
        for url in [rotated,rotatedJPEG] {
            try require(try ImageInput(url).orientation==6,"rotated fixture orientation")
            let r=try await RingEngine.shared.run(.init(source:url,operation:.cleanMetadata))
            let written=try Data(contentsOf:r.url)
            try require(try ImageInput(r.url).orientation==6,"metadata clean dropped orientation \(url.pathExtension)")
            try require(written.range(of:Data("RingPrivate".utf8))==nil,"rotated private metadata remains")
            print("PASS metadata orientation",url.pathExtension,r.detail)
        }
        for operation in [ImageEdit.resize(width:320,height:240),.resizeScale(0.25),.cropAspect(width:1,height:1),.cropAspect(width:16,height:9)] {
            let r=try await RingEngine.shared.run(.init(source:source,operation:.edit(operation)))
            print("PASS resize/crop",r.detail)
        }
        let jpg=try await RingEngine.shared.run(.init(source:source,operation:.encodeImage(format:.jpg,intent:.quality(0.95)))).url
        let crop=try await RingEngine.shared.run(.init(source:jpg,operation:.edit(.crop(CGRect(x:0.1,y:0.1,width:0.5,height:0.5)))))
        print("PASS MCU",crop.detail)
        // T.81 allows 0xFF fill bytes before any marker. Pad the quantization
        // table: ImageIO itself drops the ICC profile when APP0 is padded.
        var padded=try Data(contentsOf:jpg)
        let firstSegment=try JPEGStructure.segments(padded).first { $0.marker==0xdb }!.start
        padded.insert(contentsOf:[0xff,0xff,0xff],at:firstSegment)
        let paddedURL=file(root,"padded.jpg");try padded.write(to:paddedURL)
        let paddedFrame=try JPEGStructure.frame(padded),plainFrame=try JPEGStructure.frame(Data(contentsOf:jpg))
        try require(paddedFrame.width==plainFrame.width && paddedFrame.height==plainFrame.height,"fill-byte SOF parse")
        _=try JPEGSampling(padded);try JPEGStructure.require444(paddedURL);_=try JPEGStructure.codingBytes(padded)
        let paddedCrop=try await RingEngine.shared.run(.init(source:paddedURL,operation:.edit(.crop(CGRect(x:0.1,y:0.1,width:0.5,height:0.5)))))
        print("PASS JPEG fill bytes",paddedCrop.detail)
        for operation in [ImageEdit.resize(width:320,height:240),.cropAspect(width:1,height:1)] {
            let r=try await RingEngine.shared.run(.init(source:jpg,operation:.edit(operation)))
            try require(r.url.pathExtension=="jpg","JPEG edit must stay JPEG")
            try require(try Data(contentsOf:r.url).count<Data(contentsOf:jpg).count*2,"JPEG edit output grew")
            print("PASS JPEG edit keeps format",r.detail)
        }
        let before=Set(try FileManager.default.contentsOfDirectory(atPath:root.path))
        do { _=try await RingEngine.shared.run(.init(source:source,operation:.encodeImage(format:.jpg,intent:.targetBytes(1))));throw EngineError.invalid("TEST: impossible target accepted") }
        catch EngineError.quality { }
        try require(before==Set(FileManager.default.contentsOfDirectory(atPath:root.path)),"failed target left output")
        try require(try Data(contentsOf:source)==original,"source overwritten")
        do { _=try MetadataEngine.stripISOBMFFMetadata(data:Data([0,0,0,1,109,101,116,97]));throw EngineError.quality("TEST: corrupt BMFF accepted") } catch EngineError.invalid { }
        print("PASS impossible target rollback, corrupt BMFF, source preservation")
    }
    static func pdf(_ root:URL,name:String,width:Double=300,pages:Int=2,withImage:Bool=false) throws -> URL {
        let url=file(root,name),raster=withImage ? try ImageInput(image(root,name:"pdf-image.png",width:2400,height:1800)).image:nil
        var bounds=CGRect(x:0,y:0,width:width,height:400)
        let context=CGContext(url as CFURL,mediaBox:&bounds,nil)!
        for i in 0..<pages {
            context.beginPDFPage(nil)
            if let raster { context.draw(raster,in:CGRect(x:20,y:30,width:width-40,height:260)) }
            let line=CTLineCreateWithAttributedString(NSAttributedString(string:"Ring \(name) page \(i+1)",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica" as CFString,14,nil)]))
            context.textPosition=CGPoint(x:20,y:350);CTLineDraw(line,context)
            context.setStrokeColor(CGColor(gray:0,alpha:1));context.stroke(CGRect(x:10,y:10,width:width-20,height:380))
            context.endPDFPage()
        }
        context.closePDF();return url
    }
    static func pdfs(_ root:URL) async throws {
        let a=try pdf(root,name:"a.pdf"),b=try pdf(root,name:"b.pdf",width:500,pages:1)
        let merged=try await RingEngine.shared.run(.init(source:a,operation:.pdfMerge(sources:[b,a])))
        let doc=try PDFEngine.open(merged.url)
        try require(doc.pageCount==3 && doc.page(at:0)!.string!.contains("b.pdf") && doc.page(at:2)!.string!.contains("page 2"),"merge order")
        let normalized=try await RingEngine.shared.run(.init(source:a,operation:.pdfMerge(sources:[b,a],uniformWidth:400)))
        try require(try PDFEngine.open(normalized.url).page(at:0)!.bounds(for:.mediaBox).width==400,"uniform width")
        let automatic=try await RingEngine.shared.run(.init(source:a,operation:.pdfMerge(sources:[b,a],uniformWidth:0)))
        try require(try PDFEngine.open(automatic.url).page(at:2)!.bounds(for:.mediaBox).width==500,"automatic uniform width")
        let rotated=file(root,"rotated.pdf"),rotatedDoc=try PDFEngine.open(b)
        rotatedDoc.page(at:0)!.rotation=90;try require(rotatedDoc.write(to:rotated),"rotated fixture")
        let rotationResult=try await RingEngine.shared.run(.init(source:rotated,operation:.pdfMerge(sources:[rotated],uniformWidth:400)))
        let rotationBox=try PDFEngine.open(rotationResult.url).page(at:0)!.bounds(for:.mediaBox)
        try require(abs(rotationBox.width-400)<0.01 && abs(rotationBox.height-500)<0.01,"rotated page aspect ratio")
        let reordered=try await RingEngine.shared.run(.init(source:merged.url,operation:.pdfPages([2,0,2])))
        try require(try PDFEngine.open(reordered.url).pageCount==3,"reorder/duplicate")
        let split=try await RingEngine.shared.run(.init(source:merged.url,operation:.pdfSplit([0...0,1...2])))
        try require(try FileManager.default.contentsOfDirectory(atPath:split.url.path).count==2,"split count")
        // A standards-based appearance fixture: PDFKit on this OS can emit an
        // invalid Length=0 SFNS font stream, which the preservation gate rejects.
        let noted=try annotatedPDF(root)
        let duplicates=try await RingEngine.shared.run(.init(source:noted,operation:.pdfPages([0,0])))
        let duplicatedDoc=try PDFEngine.open(duplicates.url)
        try require(duplicatedDoc.page(at:0)!.annotations.count==1 && duplicatedDoc.page(at:1)!.annotations.count==1,"copied annotations lost")
        let webp=try await RingEngine.shared.run(.init(source:a,operation:.convert(.webp)))
        try require(try FileManager.default.contentsOfDirectory(atPath:webp.url.path).count==2,"PDF WebP pages")
        let imagePDF=try pdf(root,name:"images.pdf",pages:1,withImage:true)
        let compressed=try await RingEngine.shared.run(.init(source:imagePDF,operation:.pdfSmartCompress(.init(maxImageDimension:700,jpegQuality:0.8))))
        try require(try Data(contentsOf:compressed.url).count<Data(contentsOf:imagePDF).count,"smart PDF did not shrink")
        try require(try PDFEngine.imageStreams(imagePDF) != PDFEngine.imageStreams(compressed.url),"PDF image XObject was not recompressed")
        let docx=try await RingEngine.shared.run(.init(source:a,operation:.convert(.docx)))
        let archive=try DocumentZIP(docx.url)
        let xml=String(data:try archive.data("word/document.xml"),encoding:.utf8)!
        try require(xml.contains("Ring"),"DOCX reflow missing text")
        print("PASS PDF merge/order/duplicates/split/width/WebP;",compressed.detail)
        print("PASS Vision DOCX",docx.detail)
    }
    @MainActor static func documents(_ root:URL) async throws {
        _=NSApplication.shared
        let html=file(root,"document.html")
        let longParagraph="<p>"+Array(repeating:"LongWord ",count:1500).joined()+"LongFinalMarker</p>"
        let body="<h1>Ring vector document</h1>"+(0..<80).map { "<p>Paragraph \($0). Native document pagination preserves all words and line boundaries. 한글 문서 변환 검사입니다.</p>" }.joined()+longParagraph+"<table><thead><tr><th>Repeated header</th></tr></thead><tbody>"+(0..<60).map { "<tr><td>Table row \($0)</td></tr>" }.joined()+"</tbody></table><p>END_SENTINEL</p><script>document.body.innerHTML='SCRIPT_EXECUTED'</script><img src='https://127.0.0.1:9/tracker'>"
        try Data(body.utf8).write(to:html)
        let result=try await RingEngine.shared.run(.init(source:html,operation:.convert(.pdf)))
        let pdf=try PDFEngine.open(result.url),text=pdf.string ?? ""
        try require(pdf.pageCount>1 && text.contains("Paragraph 79") && text.contains("Table row 59") && text.contains("SENTINEL") && !text.contains("SCRIPT_EXECUTED"),"DOM paginator content/security")
        let compact=text.filter { !$0.isWhitespace }
        try require(compact.components(separatedBy:"LongWord").count-1==1500 && compact.contains("LongFinalMarker"),"binary paragraph splitter lost words")
        let md=file(root,"sample.md");try Data("# Ring Markdown\n\n**Bold** and 한글 문서.\n\n- First item\n- Second item\n".utf8).write(to:md)
        let mdResult=try await RingEngine.shared.run(.init(source:md,operation:.convert(.png)))
        try require(try FileManager.default.contentsOfDirectory(atPath:mdResult.url.path).count==1,"Markdown PNG")
        let rtf=file(root,"sample.rtf"),attributed=NSAttributedString(string:"Ring RTF text",attributes:[.font:NSFont.systemFont(ofSize:18)])
        try attributed.data(from:NSRange(location:0,length:attributed.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf]).write(to:rtf)
        let rtfResult=try await RingEngine.shared.run(.init(source:rtf,operation:.convert(.pdf)))
        try require(try PDFEngine.open(rtfResult.url).string?.contains("Ring RTF text")==true,"RTF text")
        let docx=file(root,"sample.docx")
        // Independent deflated OOXML fixture, generated with Python's ZIP implementation.
        try Data(base64Encoded:"UEsDBBQAAAAIAOmmVF19j8M5SgAAAE0AAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbLMJqSxILVaoyM3JK7ZVyigpKbDS1y9OzkjNTSzWyy9IzQPKpOUX5SaWALlF6foFicnZiemp+kYGBmb6yfl5Jal5JbolIDOU9O0AUEsDBBQAAAAIAOmmVF0craaZggAAAKkAAAARAAAAd29yZC9kb2N1bWVudC54bWxFzjEOwjAMBdCrRD0ArhgYopAFdiQm1pCYtlKdRI5Ryu1JysDyLOt/WTZVh+TfhFHURmssup6HWSRrgOJnJFcOKWNs2SsxOWkrT1ATh8zJYylLnGiF4ziegNwSB2uqfqbw6TN3uCP23orqers8FGMMyBiU4CYGetjl3bz7OwD/5+wXUEsBAhQDFAAAAAgA6aZUXX2PwzlKAAAATQAAABMAAAAAAAAAAAAAAIABAAAAAFtDb250ZW50X1R5cGVzXS54bWxQSwECFAMUAAAACADpplRdHK2mmYIAAACpAAAAEQAAAAAAAAAAAAAAgAF7AAAAd29yZC9kb2N1bWVudC54bWxQSwUGAAAAAAIAAgCAAAAALAEAAAAA")!.write(to:docx)
        let docxResult=try await RingEngine.shared.run(.init(source:docx,operation:.convert(.pdf)))
        try require(try PDFEngine.open(docxResult.url).string?.contains("Ring DOCX rendered text")==true,"DOCX render text")
        print("PASS offline WebKit HTML, DOM text/table pagination, Markdown PNG, RTF, DOCX;",result.detail)
    }
    static func videoFixture(_ root:URL) async throws -> URL {
        let video=file(root,"silent.mp4"),writer=try AVAssetWriter(outputURL:video,fileType:.mp4)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:320,AVVideoHeightKey:240,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:2_000_000]])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:320,kCVPixelBufferHeightKey as String:240])
        writer.add(input);try require(writer.startWriting(),"fixture writer");writer.startSession(atSourceTime:.zero)
        for i in 0..<40 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds:2_000_000) }
            var buffer:CVPixelBuffer?
            try require(CVPixelBufferPoolCreatePixelBuffer(nil,adaptor.pixelBufferPool!,&buffer)==kCVReturnSuccess,"fixture pixel buffer")
            CVPixelBufferLockBaseAddress(buffer!,[])
            let base=CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(buffer!)
            for y in 0..<240 { for x in 0..<320 { let p=y*row+x*4;base[p]=UInt8((x+i*5)%256);base[p+1]=UInt8((y+i*3)%256);base[p+2]=UInt8((x+y+i*7)%256);base[p+3]=255 } }
            CVPixelBufferUnlockBaseAddress(buffer!,[])
            try require(adaptor.append(buffer!,withPresentationTime:CMTime(value:Int64(i),timescale:20)),"fixture frame append")
        }
        input.markAsFinished();writer.endSession(atSourceTime:CMTime(seconds:2,preferredTimescale:600));await writer.finishWriting()
        try require(writer.status == .completed,"fixture writing failed")
        let audio=file(root,"tone.caf"),format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        let audioFile=try AVAudioFile(forWriting:audio,settings:format.settings),pcm=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:96000)!
        pcm.frameLength=96000
        for i in 0..<96000 { pcm.floatChannelData![0][i]=Float(0.1*sin(2*Double.pi*440*Double(i)/48000)) }
        try audioFile.write(from:pcm)
        let composition=AVMutableComposition(),vasset=AVURLAsset(url:video),aasset=AVURLAsset(url:audio)
        let v=try await vasset.loadTracks(withMediaType:.video)[0],a=try await aasset.loadTracks(withMediaType:.audio)[0]
        let range=CMTimeRange(start:.zero,duration:CMTime(seconds:2,preferredTimescale:600))
        try composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!.insertTimeRange(range,of:v,at:.zero)
        try composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid)!.insertTimeRange(range,of:a,at:.zero)
        let output=file(root,"fixture.mov"),export=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetPassthrough)!
        try await export.export(to:output,as:.mov);return output
    }
    static func media(_ root:URL,codecs:[VideoCodec]=[.h264,.hevc]) async throws {
        let source=try await videoFixture(root),original=try Data(contentsOf:source)
        let square=VideoCropGeometry.centeredRect(width:320,height:240,ratio:.square)
        try require(square.origin.x==40 && square.origin.y==0 && square.width==240 && square.height==240,"centered square video crop")
        let trimmed=try await RingEngine.shared.run(.init(source:source,operation:.video(.trim(start:0.3,end:1.4))))
        let originalSamples=try await compressedSamples(source),trimmedSamples=try await compressedSamples(trimmed.url)
        try require(!trimmedSamples.isEmpty && trimmedSamples.allSatisfy { originalSamples.contains($0) },"passthrough changed encoded video samples")
        print("PASS trim",trimmed.detail)
        for codec in codecs {
            let compressed=try await RingEngine.shared.run(.init(source:source,operation:.video(.compress(.init(targetBytes:80000,codec:codec)))))
            try require(try Data(contentsOf:compressed.url).count<=80000,"video target bytes")
            print("PASS video target",compressed.detail)
        }
        let cropped=try await RingEngine.shared.run(.init(source:source,operation:.video(.compress(.init(targetBytes:240000,codec:.h264,maxDimension:128,cropRatio:.square)))))
        let croppedAsset=AVURLAsset(url:cropped.url),croppedTrack=try await croppedAsset.loadTracks(withMediaType:.video)[0],croppedSize=try await croppedTrack.load(.naturalSize)
        try require(croppedSize.width==128 && croppedSize.height==128,"video crop and maximum dimension")
        print("PASS video crop/resize",cropped.detail)
        let sourceTrack=try await AVURLAsset(url:source).loadTracks(withMediaType:.video)[0]
        let shown=try await sourceTrack.load(.naturalSize).applying(sourceTrack.load(.preferredTransform))
        // The panel's resolution preview must match what the engine writes.
        for (format,ratio,limit) in [(AnimationFormat.gif,VideoCropRatio.square,160),(.webp,.square,160),(.webp,.free,150),(.gif,.wide,97)] {
            let animated=try await RingEngine.shared.run(.init(source:source,operation:.video(.animation(.init(format:format,fps:10,maxDimension:limit,start:0,duration:1,cropRatio:ratio)))))
            let sizeText=animated.detail.components(separatedBy:" · ").dropFirst().first ?? ""
            let dimensions=sizeText.split(separator:"×").compactMap { Int($0) }
            let expected=VideoCropGeometry.animationSize(width:abs(shown.width),height:abs(shown.height),ratio:ratio,maxDimension:limit)
            try require(dimensions==[expected.width,expected.height],"\(format) \(ratio) preview \(expected) != \(dimensions)")
            if ratio == .square { try require(dimensions[0]==dimensions[1] && dimensions[0]<=limit,"\(format) video crop ratio/output dimensions") }
            print("PASS animation",animated.detail)
        }
        let compressedPreview=VideoCropGeometry.compressedSize(width:abs(shown.width),height:abs(shown.height),ratio:.square,maxDimension:128,
            bitrate:Int(min(VideoCropGeometry.videoBitrate(targetBytes:240000,duration:try await AVURLAsset(url:source).load(.duration).seconds,audio:!(try await AVURLAsset(url:source).loadTracks(withMediaType:.audio).isEmpty)),100_000_000)))
        try require(compressedPreview.width==128 && compressedPreview.height==128,"video compress preview")
        try require(try Data(contentsOf:source)==original,"media source changed")
        let before=Set(try FileManager.default.contentsOfDirectory(atPath:root.path))
        for delay:UInt64 in [0,10_000_000,50_000_000] {
            let task=Task { try await RingEngine.shared.run(.init(source:source,operation:.video(.compress(.init(targetBytes:100000,codec:.h264))))) }
            if delay>0 { try await Task.sleep(nanoseconds:delay) };task.cancel()
            do { _=try await task.value;throw EngineError.invalid("TEST: media cancellation ignored") } catch is CancellationError { }
        }
        try require(before==Set(FileManager.default.contentsOfDirectory(atPath:root.path)),"media cancellation leaked output")
        print("PASS media cancellation/source preservation")
    }
    static func compressedSamples(_ url:URL) async throws -> Set<Data> {
        let asset=AVURLAsset(url:url),track=try await asset.loadTracks(withMediaType:.video)[0],reader=try AVAssetReader(asset:asset)
        let out=AVAssetReaderTrackOutput(track:track,outputSettings:nil);reader.add(out)
        try require(reader.startReading(),"compressed sample reader")
        var samples=Set<Data>()
        while let sample=out.copyNextSampleBuffer() {
            // Edit-list / discontinuity markers have zero samples and no block buffer.
            guard let block=CMSampleBufferGetDataBuffer(sample) else { continue }
            var bytes=Data(count:CMBlockBufferGetDataLength(block))
            let count=bytes.count
            let rc=bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:count,destination:$0.baseAddress!) }
            try require(rc==kCMBlockBufferNoErr,"compressed sample copy")
            samples.insert(Data(SHA256.hash(data:bytes)))
        }
        return samples
    }
    static func annotatedPDF(_ root:URL) throws -> URL {
        func stream(_ text:String,_ dictionary:String="") -> String { "<< /Length \(text.utf8.count) \(dictionary) >>\nstream\n\(text)\nendstream" }
        let objects=[
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 400] /Resources << /Font << /F1 6 0 R >> >> /Contents 4 0 R /Annots [5 0 R] >>",
            stream("BT /F1 14 Tf 20 350 Td (Ring annotation page) Tj ET"),
            "<< /Type /Annot /Subtype /FreeText /Rect [20 50 180 80] /Contents (Preserved annotation) /DA (/F1 14 Tf 0 g) /AP << /N 7 0 R >> /F 4 >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            stream("BT /F1 14 Tf 0 10 Td (Preserved annotation) Tj ET","/Type /XObject /Subtype /Form /BBox [0 0 160 30] /Resources << /Font << /F1 6 0 R >> >>")]
        var data=Data("%PDF-1.7\n".utf8),offsets:[Int]=[]
        for (i,object) in objects.enumerated() { offsets.append(data.count);data.append(Data("\(i+1) 0 obj\n\(object)\nendobj\n".utf8)) }
        let start=data.count
        let xref="xref\n0 \(objects.count+1)\n0000000000 65535 f \n"+offsets.map { String(format:"%010d 00000 n \n",$0) }.joined()
        data.append(Data((xref+"trailer\n<< /Size \(objects.count+1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n").utf8))
        let url=file(root,"annotated.pdf");try data.write(to:url);return url
    }
}

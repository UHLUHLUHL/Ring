import Foundation
import CoreGraphics

enum EngineError: LocalizedError {
    case invalid(String), unsupported(String), quality(String), io(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let s), .unsupported(let s), .quality(let s), .io(let s): return s
        }
    }
}

enum ImageFormat: String, CaseIterable {
    case png, jpg, heic, tiff, bmp, webp, avif, pdf, docx, txt
    var uti: String {
        switch self {
        case .png: return "public.png"
        case .jpg: return "public.jpeg"
        case .heic: return "public.heic"
        case .tiff: return "public.tiff"
        case .bmp: return "com.microsoft.bmp"
        case .webp: return "org.webmproject.webp"
        case .avif: return "public.avif"
        case .pdf: return "com.adobe.pdf"
        case .docx: return "org.openxmlformats.wordprocessingml.document"
        case .txt: return "public.plain-text"
        }
    }
}

enum EngineOperation {
    case convert(ImageFormat)
    case encodeImage(format:ImageFormat,intent:CompressionIntent)
    case cleanMetadata
    case pdfMerge(sources:[URL],uniformWidth:Double? = nil)
    case pdfPages([Int])
    case pdfSplit([ClosedRange<Int>])
    case pdfSmartCompress(PDFCompressionOptions)
    case renderDocument(format:ImageFormat,options:DocumentRenderOptions)
    case video(VideoOperation)
    case removeLocation
    case pdfMetadata(PDFMetadata)
    case pdfNote(PDFNote)
    case pdfRedact(PDFRedaction)
    case edit(ImageEdit)
    case compress
}

struct EngineJob {
    let source: URL
    let operation: EngineOperation
}

struct EngineResult {
    let url: URL
    let detail: String
    let seconds: Double
}

/// Fraction done (0...1) for the job running in the current task. Engines report at real
/// checkpoints (pages, verification); there is no timer. The UI may interpolate between them.
enum EngineProgress {
    @TaskLocal static var handler: (@Sendable (Double) -> Void)?
    static func report(_ value: Double) { handler?(min(max(value, 0), 1)) }
    /// Step `index` of `count` inside the main work span (5%...90%).
    static func step(_ index: Int, of count: Int) { report(0.05 + 0.85 * Double(index + 1) / Double(max(count, 1))) }
}

/// Thermal admission bounds simultaneous full-resolution decoders. No idle polling.
/// A job's codec can still use platform SIMD / codec-internal parallelism.
actor RingEngine {
    static let shared = RingEngine()
    private var active=0
    private var waiting:[CheckedContinuation<Void,Never>]=[]
    private func enter() async {
        if active<ThermalPolicy.jobs { active+=1;return }
        await withCheckedContinuation { waiting.append($0) }
    }
    private func leave() {
        active-=1
        if active<ThermalPolicy.jobs,!waiting.isEmpty { active+=1;waiting.removeFirst().resume() }
    }
    func run(_ job: EngineJob) async throws -> EngineResult {
        await enter();defer { leave() }
        try Task.checkCancellation()
        EngineProgress.report(0.03)
        let start=ProcessInfo.processInfo.systemUptime
        let ext: String
        switch job.operation {
        case .convert(let f): ext=f.rawValue
        case .encodeImage(let format,_): ext=format.rawValue
        case .cleanMetadata: ext=job.source.pathExtension.lowercased()
        case .pdfMerge,.pdfPages,.pdfSplit,.pdfSmartCompress: ext="pdf"
        case .renderDocument(let format,_): ext=format.rawValue
        case .video(let operation): ext=operation.fileExtension
        case .removeLocation,.compress: ext=job.source.pathExtension.lowercased()
        case .pdfMetadata,.pdfNote,.pdfRedact: ext="pdf"
        case .edit(.crop) where ["jpg","jpeg"].contains(job.source.pathExtension.lowercased()): ext="jpg"
        case .edit(.adjust(let e,let c,let s)) where e == 0 && c == 1 && s == 1: ext=job.source.pathExtension.lowercased()
        case .edit: ext="png"
        }
        let transaction=try OutputTransaction(source:job.source,extension:ext)
        defer { transaction.cleanup() }
        let detail:String
        do { switch job.operation {
        case .video(let operation):
            detail=try await MediaEngine.run(job.source,to:transaction.file,operation:operation)
        case .renderDocument(let format,let options):
            detail=try await OfficeEngine.render(job.source,to:transaction.file,format:format,options:options)
        case .convert(let format) where DocumentSource.extensions.contains(job.source.pathExtension.lowercased()):
            if format == .docx,job.source.pathExtension.lowercased() == "docx" {
                try FileIntegrity.copy(job.source,to:transaction.file);detail="원본 DOCX 바이트 그대로"
            } else { detail=try await OfficeEngine.render(job.source,to:transaction.file,format:format) }
        case .convert(.docx):
            detail=try await DOCXEngine.convert(job.source,to:transaction.file)
        default:
            detail=try autoreleasepool { try Self.synchronous(job,to:transaction.file) }
        } } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        EngineProgress.report(0.95)
        let result=try transaction.publish()
        EngineProgress.report(1)
        return EngineResult(url:result,detail:detail,seconds:ProcessInfo.processInfo.systemUptime-start)
    }
    private static func synchronous(_ job:EngineJob,to output:URL) throws -> String {
        switch job.operation {
        case .video,.renderDocument:throw EngineError.invalid("비동기 엔진 경로 오류")
        case .encodeImage(let format,let intent):return try TargetSizeCodec.encode(job.source,to:output,format:format,intent:intent)
        case .cleanMetadata:return try MetadataEngine.clean(job.source,to:output)
        case .pdfMerge(let sources,let width):return try PDFEngine.merge(sources,to:output,uniformWidth:width)
        case .pdfPages(let pages):return try PDFEngine.organize(Array(repeating:job.source,count:pages.count),pages:pages,to:output)
        case .pdfSplit(let ranges):return try PDFEngine.split(job.source,ranges:ranges,to:output)
        case .pdfSmartCompress(let options):return try PDFEngine.smartCompress(job.source,to:output,options:options)
        case .convert(let format):
            if job.source.pathExtension.lowercased() == "pdf" { return try PDFEngine.export(job.source,to:output,format:format) }
            if format == .pdf { return try PDFEngine.imageToPDF(job.source,to:output) }
            return try ImageCodec.convert(job.source,to:output,format:format)
        case .removeLocation:return try ImageCodec.removeLocation(job.source,to:output)
        case .pdfMetadata(let value):return try PDFEngine.metadata(job.source,to:output,value:value)
        case .pdfNote(let note):return try PDFEngine.annotate(job.source,to:output,note:note)
        case .pdfRedact(let selection):return try PDFRedactor.run(job.source,to:output,selection:selection)
        case .edit(let edit):return try ImageEdits.run(job.source,to:output,edit:edit)
        case .compress:
            if job.source.pathExtension.lowercased() == "pdf" { return try PDFEngine.compress(job.source,to:output) }
            return try ExternalCodecs.compress(job.source,to:output)
        }
    }
}

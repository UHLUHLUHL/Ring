import AppKit
import UniformTypeIdentifiers

enum ActionKind: Equatable {
    case convert(String)
    case crop
    case addBackground
    case tool
}

struct RingAction: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String?
    let kind: ActionKind
}

struct FileInfo {
    enum Kind { case pdf, image, document, video, other }

    let url: URL
    let name: String
    let ext: String
    let kind: Kind
    let sizeText: String
    let selection: [URL]

    init(url: URL, selection: [URL] = []) {
        self.url = url
        self.selection = selection.isEmpty ? [url] : selection
        name = url.lastPathComponent
        ext = url.pathExtension.uppercased()
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true {
            kind = .pdf
        } else if DocumentSource.extensions.contains(url.pathExtension.lowercased()) {
            kind = .document
        } else if type?.conforms(to: .movie) == true || ["mp4","mov","m4v"].contains(url.pathExtension.lowercased()) {
            kind = .video
        } else if type?.conforms(to: .image) == true || ["webp","avif","heic"].contains(url.pathExtension.lowercased()) {
            kind = .image
        } else {
            kind = .other
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        sizeText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var baseName: String { url.deletingPathExtension().lastPathComponent }

    var convertActions: [RingAction] {
        switch kind {
        case .pdf:
            return ["DOCX", "JPG", "PNG", "WEBP"].map { RingAction(id: $0, title: $0, symbol: nil, kind: .convert($0)) }
        case .image:
            let own = (ext == "JPEG") ? "JPG" : ext
            let formats = ["PNG", "JPG", "WEBP", "HEIC", "PDF"].filter { $0 != own }
            return formats.map { RingAction(id: $0, title: $0, symbol: nil, kind: .convert($0)) }
        case .document:
            return ["PDF","PNG","JPG","WEBP"].map { RingAction(id:$0,title:$0,symbol:nil,kind:.convert($0)) }
        case .video:
            return ["GIF","WEBP"].map { RingAction(id:$0,title:$0,symbol:nil,kind:.convert($0)) }
        case .other:
            return []
        }
    }

    var editActions: [RingAction] {
        switch kind {
        case .image:
            return [
                RingAction(id: "compress", title: "압축", symbol: "arrow.down.right.and.arrow.up.left", kind: .tool),
                RingAction(id: "metadata", title: "메타데이터", symbol: "tag", kind: .tool),
                RingAction(id: "resize", title: "크기 조절", symbol: "arrow.up.left.and.arrow.down.right", kind: .tool),
                RingAction(id: "crop", title: "자르기", symbol: "crop", kind: .crop),
            ]
        case .pdf:
            return [
                RingAction(id: "compress", title: "용량 줄이기", symbol: "arrow.down.right.and.arrow.up.left", kind: .tool),
                RingAction(id: "merge", title: "병합", symbol: "doc.on.doc", kind: .tool),
                RingAction(id: "pages", title: "페이지 정리", symbol: "square.grid.2x2", kind: .tool),
                RingAction(id: "split", title: "분할", symbol: "scissors", kind: .tool),
            ]
        case .video:
            return [
                RingAction(id: "trim", title: "자르기", symbol: "scissors", kind: .tool),
                RingAction(id: "compress", title: "용량 줄이기", symbol: "arrow.down.right.and.arrow.up.left", kind: .tool),
            ]
        case .other, .document:
            return []
        }
    }
}

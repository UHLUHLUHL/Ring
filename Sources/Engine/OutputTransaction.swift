import Foundation
import Darwin

/// Private scratch space, always removed on success, error, or cancellation.
final class StagingWorkspace {
    let directory: URL
    init(beside source: URL) throws {
        directory = source.deletingLastPathComponent().appendingPathComponent(".ring-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    }
    func cleanup() { try? FileManager.default.removeItem(at:directory) }
    deinit { cleanup() }
}

/// Staging is private and on the destination volume. Publication never replaces an entry,
/// including a symlink created between candidate selection and publication.
final class OutputTransaction {
    let source: URL
    let directory: URL
    let file: URL
    let ext: String
    private let workspace: StagingWorkspace
    init(source: URL, extension ext: String) throws {
        guard !ext.isEmpty,ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw EngineError.invalid("결과 확장자 오류") }
        self.source = source; self.ext = ext
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw EngineError.invalid("일반 파일만 처리할 수 있어요.")
        }
        workspace = try StagingWorkspace(beside:source)
        directory = workspace.directory
        file = directory.appendingPathComponent("result.\(ext)")
    }
    func cleanup() { workspace.cleanup() }
    func publish() throws -> URL {
        // The result keeps its own (current) dates. Copying the source's dates made new files
        // sort among old ones in Finder, so users could not find the result.
        let base = source.deletingPathExtension().lastPathComponent
        let values = try file.resourceValues(forKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        let isDirectory = values.isDirectory == true
        guard values.isSymbolicLink != true else { throw EngineError.quality("결과에 심볼릭 링크가 있어요.") }
        let files = isDirectory ? try FileManager.default.contentsOfDirectory(at:file,includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey]) : [file]
        guard !files.isEmpty else { throw EngineError.quality("결과가 비어 있어요.") }
        for url in files {
            let v = try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
            guard v.isRegularFile == true,v.isSymbolicLink != true,(v.fileSize ?? 0)>0 else { throw EngineError.quality("결과 파일 크기 검사 실패") }
        }
        for number in 0..<100_000 {
            try Task.checkCancellation()
            let name = base + (number == 0 ? "" : " (\(number))") + "." + ext
            let target = source.deletingLastPathComponent().appendingPathComponent(name)
            let rc = file.path.withCString { from in target.path.withCString { to in
                isDirectory ? renamex_np(from, to, UInt32(RENAME_EXCL)) : Darwin.link(from, to)
            }}
            if rc == 0 { return target }
            if errno != EEXIST { throw EngineError.io("결과 저장 실패: \(String(cString: strerror(errno)))") }
        }
        throw EngineError.io("같은 이름의 결과가 너무 많아요.")
    }
}

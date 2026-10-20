import Foundation

enum FileIntegrity {
    static func copy(_ source:URL,to output:URL) throws {
        try FileManager.default.copyItem(at:source,to:output)
        let a=try FileHandle(forReadingFrom:source),b=try FileHandle(forReadingFrom:output)
        defer { try? a.close();try? b.close() }
        while true {
            try Task.checkCancellation()
            let left=try a.read(upToCount:65536) ?? Data(),right=try b.read(upToCount:65536) ?? Data()
            guard left==right else { throw EngineError.quality("원본 바이트 복사 검증 실패") }
            if left.isEmpty { return }
        }
    }
}

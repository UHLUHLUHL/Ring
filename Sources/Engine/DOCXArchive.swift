import Foundation

/// ZIP32 stored entries: compressed image bytes are never compressed again.
/// Files are streamed in 64KiB chunks; readback verifies every byte and CRC.
final class DOCXArchive {
    struct Entry {
        let name:String
        let data:Data?
        let file:URL?
        init(_ name:String,_ text:String) { self.name=name;data=Data(text.utf8);file=nil }
        init(_ name:String,file:URL) { self.name=name;self.file=file;data=nil }
        func chunks(_ body:(Data)throws->Void) throws {
            if let data { try body(data);return }
            let handle=try FileHandle(forReadingFrom:file!);defer { try? handle.close() }
            while let bytes=try handle.read(upToCount:65536),!bytes.isEmpty { try Task.checkCancellation();try body(bytes) }
        }
    }
    static func write(_ entries:[Entry],to output:URL) throws {
        guard entries.count < 65535,Set(entries.map(\.name)).count == entries.count else { throw EngineError.invalid("DOCX 항목 수 오류") }
        guard FileManager.default.createFile(atPath:output.path,contents:nil) else { throw EngineError.io("DOCX 생성 실패") }
        let handle=try FileHandle(forWritingTo:output);defer { try? handle.close() }
        var directory=Data(),offset:UInt64=0,positions:[UInt64]=[]
        func emit(_ bytes:Data) throws { try handle.write(contentsOf:bytes);offset += UInt64(bytes.count) }
        for entry in entries {
            var size:UInt64=0,crc:UInt32=0
            try entry.chunks { bytes in size += UInt64(bytes.count);crc=checksum(crc,bytes) }
            let name=Data(entry.name.utf8)
            guard size <= UInt32.max,offset <= UInt32.max,name.count <= 65535 else { throw EngineError.unsupported("4GB 이상 DOCX는 지원하지 않아요.") }
            if let data=entry.data,entry.name.hasSuffix(".xml") || entry.name.hasSuffix(".rels") {
                let parser=XMLParser(data:data);parser.shouldResolveExternalEntities=false
                guard parser.parse() else { throw EngineError.quality("DOCX XML 검증 실패: \(entry.name)") }
            }
            var header=Data();header.le(UInt32(0x04034b50));header.le(UInt16(20));header.le(UInt16(0x800));header.le(UInt16(0));header.le(UInt16(0));header.le(UInt16(0x21));header.le(crc);header.le(UInt32(size));header.le(UInt32(size));header.le(UInt16(name.count));header.le(UInt16(0));header.append(name)
            var central=Data();central.le(UInt32(0x02014b50));central.le(UInt16(20));central.append(header.subdata(in:4..<28));central.le(UInt16(0));central.le(UInt16(0));central.le(UInt16(0));central.le(UInt16(0));central.le(UInt32(0));central.le(UInt32(offset));central.append(name)
            // Central header contains filename length copied above, followed by five fixed fields.
            directory.append(central)
            try emit(header);positions.append(offset)
            try entry.chunks { try emit($0) }
        }
        let start=offset;try emit(directory)
        guard offset <= UInt32.max else { throw EngineError.unsupported("4GB 이상 DOCX는 지원하지 않아요.") }
        var end=Data();end.le(UInt32(0x06054b50));end.le(UInt16(0));end.le(UInt16(0));end.le(UInt16(entries.count));end.le(UInt16(entries.count));end.le(UInt32(directory.count));end.le(UInt32(start));end.le(UInt16(0));try emit(end)
        try handle.synchronize()
        let read=try FileHandle(forReadingFrom:output);defer { try? read.close() }
        for (i,entry) in entries.enumerated() {
            try read.seek(toOffset:positions[i]);var crc:UInt32=0,actual:UInt32=0
            try entry.chunks { expected in
                let found=try read.read(upToCount:expected.count) ?? Data()
                guard found == expected else { throw EngineError.quality("DOCX 포함 파일 바이트 검증 실패") }
                crc=checksum(crc,expected);actual=checksum(actual,found)
            }
            guard crc == actual else { throw EngineError.quality("DOCX CRC 검증 실패") }
        }
    }
    static func checksum(_ crc:UInt32,_ data:Data) -> UInt32 {
        data.withUnsafeBytes { ring_crc32(crc,$0.bindMemory(to:UInt8.self).baseAddress,data.count) }
    }
}
private extension Data {
    mutating func le<T:FixedWidthInteger>(_ value:T) { var number=value.littleEndian;Swift.withUnsafeBytes(of:&number) { append(contentsOf:$0) } }
}

import Foundation

/// Turn ImageIO's tiny TIFF metadata serialization into an EXIF envelope, without a raster/thumbnail IFD.
enum TIFFMetadataEnvelope {
    static func sanitize(_ data:Data,width:Int,height:Int) throws -> Data {
        var editor=try Editor(data)
        let root=try editor.read(4,4),count=try editor.read(root,2)
        guard count<=4096,root+2+12*count+4<=data.count else { throw EngineError.invalid("EXIF 디렉터리 오류") }
        let rasterTags:Set<Int>=[0x0102,0x0103,0x0106,0x0111,0x0115,0x0116,0x0117,0x011c,0x013d,0x0140,0x0144,0x0145,0x8773]
        var kept=Data(),exifOffset:Int?
        for i in 0..<count {
            let entry=root+2+i*12,tag=try editor.read(entry,2)
            if tag==0x8769 { exifOffset=try editor.read(entry+8,4) }
            if tag==0x0100 || tag==0x0101 { try editor.dimension(entry,tag==0x0100 ? width:height) }
            if !rasterTags.contains(tag) { kept.append(editor.bytes[entry..<(entry+12)]) }
        }
        if let exifOffset {
            let n=try editor.read(exifOffset,2)
            guard n<=4096,exifOffset+2+12*n+4<=editor.bytes.count else { throw EngineError.invalid("EXIF 포인터 오류") }
            for i in 0..<n {
                let entry=exifOffset+2+i*12,tag=try editor.read(entry,2)
                if tag==0xa002 || tag==0xa003 { try editor.dimension(entry,tag==0xa002 ? width:height) }
            }
        }
        editor.bytes.replaceSubrange((root+2)..<(root+2+count*12+4),with:Data(count:count*12+4))
        editor.bytes.replaceSubrange((root+2)..<(root+2+kept.count),with:kept)
        try editor.write(kept.count/12,root,2)
        return editor.bytes
    }
    private struct Editor {
        var bytes:Data
        let little:Bool
        init(_ data:Data) throws {
            guard data.count>=8,data.starts(with:[0x49,0x49]) || data.starts(with:[0x4d,0x4d]) else { throw EngineError.invalid("EXIF 바이트 순서 오류") }
            bytes=data;little=data[0]==0x49
        }
        func read(_ offset:Int,_ count:Int) throws -> Int {
            guard offset>=0,offset<=bytes.count-count else { throw EngineError.invalid("EXIF 범위 오류") }
            return (0..<count).reduce(0){$0 | Int(bytes[offset+$1]) << (8*(little ? $1:count-1-$1))}
        }
        mutating func write(_ value:Int,_ offset:Int,_ count:Int) throws {
            guard offset>=0,offset<=bytes.count-count else { throw EngineError.invalid("EXIF 쓰기 범위 오류") }
            for i in 0..<count { bytes[offset+i]=UInt8((value >> (8*(little ? i:count-1-i)))&255) }
        }
        mutating func dimension(_ entry:Int,_ value:Int) throws {
            let type=try read(entry+2,2),count=try read(entry+4,4)
            guard count==1,type==3 || type==4 else { throw EngineError.invalid("EXIF 크기 필드 오류") }
            try write(value,entry+8,type==3 ? 2:4)
        }
    }
}

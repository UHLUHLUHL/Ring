import Foundation

/// Removes EXIF GPS and textual XMP without changing a PNG's image-data chunks.
enum PNGMetadata {
    static func stripLocation(_ source: URL, to target: URL) throws {
        let input = try Data(contentsOf: source)
        guard input.starts(with: [137,80,78,71,13,10,26,10]) else { throw EngineError.invalid("잘못된 PNG") }
        var output = Data(input.prefix(8)), offset = 8
        while offset + 12 <= input.count {
            let length = Int(read32(input, offset))
            guard length <= input.count - offset - 12 else { throw EngineError.invalid("손상된 PNG 청크") }
            let type = String(bytes: input[(offset+4)..<(offset+8)], encoding:.ascii) ?? ""
            var payload = Data(input[(offset+8)..<(offset+8+length)])
            if type == "eXIf" { try stripGPS(&payload) }
            // Text can contain XMP or proprietary position fields. Remove all text chunks.
            if !["iTXt","tEXt","zTXt"].contains(type) {
                if type == "eXIf" {
                    append32(UInt32(payload.count), to:&output)
                    let chunk = Data("eXIf".utf8) + payload
                    output.append(chunk); append32(crc32(chunk),to:&output)
                } else { output.append(input[offset..<(offset+12+length)]) }
            }
            offset += length + 12
            if type == "IEND" { break }
        }
        guard offset == input.count else { throw EngineError.invalid("PNG 뒤에 알 수 없는 데이터가 있어요.") }
        try output.write(to:target)
    }
    private static func stripGPS(_ tiff: inout Data) throws {
        guard tiff.count >= 8 else { throw EngineError.invalid("손상된 EXIF") }
        let little = tiff.starts(with:[0x49,0x49])
        guard little || tiff.starts(with:[0x4d,0x4d]) else { throw EngineError.invalid("손상된 EXIF") }
        func number(_ offset:Int,_ bytes:Int) throws -> Int {
            guard offset >= 0, offset <= tiff.count-bytes else { throw EngineError.invalid("잘못된 EXIF 오프셋") }
            return (0..<bytes).reduce(0) { value,i in value | (Int(tiff[offset+i]) << (8 * (little ? i : bytes-1-i))) }
        }
        let root = try number(4,4), count = try number(root,2)
        guard count <= 4096, root + 2 + count*12 + 4 <= tiff.count else { throw EngineError.invalid("잘못된 EXIF 디렉터리") }
        var remove: Int?
        for i in 0..<count {
            let entry = root+2+i*12
            if try number(entry,2) == 0x8825 {
                let gps = try number(entry+8,4), n = try number(gps,2)
                guard n <= 256, gps+2+n*12+4 <= tiff.count else { throw EngineError.invalid("잘못된 GPS 디렉터리") }
                let sizes = [1:1,2:1,3:2,4:4,5:8,7:1,9:4,10:8]
                var ranges: [Range<Int>] = []
                for j in 0..<n {
                    let e = gps+2+j*12
                    let type = try number(e+2,2), qty = try number(e+4,4)
                    guard let size = sizes[type], qty <= tiff.count/size else { throw EngineError.invalid("잘못된 GPS 값") }
                    let bytes = qty*size
                    if bytes > 4 {
                        let start = try number(e+8,4)
                        guard start >= 8, start <= tiff.count-bytes else { throw EngineError.invalid("잘못된 GPS 값 위치") }
                        ranges.append(start..<(start+bytes))
                    }
                }
                ranges.append(gps..<(gps+2+n*12+4))
                for range in ranges { tiff.replaceSubrange(range,with:repeatElement(UInt8(0),count:range.count)) }
                remove = entry
                break
            }
        }
        if let entry = remove {
            let end = root+2+count*12+4
            let rest = Data(tiff[(entry+12)..<end])
            tiff.replaceSubrange(entry..<(end-12),with:rest)
            tiff.replaceSubrange((end-12)..<end,with:repeatElement(UInt8(0),count:12))
            let newCount = count-1
            tiff[root] = UInt8((newCount >> (little ? 0 : 8)) & 255)
            tiff[root+1] = UInt8((newCount >> (little ? 8 : 0)) & 255)
        }
    }
    static func read32(_ data:Data,_ offset:Int)->UInt32 {
        data[offset..<(offset+4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    static func append32(_ n:UInt32,to data:inout Data) { for shift in [24,16,8,0] { data.append(UInt8((n >> shift)&255)) } }
    static func crc32(_ data:Data)->UInt32 {
        var crc:UInt32 = 0xffffffff
        for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) } }
        return ~crc
    }
    static func imageData(_ url:URL) throws -> Data {
        let data = try Data(contentsOf:url)
        var offset = 8, result = Data()
        while offset+12 <= data.count {
            let n = Int(read32(data,offset))
            guard n <= data.count-offset-12 else { throw EngineError.invalid("잘못된 PNG") }
            if data[(offset+4)..<(offset+8)] == Data("IDAT".utf8) { result.append(data[(offset+8)..<(offset+8+n)]) }
            offset += n+12
        }
        return result
    }
}

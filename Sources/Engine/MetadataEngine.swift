import Foundation
import ImageIO
import CryptoKit

/// Container edits only. Encoded image payloads never enter an encoder.
enum MetadataEngine {
    static func clean(_ source: URL, to output: URL) throws -> String {
        let original = try Data(contentsOf: source, options: .mappedIfSafe)
        let input = try ImageInput(source)
        let bytes: Data
        switch input.type {
        case ImageFormat.jpg.uti:
            bytes = try jpeg(original)
            var error = [CChar](repeating: 0, count: 512)
            let equal = original.withUnsafeBytes { a in bytes.withUnsafeBytes { b in
                ring_jpeg_coefficients_equal(a.bindMemory(to: UInt8.self).baseAddress!, original.count,
                    b.bindMemory(to: UInt8.self).baseAddress!, bytes.count, 0, 0, &error, error.count)
            } }
            guard equal == 1 else { throw EngineError.quality("JPEG DCT 계수 검증 실패") }
        case ImageFormat.png.uti: bytes = try png(original)
        case ImageFormat.webp.uti: bytes = try webp(original)
        case ImageFormat.heic.uti, ImageFormat.avif.uti: bytes = try stripISOBMFFMetadata(data: original)
        default: throw EngineError.unsupported("전체 메타데이터 소거는 JPEG/PNG/WebP/HEIC/AVIF를 지원해요.")
        }
        try bytes.write(to: output)
        let result = try ImageInput(output)
        guard result.image.width == input.image.width, result.image.height == input.image.height,
              result.image.colorSpace?.copyICCData() == input.image.colorSpace?.copyICCData(),
              result.properties[kCGImagePropertyGPSDictionary] == nil,
              result.properties[kCGImagePropertyExifDictionary] == nil else { throw EngineError.quality("메타데이터 소거·ICC 검증 실패") }
        guard try PixelCheck.compare(input.image, result.image).exact else { throw EngineError.quality("메타데이터 소거 후 픽셀 불일치") }
        return "전체 개인정보 소거 · 픽셀 재인코딩 없음 · ICC·압축 페이로드 검증" + (input.orientation == result.orientation ? "" : " · EXIF 방향 태그 제거")
    }

    static func jpeg(_ data: Data) throws -> Data {
        guard data.starts(with: [255, 216]) else { throw EngineError.invalid("JPEG 헤더 오류") }
        var out = Data([255, 216]), p = 2, inScan = false, ended = false
        while p < data.count {
            try Task.checkCancellation()
            if inScan {
                let start = p
                while p < data.count {
                    if data[p] != 255 { p += 1; continue }
                    guard p + 1 < data.count else { throw EngineError.invalid("JPEG 스캔 잘림") }
                    if data[p + 1] == 0 || (0xd0...0xd7).contains(data[p + 1]) { p += 2; continue }
                    break
                }
                out.append(data[start..<p]); inScan = false
            }
            let start = p
            guard p < data.count, data[p] == 255 else { throw EngineError.invalid("JPEG 마커 오류") }
            while p < data.count && data[p] == 255 { p += 1 }
            guard p < data.count else { throw EngineError.invalid("JPEG 마커 잘림") }
            let marker = data[p]; p += 1
            if marker == 0xd9 { out.append(data[start..<p]); ended = true; break }
            guard marker != 0xd8, marker != 0, p + 2 <= data.count else { throw EngineError.invalid("JPEG 구조 오류") }
            let length = Int(data[p]) * 256 + Int(data[p + 1])
            guard length >= 2, length <= data.count - p else { throw EngineError.invalid("JPEG 세그먼트 잘림") }
            let payload = Data(data[(p + 2)..<(p + length)])
            let app = (0xe0...0xef).contains(marker)
            // APP14 defines Adobe color interpretation; ICC defines the source profile.
            let keep = !app && marker != 0xfe || marker == 0xe2 && payload.starts(with: Data("ICC_PROFILE\0".utf8)) || marker == 0xee && payload.starts(with: Data("Adobe".utf8))
            if keep { out.append(data[start..<(p + length)]) }
            p += length; inScan = marker == 0xda
        }
        guard ended else { throw EngineError.invalid("JPEG 종료 마커 없음") }
        return out // Discard trailer bytes, which can contain previews or private data.
    }

    static func png(_ data: Data) throws -> Data {
        guard data.starts(with: [137,80,78,71,13,10,26,10]) else { throw EngineError.invalid("PNG 헤더 오류") }
        var result = Data(data.prefix(8)), p = 8, originalIDAT = Data(), outputIDAT = Data(), ended = false
        while p + 12 <= data.count {
            let n = Int(PNGMetadata.read32(data, p))
            guard n <= data.count - p - 12 else { throw EngineError.invalid("PNG 길이 오류") }
            let name = String(bytes: data[(p + 4)..<(p + 8)], encoding: .ascii) ?? ""
            let chunk = Data(data[(p + 4)..<(p + 8 + n)])
            guard DOCXArchive.checksum(0, chunk) == PNGMetadata.read32(data, p + 8 + n) else { throw EngineError.invalid("PNG CRC 오류") }
            if name == "IDAT" { originalIDAT.append(data[(p + 8)..<(p + 8 + n)]) }
            if !["eXIf", "iTXt", "tEXt", "zTXt", "tIME"].contains(name) {
                result.append(data[p..<(p + n + 12)])
                if name == "IDAT" { outputIDAT.append(data[(p + 8)..<(p + 8 + n)]) }
            }
            p += n + 12
            if name == "IEND" { ended = true; break }
        }
        guard ended, !originalIDAT.isEmpty, SHA256.hash(data: originalIDAT) == SHA256.hash(data: outputIDAT) else { throw EngineError.quality("PNG IDAT 검증 실패") }
        return result
    }

    static func webp(_ data:Data) throws -> Data {
        guard data.count>=12,data.prefix(4)==Data("RIFF".utf8),data[8..<12]==Data("WEBP".utf8) else { throw EngineError.invalid("WebP RIFF 헤더 오류") }
        func little(_ p:Int)->Int { (0..<4).reduce(0) { $0 | Int(data[p+$1]) << ($1*8) } }
        let end=little(4)+8
        guard end<=data.count else { throw EngineError.invalid("WebP RIFF 길이 오류") }
        var chunks=Data(),p=12,before=Data(),after=Data()
        while p<end {
            guard p+8<=end else { throw EngineError.invalid("WebP 청크 잘림") }
            let n=little(p+4),kind=String(bytes:data[p..<(p+4)],encoding:.ascii) ?? ""
            guard n<=end-p-8,n+(n&1)<=end-p-8 else { throw EngineError.invalid("WebP 청크 길이 오류") }
            let payload=Data(data[(p+8)..<(p+8+n)])
            if ["VP8 ","VP8L","ALPH"].contains(kind) { before.append(payload) }
            if !["EXIF","XMP "].contains(kind) {
                var raw=Data(data[p..<(p+8+n+(n&1))])
                if kind=="VP8X" {
                    guard n==10 else { throw EngineError.invalid("WebP VP8X 길이 오류") }
                    raw[8] &= ~UInt8(0x0c)
                }
                chunks.append(raw)
                if ["VP8 ","VP8L","ALPH"].contains(kind) { after.append(payload) }
            }
            p+=8+n+(n&1)
        }
        guard p==end,!before.isEmpty,SHA256.hash(data:before)==SHA256.hash(data:after) else { throw EngineError.quality("WebP 압축 페이로드 검증 실패") }
        let size=UInt32(chunks.count+4)
        let header=Data("RIFF".utf8)+Data((0..<4).map { UInt8((size >> ($0*8))&255) })+Data("WEBP".utf8)
        return header+chunks
    }

    struct Box {
        let type: String, start: Int, header: Int, end: Int
        var payload: Range<Int> { (start + header)..<end }
    }
    static func boxes(_ data: Data, in range: Range<Int>) throws -> [Box] {
        var result: [Box] = [], p = range.lowerBound
        while p < range.upperBound {
            guard range.upperBound - p >= 8 else { throw EngineError.invalid("ISOBMFF 박스 잘림") }
            let short = try number(data, p, 4), header = short == 1 ? 16 : 8
            let size = short == 1 ? try number(data, p + 8, 8) : short == 0 ? range.upperBound - p : short
            guard size >= header, size <= range.upperBound - p else { throw EngineError.invalid("ISOBMFF 박스 길이 오류") }
            let type = String(bytes: data[(p + 4)..<(p + 8)], encoding: .ascii) ?? "????"
            result.append(Box(type: type, start: p, header: header, end: p + size)); p += size
        }
        return result
    }
    static func number(_ d: Data, _ p: Int, _ n: Int) throws -> Int {
        guard n >= 0, n <= 8, p >= 0, p <= d.count - n else { throw EngineError.invalid("컨테이너 오프셋 오류") }
        var value: UInt64 = 0
        for i in 0..<n { value = (value << 8) | UInt64(d[p + i]) }
        guard value <= UInt64(Int.max) else { throw EngineError.invalid("컨테이너 정수 초과") }
        return Int(value)
    }
    static func big(_ value: Int, _ n: Int) -> Data {
        Data((0..<n).reversed().map { UInt8((UInt64(value) >> ($0 * 8)) & 255) })
    }
    static func box(_ type: String, _ payload: Data) -> Data { big(payload.count + 8, 4) + Data(type.utf8) + payload }

    static func stripISOBMFFMetadata(data: Data) throws -> Data {
        let top = try boxes(data, in: 0..<data.count)
        guard top.contains(where: { $0.type == "ftyp" }), let meta = top.first(where: { $0.type == "meta" }), meta.payload.count >= 4 else { throw EngineError.invalid("HEIF meta 박스 없음") }
        let children = try boxes(data, in: (meta.payload.lowerBound + 4)..<meta.end)
        guard let info = children.first(where: { $0.type == "iinf" }), let locations = children.first(where: { $0.type == "iloc" }) else { throw EngineError.invalid("HEIF 아이템 테이블 없음") }
        var output = data, removed = Set<Int>()
        // Each changed child occupies its original slot. idat and mdat never move.
        func patch(_ original: Box, _ payload: Data) throws {
            let replacement = box(original.type, payload), delta = original.end - original.start - replacement.count
            guard delta == 0 || delta >= 8 else { throw EngineError.unsupported("HEIF 패딩 공간이 부족해요.") }
            let padded = replacement + (delta == 0 ? Data() : box("free", Data(count: delta - 8)))
            output.replaceSubrange(original.start..<original.end, with: padded)
        }
        let ip = info.payload.lowerBound, iv = try number(data, ip, 1), countSize = iv == 0 ? 2 : 4
        let entries = try boxes(data, in: (ip + 4 + countSize)..<info.end)
        var retained: [Box] = []
        for entry in entries {
            guard entry.type == "infe", entry.payload.count >= 8 else { throw EngineError.unsupported("지원하지 않는 HEIF item info") }
            let p = entry.payload.lowerBound, version = try number(data, p, 1)
            guard version == 2 || version == 3 else { throw EngineError.unsupported("HEIF infe v2/v3만 지원해요.") }
            let idSize = version == 2 ? 2 : 4, id = try number(data, p + 4, idSize)
            guard p + 6 + idSize + 4 <= entry.end else { throw EngineError.invalid("HEIF item info 잘림") }
            let type = String(bytes: data[(p + 6 + idSize)..<(p + 10 + idSize)], encoding: .ascii) ?? ""
            if ["Exif", "mime", "uri "].contains(type) { removed.insert(id) } else { retained.append(entry) }
        }
        guard try number(data, ip + 4, countSize) == entries.count else { throw EngineError.invalid("HEIF item count 오류") }
        var newInfo = Data(data[ip..<(ip + 4)]) + big(retained.count, countSize)
        for entry in retained { newInfo.append(data[entry.start..<entry.end]) }
        try patch(info, newInfo)

        let lp = locations.payload.lowerBound, lv = try number(data, lp, 1)
        guard (0...2).contains(lv) else { throw EngineError.unsupported("HEIF iloc 버전 오류") }
        let sizes = try number(data, lp + 4, 1), extra = try number(data, lp + 5, 1)
        let offsetSize = sizes >> 4, lengthSize = sizes & 15, baseSize = extra >> 4, indexSize = lv == 0 ? 0 : extra & 15
        guard [offsetSize, lengthSize, baseSize, indexSize].allSatisfy({ $0 <= 8 }) else { throw EngineError.invalid("HEIF iloc 필드 오류") }
        let idSize = lv == 2 ? 4 : 2, count = try number(data, lp + 6, idSize)
        guard count <= 100_000 else { throw EngineError.invalid("HEIF item 수 초과") }
        var p = lp + 6 + idSize, keptRecords = Data(), keptCount = 0
        var erase: [Range<Int>] = [], preserve: [Range<Int>] = []
        let idat = children.first(where: { $0.type == "idat" })
        for _ in 0..<count {
            let start = p, id = try number(data, p, idSize); p += idSize
            let method: Int
            if lv > 0 { method = try number(data, p, 2) & 15; p += 2 } else { method = 0 }
            let reference = try number(data, p, 2); p += 2
            let base = try number(data, p, baseSize); p += baseSize
            let extents = try number(data, p, 2); p += 2
            guard reference == 0, method <= 1 else { throw EngineError.unsupported("외부 참조·파생 HEIF item은 소거하지 않아요.") }
            for _ in 0..<extents {
                p += indexSize
                let offset = try number(data, p, offsetSize); p += offsetSize
                let length = try number(data, p, lengthSize); p += lengthSize
                let origin = method == 0 ? 0 : (idat?.payload.lowerBound ?? -1)
                guard origin >= 0, base <= data.count - origin, offset <= data.count - origin - base,
                      length > 0, length <= data.count - origin - base - offset else { throw EngineError.invalid("HEIF extent 범위 오류") }
                let range = (origin + base + offset)..<(origin + base + offset + length)
                let valid = method == 1 ? idat!.payload.contains(range.lowerBound) && range.upperBound <= idat!.end : top.contains { $0.type == "mdat" && $0.payload.lowerBound <= range.lowerBound && range.upperBound <= $0.end }
                guard valid else { throw EngineError.unsupported("미디어 박스 밖 HEIF extent") }
                if removed.contains(id) { erase.append(range) } else { preserve.append(range) }
            }
            guard p <= locations.end else { throw EngineError.invalid("HEIF iloc 잘림") }
            if !removed.contains(id) { keptCount += 1; keptRecords.append(data[start..<p]) }
        }
        guard p == locations.end else { throw EngineError.invalid("HEIF iloc 끝 오류") }
        try patch(locations, Data(data[lp..<(lp + 6)]) + big(keptCount, idSize) + keptRecords)
        for range in erase {
            guard !preserve.contains(where: { $0.overlaps(range) }) else { throw EngineError.invalid("HEIF 메타데이터와 이미지 extent 중첩") }
            output.replaceSubrange(range, with: Data(count: range.count))
        }
        if let refs = children.first(where: { $0.type == "iref" }) {
            let rp = refs.payload.lowerBound, version = try number(data, rp, 1), size = version == 0 ? 2 : 4
            guard version <= 1 else { throw EngineError.unsupported("HEIF iref 버전 오류") }
            var payload = Data(data[rp..<(rp + 4)])
            for ref in try boxes(data, in: (rp + 4)..<refs.end) {
                let q = ref.payload.lowerBound, from = try number(data, q, size), n = try number(data, q + size, 2)
                guard q + size + 2 + n * size == ref.end else { throw EngineError.invalid("HEIF 참조 길이 오류") }
                if removed.contains(from) { continue }
                let ids = try (0..<n).map { try number(data, q + size + 2 + $0 * size, size) }.filter { !removed.contains($0) }
                if !ids.isEmpty { payload.append(box(ref.type, big(from, size) + big(ids.count, 2) + ids.reduce(into: Data()) { $0.append(big($1, size)) })) }
            }
            try patch(refs, payload)
        }
        // Item-property associations must not leave dangling metadata item IDs.
        if let iprp = children.first(where: { $0.type == "iprp" }) {
            for association in try boxes(data, in: iprp.payload) where association.type == "ipma" {
                let a = association.payload.lowerBound, version = try number(data, a, 1), flags = try number(data, a + 1, 3)
                let records = try number(data, a + 4, 4), idBytes = version < 1 ? 2 : 4, entryBytes = flags & 1 == 0 ? 1 : 2
                var cursor = a + 8, body = Data(), kept = 0
                for _ in 0..<records {
                    let start = cursor, id = try number(data, cursor, idBytes); cursor += idBytes
                    let n = try number(data, cursor, 1); cursor += 1 + n * entryBytes
                    guard cursor <= association.end else { throw EngineError.invalid("HEIF ipma 잘림") }
                    if !removed.contains(id) { body.append(data[start..<cursor]); kept += 1 }
                }
                guard cursor == association.end else { throw EngineError.invalid("HEIF ipma 길이 오류") }
                if kept != records { try patch(association, Data(data[a..<(a + 4)]) + big(kept, 4) + body) }
            }
        }
        for b in top + children where ["uuid", "xml ", "XMP "].contains(b.type) {
            output.replaceSubrange(b.start..<b.end, with: box("free", Data(count: b.end - b.start - 8)))
        }
        guard output.count == data.count else { throw EngineError.quality("HEIF 오프셋 불변 검사 실패") }
        for range in preserve {
            guard SHA256.hash(data: Data(data[range])) == SHA256.hash(data: Data(output[range])) else { throw EngineError.quality("HEIF 이미지 extent 해시 불일치") }
        }
        return output
    }
}

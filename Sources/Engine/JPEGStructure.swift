import Foundation

enum JPEGStructure {
    static func codingBytes(_ data:Data) throws -> Data {
        guard data.starts(with:[0xff,0xd8]) else { throw EngineError.invalid("잘못된 JPEG") }
        var result = Data([0xff,0xd8]), index = 2
        while index+4 <= data.count {
            guard data[index] == 0xff else { throw EngineError.invalid("손상된 JPEG 마커") }
            let marker = data[index+1]
            if marker == 0xda { result.append(data[index...]); return result }
            let length = Int(data[index+2])*256+Int(data[index+3])
            guard length >= 2, index+2+length <= data.count else { throw EngineError.invalid("손상된 JPEG 길이") }
            if !(0xe0...0xef).contains(marker) && marker != 0xfe { result.append(data[index..<(index+2+length)]) }
            index += 2+length
        }
        throw EngineError.invalid("JPEG 이미지 스트림 없음")
    }
    static func replacingExif(_ data:Data,exif:Data) throws -> Data {
        let payload=Data("Exif\0\0".utf8)+exif
        guard payload.count<=65533 else { throw EngineError.unsupported("JPEG에 보존할 EXIF가 너무 커요.") }
        let length=payload.count+2
        var result=Data([0xff,0xd8,0xff,0xe1,UInt8(length>>8),UInt8(length&255)])
        result.append(payload)
        var index=2
        while index+4<=data.count {
            let marker=data[index+1],n=Int(data[index+2])*256+Int(data[index+3])
            if marker==0xda { result.append(data[index...]);return result }
            guard data[index]==0xff,n>=2,index+2+n<=data.count else { break }
            let old=data[(index+4)..<(index+2+n)]
            if marker != 0xe1 || !old.starts(with:Data("Exif\0\0".utf8)) { result.append(data[index..<(index+2+n)]) }
            index+=n+2
        }
        throw EngineError.invalid("JPEG EXIF 교체 실패")
    }
    static func require444(_ url:URL) throws {
        let data = try Data(contentsOf:url)
        var index = 2
        while index+4 <= data.count {
            let marker = data[index+1], length = Int(data[index+2])*256+Int(data[index+3])
            guard length >= 2, index+2+length <= data.count else { break }
            if [0xc0,0xc1,0xc2].contains(marker) {
                let count = Int(data[index+9])
                guard length >= 8+3*count else { break }
                for i in 0..<count where data[index+11+i*3] != 0x11 { throw EngineError.quality("JPEG 4:4:4 검사 실패") }
                return
            }
            index += length+2
        }
        throw EngineError.quality("JPEG 샘플링 검사 실패")
    }
}

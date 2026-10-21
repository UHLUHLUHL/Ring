import Foundation

enum JPEGStructure {
    struct Segment { let marker:UInt8,start:Int,payload:Range<Int> }
    /// Header segments up to and including SOS. T.81 B.1.1.2 allows any number
    /// of 0xFF fill bytes before a marker; `start` includes them.
    static func segments(_ data:Data) throws -> [Segment] {
        guard data.count>=4,data[data.startIndex]==0xff,data[data.startIndex+1]==0xd8 else { throw EngineError.invalid("잘못된 JPEG") }
        var result:[Segment]=[],index=data.startIndex+2
        while index<data.endIndex {
            guard data[index]==0xff else { throw EngineError.invalid("손상된 JPEG 마커") }
            var m=index
            while m<data.endIndex && data[m]==0xff { m+=1 }
            guard m+2<data.endIndex else { break }
            let marker=data[m],length=Int(data[m+1])*256+Int(data[m+2])
            guard marker != 0,length>=2,m+1+length<=data.endIndex else { throw EngineError.invalid("손상된 JPEG 길이") }
            result.append(Segment(marker:marker,start:index,payload:(m+3)..<(m+1+length)))
            if marker==0xda { return result }
            index=m+1+length
        }
        throw EngineError.invalid("JPEG 이미지 스트림 없음")
    }
    static func codingBytes(_ data:Data) throws -> Data {
        var result = Data([0xff,0xd8])
        for segment in try segments(data) {
            if segment.marker == 0xda { result.append(data[segment.start...]); return result }
            if !(0xe0...0xef).contains(segment.marker) && segment.marker != 0xfe { result.append(data[segment.start..<segment.payload.upperBound]) }
        }
        throw EngineError.invalid("JPEG 이미지 스트림 없음")
    }
    static func replacingExif(_ data:Data,exif:Data) throws -> Data {
        let payload=Data("Exif\0\0".utf8)+exif
        guard payload.count<=65533 else { throw EngineError.unsupported("JPEG에 보존할 EXIF가 너무 커요.") }
        let length=payload.count+2
        var result=Data([0xff,0xd8,0xff,0xe1,UInt8(length>>8),UInt8(length&255)])
        result.append(payload)
        for segment in try segments(data) {
            if segment.marker==0xda { result.append(data[segment.start...]);return result }
            if segment.marker != 0xe1 || !data[segment.payload].starts(with:Data("Exif\0\0".utf8)) { result.append(data[segment.start..<segment.payload.upperBound]) }
        }
        throw EngineError.invalid("JPEG EXIF 교체 실패")
    }
    /// Baseline / extended / progressive SOF component sampling: (width, height, [(h,v)]).
    static func frame(_ data:Data) throws -> (width:Int,height:Int,sampling:[(Int,Int)]) {
        for segment in try segments(data) where [0xc0,0xc1,0xc2].contains(segment.marker) {
            let p=segment.payload.lowerBound
            guard segment.payload.count>=6 else { break }
            let count=Int(data[p+5])
            guard segment.payload.count>=6+count*3 else { break }
            let sampling=(0..<count).map { (Int(data[p+7+$0*3])>>4,Int(data[p+7+$0*3])&15) }
            return (Int(data[p+3])*256+Int(data[p+4]),Int(data[p+1])*256+Int(data[p+2]),sampling)
        }
        throw EngineError.unsupported("지원하지 않는 JPEG 구조예요.")
    }
    static func require444(_ url:URL) throws {
        let data = try Data(contentsOf:url)
        guard let frame = try? frame(data) else { throw EngineError.quality("JPEG 샘플링 검사 실패") }
        guard frame.sampling.allSatisfy({ $0 == (1,1) }) else { throw EngineError.quality("JPEG 4:4:4 검사 실패") }
    }
}

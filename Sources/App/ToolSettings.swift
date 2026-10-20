import Foundation

enum ToolSettings {
    static func number(_ text:String,name:String,range:ClosedRange<Double>) throws -> Double {
        guard let value=Double(text.trimmingCharacters(in:.whitespacesAndNewlines)),value.isFinite,range.contains(value) else {
            throw EngineError.invalid("\(name): \(range.lowerBound.formatted())~\(range.upperBound.formatted()) 범위의 숫자를 입력해 주세요.")
        }
        return value
    }
    static func integer(_ text:String,name:String,range:ClosedRange<Int>) throws -> Int {
        guard let value=Int(text.trimmingCharacters(in:.whitespacesAndNewlines)),range.contains(value) else { throw EngineError.invalid("\(name): \(range.lowerBound)~\(range.upperBound) 범위의 정수를 입력해 주세요.") }
        return value
    }
    static func bytes(_ text:String,unit:Int64) throws -> Int64 {
        let value=try number(text,name:"목표 용량",range:0.000001...1_000_000)
        let bytes=value*Double(unit)
        guard bytes>=1,bytes<=1_000_000_000_000 else { throw EngineError.invalid("목표 용량은 1바이트~1TB 범위여야 해요.") }
        return Int64(bytes.rounded(.down))
    }
    /// UI uses one-based inclusive page numbers. Engine indexes are zero-based.
    static func pageGroups(_ text:String,count:Int) throws -> [[Int]] {
        guard count>0,text.count<=100000 else { throw EngineError.invalid("페이지 지정 길이를 확인해 주세요.") }
        let tokens=text.replacingOccurrences(of:"，",with:",").split(separator:",",omittingEmptySubsequences:false)
        guard !tokens.isEmpty,tokens.count<=10000 else { throw EngineError.invalid("페이지를 입력해 주세요.") }
        var total=0
        return try tokens.map { token in
            let parts=token.trimmingCharacters(in:.whitespacesAndNewlines).split(separator:"-",omittingEmptySubsequences:false)
            guard (1...2).contains(parts.count) else { throw EngineError.invalid("페이지는 1-3, 5, 8-10처럼 입력해 주세요.") }
            let first=try integer(String(parts[0]),name:"페이지",range:1...count)
            let last=parts.count==1 ? first : try integer(String(parts[1]),name:"페이지",range:1...count)
            guard last>=first else { throw EngineError.invalid("역순은 3, 2, 1처럼 페이지 번호를 나열해 주세요.") }
            total+=last-first+1
            guard total<=10000 else { throw EngineError.invalid("한 번에 최대 10,000페이지를 처리해요.") }
            return Array((first-1)...(last-1))
        }
    }
    static func time(_ text:String,name:String) throws -> Double {
        let parts=text.trimmingCharacters(in:.whitespacesAndNewlines).split(separator:":",omittingEmptySubsequences:false)
        guard (1...3).contains(parts.count) else { throw EngineError.invalid("\(name): 초 또는 시:분:초로 입력해 주세요.") }
        var seconds:Double=0
        for (i,part) in parts.enumerated() {
            let value=try number(String(part),name:name,range:0...86400)
            guard i==0 || value<60,i==parts.count-1 || value.rounded(.down)==value else { throw EngineError.invalid("\(name)의 분·초 표기를 확인해 주세요.") }
            seconds=seconds*60+value
        }
        guard seconds<=86400 else { throw EngineError.invalid("최대 24시간까지 지정할 수 있어요.") }
        return seconds
    }
}

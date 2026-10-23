import Foundation

/// AAC without an edit list uses implicit priming. Inventing a zero edit
/// changes audible timing even when the compressed packets are copied exactly.
enum MP4AudioTimeline {
    private struct Atom { let start:Int,end:Int,header:Int,type:String }
    private struct Movie { let data:Data,offset:UInt64,header:Int,edit:Atom?,roll:[Atom] }
    private static func number(_ data:Data,_ offset:Int,_ count:Int)->UInt64 {
        (offset..<(offset+count)).reduce(0) { ($0<<8)|UInt64(data[$1]) }
    }
    private static func atoms(_ data:Data,_ start:Int,_ end:Int) throws -> [Atom] {
        var result=[Atom](),position=start
        while position<end {
            guard end-position>=8 else { throw EngineError.quality("MP4 트랙 구조가 잘못됐어요.") }
            let short=number(data,position,4),header=short == 1 ? 16:8
            guard end-position>=header else { throw EngineError.quality("MP4 헤더가 잘렸어요.") }
            let length=short == 0 ? UInt64(end-position):(short == 1 ? number(data,position+8,8):short)
            guard length>=header,length<=UInt64(end-position) else { throw EngineError.quality("MP4 트랙 길이가 잘못됐어요.") }
            result.append(.init(start:position,end:position+Int(length),header:header,
                type:String(decoding:data[(position+4)..<(position+8)],as:UTF8.self)))
            position+=Int(length)
        }
        return result
    }
    private static func movie(_ url:URL) throws -> Movie? {
        let file=try FileHandle(forReadingFrom:url);defer { try? file.close() }
        let size=try file.seekToEnd();var offset:UInt64=0
        while offset+8<=size {
            try Task.checkCancellation()
            try file.seek(toOffset:offset)
            let header=try file.read(upToCount:16) ?? Data()
            guard header.count>=8 else { return nil }
            let short=number(header,0,4),length:UInt64
            if short==1 { guard header.count>=16 else { return nil };length=number(header,8,8) }
            else { length=short==0 ? size-offset:short }
            guard length>=8,length<=size-offset else { return nil }
            if String(decoding:header[4..<8],as:UTF8.self)=="moov" {
                // Read only metadata; compressed media is never rewritten here.
                guard length<=64*1024*1024 else { throw EngineError.unsupported("MP4 메타데이터가 너무 커 음성 보존을 확인할 수 없어요.") }
                try file.seek(toOffset:offset)
                guard let data=try file.read(upToCount:Int(length)),data.count==Int(length) else { throw EngineError.io("MP4 메타데이터 읽기 실패") }
                for track in try atoms(data,short==1 ? 16:8,data.count) where track.type=="trak" {
                    let children=try atoms(data,track.start+track.header,track.end)
                    guard let media=children.first(where:{$0.type=="mdia"}) else { continue }
                    let parts=try atoms(data,media.start+media.header,media.end)
                    guard let handler=parts.first(where:{$0.type=="hdlr"}),handler.end-handler.start>=handler.header+12,
                          String(decoding:data[(handler.start+handler.header+8)..<(handler.start+handler.header+12)],as:UTF8.self)=="soun" else { continue }
                    guard let minf=parts.first(where:{$0.type=="minf"}),
                          let table=try atoms(data,minf.start+minf.header,minf.end).first(where:{$0.type=="stbl"}),
                          let descriptions=try atoms(data,table.start+table.header,table.end).first(where:{$0.type=="stsd"}),
                          descriptions.end>=descriptions.start+descriptions.header+16,
                          String(decoding:data[(descriptions.start+descriptions.header+12)..<(descriptions.start+descriptions.header+16)],as:UTF8.self)=="mp4a" else { return nil }
                    let roll=try atoms(data,table.start+table.header,table.end).filter {
                        ["sgpd","sbgp"].contains($0.type) && $0.end>=$0.start+$0.header+8 &&
                        String(decoding:data[($0.start+$0.header+4)..<($0.start+$0.header+8)],as:UTF8.self)=="roll"
                    }
                    return .init(data:data,offset:offset,header:short==1 ? 16:8,edit:children.first(where:{$0.type=="edts"}),roll:roll)
                }
                return nil
            }
            offset+=length
        }
        return nil
    }
    static func usesImplicitPriming(_ source:URL) throws -> Bool {
        guard let movie=try movie(source) else { return false }
        return movie.edit == nil
    }
    static func preservePriming(from source:URL,in output:URL) throws {
        guard let original=try movie(source),let result=try movie(output) else { return }
        var invented=original.roll.isEmpty ? result.roll:[]
        if original.edit == nil,let edit=result.edit { invented.append(edit) }
        guard !invented.isEmpty else { return }
        // Same-size 'free' keeps every media/chunk offset intact. Existing
        // source edit lists are never removed or altered.
        let file=try FileHandle(forUpdating:output);defer { try? file.close() }
        for atom in invented {
            // FFmpeg's newly added AAC roll group also changes Apple's default
            // priming rule. Preserve the source's absence of that group.
            try file.seek(toOffset:result.offset+UInt64(atom.start+4))
            try file.write(contentsOf:Data("free".utf8))
        }
        try Task.checkCancellation()
    }

    /// Limit only the video presentation window. Ending the whole writer
    /// session would also cut AAC postroll that its implicit priming needs.
    /// Encoded pictures, media timestamps and audio packets are untouched.
    static func finishVideoPresentation(in output:URL,end:Double,movieDuration:Double) throws {
        guard let movie=try movie(output) else { throw EngineError.quality("MP4 종료 시각 보존 정보를 읽지 못했어요.") }
        let data=movie.data,top=try atoms(data,movie.header,data.count)
        guard let header=top.first(where:{$0.type=="mvhd"}) else { throw EngineError.quality("MP4 시간 단위가 없어요.") }
        let version=data[header.start+header.header],scaleOffset=header.start+header.header+(version==1 ? 20:12)
        guard header.end>=scaleOffset+12 else { throw EngineError.quality("MP4 시간 정보가 잘렸어요.") }
        let scale=Double(number(data,scaleOffset,4))
        let file=try FileHandle(forUpdating:output);defer { try? file.close() }
        func write(_ value:Double,_ offset:Int,_ count:Int) throws {
            guard value.isFinite,value>=0,value<Double(UInt64.max),count==8 || value<=Double(UInt32.max) else { throw EngineError.unsupported("MP4 종료 시각의 정밀도를 유지할 수 없어요.") }
            let integer=UInt64(value.rounded())
            let bytes=Data((0..<count).reversed().map { UInt8(truncatingIfNeeded:integer>>($0*8)) })
            try file.seek(toOffset:movie.offset+UInt64(offset));try file.write(contentsOf:bytes)
        }
        for track in top where track.type=="trak" {
            let children=try atoms(data,track.start+track.header,track.end)
            guard let media=children.first(where:{$0.type=="mdia"}),
                  let handler=try atoms(data,media.start+media.header,media.end).first(where:{$0.type=="hdlr"}),
                  handler.end>=handler.start+handler.header+12,
                  String(decoding:data[(handler.start+handler.header+8)..<(handler.start+handler.header+12)],as:UTF8.self)=="vide",
                  let trackHeader=children.first(where:{$0.type=="tkhd"}),
                  let edits=children.first(where:{$0.type=="edts"}),
                  let list=try atoms(data,edits.start+edits.header,edits.end).first(where:{$0.type=="elst"}) else { continue }
            let base=list.start+list.header
            guard list.end>=base+8 else { throw EngineError.quality("MP4 영상 재생 구간이 잘렸어요.") }
            let wide=data[base]==1,entryBytes=wide ? 20:12,count=Int(number(data,base+4,4))
            guard (1...2).contains(count),list.end>=base+8+entryBytes*count else { throw EngineError.unsupported("복잡한 MP4 재생 구간의 종료 시각을 보존할 수 없어요.") }
            let prior=(0..<(count-1)).reduce(0.0) { $0+Double(number(data,base+8+$1*entryBytes,wide ? 8:4)) }
            let remaining=(end*scale).rounded()-prior
            guard remaining>0 else { throw EngineError.quality("영상 종료 시각이 마지막 재생 구간보다 앞서요.") }
            try write(remaining,base+8+(count-1)*entryBytes,wide ? 8:4)
            let trackWide=data[trackHeader.start+trackHeader.header]==1
            let durationOffset=trackHeader.start+trackHeader.header+(trackWide ? 28:20)
            guard trackHeader.end>=durationOffset+(trackWide ? 8:4) else { throw EngineError.quality("MP4 트랙 종료 정보가 잘렸어요.") }
            try write(end*scale,durationOffset,trackWide ? 8:4)
            try write(movieDuration*scale,scaleOffset+4,version==1 ? 8:4)
            try Task.checkCancellation()
            return
        }
        throw EngineError.unsupported("MP4 영상의 종료 시각을 안전하게 보존할 수 없어요.")
    }
}

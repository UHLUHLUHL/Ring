import Foundation
import AppKit

/// ZIP32 reader for stored/deflated OOXML. No extraction to disk or external unzip.
struct DocumentZIP {
    private let bytes: Data
    private let entries: [String: (offset:Int,size:Int,compressed:Int,method:Int,crc:UInt32)]
    init(_ url: URL) throws {
        let bytes = try Data(contentsOf:url,options:.mappedIfSafe)
        guard bytes.count>=22,bytes.count<=64*1024*1024 else { throw EngineError.unsupported("DOCX 크기는 64MB 이하여야 해요.") }
        func le(_ p:Int,_ n:Int) throws -> Int {
            guard p>=0,p<=bytes.count-n else { throw EngineError.invalid("ZIP 오프셋 오류") }
            return (0..<n).reduce(0) { $0 | Int(bytes[p+$1]) << (8*$1) }
        }
        var end: Int?
        for p in stride(from:bytes.count-22,through:max(0,bytes.count-65557),by:-1) {
            if try le(p,4)==0x06054b50, try p+22+le(p+20,2)==bytes.count { end=p;break }
        }
        guard let end,try le(end+4,2)==0,try le(end+6,2)==0,
              try le(end+8,2)==le(end+10,2) else { throw EngineError.invalid("다중 디스크·ZIP64 DOCX는 지원하지 않아요.") }
        let count=try le(end+10,2),start=try le(end+16,4),length=try le(end+12,4)
        guard count<10000,start>=0,length<=end-start else { throw EngineError.invalid("ZIP 디렉터리 오류") }
        var p=start,entries:[String:(Int,Int,Int,Int,UInt32)]=[:],total=0
        for _ in 0..<count {
            guard try le(p,4)==0x02014b50 else { throw EngineError.invalid("ZIP 디렉터리 시그니처 오류") }
            let flags=try le(p+8,2),method=try le(p+10,2),compressed=try le(p+20,4),size=try le(p+24,4)
            let nameSize=try le(p+28,2),extra=try le(p+30,2),comment=try le(p+32,2),offset=try le(p+42,4)
            guard flags & 1 == 0,[0,8].contains(method),nameSize>0,p+46+nameSize+extra+comment<=start+length,
                  let name=String(data:bytes[(p+46)..<(p+46+nameSize)],encoding:.utf8),
                  !name.hasPrefix("/"),!name.contains("\\"),!name.split(separator:"/").contains(".."),entries[name]==nil,
                  size<=32*1024*1024,compressed<=bytes.count else { throw EngineError.invalid("ZIP 항목·경로·용량 오류") }
            total+=size;guard total<=128*1024*1024 else { throw EngineError.unsupported("DOCX 펼친 크기 한도 초과") }
            entries[name]=(offset,size,compressed,method,UInt32(try le(p+16,4)))
            p+=46+nameSize+extra+comment
        }
        guard p==start+length else { throw EngineError.invalid("ZIP 디렉터리 길이 오류") }
        self.bytes=bytes;self.entries=entries
    }
    func contains(_ name:String) -> Bool { entries[name] != nil }
    func data(_ name: String) throws -> Data {
        guard let e=entries[name] else { throw EngineError.invalid("DOCX 필수 항목 없음: \(name)") }
        func le(_ p:Int,_ n:Int) throws -> Int {
            guard p>=0,p<=bytes.count-n else { throw EngineError.invalid("ZIP 로컬 헤더 오류") }
            return (0..<n).reduce(0) { $0 | Int(bytes[p+$1]) << (8*$1) }
        }
        guard try le(e.offset,4)==0x04034b50,try le(e.offset+8,2)==e.method else { throw EngineError.invalid("ZIP 로컬 헤더 불일치") }
        let start=try e.offset+30+le(e.offset+26,2)+le(e.offset+28,2)
        guard start<=bytes.count-e.compressed else { throw EngineError.invalid("ZIP 압축 데이터 잘림") }
        let compressed=Data(bytes[start..<(start+e.compressed)]),result:Data
        if e.method==0 { result=compressed }
        else {
            var expanded=Data(count:e.size)
            let expandedSize=e.size
            let ok=expanded.withUnsafeMutableBytes { out in compressed.withUnsafeBytes { input in
                ring_inflate_raw(input.bindMemory(to:UInt8.self).baseAddress,compressed.count,out.bindMemory(to:UInt8.self).baseAddress,expandedSize)
            } }
            guard ok==1 else { throw EngineError.invalid("DOCX DEFLATE 오류") };result=expanded
        }
        guard result.count==e.size,DOCXArchive.checksum(0,result)==e.crc else { throw EngineError.quality("DOCX CRC 오류") }
        return result
    }
}

private final class DocumentNode {
    let name: String,attributes:[String:String]
    var children:[DocumentNode]=[],text=""
    init(_ name:String,_ attributes:[String:String]) { self.name=name;self.attributes=attributes }
    func descendants(_ name:String) -> [DocumentNode] { children.flatMap { ($0.name==name ? [$0]:[])+$0.descendants(name) } }
    func attribute(_ name:String) -> String? { attributes.first { $0.key.split(separator:":").last.map(String.init)==name }?.value }
}
private final class DocumentXML: NSObject,XMLParserDelegate {
    var root:DocumentNode?,stack:[DocumentNode]=[]
    static func parse(_ data:Data) throws -> DocumentNode {
        guard data.count<=32*1024*1024,
              let text=String(data:data,encoding:.utf8),!text.contains("<!DOCTYPE"),!text.contains("<!ENTITY") else { throw EngineError.invalid("문서 XML 선언 오류") }
        let delegate=DocumentXML(),parser=XMLParser(data:data)
        parser.shouldResolveExternalEntities=false;parser.delegate=delegate
        guard parser.parse(),let root=delegate.root else { throw EngineError.invalid("문서 XML 파싱 실패") }
        return root
    }
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        guard stack.count<128 else { parser.abortParsing();return }
        let node=DocumentNode(String(name.split(separator:":").last ?? ""),attributes)
        if let parent=stack.last { parent.children.append(node) } else { root=node };stack.append(node)
    }
    func parser(_ parser:XMLParser,foundCharacters string:String) { stack.last?.text+=string }
    func parser(_ parser:XMLParser,didEndElement:String,namespaceURI:String?,qualifiedName:String?) { if !stack.isEmpty { stack.removeLast() } }
}

enum DocumentSource {
    static let extensions = ["docx","md","markdown","html","htm","rtf"]
    static func html(_ url:URL) throws -> String {
        let data=try Data(contentsOf:url,options:.mappedIfSafe)
        guard data.count<=64*1024*1024 else { throw EngineError.unsupported("문서는 64MB 이하여야 해요.") }
        switch url.pathExtension.lowercased() {
        case "docx": return try docx(url)
        case "rtf":
            let attributed=try NSAttributedString(data:data,options:[.documentType:NSAttributedString.DocumentType.rtf],documentAttributes:nil)
            let html=try attributed.data(from:NSRange(location:0,length:attributed.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.html])
            guard let result=String(data:html,encoding:.utf8) else { throw EngineError.invalid("RTF HTML 변환 실패") };return result
        case "md","markdown":
            guard let text=String(data:data,encoding:.utf8) else { throw EngineError.invalid("Markdown UTF-8 오류") };return markdown(text)
        case "html","htm":
            guard let text=String(data:data,encoding:.utf8) else { throw EngineError.invalid("HTML UTF-8 오류") };return text
        default: throw EngineError.unsupported("DOCX/Markdown/HTML/RTF 문서를 선택해 주세요.")
        }
    }
    private static func docx(_ url:URL) throws -> String {
        let zip=try DocumentZIP(url)
        _=try DocumentXML.parse(zip.data("[Content_Types].xml"))
        let doc=try DocumentXML.parse(zip.data("word/document.xml"))
        let relationships=zip.contains("word/_rels/document.xml.rels") ? try DocumentXML.parse(zip.data("word/_rels/document.xml.rels")) : DocumentNode("Relationships",[:])
        var media:[String:String]=[:]
        for relation in relationships.children where relation.name=="Relationship" && relation.attribute("TargetMode") != "External" {
            guard let target=relation.attribute("Target"),let id=relation.attribute("Id"),
                  target.hasPrefix("media/"),!target.contains(".."),!target.contains(":"),!target.contains("\\") else { continue }
            let file=try zip.data("word/"+target),ext=URL(fileURLWithPath:target).pathExtension.lowercased()
            guard ["png","jpg","jpeg","gif","webp"].contains(ext) else { continue }
            media[id]="data:image/\(ext=="jpg" ? "jpeg":ext);base64,"+file.base64EncodedString()
        }
        func render(_ node:DocumentNode) -> String {
            func all() -> String { node.children.map(render).joined() }
            switch node.name {
            case "p":
                let style=node.descendants("pStyle").first?.attribute("val") ?? ""
                let tag=style.lowercased().hasPrefix("heading") ? "h\(min(6,max(1,Int(style.filter(\.isNumber)) ?? 1)))":"p"
                let align=node.descendants("jc").first?.attribute("val") ?? "left"
                return "<\(tag) style=\"text-align:\(["left","center","right","justify"].contains(align) ? align:"left")\">"+all()+"</\(tag)>"
            case "r":
                var css=""
                if !node.descendants("b").isEmpty { css+="font-weight:bold;" }
                if !node.descendants("i").isEmpty { css+="font-style:italic;" }
                if let size=node.descendants("sz").first?.attribute("val").flatMap(Double.init),size.isFinite,(2...400).contains(size) { css+="font-size:\(size/2)pt;" }
                if let color=node.descendants("color").first?.attribute("val"),color.count==6,color.allSatisfy(\.isHexDigit) { css+="color:#\(color);" }
                return "<span style=\"\(css)\">"+all()+"</span>"
            case "t":return DOCXEngine.xml(node.text)
            case "tab":return "&emsp;"
            case "br":return "<br>"
            case "tbl":return "<table>"+all()+"</table>"
            case "tr":return "<tr>"+all()+"</tr>"
            case "tc":
                let span=min(100,max(1,Int(node.descendants("gridSpan").first?.attribute("val") ?? "1") ?? 1))
                return "<td colspan=\"\(span)\">"+all()+"</td>"
            case "drawing":
                guard let id=node.descendants("blip").first?.attribute("embed"),let source=media[id] else { return "" }
                let cx=node.descendants("extent").first?.attribute("cx").flatMap(Double.init) ?? 0
                let width=cx.isFinite && cx>0 ? "width:\(min(10000,cx/12700))pt;":""
                return "<img style=\"\(width)max-width:100%;height:auto\" src=\"\(source)\">"
            case "pPr","rPr","tcPr","tblPr","sectPr":return ""
            default:return all()
            }
        }
        return doc.children.map(render).joined()
    }
    static func markdown(_ text:String) -> String {
        func inline(_ source:String) -> String {
            var value=DOCXEngine.xml(source)
            for (pattern,template) in [("`([^`]+)`","<code>$1</code>"),("\\*\\*([^*]+)\\*\\*","<strong>$1</strong>"),("\\*([^*]+)\\*","<em>$1</em>")] {
                value=value.replacingOccurrences(of:pattern,with:template,options:.regularExpression)
            }
            return value
        }
        var html="",paragraph:[String]=[],code:[String]=[],fenced=false,list=false
        func flush() { if !paragraph.isEmpty { html+="<p>"+paragraph.map(inline).joined(separator:" ")+"</p>";paragraph=[] } }
        for line in text.components(separatedBy:.newlines) {
            if line.hasPrefix("```") { flush();if fenced { html+="<pre><code>"+DOCXEngine.xml(code.joined(separator:"\n"))+"</code></pre>";code=[] };fenced.toggle();continue }
            if fenced { code.append(line);continue }
            if line.trimmingCharacters(in:.whitespaces).isEmpty { flush();if list { html+="</ul>";list=false };continue }
            let hashes=line.prefix(while:{$0=="#"}).count
            if (1...6).contains(hashes),line.dropFirst(hashes).first==" " { flush();html+="<h\(hashes)>"+inline(String(line.dropFirst(hashes+1)))+"</h\(hashes)>" }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { flush();if !list { html+="<ul>";list=true };html+="<li>"+inline(String(line.dropFirst(2)))+"</li>" }
            else { if list { html+="</ul>";list=false };paragraph.append(line) }
        }
        flush();if list { html+="</ul>" };if fenced { html+="<pre>"+DOCXEngine.xml(code.joined(separator:"\n"))+"</pre>" }
        return html
    }
}

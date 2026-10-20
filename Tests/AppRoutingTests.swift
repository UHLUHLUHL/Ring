import Foundation

@main struct AppRoutingTests {
    static func require(_ value:Bool,_ message:String) throws { if !value { throw EngineError.invalid("TEST: "+message) } }
    static func rejects(_ message:String,_ body:() throws -> Void) throws {
        do { try body() } catch { return }
        throw EngineError.invalid("TEST: invalid input accepted: "+message)
    }
    static func main() throws {
        for ext in ["docx","md","markdown","html","htm","rtf"] {
            let f=FileInfo(url:URL(fileURLWithPath:"/tmp/Ring.\(ext)"))
            try require(f.kind == .document && f.convertActions.map(\.title)==["PDF","PNG","JPG","WEBP"],"document routing \(ext)")
        }
        for ext in ["mp4","mov","m4v"] {
            let f=FileInfo(url:URL(fileURLWithPath:"/tmp/Ring.\(ext)"))
            try require(f.kind == .video && f.convertActions.map(\.title)==["GIF","WEBP"] && f.editActions.map(\.id)==["trim","compress"],"video routing \(ext)")
        }
        for ext in ["png","jpg","webp","heic","avif","pdf"] {
            let f=FileInfo(url:URL(fileURLWithPath:"/tmp/Ring.\(ext)"))
            try require(f.editActions.contains { $0.id=="compress" },"compression missing \(ext)")
            try require(f.editActions.count<=8 && Set(f.editActions.map(\.id)).count==f.editActions.count,"ring slots overlap \(ext)")
        }
        let pdf=FileInfo(url:URL(fileURLWithPath:"/tmp/a.pdf"),selection:[URL(fileURLWithPath:"/tmp/a.pdf"),URL(fileURLWithPath:"/tmp/b.pdf")])
        try require(pdf.selection.count==2 && pdf.editActions.contains { $0.id=="merge" } && pdf.convertActions.contains { $0.id=="WEBP" },"PDF merge/WebP not exposed")
        try require(try ToolSettings.pageGroups("3, 1-2, 5",count:5)==[[2],[0,1],[4]],"page order/off-by-one")
        try require(try ToolSettings.pageGroups("1-3, 4-6",count:6)==[[0,1,2],[3,4,5]],"split endpoints")
        for spec in ["","0","7","3-1","1-","1,,2","1.5","1-3-4"] {
            try rejects(spec) { _=try ToolSettings.pageGroups(spec,count:6) }
        }
        try require(try ToolSettings.bytes("1.5",unit:1_000_000)==1_500_000,"decimal size")
        for input in ["0","-1","nan","inf","1e309",""] { try rejects(input) { _=try ToolSettings.bytes(input,unit:1000) } }
        try require(try ToolSettings.time("1:02:03.5",name:"time")==3723.5,"time conversion")
        try require(try ToolSettings.time("0:01.5",name:"time")==1.5,"fractional seconds")
        for input in ["1:60","-1","1:2:3:4","nan","1.5:30",""] { try rejects(input) { _=try ToolSettings.time(input,name:"time") } }
        print("PASS app file routing, ring slots, multi-PDF context, page range validation, bytes, timestamps")
    }
}

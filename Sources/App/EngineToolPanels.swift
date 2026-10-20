import SwiftUI
import AppKit
import PDFKit
import AVFoundation
import UniformTypeIdentifiers

struct EngineToolPanel: View {
    @ObservedObject var model:RingModel
    let tool:RingModel.Tool
    var body:some View {
        Group {
            switch tool {
            case .imageCompression:ImageCompressionPanel(model:model)
            case .imageResize:ImageResizePanel(model:model)
            case .imageMetadata:ImageMetadataPanel(model:model)
            case .pdfCompression:PDFCompressionPanel(model:model)
            case .pdfMerge:PDFMergePanel(model:model)
            case .pdfPages:PDFPagesPanel(model:model,split:false)
            case .pdfSplit:PDFPagesPanel(model:model,split:true)
            case .document(let format):DocumentPanel(model:model,format:format)
            case .videoTrim:VideoToolPanel(model:model,tool:.trim)
            case .videoCompression:VideoToolPanel(model:model,tool:.compress)
            case .animation(let format):VideoToolPanel(model:model,tool:.animation(format))
            }
        }
        .id(tool)
    }
}

private struct ToolForm<Content:View>:View {
    @ObservedObject var model:RingModel
    let title:String
    var ready=true
    var buttonTitle="새 파일 저장"
    let operation:() throws -> EngineOperation
    @ViewBuilder var content:Content
    @State private var error:String?
    var body:some View {
        GlassPanel(title:title,subtitle:model.file.name,width:460,onClose:model.backToRing) {
            VStack(alignment:.leading,spacing:14) {
                content
                if let error {
                    Text(error).font(.system(size:12)).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)
                        .accessibilityIdentifier("tool.validation")
                }
                Divider()
                HStack {
                    Text("원본 옆에 새 결과를 저장합니다.").font(.system(size:11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(buttonTitle) {
                        do { let job=try operation();error=nil;model.run(job) }
                        catch { self.error=error.localizedDescription }
                    }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(!ready || model.isWorking)
                    .accessibilityIdentifier("tool.save")
                }
            }
        }
    }
}

private struct ToolNote:View {
    let text:String
    init(_ text:String) { self.text=text }
    var body:some View { Text(text).font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading) }
}
private struct SizeFields:View {
    @Binding var value:String
    @Binding var unit:Int64
    var body:some View {
        HStack {
            TextField("예: 1.5",text:$value).textFieldStyle(.roundedBorder).accessibilityLabel("목표 용량")
            Picker("단위",selection:$unit) { Text("KB").tag(Int64(1000));Text("MB").tag(Int64(1_000_000)) }
                .labelsHidden().frame(width:80).accessibilityLabel("용량 단위")
        }
    }
}

private enum CompressionMode:String,CaseIterable { case lossless="무손실",target="목표 용량",quality="품질 지정" }
private struct ImageCompressionPanel:View {
    @ObservedObject var model:RingModel
    @State private var mode=CompressionMode.lossless
    @State private var format=ImageFormat.webp
    @State private var size="500"
    @State private var unit:Int64=1000
    @State private var quality=85.0
    var body:some View {
        ToolForm(model:model,title:"이미지 압축",operation:operation) {
            Picker("압축 방식",selection:$mode) { ForEach(CompressionMode.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            if mode == .lossless {
                ToolNote("현재 형식과 픽셀을 유지해 압축합니다. 줄일 수 없는 파일은 원본 바이트를 그대로 복사합니다.")
            } else {
                PanelRow(label:"형식") { Picker("출력 형식",selection:$format) { ForEach([ImageFormat.jpg,.webp,.heic],id:\.self) { Text($0.rawValue.uppercased()).tag($0) } }.labelsHidden() }
                if mode == .target { PanelRow(label:"용량") { SizeFields(value:$size,unit:$unit) } }
                else { PanelRow(label:"품질") { Slider(value:$quality,in:1...100,step:1).accessibilityLabel("이미지 품질");Text("\(Int(quality))%").monospacedDigit().frame(width:40) } }
                ToolNote(mode == .target ? "해상도를 유지하며 품질을 조절합니다. 목표를 충족하지 못하면 저장하지 않습니다. KB는 1,000바이트입니다." : "품질을 조절한 새 파일을 저장합니다. 원본 파일은 유지합니다.")
                if format == .jpg { ToolNote("JPEG는 투명한 부분을 흰색 배경으로 합성합니다.") }
            }
        }.onAppear {
            if ["JPG","JPEG"].contains(model.file.ext) { format = .jpg }
            else if model.file.ext == "HEIC" { format = .heic }
        }
    }
    private func operation() throws -> EngineOperation {
        if mode == .lossless { return .compress }
        return .encodeImage(format:format,intent:mode == .target ? .targetBytes(try ToolSettings.bytes(size,unit:unit)) : .quality(quality/100))
    }
}

private struct ImageResizePanel:View {
    @ObservedObject var model:RingModel
    @State private var mode="픽셀"
    @State private var width=""
    @State private var height=""
    @State private var percent="50"
    @State private var locked=true
    private var original:CGSize { pixelSize(of:model.file.url) }
    var body:some View {
        ToolForm(model:model,title:"이미지 크기 조절",operation:{
            if mode == "비율" { return .edit(.resizeScale(try ToolSettings.number(percent,name:"비율",range:0.01...10000)/100)) }
            let w=try ToolSettings.integer(width,name:"너비",range:1...65535)
            let h=locked ? max(1,Int((Double(w)*original.height/original.width).rounded())) : try ToolSettings.integer(height,name:"높이",range:1...65535)
            guard h<=65535,Int64(w)*Int64(h)<=52_000_000 else { throw EngineError.invalid("결과 크기는 52MP 이하여야 해요.") }
            return .edit(.resize(width:w,height:h))
        }) {
            ToolNote("현재 크기 \(Int(original.width)) × \(Int(original.height))px · 결과 PNG")
            Picker("입력 방식",selection:$mode) { Text("픽셀").tag("픽셀");Text("비율").tag("비율") }.pickerStyle(.segmented).labelsHidden()
            if mode == "픽셀" {
                PanelRow(label:"너비") { TextField("px",text:$width).textFieldStyle(.roundedBorder).accessibilityLabel("너비 픽셀");Text("px") }
                PanelRow(label:"높이") {
                    if locked { Text("\(calculatedHeight)px").foregroundStyle(.secondary) }
                    else { TextField("px",text:$height).textFieldStyle(.roundedBorder).accessibilityLabel("높이 픽셀");Text("px") }
                }
                Toggle("원본 종횡비 유지",isOn:$locked)
            } else { PanelRow(label:"배율") { TextField("50",text:$percent).textFieldStyle(.roundedBorder).accessibilityLabel("리사이즈 비율");Text("%") } }
            ToolNote("표시 방향을 적용하고 색상 프로파일·투명도를 유지합니다.")
        }.onAppear { width=String(Int(original.width));height=String(Int(original.height)) }
    }
    private var calculatedHeight:Int { guard let w=Double(width),w.isFinite,(1...65535).contains(w) else { return 0 };return max(1,Int((w*original.height/original.width).rounded())) }
}

private struct ImageMetadataPanel:View {
    @ObservedObject var model:RingModel
    @State private var all=false
    private var supportsAll:Bool { ["PNG","JPG","JPEG","WEBP","HEIC","AVIF"].contains(model.file.ext) }
    var body:some View {
        ToolForm(model:model,title:"메타데이터 제거",operation:{ all ? .cleanMetadata:.removeLocation }) {
            Picker("제거 범위",selection:$all) {
                Text("위치 정보만").tag(false)
                Text("전체 촬영 정보").tag(true).disabled(!supportsAll)
            }.pickerStyle(.segmented).labelsHidden()
            ToolNote(all ? "EXIF·GPS·카메라 정보·주석을 제거합니다. 픽셀을 다시 압축하지 않으며 색상 프로파일은 유지합니다." : "GPS와 XMP를 제거하고 촬영 정보·색상·방향은 유지합니다.")
            if all { ToolNote("JPEG·PNG의 EXIF 방향 태그도 제거됩니다. 세로 사진의 표시 방향을 유지하려면 ‘위치 정보만’을 선택하세요.") }
            if !supportsAll { ToolNote("이 형식은 위치 정보 제거를 지원합니다.") }
        }
    }
}

private struct PDFCompressionPanel:View {
    @ObservedObject var model:RingModel
    @State private var smart=true
    @State private var dimension="2000"
    @State private var quality=82.0
    var body:some View {
        ToolForm(model:model,title:"PDF 용량 줄이기",operation:{
            if !smart { return .compress }
            return .pdfSmartCompress(.init(maxImageDimension:try ToolSettings.integer(dimension,name:"이미지 최대 변",range:64...16384),jpegQuality:quality/100))
        }) {
            Picker("압축 방식",selection:$smart) { Text("이미지 최적화").tag(true);Text("무손실 정리").tag(false) }.pickerStyle(.segmented).labelsHidden()
            if smart {
                PanelRow(label:"최대 변") { TextField("2000",text:$dimension).textFieldStyle(.roundedBorder).accessibilityLabel("PDF 이미지 최대 변");Text("px") }
                PanelRow(label:"품질") { Slider(value:$quality,in:5...100,step:1).accessibilityLabel("PDF 이미지 품질");Text("\(Int(quality))%").monospacedDigit().frame(width:40) }
                ToolNote("큰 이미지만 축소·재압축합니다. 텍스트·벡터·글꼴은 유지하며, 지원하지 않는 이미지 구조는 원형을 보존합니다.")
            } else { ToolNote("픽셀을 바꾸지 않고 PDF를 재정리합니다. 절감이 없으면 원본 바이트를 그대로 저장합니다.") }
        }
    }
}

private struct PDFMergePanel:View {
    @ObservedObject var model:RingModel
    @State private var files:[URL]=[]
    @State private var selected:Int?
    @State private var uniform=false
    var body:some View {
        ToolForm(model:model,title:"PDF 병합",ready:files.count>=2,operation:{ .pdfMerge(sources:files,uniformWidth:uniform ? 0:nil) }) {
            ToolNote("위에서 아래 순서로 병합합니다. 파일을 선택해 순서를 바꿀 수 있어요.")
            ScrollView {
                VStack(spacing:4) {
                    ForEach(Array(files.enumerated()),id:\.offset) { i,url in
                        Button { selected=i } label: {
                            HStack(spacing:8) { Text("\(i+1)").monospacedDigit().foregroundStyle(.secondary).frame(width:22);Image(systemName:"doc.richtext");Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle);Spacer() }
                                .padding(8).background(selected == i ? Color.accentColor.opacity(0.16):.clear,in:RoundedRectangle(cornerRadius:8))
                        }.buttonStyle(.plain).accessibilityLabel("병합 \(i+1): \(url.lastPathComponent)")
                    }
                }
            }.frame(height:180).background(.black.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
            HStack {
                Button("PDF 추가",action:add)
                Spacer()
                Button { move(-1) } label:{ Image(systemName:"arrow.up") }.accessibilityLabel("위로 이동").disabled(selected == nil || selected == 0)
                Button { move(1) } label:{ Image(systemName:"arrow.down") }.accessibilityLabel("아래로 이동").disabled(selected == nil || selected == files.count-1)
                Button("제거") { if let selected { files.remove(at:selected);self.selected=nil } }.disabled(selected == nil)
            }.buttonStyle(.glass)
            Toggle("가로폭 자동 균일화",isOn:$uniform)
            ToolNote(uniform ? "가장 넓은 페이지에 맞춰 비율을 유지합니다. 주석이 있는 문서는 폭 변경을 지원하지 않습니다." : "각 문서의 원래 페이지 크기를 유지합니다.")
        }.onAppear { files=model.file.selection.filter { FileInfo(url:$0).kind == .pdf } }
    }
    private func add() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.pdf];panel.allowsMultipleSelection=true;panel.canChooseDirectories=false;panel.prompt="추가"
        RingWindowController.chooseFiles(panel) { urls in
            files.append(contentsOf:urls);selected=files.count-1
        }
    }
    private func move(_ step:Int) { guard let index=selected,files.indices.contains(index+step) else { return };files.swapAt(index,index+step);selected=index+step }
}

private struct PDFPagesPanel:View {
    @ObservedObject var model:RingModel
    let split:Bool
    @State private var count:Int?
    @State private var spec=""
    @State private var remove=false
    @State private var loadError:String?
    var body:some View {
        ToolForm(model:model,title:split ? "PDF 분할":"PDF 페이지 정리",ready:count != nil,operation:{
            guard let count else { throw EngineError.invalid("페이지를 먼저 읽어야 해요.") }
            let groups=try ToolSettings.pageGroups(spec,count:count)
            if split { return .pdfSplit(groups.map { $0.first!...$0.last! }) }
            let listed=groups.flatMap { $0 }
            let excluded=Set(listed)
            let pages=remove ? (0..<count).filter { !excluded.contains($0) }:listed
            guard !pages.isEmpty else { throw EngineError.invalid("최소 한 페이지를 남겨 주세요.") }
            return .pdfPages(pages)
        }) {
            ToolNote(count.map { "전체 \($0)페이지 · 번호는 1부터 시작합니다." } ?? (loadError ?? "페이지 수를 읽는 중…"))
            if !split { Picker("작업",selection:$remove) { Text("순서 지정·추출").tag(false);Text("페이지 삭제").tag(true) }.pickerStyle(.segmented).labelsHidden() }
            TextField(split ? "예: 1-3, 4-6, 8":"예: 3, 1-2, 5",text:$spec).textFieldStyle(.roundedBorder).accessibilityLabel("페이지 범위")
            ToolNote(split ? "쉼표로 나눈 각 범위를 별도의 PDF로 저장합니다. 예: 1-3, 4-6 → PDF 2개." : (remove ? "입력한 페이지를 제외하고 나머지를 원래 순서로 저장합니다." : "입력한 순서대로 저장합니다. 중복 번호는 페이지를 복제하고, 생략한 페이지는 포함하지 않습니다."))
        }.task {
            do { let url=model.file.url;count=try await Task.detached { try PDFEngine.open(url).pageCount }.value }
            catch { loadError=error.localizedDescription }
        }
    }
}

private struct DocumentPanel:View {
    @ObservedObject var model:RingModel
    let format:ImageFormat
    @State private var paper="A4"
    @State private var margin="36"
    @State private var dpi="200"
    var body:some View {
        ToolForm(model:model,title:"\(format.rawValue.uppercased())로 문서 변환",operation:{
            let page=paper == "A4" ? CGSize(width:595.28,height:841.89):CGSize(width:612,height:792)
            let m=try ToolSettings.number(margin,name:"여백",range:0...140),resolution=try ToolSettings.number(dpi,name:"해상도",range:72...600)
            return .renderDocument(format:format,options:.init(pageSize:page,margin:m,dpi:resolution))
        }) {
            PanelRow(label:"용지") { Picker("용지",selection:$paper) { Text("A4").tag("A4");Text("Letter").tag("Letter") }.labelsHidden() }
            PanelRow(label:"여백") { TextField("36",text:$margin).textFieldStyle(.roundedBorder).accessibilityLabel("문서 여백");Text("pt") }
            if format != .pdf { PanelRow(label:"해상도") { TextField("200",text:$dpi).textFieldStyle(.roundedBorder).accessibilityLabel("문서 해상도");Text("dpi") } }
            ToolNote(format == .pdf ? "텍스트와 선을 유지한 벡터 PDF를 만듭니다." : "문서를 페이지별 이미지로 만들어 폴더에 저장합니다.")
            ToolNote("원격 이미지·스크립트는 불러오지 않습니다. 복잡한 Word 배치는 흐름에 맞게 재배치될 수 있습니다.")
        }
    }
}

private struct VideoToolPanel:View {
    enum Tool { case trim,compress,animation(AnimationFormat) }
    @ObservedObject var model:RingModel
    let tool:Tool
    @State private var duration:Double?
    @State private var loadError:String?
    @State private var start="0"
    @State private var end=""
    @State private var size="10"
    @State private var unit:Int64=1_000_000
    @State private var codec="HEVC"
    @State private var fps="15"
    @State private var dimension="640"
    @State private var target=false
    private var title:String { switch tool { case .trim:return "비디오 구간 자르기";case .compress:return "비디오 용량 줄이기";case .animation(let f):return "\(f.rawValue.uppercased()) 애니메이션" } }
    var body:some View {
        ToolForm(model:model,title:title,ready:duration != nil,operation:operation) {
            ToolNote(duration.map { "영상 길이 \(String(format:"%.2f",$0))초" } ?? (loadError ?? "영상 정보를 읽는 중…"))
            switch tool {
            case .trim:
                timeFields
                ToolNote("원본 코덱을 유지한 MOV로 저장합니다. 샘플·키프레임과 컨테이너 편집 목록을 사용합니다.")
            case .compress:
                PanelRow(label:"목표") { SizeFields(value:$size,unit:$unit) }
                PanelRow(label:"코덱") { Picker("코덱",selection:$codec) { Text("HEVC · 작은 용량").tag("HEVC");Text("H.264 · 호환성").tag("H264") }.labelsHidden() }
                ToolNote("용량에 맞춰 품질과 해상도를 조절합니다. HDR과 다중 비디오 트랙은 지원하지 않습니다.")
            case .animation(let f):
                timeFields
                PanelRow(label:"프레임") { TextField("15",text:$fps).textFieldStyle(.roundedBorder).accessibilityLabel("애니메이션 FPS");Text("fps") }
                PanelRow(label:"최대 변") { TextField("640",text:$dimension).textFieldStyle(.roundedBorder).accessibilityLabel("애니메이션 최대 변");Text("px") }
                Toggle("목표 용량 지정",isOn:$target)
                if target { PanelRow(label:"용량") { SizeFields(value:$size,unit:$unit) } }
                ToolNote(target ? "목표에 맞춰 크기·FPS·품질을 추가로 낮출 수 있습니다. 최대 1,800프레임입니다." : "최대 1,800프레임입니다. \(f == .gif ? "GIF는 256색과 디더링을 사용합니다.":"WebP는 전체 색상의 애니메이션으로 저장합니다.")")
            }
        }.task {
            do {
                let asset=AVURLAsset(url:model.file.url),d=try await asset.load(.duration)
                guard d.seconds.isFinite,d.seconds>0,!((try await asset.loadTracks(withMediaType:.video)).isEmpty) else { throw EngineError.unsupported("재생 가능한 비디오 트랙이 없어요.") }
                duration=d.seconds
                if case .animation=tool { end=String(format:"%.2f",min(5,d.seconds));size="2" }
                else { end=String(format:"%.3f",d.seconds) }
            } catch { loadError=error.localizedDescription }
        }
    }
    private var timeFields:some View {
        Group {
            PanelRow(label:"시작") { TextField("0",text:$start).textFieldStyle(.roundedBorder).accessibilityLabel("시작 시간") }
            PanelRow(label:"종료") { TextField("초 또는 0:30",text:$end).textFieldStyle(.roundedBorder).accessibilityLabel("종료 시간") }
        }
    }
    private func operation() throws -> EngineOperation {
        guard let duration else { throw EngineError.invalid("영상 정보를 읽는 중이에요.") }
        if case .compress=tool { return .video(.compress(targetBytes:try ToolSettings.bytes(size,unit:unit),codec:codec == "HEVC" ? .hevc:.h264)) }
        let from=try ToolSettings.time(start,name:"시작"),to=try ToolSettings.time(end,name:"종료")
        guard to>from,to<=duration+0.001 else { throw EngineError.invalid("종료는 시작보다 늦고 영상 길이 이내여야 해요.") }
        if case .trim=tool { return .video(.trim(start:from,end:min(duration,to))) }
        if case .animation(let format)=tool {
            let frames=try ToolSettings.number(fps,name:"FPS",range:1...30),limit=try ToolSettings.integer(dimension,name:"최대 변",range:16...1920)
            guard (to-from)*frames<=1800 else { throw EngineError.invalid("선택 구간은 최대 1,800프레임이어야 해요. 구간이나 FPS를 줄여 주세요.") }
            return .video(.animation(.init(format:format,fps:frames,maxDimension:limit,targetBytes:target ? try ToolSettings.bytes(size,unit:unit):nil,start:from,duration:min(duration,to)-from)))
        }
        throw EngineError.invalid("비디오 작업 오류")
    }
}

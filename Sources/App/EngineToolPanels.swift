import SwiftUI
import AppKit
import PDFKit
import AVFoundation
import AVKit
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
    var width:CGFloat = 460
    var ready=true
    var buttonTitle="저장"
    let operation:() throws -> EngineOperation
    @ViewBuilder var content:Content
    @State private var error:String?
    var body:some View {
        GlassPanel(title:title,subtitle:model.file.name,width:width,onClose:model.backToRing) {
            VStack(alignment:.leading,spacing:14) {
                content
                if let error {
                    Text(error).font(.system(size:12)).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)
                        .accessibilityIdentifier("tool.validation")
                }
                HStack(spacing:8) {
                    Spacer()
                    Button("취소", action: model.backToRing)
                        .buttonStyle(.glass)
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
            PanelRow(label:"원본") { Text(model.file.sizeText).font(.system(size:13,weight:.medium)).foregroundStyle(.secondary) }
            if mode != .lossless {
                PanelRow(label:"형식") { Picker("출력 형식",selection:$format) { ForEach([ImageFormat.jpg,.webp,.heic],id:\.self) { Text($0.rawValue.uppercased()).tag($0) } }.labelsHidden() }
                if mode == .target {
                    PanelRow(label:"용량") { SizeFields(value:$size,unit:$unit) }
                } else {
                    PanelRow(label:"품질") {
                        Slider(value:$quality,in:1...100).accessibilityLabel("이미지 품질")
                        Text("\(Int(quality))%").monospacedDigit().frame(width:40)
                    }
                }
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
    @State private var width:String
    @State private var height:String
    @State private var percent="50"
    @State private var locked=true
    private let original:CGSize

    init(model: RingModel) {
        self.model = model
        let sz = pixelSize(of: model.file.url)
        self.original = sz
        _width = State(initialValue: String(Int(sz.width)))
        _height = State(initialValue: String(Int(sz.height)))
    }

    var body:some View {
        ToolForm(model:model,title:"이미지 크기 조절",operation:{
            if mode == "비율" { return .edit(.resizeScale(try ToolSettings.number(percent,name:"비율",range:0.01...10000)/100)) }
            let w=try ToolSettings.integer(width,name:"너비",range:1...65535)
            let h=locked ? max(1,Int((Double(w)*original.height/original.width).rounded())) : try ToolSettings.integer(height,name:"높이",range:1...65535)
            guard h<=65535,Int64(w)*Int64(h)<=52_000_000 else { throw EngineError.invalid("결과 크기는 52MP 이하여야 해요.") }
            return .edit(.resize(width:w,height:h))
        }) {
            PanelRow(label:"원본") { Text("\(Int(original.width)) × \(Int(original.height)) px").font(.system(size:13,weight:.medium)).foregroundStyle(.secondary) }
            Picker("입력 방식",selection:$mode) { Text("픽셀").tag("픽셀");Text("비율").tag("비율") }.pickerStyle(.segmented).labelsHidden()
            if mode == "픽셀" {
                PanelRow(label:"너비") { TextField("px",text:$width).textFieldStyle(.roundedBorder).accessibilityLabel("너비 픽셀");Text("px") }
                PanelRow(label:"높이") {
                    if locked { Text("\(calculatedHeight)px").foregroundStyle(.secondary) }
                    else { TextField("px",text:$height).textFieldStyle(.roundedBorder).accessibilityLabel("높이 픽셀");Text("px") }
                }
                Toggle("원본 종횡비 유지",isOn:$locked)
            } else { PanelRow(label:"배율") { TextField("50",text:$percent).textFieldStyle(.roundedBorder).accessibilityLabel("리사이즈 비율");Text("%") } }
        }
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
            return .pdfSmartCompress(.init(maxImageDimension:try ToolSettings.integer(dimension,name:"이미지 긴 변",range:64...16384),jpegQuality:quality/100))
        }) {
            Picker("압축 방식",selection:$smart) { Text("이미지 최적화").tag(true);Text("무손실 정리").tag(false) }.pickerStyle(.segmented).labelsHidden()
            PanelRow(label:"원본") { Text(model.file.sizeText).font(.system(size:13,weight:.medium)).foregroundStyle(.secondary) }
            if smart {
                PanelRow(label:"긴 변") { TextField("2000",text:$dimension).textFieldStyle(.roundedBorder).accessibilityLabel("PDF 이미지 긴 변");Text("px") }
                PanelRow(label:"품질") {
                    Slider(value:$quality,in:5...100).accessibilityLabel("PDF 이미지 품질")
                    Text("\(Int(quality))%").monospacedDigit().frame(width:40)
                }
            }
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
            PanelRow(label:"페이지") { Text(count.map { "전체 \($0)페이지" } ?? (loadError ?? "읽는 중…")).font(.system(size:13,weight:.medium)).foregroundStyle(.secondary) }
            if !split { Picker("작업",selection:$remove) { Text("순서 지정·추출").tag(false);Text("페이지 삭제").tag(true) }.pickerStyle(.segmented).labelsHidden() }
            TextField(split ? "예: 1-3, 4-6, 8":"예: 3, 1-2, 5",text:$spec).textFieldStyle(.roundedBorder).accessibilityLabel("페이지 범위")
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
        }
    }
}

private struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFrameSteppingButtons = false
        view.showsSharingServiceButton = false
        return view
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

private struct FilmstripTrimBar: View {
    let thumbnails: [NSImage]
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    @Binding var currentTime: Double
    let onSeek: (Double) -> Void

    private let handleWidth: CGFloat = 16
    private let barHeight: CGFloat = 46
    private let borderHeight: CGFloat = 3.5
    private let cornerRadius: CGFloat = 8

    @State private var dragInitialStart: Double?
    @State private var dragInitialEnd: Double?

    var body: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            let d = max(0.01, duration)
            let sFrac = max(0, min(1, start / d))
            let eFrac = max(0, min(1, (end > 0 ? end : d) / d))
            let cFrac = max(0, min(1, currentTime / d))

            let innerW = max(1, totalW - 2 * handleWidth)
            let startX = CGFloat(sFrac) * innerW
            let endX = max(startX + 2 * handleWidth, CGFloat(eFrac) * innerW + 2 * handleWidth)
            let playheadX = handleWidth + CGFloat(cFrac) * innerW

            let trimRect = CGRect(x: startX, y: 0, width: endX - startX, height: barHeight)
            let cutoutRect = CGRect(
                x: trimRect.minX + handleWidth,
                y: borderHeight,
                width: max(0, trimRect.width - 2 * handleWidth),
                height: barHeight - 2 * borderHeight
            )

            ZStack(alignment: .leading) {
                // 1. Filmstrip thumbnails + outside dimmed overlays, all clipped to the same rounded rect
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        if thumbnails.isEmpty {
                            Rectangle()
                                .fill(Color.black.opacity(0.35))
                        } else {
                            ForEach(0..<thumbnails.count, id: \.self) { idx in
                                Image(nsImage: thumbnails[idx])
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: totalW / CGFloat(thumbnails.count), height: barHeight)
                                    .clipped()
                            }
                        }
                    }
                    .frame(width: totalW, height: barHeight)

                    // Left outside dimmed region (extends under the left handle so rounded corners have no bright gap)
                    Rectangle()
                        .fill(Color.black.opacity(0.65))
                        .frame(width: max(0, trimRect.minX + cornerRadius), height: barHeight)

                    // Right outside dimmed region (extends under the right handle so rounded corners have no bright gap)
                    Rectangle()
                        .fill(Color.black.opacity(0.65))
                        .frame(width: max(0, totalW - (trimRect.maxX - cornerRadius)), height: barHeight)
                        .offset(x: max(0, trimRect.maxX - cornerRadius))
                }
                .frame(width: totalW, height: barHeight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .allowsHitTesting(false)

                // 2. Playhead (white line inside cutout)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: barHeight - 2 * borderHeight)
                    .shadow(color: .black.opacity(0.55), radius: 1, x: 0, y: 0)
                    .offset(x: min(max(trimRect.minX + handleWidth, playheadX - 1), max(trimRect.minX + handleWidth, trimRect.maxX - handleWidth - 2)))
                    .allowsHitTesting(false)

                // 3. Unified Yellow Trim Frame + Handles (single even-odd path: zero corner steps or seams)
                Path { p in
                    p.addPath(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).path(in: trimRect))
                    if cutoutRect.width > 0.5 {
                        p.addPath(RoundedRectangle(cornerRadius: 2.5, style: .continuous).path(in: cutoutRect))
                    }
                }
                .fill(Color(red: 1.0, green: 0.8, blue: 0.0), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                // 4. Left Handle Grip & Drag Target
                ZStack {
                    Color.clear
                    Capsule()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 2.5, height: 16)
                }
                .frame(width: handleWidth, height: barHeight)
                .contentShape(Rectangle())
                .offset(x: trimRect.minX)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if dragInitialStart == nil { dragInitialStart = start }
                            let delta = Double(g.translation.width / innerW) * d
                            let newStart = (dragInitialStart ?? start) + delta
                            start = max(0, min(end - 0.2, newStart))
                            onSeek(start)
                        }
                        .onEnded { _ in
                            dragInitialStart = nil
                        }
                )

                // 5. Right Handle Grip & Drag Target
                ZStack {
                    Color.clear
                    Capsule()
                        .fill(Color.black.opacity(0.55))
                        .frame(width: 2.5, height: 16)
                }
                .frame(width: handleWidth, height: barHeight)
                .contentShape(Rectangle())
                .offset(x: trimRect.maxX - handleWidth)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if dragInitialEnd == nil { dragInitialEnd = end }
                            let delta = Double(g.translation.width / innerW) * d
                            let newEnd = (dragInitialEnd ?? end) + delta
                            end = min(d, max(start + 0.2, newEnd))
                            onSeek(end)
                        }
                        .onEnded { _ in
                            dragInitialEnd = nil
                        }
                )
            }
        }
        .frame(height: barHeight)
    }
}

private struct VideoToolPanel:View {
    enum Tool { case trim,compress,animation(AnimationFormat) }
    @ObservedObject var model:RingModel
    let tool:Tool
    @State private var duration:Double?
    @State private var startVal:Double = 0
    @State private var endVal:Double = 1
    @State private var size="10"
    @State private var unit:Int64=1_000_000
    @State private var codec="HEVC"
    @State private var fps=""
    @State private var sourceFPS: Double?
    @State private var dimension="640"
    @State private var compressionDimension=""
    @State private var cropRatio=VideoCropRatio.free
    @State private var cropPortrait=false
    /// Normalized to the upright frame, top-left origin, as the engine expects.
    @State private var cropRect=CGRect(x:0,y:0,width:1,height:1)
    /// Upright source size and audio presence, for the output-resolution preview.
    @State private var sourceSize:CGSize?
    @State private var sourceHasAudio=false
    @State private var target=false
    @State private var player:AVPlayer?
    @State private var isPlaying=false
    @State private var currentTime=0.0
    @State private var timeObserver:Any?
    @State private var thumbnails:[NSImage]=[]

    private var title:String {
        switch tool {
        case .trim:return "비디오 자르기"
        case .compress:return "비디오 용량 줄이기"
        case .animation(let f):return "\(f.rawValue.uppercased()) 변환"
        }
    }

    private func formatSeconds(_ s: Double) -> String {
        let mins = Int(s) / 60
        let secs = Int(s) % 60
        let tenths = Int((s.truncatingRemainder(dividingBy: 1)) * 10)
        return String(format: "%02d:%02d.%d", mins, secs, tenths)
    }

    private func seek(to seconds: Double) {
        player?.pause()
        isPlaying = false
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    private func togglePlay() {
        guard let p = player else { return }
        if isPlaying {
            p.pause()
            isPlaying = false
        } else {
            let s = startVal
            let e = endVal > 0 ? endVal : (duration ?? 0)
            if currentTime < s || currentTime >= e {
                p.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            p.play()
            isPlaying = true
        }
    }

    nonisolated private static func extractThumbnails(url: URL, total: Double, count: Int = 14) -> [NSImage] {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 100, height: 60)

        var images: [NSImage] = []
        images.reserveCapacity(count)
        for i in 0..<count {
            let t = CMTime(seconds: total * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
            if let cg = try? generator.copyCGImage(at: t, actualTime: nil) {
                images.append(NSImage(cgImage: cg, size: NSSize(width: 80, height: 50)))
            }
        }
        return images
    }

    private var videoCrop:VideoCrop { VideoCrop(ratio:cropRatio,portrait:cropPortrait,rect:cropRect) }
    private var cropAspect:Double? {
        guard let sourceSize else { return nil }
        return videoCrop.aspect(width:sourceSize.width,height:sourceSize.height)
    }
    private var cropsVideo:Bool { if case .trim=tool { return false }; return true }

    /// The player and, outside trimming, the Photos-style crop frame over the
    /// exact rectangle the video occupies.
    /// The preview box takes the video's own shape (no side letterbox): full
    /// panel width, as tall as the aspect needs, up to `maxHeight`. A tall
    /// video beyond that narrows the box instead of padding it.
    private func previewSize(maxHeight:CGFloat) -> CGSize {
        // 460pt is the ToolForm content width (500 minus its 20pt margins).
        let width:CGFloat = 460
        let aspect = sourceSize.map { max(0.2,min(5,$0.width/max(1,$0.height))) } ?? 16.0/9
        let height = min(maxHeight, width/aspect)
        return CGSize(width: min(width, height*aspect), height: height)
    }

    private func videoPreview(maxHeight:CGFloat) -> some View {
        let radius: CGFloat = cropsVideo ? 0 : 12
        return ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.black.opacity(0.4))
            if let player {
                VideoPlayerView(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
            if cropsVideo, let sourceSize {
                GeometryReader { geo in
                    CropFrame(crop:$cropRect,bounds:CropFrame.fitted(sourceSize,in:geo.size),pixels:sourceSize,aspect:cropAspect)
                }
                .accessibilityIdentifier("video.cropFrame")
            }
        }
        .frame(width: previewSize(maxHeight: maxHeight).width, height: previewSize(maxHeight: maxHeight).height)
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: sourceSize)
    }

    private var cropControls:some View {
        PanelRow(label:"자르기") {
            CropRatioControls(ratio:$cropRatio,portrait:$cropPortrait,
                              size:sourceSize.map { let r=videoCrop.pixelRect(width:Int($0.width.rounded()),height:Int($0.height.rounded())); return "\(Int(r.width))×\(Int(r.height))" },
                              canReset:!videoCrop.isFull) {
                withAnimation(.snappy) { cropRatio = .free; cropRect=CGRect(x:0,y:0,width:1,height:1) }
            }
        }
        .onChange(of:cropRatio) { _,_ in fitCropToRatio() }
        .onChange(of:cropPortrait) { _,_ in fitCropToRatio() }
    }

    private func fitCropToRatio() {
        guard let sourceSize,let aspect=cropAspect else { return }
        withAnimation(.snappy) { cropRect=CropFrame.largest(aspect:aspect,pixels:sourceSize,around:cropRect) }
    }

    @ViewBuilder
    private func trimTimelineSection(videoMaxHeight: CGFloat, middlePrefix: String) -> some View {
        VStack(spacing: 10) {
            videoPreview(maxHeight: videoMaxHeight)

            HStack(spacing: 12) {
                Button(action: togglePlay) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)

                FilmstripTrimBar(
                    thumbnails: thumbnails,
                    duration: duration ?? 1,
                    start: $startVal,
                    end: $endVal,
                    currentTime: $currentTime,
                    onSeek: seek
                )
            }

            HStack {
                Text("시작 " + formatSeconds(startVal))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(middlePrefix + " " + String(format: "%.2f초", max(0, endVal - startVal)))
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color(red: 1.0, green: 0.8, blue: 0.0))
                Spacer()
                Text("종료 " + formatSeconds(endVal))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    var body:some View {
        ToolForm(model:model,title:title,width:500,ready:duration != nil,operation:operation) {
            switch tool {
            case .trim:
                trimTimelineSection(videoMaxHeight: 380, middlePrefix: "선택 구간")

            case .compress:
                videoPreview(maxHeight:340)
                cropControls
                PanelRow(label:"원본") { Text(model.file.sizeText).foregroundStyle(.secondary) }
                PanelRow(label:"목표") { SizeFields(value:$size,unit:$unit) }
                PanelRow(label:"긴 변") {
                    HStack(spacing:8) {
                        TextField("자동",text:$compressionDimension).textFieldStyle(.roundedBorder)
                            .frame(width:72).accessibilityLabel("비디오 긴 변").accessibilityIdentifier("video.maxDimension")
                        Text("px")
                        Spacer(minLength:4)
                        DimensionPresets(text:$compressionDimension,values:[720,1280,1920],automatic:true,prefix:"video")
                    }
                }
                ResolutionNote(text:compressionResolution)
                PanelRow(label:"코덱") { Picker("코덱",selection:$codec) { Text("HEVC · 고효율/작은 용량").tag("HEVC");Text("H.264 · 범용 호환성").tag("H264") }.labelsHidden() }

            case .animation(let format):
                trimTimelineSection(videoMaxHeight: 270, middlePrefix: "구간")
                cropControls
                PanelRow(label:"프레임") {
                    TextField("원본",text:$fps).textFieldStyle(.roundedBorder)
                        .frame(width:72).accessibilityLabel("애니메이션 FPS")
                        .accessibilityIdentifier("animation.fps")
                    Text("fps")
                    Spacer(minLength:4)
                    ForEach([24,30,60],id:\.self) { rate in
                        Button("\(rate)") { fps=String(rate) }
                            .buttonStyle(.glass)
                            .tint(Double(fps)==Double(rate) ? .accentColor:nil)
                            .accessibilityLabel("\(rate)fps 프리셋")
                            .accessibilityIdentifier("animation.fps.\(rate)")
                    }
                }
                if let sourceFPS {
                    Button("원본 \(AnimationOptions.frameRateText(sourceFPS))fps") {
                        fps=AnimationOptions.frameRateText(sourceFPS)
                    }
                    .buttonStyle(.plain).font(.system(size:11)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("animation.fps.source")
                }
                if let value=Double(fps), value>AnimationOptions.maximumFPS {
                    Text("변환은 최대 60fps까지 지원해요. 프리셋으로 프레임률을 선택해 주세요.")
                        .font(.system(size:11)).foregroundStyle(.secondary)
                } else if format == .gif, (Double(fps) ?? 0)>50 {
                    Text("60fps GIF는 일부 뷰어에서 느리게 재생될 수 있어요. 일정한 재생 속도에는 WebP를 권장해요.")
                        .font(.system(size:11)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
                PanelRow(label:"긴 변") {
                    HStack(spacing:8) {
                        TextField("640",text:$dimension).textFieldStyle(.roundedBorder)
                            .frame(width:72).accessibilityLabel("애니메이션 긴 변")
                            .accessibilityIdentifier("animation.maxDimension")
                        Text("px")
                        Spacer(minLength:4)
                        DimensionPresets(text:$dimension,values:[480,720,1080],automatic:false,prefix:"animation")
                    }
                }
                ResolutionNote(text:animationResolution)
                Toggle("목표 용량 지정",isOn:$target)
                if target { PanelRow(label:"용량") { SizeFields(value:$size,unit:$unit) } }
            }
        }.task {
            let url = model.file.url
            let asset=AVURLAsset(url:url)
            guard let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0 else { return }
            if let track=try? await asset.loadTracks(withMediaType:.video).first,
               let natural=try? await track.load(.naturalSize),let transform=try? await track.load(.preferredTransform) {
                let shown=natural.applying(transform)
                sourceSize=CGSize(width:abs(shown.width),height:abs(shown.height))
                // Like Photos, presets start in the frame's own orientation.
                cropPortrait=abs(shown.height)>abs(shown.width)
            }
            sourceHasAudio = !((try? await asset.loadTracks(withMediaType:.audio))?.isEmpty ?? true)
            let total = d.seconds
            if case .animation = tool {
                sourceFPS=try? await MediaEngine.sourceFrameRate(asset)
                guard !Task.isCancelled else { return }
                // A preset or edit made while metadata loads belongs to the user.
                if fps.isEmpty { fps=AnimationOptions.frameRateText(sourceFPS ?? 30) }
            }
            guard !Task.isCancelled else { return }
            duration = total
            startVal = 0
            if case .animation = tool { endVal = min(5, total); size = "2" }
            else { endVal = total }

            let p = AVPlayer(url: url)
            player = p
            timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 15), queue: .main) { time in
                currentTime = time.seconds
                let s = startVal
                let e = endVal > 0 ? endVal : total
                if isPlaying && time.seconds >= e {
                    p.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            let imgs = await Task.detached(priority: .userInitiated) {
                Self.extractThumbnails(url: url, total: total)
            }.value
            thumbnails = imgs
        }
        .onDisappear {
            if let p = player, let obs = timeObserver { p.removeTimeObserver(obs) }
            player?.pause()
            player = nil
        }
    }

    /// Same geometry as the engine, so the shown size is what gets written.
    private var animationResolution:String? {
        guard let sourceSize,let limit=Int(dimension.trimmingCharacters(in:.whitespaces)),(16...1920).contains(limit) else { return nil }
        let size=VideoCropGeometry.animationSize(width:sourceSize.width,height:sourceSize.height,crop:videoCrop,maxDimension:limit)
        return "결과 \(size.width)×\(size.height)" + (target ? " · 목표 용량을 넘으면 줄어들어요":"")
    }
    private var compressionResolution:String? {
        guard let sourceSize,let duration,duration>0,let bytes=try? ToolSettings.bytes(size,unit:unit) else { return nil }
        let text=compressionDimension.trimmingCharacters(in:.whitespaces)
        let limit=text.isEmpty ? nil:Int(text)
        guard text.isEmpty || (limit.map { (16...8192).contains($0) } ?? false) else { return nil }
        let rate=VideoCropGeometry.videoBitrate(targetBytes:bytes,duration:duration,audio:sourceHasAudio)
        guard rate>=100000 else { return nil }
        let size=VideoCropGeometry.compressedSize(width:sourceSize.width,height:sourceSize.height,crop:videoCrop,maxDimension:limit,bitrate:Int(min(rate,100_000_000)))
        // A second attempt can lower the bitrate cap when the first file is too large.
        return "결과 \(size.width)×\(size.height) · 목표 용량을 넘으면 줄어들어요"
    }

    private func operation() throws -> EngineOperation {
        guard let duration else { throw EngineError.invalid("영상 정보를 읽는 중이에요.") }
        if case .compress=tool {
            let text=compressionDimension.trimmingCharacters(in:.whitespacesAndNewlines)
            let maxDimension=text.isEmpty ? nil:try ToolSettings.integer(text,name:"긴 변",range:16...8192)
            return .video(.compress(.init(targetBytes:try ToolSettings.bytes(size,unit:unit),codec:codec == "HEVC" ? .hevc:.h264,maxDimension:maxDimension,crop:videoCrop)))
        }
        let from = startVal
        let to = endVal > 0 ? endVal : duration
        guard to > from, to <= duration + 0.001 else { throw EngineError.invalid("종료는 시작보다 늦고 영상 길이 이내여야 해요.") }
        if case .trim=tool { return .video(.trim(start:from,end:min(duration,to))) }
        if case .animation(let format)=tool {
            let frames=try ToolSettings.number(fps,name:"FPS",range:1...AnimationOptions.maximumFPS),limit=try ToolSettings.integer(dimension,name:"긴 변",range:16...1920)
            guard (to-from)*frames<=Double(AnimationOptions.maximumFrames) else { throw EngineError.invalid("선택 구간은 최대 1,800프레임이어야 해요. 구간이나 FPS를 줄여 주세요.") }
            return .video(.animation(.init(format:format,fps:frames,maxDimension:limit,targetBytes:target ? try ToolSettings.bytes(size,unit:unit):nil,start:from,duration:min(duration,to)-from,crop:videoCrop)))
        }
        throw EngineError.invalid("비디오 작업 오류")
    }
}

/// Long-side presets beside a pixel field. `automatic` adds a button that
/// clears the field (the engine then picks the size).
private struct DimensionPresets:View {
    @Binding var text:String
    let values:[Int]
    let automatic:Bool
    let prefix:String
    var body:some View {
        HStack(spacing:6) {
            if automatic {
                Button("자동") { text="" }
                    .buttonStyle(.glass).tint(text.isEmpty ? .accentColor:nil)
                    .accessibilityIdentifier("\(prefix).maxDimension.auto")
            }
            ForEach(values,id:\.self) { value in
                Button(String(value)) { text=String(value) }
                    .buttonStyle(.glass)
                    .tint(Int(text)==value ? .accentColor:nil)
                    .accessibilityLabel("긴 변 \(value)px 프리셋")
                    .accessibilityIdentifier("\(prefix).maxDimension.\(value)")
            }
        }
    }
}

private struct ResolutionNote:View {
    let text:String?
    var body:some View {
        if let text {
            Text(text).font(.system(size:11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(maxWidth:.infinity,alignment:.trailing)
                .accessibilityIdentifier("video.resolution")
        }
    }
}

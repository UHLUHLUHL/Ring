import AppKit
import SwiftUI
import Combine

enum AnimatedImageTool: Hashable { case webp, crop, resize, speed, frame(ImageFormat), output(AnimationFormat) }

private actor AnimationPreviewSource {
    let url: URL
    private var decoder: AnimatedImageDecoder?
    init(url: URL) { self.url = url }
    func frame(_ index: Int) throws -> CGImage {
        try Task.checkCancellation()
        if decoder == nil { decoder = try AnimatedImageDecoder(url) }
        return try autoreleasepool { try decoder!.frame(index, preview: true) }
    }
}

/// No timer on the ring or while paused. Decode only the selected/next preview,
/// serially, and discard obsolete scrub requests before they reach ImageIO.
@MainActor
private final class AnimatedImagePlayback: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var index = 0
    @Published private(set) var playing = false
    @Published private(set) var error: String?
    private let source: AnimationPreviewSource
    private let info: AnimatedImageInfo
    private var loadTask: Task<Void, Never>?
    private var playTask: Task<Void, Never>?
    private var request = UUID()
    var rate = 1.0

    init(url: URL, info: AnimatedImageInfo) { source = AnimationPreviewSource(url: url); self.info = info }
    deinit { loadTask?.cancel(); playTask?.cancel() }

    func seek(_ frame: Int) {
        pause()
        loadTask?.cancel()
        index = min(max(frame, 0), info.frameCount - 1)
        let selected = index, token = UUID(); request = token
        loadTask = Task { [weak self, source] in
            do {
                let cg = try await source.frame(selected)
                try Task.checkCancellation()
                guard let self, self.request == token else { return }
                self.image = NSImage(cgImage: cg, size: .zero); self.error = nil
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, let self, self.request == token else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func toggle() {
        if playing { pause(); return }
        guard image != nil, error == nil else { return }
        loadTask?.cancel(); playing = true
        playTask = Task { [weak self, source, info] in
            do {
                var completedPlays = 0
                while !Task.isCancelled {
                    guard let self else { return }
                    let current = self.index, next = (current + 1) % info.frameCount
                    if next == 0 {
                        completedPlays += 1
                        if info.loopCount > 0 && completedPlays >= info.loopCount {
                            try await Task.sleep(for: .seconds(Double(info.durationsMS[current]) / 1000 / self.rate))
                            self.playing = false
                            return
                        }
                    }
                    let started = ProcessInfo.processInfo.systemUptime
                    let cg = try await source.frame(next)
                    let wait = Double(info.durationsMS[current]) / 1000 / self.rate - (ProcessInfo.processInfo.systemUptime - started)
                    if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                    try Task.checkCancellation()
                    self.index = next; self.image = NSImage(cgImage: cg, size: .zero)
                }
            } catch is CancellationError {} catch { self?.error = error.localizedDescription; self?.playing = false }
        }
    }
    func pause() { playTask?.cancel(); playTask = nil; playing = false }
    func stop() { pause(); loadTask?.cancel(); request = UUID() }
}

struct AnimatedImagePanel: View {
    @ObservedObject var model: RingModel
    let tool: AnimatedImageTool
    private let info: AnimatedImageInfo
    @StateObject private var playback: AnimatedImagePlayback
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var ratio = VideoCropRatio.free
    @State private var portrait = false
    @State private var width: String
    @State private var height: String
    @State private var locked = true
    @State private var validation: String?
    @State private var rate = 1.5
    private var frameFormat: ImageFormat? { if case .frame(let format) = tool { return format }; return nil }

    init(model: RingModel, tool: AnimatedImageTool) {
        self.model = model; self.tool = tool
        // Routed only after FileInfo's content-based animation inspection.
        let info = model.file.animation!
        self.info = info
        _playback = StateObject(wrappedValue: AnimatedImagePlayback(url: model.file.url, info: info))
        _width = State(initialValue: String(Int(info.size.width)))
        _height = State(initialValue: String(Int(info.size.height)))
        _portrait = State(initialValue: info.size.height > info.size.width)
    }

    private var title: String {
        switch tool {
        case .webp: return "움짤 WebP 변환"
        case .output(let format): return "움짤 \(format.rawValue.uppercased()) 변환"
        case .crop: return "움짤 자르기"
        case .resize: return "움짤 크기 조절"
        case .frame(let format): return "한 장 저장 · \(format.rawValue.uppercased())"
        case .speed: return "움짤 재생 속도"
        }
    }
    private var previewSize: CGSize {
        let aspect = max(1, info.size.width) / max(1, info.size.height)
        let width = min(432, 262 * aspect)
        return CGSize(width: width, height: width / aspect)
    }
    private var aspect: Double? { VideoCrop(ratio: ratio, portrait: portrait).aspect(width: info.size.width, height: info.size.height) }

    var body: some View {
        GlassPanel(title: title, subtitle: model.file.name, width: 480, onClose: back) {
            VStack(spacing: 14) {
                HStack(alignment: .center) {
                    Label("\(info.format) 움짤", systemImage: "play.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.quaternary, in: Capsule())
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(Int(info.size.width)) × \(Int(info.size.height)) · \(info.frameCount)프레임")
                        Text(String(format: "%.2f초 · %@", info.duration, info.loopCount == 0 ? "무한 반복" : "\(info.loopCount)회 재생"))
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                preview
                transport
                if tool == .crop {
                    PanelRow(label: "비율") {
                        CropRatioControls(ratio: $ratio, portrait: $portrait, size: nil,
                                          canReset: crop != CGRect(x: 0, y: 0, width: 1, height: 1) || ratio != .free) {
                            crop = CGRect(x: 0, y: 0, width: 1, height: 1); ratio = .free
                        }
                    }
                    .onChange(of: ratio) { _, _ in applyAspect() }
                    .onChange(of: portrait) { _, _ in applyAspect() }
                }
                if tool == .resize { resizeFields }
                if tool == .speed {
                    PanelRow(label: "속도") {
                        Picker("재생 속도", selection: $rate) {
                            ForEach([0.25, 0.5, 1.0, 1.5, 2.0, 4.0], id: \.self) { value in
                                Text("\(value.formatted())×").tag(value)
                            }
                        }.labelsHidden().accessibilityIdentifier("animation.speed")
                    }
                    Text(String(format: "%.2f초 → %.2f초 · 모든 프레임 유지", info.duration, info.duration / rate))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                outputDescription
                if let message = validation ?? playback.error ?? info.editingIssue {
                    Text(message).font(.system(size: 12)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("animation.validation")
                }
                HStack(spacing: 8) {
                    Spacer()
                    Button("취소", action: back).ringGlassButton()
                    Button(frameFormat.map { "\($0.rawValue.uppercased()) 한 장 저장" } ?? "\(outputFormat.rawValue.uppercased())로 저장", action: save)
                        .ringGlassButton(prominent: true).keyboardShortcut(.defaultAction)
                        .disabled(playback.image == nil || playback.error != nil || info.editingIssue != nil || model.isWorking)
                        .accessibilityIdentifier("animation.save")
                }
            }
        }
        .onAppear { playback.rate = tool == .speed ? rate : 1; playback.seek(0) }
        .onChange(of: rate) { _, value in playback.pause(); playback.rate = value }
        .onDisappear { playback.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in playback.pause() }
    }

    private var preview: some View {
        let size = previewSize
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.gray.opacity(0.12))
            Path { path in
                for y in stride(from: 0, to: Int(size.height), by: 12) {
                    for x in stride(from: 0, to: Int(size.width), by: 12) where (x / 12 + y / 12) % 2 == 0 {
                        path.addRect(CGRect(x: x, y: y, width: 12, height: 12))
                    }
                }
            }.fill(.gray.opacity(0.12))
            if let image = playback.image {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: size.width, height: size.height)
            } else {
                ProgressView().frame(width: size.width, height: size.height)
            }
            if tool == .crop {
                CropFrame(crop: $crop, bounds: CGRect(origin: .zero, size: size), pixels: info.size, aspect: aspect)
                    .onChange(of: crop) { _, _ in playback.pause() }
                if let rect = try? ImageEdits.rawRect(crop, width: Int(info.size.width), height: Int(info.size.height), orientation: 1) {
                    Text("\(Int(rect.width)) × \(Int(rect.height))")
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentColor, in: Capsule()).padding(10).allowsHitTesting(false)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: tool == .crop ? 0 : 14))
        .accessibilityLabel("움짤 미리보기")
    }

    private var transport: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Button { playback.toggle() } label: {
                    Image(systemName: playback.playing ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .ringGlassButton().accessibilityLabel(playback.playing ? "미리보기 일시 정지" : "움짤 미리보기 재생")
                .accessibilityIdentifier("animation.play").disabled(playback.image == nil || playback.error != nil)
                Slider(value: Binding(get: { Double(playback.index) }, set: { playback.seek(Int($0)) }),
                       in: 0...Double(info.frameCount - 1))
                    .accessibilityLabel("프레임 선택").accessibilityIdentifier("animation.timeline")
                Text(String(format: "%.2f / %.2f초", info.time(at: playback.index), info.duration))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 96, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Button { playback.seek(playback.index - 1) } label: { Image(systemName: "backward.frame") }
                    .disabled(playback.index == 0).accessibilityLabel("이전 프레임")
                Text("\(playback.index + 1) / \(info.frameCount) 프레임")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().accessibilityIdentifier("animation.frame")
                Button { playback.seek(playback.index + 1) } label: { Image(systemName: "forward.frame") }
                    .disabled(playback.index == info.frameCount - 1).accessibilityLabel("다음 프레임")
                Spacer()
                Text("재생을 눌러 움직임 확인").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }
    }

    private var resizeFields: some View {
        HStack(spacing: 10) {
            TextField("너비", text: $width).textFieldStyle(.roundedBorder).accessibilityLabel("움짤 너비")
                .onChange(of: width) { _, _ in updateHeight() }
            Text("×").foregroundStyle(.secondary)
            TextField("높이", text: $height).textFieldStyle(.roundedBorder).disabled(locked).accessibilityLabel("움짤 높이")
            Text("px").font(.system(size: 12)).foregroundStyle(.secondary)
            Toggle("비율 유지", isOn: $locked).toggleStyle(.checkbox).font(.system(size: 12))
                .onChange(of: locked) { _, _ in updateHeight() }
        }
    }

    private var outputDescription: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(frameFormat.map { "\($0.rawValue.uppercased()) · 선택한 한 장" } ?? "\(outputFormat.rawValue.uppercased()) · 움직임 유지",
                  systemImage: frameFormat != nil ? "photo" : "play.rectangle")
                .font(.system(size: 12, weight: .semibold))
            Text(explanation).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
    private var outputFormat: AnimationFormat {
        if case .output(let format) = tool { return format }; return .webp
    }
    private var explanation: String {
        if case .output = tool { return "모든 프레임을 무손실로 저장하고 재생 시간·반복·투명도를 유지해요. 용량은 커질 수 있어요." }
        if let format = frameFormat {
            return format == .jpg ? "선택한 프레임을 최고 품질 JPG로 저장해요. 투명한 영역은 흰색으로 저장돼요."
                : "선택한 프레임만 무손실 \(format.rawValue.uppercased())로 저장해요. 원본 움짤은 그대로 남아요."
        }
        if tool == .speed { return "프레임을 빼지 않고 재생 시간만 바꿔요. 무손실 WebP로 저장하며 반복·투명도·화질을 유지해요." }
        if tool == .webp && info.format == "WEBP" { return "이미 WebP예요. 원본 움직임과 화질을 그대로 복사해 새 파일로 저장해요." }
        if tool == .webp && info.format == "GIF" { return "GIF의 원본 화질을 유지해 무손실 WebP로 저장해요. 이미 사라진 색·디테일이 복원되지는 않으며, 용량은 달라질 수 있어요." }
        let action = tool == .crop ? "선택한 영역을 모든 프레임에 적용해요. " : ""
        return action + "\(info.format == "GIF" ? "GIF도 무손실 WebP로 저장해요. " : "무손실로 저장해요. ")재생 시간·반복·투명도를 유지하며, 용량은 커질 수 있어요."
    }
    private func updateHeight() {
        guard locked, let value = Int(width), value > 0, value <= 16383, info.size.width > 0 else { return }
        height = String(max(1, Int((Double(value) * info.size.height / info.size.width).rounded())))
    }
    private func applyAspect() {
        playback.pause()
        if let aspect { crop = CropFrame.largest(aspect: aspect, pixels: info.size, around: crop) }
    }
    private func back() { playback.stop(); model.backToRing() }
    private func save() {
        do {
            let edit: AnimatedImageEdit
            switch tool {
            case .webp: edit = .webp
            case .output(let format): edit = .output(format: format, edit: .webp)
            case .crop: edit = .crop(crop)
            case .frame(let format): edit = .frame(playback.index, format: format)
            case .speed: edit = .speed(rate)
            case .resize:
                let w = try ToolSettings.integer(width, name: "너비", range: 1...16383)
                let h = try ToolSettings.integer(height, name: "높이", range: 1...16383)
                guard Int64(w) * Int64(h) <= 52_000_000 else { throw EngineError.invalid("결과 크기는 52MP 이하여야 해요.") }
                edit = .resize(width: w, height: h)
            }
            playback.stop(); validation = nil; model.run(.animatedImage(edit))
        } catch { validation = error.localizedDescription }
    }
}

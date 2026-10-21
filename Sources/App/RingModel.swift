import AppKit
import QuickLookThumbnailing
import SwiftUI

@MainActor
final class RingModel: ObservableObject {
    enum Tab { case convert, edit }
    enum Tool: Hashable {
        case imageCompression, imageResize, imageMetadata
        case pdfCompression, pdfMerge, pdfPages, pdfSplit
        case document(ImageFormat), videoTrim, videoCompression, animation(AnimationFormat)
        case animatedImage(AnimatedImageTool)
    }
    enum Screen: Equatable { case ring, crop, addBackground, tool(Tool) }

    let file: FileInfo
    @Published var tab: Tab
    /// 0 = 변환 layout, 1 = 편집 layout; animated between the two on a tab switch.
    @Published var tabProgress: Double = 0
    @Published var hovered: Int?
    @Published var screen: Screen = .ring { didSet { if screen != oldValue { screenChanged(screen) } } }
    @Published var toast: String?
    @Published var thumbnail: NSImage?
    @Published var appeared = false
    enum RegionPurpose { case crop, redact, annotate(String) }
    @Published var regionPurpose: RegionPurpose = .crop
    @Published var isWorking = false
    @Published var isCancelling = false
    @Published var isCompleting = false
    /// Latest fraction reported by the engine. HubProgress interpolates between reports.
    @Published private(set) var progress: Double = 0
    private(set) var progressFrom: Double = 0
    private(set) var progressChangedAt = Date()
    private(set) var progressAnimationDuration: TimeInterval = 0.16
    private(set) var workStarted = Date()
    private var engineTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?

    var close: () -> Void = {}
    var screenChanged: (Screen) -> Void = { _ in }
    private var toastTask: Task<Void, Never>?

    init(file: FileInfo) {
        self.file = file
        tab = file.convertActions.isEmpty && !file.editActions.isEmpty ? .edit : .convert
        tabProgress = (tab == .edit) ? 1 : 0
        if file.kind == .pdf,file.selection.count>1 { tab = .edit;tabProgress = 1 }
        loadThumbnail()
    }

    var items: [RingAction] { tab == .convert ? file.convertActions : file.editActions }

    var hoveredAction: RingAction? {
        guard let i = hovered, items.indices.contains(i) else { return nil }
        return items[i]
    }

    func switchTab() {
        guard !file.convertActions.isEmpty, !file.editActions.isEmpty else { return }
        tab = (tab == .convert) ? .edit : .convert
        // Apple-style spring with a little bounce; the morph handles the slight overshoot.
        withAnimation(.spring(response: 0.5, dampingFraction: 0.74)) {
            hovered = nil // a lifted wedge settles back with the same spring
            tabProgress = (tab == .edit) ? 1 : 0
        }
    }

    func moveHover(_ delta: Int) {
        guard !items.isEmpty else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            hovered = ((hovered ?? (delta > 0 ? -1 : 0)) + delta + items.count) % items.count
        }
    }

    private static let panelTransition = Animation.easeOut(duration: 0.16)

    func activate(_ index: Int) {
        guard !isWorking, items.indices.contains(index) else { return }
        let action = items[index]
        switch action.kind {
        case .convert(let format):
            if file.kind == .animatedImage {
                withAnimation(Self.panelTransition) { screen = .tool(.animatedImage(.webp)) }
                return
            }
            if file.kind == .video, let format = AnimationFormat(rawValue: format.lowercased()) {
                withAnimation(Self.panelTransition) { screen = .tool(.animation(format)) }
                return
            }
            if let target = ImageFormat(rawValue: format.lowercased()) {
                if file.kind == .document {
                    withAnimation(Self.panelTransition) { screen = .tool(.document(target)) }
                    return
                }
                if target == .docx && file.kind == .pdf {
                    let alert=NSAlert();alert.messageText="PDF를 Word 문서로 변환"
                    alert.informativeText="페이지 보기와 편집용 텍스트를 함께 저장합니다. 페이지 보기는 300dpi 이미지로 만들어지며, Word에서 원본 벡터·배치를 그대로 편집할 수는 없습니다. 스캔 문서의 OCR에는 인식 오류가 있을 수 있습니다."
                    alert.addButton(withTitle:"변환");alert.addButton(withTitle:"취소")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                }
                run(.convert(target))
            }
        case .crop:
            regionPurpose = .crop
            if file.kind == .animatedImage {
                withAnimation(Self.panelTransition) { screen = .tool(.animatedImage(.crop)) }
                return
            }
            withAnimation(Self.panelTransition) { screen = .crop }
        case .addBackground:
            withAnimation(Self.panelTransition) { screen = .addBackground }
        case .tool:
            withAnimation(Self.panelTransition) {
                if file.kind == .animatedImage {
                    screen = .tool(.animatedImage(action.id == "frame" ? .frame : .resize))
                } else if action.id == "compress" {
                    switch file.kind {
                    case .image: screen = .tool(.imageCompression)
                    case .pdf: screen = .tool(.pdfCompression)
                    case .video: screen = .tool(.videoCompression)
                    default: break
                    }
                } else if file.kind == .video && action.id == "trim" {
                    screen = .tool(.videoTrim)
                } else if file.kind == .pdf && action.id == "merge" {
                    screen = .tool(.pdfMerge)
                } else if file.kind == .pdf && action.id == "pages" {
                    screen = .tool(.pdfPages)
                } else if file.kind == .pdf && action.id == "split" {
                    screen = .tool(.pdfSplit)
                } else if file.kind == .image && action.id == "resize" {
                    screen = .tool(.imageResize)
                } else if action.id == "metadata" {
                    screen = .tool(.imageMetadata)
                } else {
                    showToast("\(action.title) — 준비 중이에요", closeAfter: false)
                }
            }
        }
    }

    func run(_ operation: EngineOperation) {
        guard !isWorking else { return }
        toastTask?.cancel()
        toast = nil
        completionTask?.cancel()
        isCompleting = false
        isCancelling = false
        resetProgress()
        // Back on the ring (tool panels hand over here) so the hub can show the progress.
        withAnimation(RingMotion.sCurve(RingMotion.fold)) { screen = .ring; hovered = nil; isWorking = true }
        let job = EngineJob(source: file.url, operation: operation)
        // Retain the model until completion even when the ring is dismissed.
        engineTask = Task {
            let report: @Sendable (Double) -> Void = { [weak self] value in
                Task { @MainActor in self?.reportProgress(value) }
            }
            do {
                DebugLog.write("job start \(operation) \(job.source.lastPathComponent)")
                let output = try await EngineProgress.$handler.withValue(report) { try await RingEngine.shared.run(job) }
                DebugLog.write("job done \(output.url.lastPathComponent) \(String(format: "%.2f", output.seconds))s")
                reportProgress(1)
                engineTask = nil
                // Keep the folded hub in place: completion is a drawn check, not a new screen.
                withAnimation(.easeOut(duration:0.18)) { isCompleting=true;isCancelling=false }
                completionTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(RingMotion.successVisible))
                    guard !Task.isCancelled else { return }
                    self?.close()
                }
            } catch is CancellationError {
                withAnimation(RingMotion.sCurve(RingMotion.fold)) { isWorking=false;isCancelling=false;resetProgress() }
                engineTask=nil
                showToast("취소했어요 · 결과를 저장하지 않았어요",closeAfter:false)
            } catch {
                DebugLog.write("job failed \(error)")
                withAnimation(RingMotion.sCurve(RingMotion.fold)) { isWorking = false }
                engineTask = nil
                isCancelling=false
                let alert = NSAlert()
                alert.messageText = "저장하지 못했어요"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func resetProgress() {
        let now = Date()
        progress = 0
        progressFrom = 0
        progressChangedAt = now
        progressAnimationDuration = 0.16
        workStarted = now
    }

    private func reportProgress(_ value: Double) {
        guard value.isFinite else { return }
        let target = min(1, max(0, value))
        guard target > progress else { return }

        let now = Date()
        let interval = now.timeIntervalSince(progressChangedAt)
        progressFrom = displayedProgress(at: now)
        progressChangedAt = now
        // Track the engine's reporting cadence: frequent frame reports stay responsive,
        // while larger stage jumps get enough time to read as a continuous motion.
        progressAnimationDuration = min(0.30, max(0.025, interval * 0.9))
        progress = target
    }

    func displayedProgress(at date: Date) -> Double {
        let elapsed = max(0, date.timeIntervalSince(progressChangedAt))
        let t = min(1, elapsed / max(progressAnimationDuration, 0.001))
        let eased = t * t * (3 - 2 * t)
        let reported = progressFrom + (progress - progressFrom) * eased

        // Keep the established slow creep between engine checkpoints, but make reported
        // checkpoints ease into it instead of snapping the ring and percentage label.
        guard progress < 1 else { return reported }
        let workElapsed = max(0, date.timeIntervalSince(workStarted))
        let creep = 0.78 * (1 - exp(-workElapsed / 3.5))
        return min(max(reported, creep), 0.95)
    }

    var regionTitle: String {
        switch regionPurpose { case .crop:return "자르기";case .redact:return "가리기";case .annotate:return "주석 위치" }
    }
    func applyRegion(_ region:CGRect) {
        switch regionPurpose {
        case .crop:run(.edit(.crop(region)))
        case .redact:run(.edit(.redact(region)))
        case .annotate(let text):run(.edit(.annotate(region,text)))
        }
    }
    func cancelWork() { guard isWorking,!isCompleting,!isCancelling else { return };isCancelling=true;engineTask?.cancel() }

    func backToRing() {
        withAnimation(Self.panelTransition) { screen = .ring }
    }

    func showToast(_ text: String, closeAfter: Bool) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { toast = text }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled, let self else { return }
            if closeAfter {
                self.close()
            } else {
                withAnimation(.easeOut(duration: 0.25)) { self.toast = nil }
            }
        }
    }

    /// esc: leave a tool panel, or close the ring.
    func escape() {
        if isCompleting { completionTask?.cancel();close();return }
        if isWorking { cancelWork();return }
        if screen == .ring { close() } else { backToRing() }
    }

    /// Keyboard handling forwarded from the panel. Returns true when consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { // esc
            escape()
            return true
        }
        // Everything else belongs to the panels' own controls once a tool is open.
        guard screen == .ring,!isWorking else { return false }
        switch event.keyCode {
        case 48 where event.modifierFlags.contains(.shift):
            // ⇧tab: start at the top slot, then step clockwise.
            withAnimation(.spring(response: 0.3, dampingFraction: 0.72)) {
                hovered = hovered.map { ($0 + 1) % max(items.count, 1) } ?? 0
            }
        case 48: // tab
            switchTab()
        case 123, 126: // left, up
            moveHover(-1)
        case 124, 125: // right, down
            moveHover(1)
        case 36, 76: // return, enter
            if let i = hovered { activate(i) }
        default:
            return false
        }
        return true
    }

    private func loadThumbnail() {
        let request = QLThumbnailGenerator.Request(fileAt: file.url, size: CGSize(width: 96, height: 96),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            let image = rep?.nsImage
            Task { @MainActor in
                self?.thumbnail = image ?? NSWorkspace.shared.icon(forFile: self?.file.url.path ?? "")
            }
        }
    }
}

/// Folding uses standard ease-in-ease-out; dismissal has a slower start and soft landing.
enum RingMotion {
    static let checkDraw = 0.55
    /// Draw the check, hold it briefly, then use the normal ring close animation.
    static let successVisible = 1.35
    static let fold = 0.4
    static let close = 0.30
    static var closeDuration: Double { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.18 : close }
    static var dismissal: Animation {
        .timingCurve(0.65, 0, 0.25, 1, duration: closeDuration)
    }
    static func sCurve(_ duration: Double) -> Animation {
        let d = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? duration / 2 : duration
        return .timingCurve(0.42, 0, 0.58, 1, duration: d)
    }
}

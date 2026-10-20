import SwiftUI

/// Window content: switches between the ring and the tool panels, plus the toast.
struct RootView: View {
    @ObservedObject var model: RingModel

    var body: some View {
        ZStack {
            switch model.screen {
            case .ring:
                // Pin the ring's centre to ringCenterY so it sits on the clicked point.
                RingScreen(model: model)
                    .padding(.top, RingWindowLayout.ringCenterY - RingMetrics.canvas / 2)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            case .crop:
                CropPanel(model: model)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            case .addBackground:
                AddBackgroundPanel(model: model)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            case .tool(let tool):
                EngineToolPanel(model:model,tool:tool)
                    .transition(.scale(scale:0.9).combined(with:.opacity))
            }
            if let toast = model.toast {
                VStack {
                    Spacer()
                    ToastView(text: toast)
                        .padding(.bottom, 18)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: RingWindowLayout.size.width, height: RingWindowLayout.size.height)
        // Only a fade here: the ring grows out of its centre inside RingView. Scaling this
        // whole view made the glass render lighter until the animation ended.
        .opacity(model.appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.74)) { model.appeared = true }
        }
    }
}

struct RingScreen: View {
    @ObservedObject var model: RingModel
    @AppStorage(AppSettings.showShortcutHints) private var showHints = true

    var body: some View {
        VStack(spacing: 8 * RingMetrics.scale) {
            RingView(model: model)
            Group {
                if !model.file.convertActions.isEmpty && !model.file.editActions.isEmpty {
                    TabPill(model: model)
                }
                if showHints { ShortcutHints() }
            }
            .opacity(model.isWorking ? 0 : 1)
            .allowsHitTesting(!model.isWorking)
            if model.isWorking && !model.isCompleting {
                Button(model.isCancelling ? "취소 중…":"작업 취소") { model.cancelWork() }
                    .buttonStyle(.glass).controlSize(.small).disabled(model.isCancelling)
                    .accessibilityIdentifier("job.cancel")
            }
        }
    }
}

struct RingView: View {
    @ObservedObject var model: RingModel

    private let side = RingMetrics.canvas
    private var center: CGPoint { CGPoint(x: side / 2, y: side / 2) }

    var body: some View {
        let items = model.items
        let settled = model.tabProgress == (model.tab == .edit ? 1 : 0)
        // Open/close: everything grows out of (and back into) the ring centre. Sizes change
        // instead of a scale effect so the glass keeps its final tone from the first frame.
        let g = model.appeared ? 1 : RingMetrics.closedGrow
        let hub = RingMetrics.hubDiameter * g
        ZStack {
            // Clear glass needs a darker backdrop to stay legible (Apple's guidance for the
            // clear variant). The glass refracts this soft shadow together with the desktop.
            // While a job runs it folds in with the wedges and fades out, otherwise it was left
            // as a soft round halo around the lone hub.
            let backdrop = model.isWorking ? RingMetrics.hubDiameter : RingMetrics.outer * 2 + 10
            Circle()
                .fill(.black.opacity(0.18))
                .frame(width: backdrop * g, height: backdrop * g)
                .blur(radius: 22)
                .opacity(model.isWorking ? 0 : 1)
                .allowsHitTesting(false)
            // While a job runs the wedges fold into the hub and fade; only the hub stays.
            RingWedges(progress: model.tabProgress, grow: g * (model.isWorking ? 0.62 : 1),
                       convert: model.file.convertActions, edit: model.file.editActions,
                       lifts: LiftVector((0..<max(model.file.convertActions.count, model.file.editActions.count)).map { settled && $0 == model.hovered ? 1 : 0 }), side: side)
                .opacity(model.isWorking ? 0 : 1)
            FrostLayer()
                .frame(width: hub, height: hub)
                .clipShape(Circle())
            Color.clear
                .frame(width: hub, height: hub)
                .glassEffect(RingMetrics.glass.interactive(), in: Circle())
            HubContent(model: model)
                .scaleEffect(g)
                .opacity(model.isCompleting ? 0 : 1)
                .accessibilityHidden(model.isCompleting)
                .allowsHitTesting(false)
            // Hit-testable veil over the glass (see hitTestableGlass): without it every click on
            // a wedge went through to Finder behind the ring.
            Circle()
                .fill(Color.white.opacity(0.01))
                .frame(width: (model.isWorking ? RingMetrics.hubDiameter : RingMetrics.outer * 2) * g,
                       height: (model.isWorking ? RingMetrics.hubDiameter : RingMetrics.outer * 2) * g)
            if model.isWorking {
                HubProgress(model: model)
                    .frame(width: hub, height: hub)
                    .opacity(model.isCompleting ? 0 : 1)
                    .accessibilityHidden(model.isCompleting)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if model.isCompleting {
                HubSuccess()
                    .frame(width: 60 * RingMetrics.scale, height: 52 * RingMetrics.scale)
                    .scaleEffect(g)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .contentShape(Circle().inset(by: 4))
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                guard !model.isWorking else { return }
                let hit = RingSlot.hit(p, center: center, count: items.count)
                if hit != model.hovered {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { model.hovered = hit }
                }
            case .ended:
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.hovered = nil }
            }
        }
        .onTapGesture { p in
            guard settled, !model.isWorking, let i = RingSlot.hit(p, center: center, count: items.count) else { return }
            model.activate(i)
        }
    }
}

/// All wedges for a given point of the 변환 ⇄ 편집 morph (progress 0 = 변환, 1 = 편집).
///
/// The same slot views live through the whole switch; only their angles and labels change,
/// frame by frame. Going 8 → 7, the slot that has no counterpart (DOCX) shrinks in place and
/// vanishes while every other wedge widens and slides into its new place; 7 → 8 plays the
/// reverse. Progress is driven by a spring, so it may overshoot a little — that slight
/// overshoot is the "squish" at the end.
struct RingWedges: View, Animatable {
    var progress: Double
    /// Ring size relative to full, about the centre (open/close animation).
    var grow: CGFloat
    let convert: [RingAction]
    let edit: [RingAction]
    var lifts: LiftVector
    let side: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<Double, CGFloat>, LiftVector> {
        get { AnimatablePair(AnimatablePair(progress, grow), lifts) }
        set { progress = newValue.first.first; grow = newValue.first.second; lifts = newValue.second }
    }

    struct Wedge {
        let index: Int
        let start: Double, end: Double, outer: CGFloat
        let mid: Double
        let fromOpacity: Double, toOpacity: Double
    }

    private var slotCount: Int { max(convert.count, edit.count) }

    /// Angle layout of slot `i` when the ring shows `n` items. A slot beyond `n` is folded
    /// to zero width at the seam between the last and the first wedge, where it disappears.
    private func layout(_ i: Int, _ n: Int) -> (mid: Double, span: Double) {
        guard n > 0 else { return (0, 0) }
        return i < n ? (Double(i) * 360 / Double(n), 360 / Double(n)) : (360 - 180 / Double(n), 0)
    }

    private func wedge(_ i: Int) -> Wedge {
        let p = progress
        let pc = min(max(p, 0), 1)
        let a = layout(i, convert.count), b = layout(i, edit.count)
        let mid = a.mid + (b.mid - a.mid) * p
        let span = max(0, a.span + (b.span - a.span) * p)
        // A slot that exists on one side only shrinks toward the hub as it folds away.
        let exist = b.span == 0 ? 1 - pc : (a.span == 0 ? pc : 1)
        let outer = RingMetrics.inner + (RingMetrics.outer - RingMetrics.inner) * CGFloat(0.4 + 0.6 * exist)
        // Labels swap quickly around the middle of the move.
        let from = min(max(1 - pc * 2.2, 0), 1) * (a.span == 0 ? 0 : 1)
        let to = min(max(pc * 2.2 - 1.2, 0), 1) * (b.span == 0 ? 0 : 1)
        return Wedge(index: i, start: mid - span / 2, end: mid + span / 2, outer: outer, mid: mid,
                     fromOpacity: from, toOpacity: to)
    }

    /// How far wedge `i` is lifted (0 = resting, 1 = selected), mid-animation in between.
    private func lift(_ i: Int) -> CGFloat { CGFloat(lifts[i]) }

    private func shift(_ w: Wedge) -> CGSize {
        RingSlot.lift(mid: w.mid, amount: RingMetrics.hoverLift * grow * lift(w.index))
    }

    var body: some View {
        let wedges = (0..<slotCount).map(wedge)
        // Every wedge stays in the ONE glass shape, the selected one just shifted outward by its
        // lift. Selecting used to move a wedge into a separate glass view, which cannot animate
        // (it appears and disappears), so the selection jumped from wedge to wedge.
        let all = SectorSet(sectors: wedges.map { ($0.start, $0.end, $0.outer, shift($0)) }, grow: grow)
        ZStack {
            // A faint, light frosted layer under the glass: clear glass alone looked too bare.
            // The glass still refracts it, so the lensing stays visible.
            FrostLayer().frame(width: side, height: side).clipShape(all)
            // The selection colour, under the glass so the glass refracts it like a tint;
            // it fades with the lift instead of switching on and off.
            ForEach(wedges.filter { lift($0.index) > 0.001 }, id: \.index) { w in
                SectorShape(start: w.start, end: w.end, outer: w.outer, grow: grow, shift: shift(w))
                    .fill(Color.accentColor.opacity(0.9 * min(Double(lift(w.index)), 1)))
                    .frame(width: side, height: side)
            }
            // One glass surface for all wedges (a multi-part shape): the glass is computed once
            // per frame instead of once per wedge — that kept the morph at 50–60 fps.
            Color.clear
                .frame(width: side, height: side)
                .glassEffect(RingMetrics.glass.interactive(), in: all)
            ForEach(wedges, id: \.index) { w in
                labels(w)
            }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func labels(_ w: Wedge) -> some View {
        let labelR = (w.outer + RingMetrics.inner) / 2 * grow
        let la = (w.mid - 90) * .pi / 180
        let lift = shift(w)
        let lit = min(max(Double(self.lift(w.index)), 0), 1)
        let point = CGPoint(x: side / 2 + labelR * CGFloat(Foundation.cos(la)) + lift.width,
                            y: side / 2 + labelR * CGFloat(Foundation.sin(la)) + lift.height)
        // Both labels always exist (invisible when not shown) so the first switch does not
        // hitch while it creates the other tab's symbols and text.
        if w.index < convert.count {
            SlotLabel(action: convert[w.index], lit: lit)
                .scaleEffect((0.85 + 0.15 * w.fromOpacity) * grow)
                .opacity(w.fromOpacity)
                .position(point)
        }
        if w.index < edit.count {
            SlotLabel(action: edit[w.index], lit: lit)
                .scaleEffect((0.85 + 0.15 * w.toOpacity) * grow)
                .opacity(w.toOpacity)
                .position(point)
        }
    }
}

/// Per-wedge lift amounts, interpolated by SwiftUI so a selection moving between wedges
/// lowers one while it raises the other.
struct LiftVector: VectorArithmetic {
    var values: [Double]

    init(_ values: [Double]) { self.values = values }
    subscript(i: Int) -> Double { i < values.count ? values[i] : 0 }

    static var zero: LiftVector { LiftVector([]) }
    private static func combine(_ a: LiftVector, _ b: LiftVector, _ f: (Double, Double) -> Double) -> LiftVector {
        LiftVector((0..<max(a.values.count, b.values.count)).map { f(a[$0], b[$0]) })
    }
    static func + (a: LiftVector, b: LiftVector) -> LiftVector { combine(a, b, +) }
    static func - (a: LiftVector, b: LiftVector) -> LiftVector { combine(a, b, -) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
    static func == (a: LiftVector, b: LiftVector) -> Bool {
        (0..<max(a.values.count, b.values.count)).allSatisfy { a[$0] == b[$0] }
    }
}

/// Several ring sectors as one shape, each optionally shifted (a lifted wedge).
struct SectorSet: Shape {
    let sectors: [(Double, Double, CGFloat, CGSize)]
    var grow: CGFloat = 1

    func path(in rect: CGRect) -> Path {
        var p = Path()
        for (start, end, outer, shift) in sectors {
            p.addPath(SectorShape(start: start, end: end, outer: outer, grow: grow, shift: shift).path(in: rect))
        }
        return p
    }
}

struct SlotLabel: View {
    let action: RingAction
    /// 0 = resting label, 1 = on the selection colour (white, no shadow).
    let lit: Double
    private let s = RingMetrics.scale

    var body: some View {
        ZStack {
            content.foregroundStyle(.primary)
                .shadow(color: .black.opacity(0.35), radius: 3, y: 0.5)
                .opacity(1 - lit)
            content.foregroundStyle(.white)
                .opacity(lit)
        }
        .fixedSize()
    }

    private var content: some View {
        VStack(spacing: 4 * s) {
            if let symbol = action.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 19 * s, weight: .medium))
                Text(action.title)
                    .font(.system(size: max(10, 12.5 * s), weight: .semibold))
            } else {
                Text(action.title)
                    .font(.system(size: 17 * s, weight: .bold))
            }
        }
    }
}

struct HubContent: View {
    @ObservedObject var model: RingModel
    private let s = RingMetrics.scale

    var body: some View {
        VStack(spacing: 2) {
            Group {
                if let image = model.thumbnail {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "doc").font(.system(size: 30 * s))
                }
            }
            .frame(width: 46 * s, height: 46 * s)
            .padding(.bottom, 4 * s)

            let action = model.hoveredAction
            // The views below stay the same views for every selection; only their text and
            // sizes change, so moving between wedges morphs instead of swapping views.
            VStack(spacing: 2) {
                chip(action)
                Text(action.map(resultName) ?? model.file.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(model.items.isEmpty ? "지원하지 않는 형식" : "\(model.file.ext) · \(model.file.sizeText)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .opacity(action == nil ? 1 : 0)
                    .frame(height: action == nil ? nil : 0)
                    .clipped()
            }
            .contentTransition(.interpolate)
            .opacity(model.isWorking ? 0 : 1)
            // Same faint shadow as the wedge labels, so the text holds up over busy backgrounds.
            .shadow(color: .black.opacity(0.3), radius: 2, y: 0.5)
        }
        .frame(width: RingMetrics.hubDiameter - 26)
        .multilineTextAlignment(.center)
        .animation(.spring(response: 0.24, dampingFraction: 0.82), value: model.hovered)
        .onChange(of: model.hovered) { _, _ in
            if let a = model.hoveredAction { lastKicker = kicker(for: a) }
        }
    }

    /// Kicker text shown while the chip shrinks away, so it does not change mid-collapse.
    @State private var lastKicker = ""
    private static let chipFont = NSFont.systemFont(ofSize: 10.5, weight: .bold)

    /// White text on a solid chip: thin blue text on the glass was unreadable over busy or light
    /// backgrounds. The chip is the selected wedge's colour (accent lightened by the glass,
    /// measured ≈ 17 % white), and its width springs between selections.
    private func chip(_ action: RingAction?) -> some View {
        let text = action.map(kicker) ?? lastKicker
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: Self.chipFont]).width)
        let shown = action != nil
        // The old word blurs out while the new one blurs in (a glyph morph between different
        // Korean words came out as a jumble), clipped to the capsule while its width springs.
        return ZStack {
            Text(text)
                .font(Font(Self.chipFont))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .id(text)
                .transition(.blurReplace)
        }
        .frame(width: textWidth + 16, height: 17)
        .background(Capsule().fill(Color.accentColor.mix(with: .white, by: 0.17)))
        .clipShape(Capsule())
            .scaleEffect(shown ? 1 : 0.6)
            .opacity(shown ? 1 : 0)
            .frame(height: shown ? 17 : 0)
            .padding(.bottom, shown ? 2 : 0)
    }

    private func kicker(for action: RingAction) -> String {
        if case .convert(let f) = action.kind { return "\(f)로 변환" }
        return action.title
    }

    private func resultName(for action: RingAction) -> String {
        let base = model.file.baseName
        switch action.kind {
        case .convert(let f): return "\(base).\(f.lowercased())"
        case .crop: return "\(base) 자름.\(model.file.url.pathExtension)"
        case .addBackground: return "\(base) 배경.png"
        case .tool: return model.file.name
        }
    }
}

/// 변환/편집 switch. The white knob is one view moving between the two slots with a
/// springy slide that stays inside the track.
struct TabPill: View {
    @ObservedObject var model: RingModel
    private let s = RingMetrics.scale
    private var chipW: CGFloat { 84 * s }
    private var chipH: CGFloat { 30 * s }
    private let spacing: CGFloat = 3

    // The knob's two ends move on separate springs: the leading end sets off first and the
    // trailing end catches up, so the knob stretches and snaps back — always inside the track.
    @State private var leftEdge: CGFloat = 0
    @State private var rightEdge: CGFloat = 0

    private func edges(for tab: RingModel.Tab) -> (CGFloat, CGFloat) {
        tab == .convert ? (0, chipW) : (chipW + spacing, chipW * 2 + spacing)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                .frame(width: max(chipH, rightEdge - leftEdge), height: chipH)
                .offset(x: leftEdge)
            HStack(spacing: spacing) {
                chip("변환", .convert)
                chip("편집", .edit)
            }
        }
        // The bouncy knob may overshoot a pixel or two; never let it leave the track.
        .clipShape(Capsule())
        .padding(3)
        .glassEffect(.regular.interactive(), in: Capsule())
        .hitTestableGlass(Capsule())
        .onAppear { (leftEdge, rightEdge) = edges(for: model.tab) }
        .onChange(of: model.tab) { _, tab in
            let (l, r) = edges(for: tab)
            let lead = Animation.spring(response: 0.3, dampingFraction: 0.7)
            let follow = Animation.spring(response: 0.46, dampingFraction: 0.68)
            if tab == .edit {
                withAnimation(lead) { rightEdge = r }
                withAnimation(follow) { leftEdge = l }
            } else {
                withAnimation(lead) { leftEdge = l }
                withAnimation(follow) { rightEdge = r }
            }
        }
    }

    private func chip(_ title: String, _ tab: RingModel.Tab) -> some View {
        let on = model.tab == tab
        return Button {
            if !on { model.switchTab() }
        } label: {
            Text(title)
                .font(.system(size: max(10.5, 13 * s), weight: on ? .bold : .medium))
                // The knob is always white, so the selected label stays dark in Dark Mode too.
                .foregroundStyle(on ? AnyShapeStyle(Color.black.opacity(0.85)) : AnyShapeStyle(.secondary))
                .frame(width: chipW, height: chipH)
                .contentShape(Capsule())
                .animation(.easeInOut(duration: 0.18), value: on)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}

struct ShortcutHints: View {
    var body: some View {
        HStack(spacing: 10) {
            hint("tab", "탭 전환")
            hint("⇧ tab", "선택")
            hint("return", "실행")
            hint("esc", "닫기")
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .glassEffect(.regular, in: Capsule())
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.12)))
            Text(label).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hammer.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white, Color.orange)
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .padding(.leading, 9).padding(.trailing, 14).padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
    }
}

/// Light, thin frosted material used under the ring glass (always the light variant, so it
/// brightens rather than darkens in Dark Mode).
struct FrostLayer: View {
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .environment(\.colorScheme, .light)
            .opacity(0.38)
            .overlay(Color.white.opacity(0.05))
    }
}

/// Progress drawn on the hub's rim while the engine works. The engine reports real
/// checkpoints (start, each PDF page, verification, saved); between them the arc creeps
/// forward on a fixed curve so a single long step does not look frozen. It never passes 95%
/// before the engine says the file is saved. Redrawn only while a job runs.
struct HubProgress: View {
    @ObservedObject var model: RingModel

    var body: some View {
        // Paused at 100% so nothing redraws while the finished ring closes.
        TimelineView(.animation(minimumInterval: nil, paused: model.progress >= 1)) { context in
            let value = shown(at: context.date)
            ZStack {
                Circle()
                    .inset(by: 1.5) // half the line width: the arc reaches the hub edge
                    .stroke(.white.opacity(0.16), lineWidth: 3)
                Circle()
                    .inset(by: 1.5) // half the line width: the arc reaches the hub edge
                    .trim(from: 0, to: value)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack {
                    Spacer()
                    Text("\(Int((value * 100).rounded()))%")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 0.5)
                        .padding(.bottom, 22)
                }
            }
        }
    }

    private func shown(at date: Date) -> Double {
        if model.progress >= 1 { return 1 }
        let t = date.timeIntervalSince(model.workStarted)
        let creep = 0.9 * (1 - exp(-t / 2.0))
        return min(max(model.progress, creep), 0.95)
    }
}

/// One continuous stroke, starting at the left arm, through the low vertex, up to the right.
private struct SuccessCheck: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.42))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.40, y: rect.minY + rect.height * 0.76))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.88, y: rect.minY + rect.height * 0.18))
        }
    }
}

private struct HubSuccess: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0

    var body: some View {
        SuccessCheck()
            .trim(from: 0, to: drawn)
            .stroke(Color.green, style: StrokeStyle(lineWidth: 7 * RingMetrics.scale, lineCap: .round, lineJoin: .round))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("저장 완료")
            .onAppear {
                withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : RingMotion.checkDraw)) { drawn = 1 }
            }
    }
}

extension View {
    /// Liquid Glass is composited outside the window's own pixels, so on Ring's transparent
    /// panel the window server treated glass-only areas as empty and sent clicks to the app
    /// behind (measured: a click on a wedge reached Finder). An invisible 1% veil on top gives
    /// those areas alpha. It does not take part in SwiftUI hit testing.
    func hitTestableGlass<S: Shape>(_ shape: S) -> some View {
        overlay(shape.fill(Color.white.opacity(0.01)).allowsHitTesting(false))
    }
}

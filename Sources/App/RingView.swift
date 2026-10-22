import SwiftUI

/// Window content: switches between the ring and the tool panels, plus the toast.
struct RootView: View {
    @ObservedObject var model: RingModel

    var body: some View {
        ZStack {
            // Keep the glass graph alive when a tool covers the ring. Rebuilding
            // harvested surfaces could leave labels visible before the glass returned.
            RingScreen(model: model)
                .padding(.top, RingWindowLayout.ringCenterY - RingMetrics.canvas / 2)
                .frame(maxHeight: .infinity, alignment: .top)
                .opacity(model.screen == .ring ? 1 : 0)
                .allowsHitTesting(model.screen == .ring)
                .accessibilityHidden(model.screen != .ring)
            switch model.screen {
            case .ring: EmptyView()
            case .crop:
                CropPanel(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .addBackground:
                AddBackgroundPanel(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            case .tool(let tool):
                EngineToolPanel(model:model,tool:tool)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
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
            withAnimation(RingMotion.opening) { model.appeared = true }
        }
    }
}

struct RingScreen: View {
    @ObservedObject var model: RingModel
    @AppStorage(AppSettings.showShortcutHints) private var showHints = true

    var body: some View {
        ZStack(alignment: .top) {
            // One persistent glass surface owns both the hub and sectors. At contact
            // their paths unite, so no hidden lens or selection can remain behind it.
            VStack(spacing: 8 * RingMetrics.scale) {
                RingView(model: model, layer: .surface)
                Group {
                    if model.isSubmenu || (!model.file.convertActions.isEmpty && !model.file.editActions.isEmpty) {
                        TabPill(model: model)
                    }
                    if showHints {
                        if model.isSubmenu {
                            Text("⇧tab 선택 · return 열기 · esc 뒤로").font(.system(size: 10)).foregroundStyle(.secondary)
                        } else { ShortcutHints() }
                    }
                }
                .allowsHitTesting(!model.isWorking && !model.isNavigating)
                .opacity(model.isWorking ? 0 : 1)
                if model.showsVideoHub && !model.isWorking {
                    VStack(spacing: 4) {
                        Text(model.videoNotice)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).lineLimit(3)
                    }
                    .frame(width: RingMetrics.canvas - 12)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 0.5)
                }
            }
            .overlay(alignment: .top) {
                RingView(model: model, layer: .content)
            }
            if model.isWorking && !model.isCompleting {
                Button(model.isCancelling ? "취소 중…":"작업 취소") { model.cancelWork() }
                    .buttonStyle(.glass).controlSize(.small).disabled(model.isCancelling)
                    .accessibilityIdentifier("job.cancel")
                    .padding(.top, RingMetrics.canvas / 2 + RingMetrics.hubDiameter / 2 + 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
    }
}

struct RingView: View {
    enum Layer { case surface, content }
    @ObservedObject var model: RingModel
    let layer: Layer

    private let side = RingMetrics.canvas
    private var center: CGPoint { CGPoint(x: side / 2, y: side / 2) }

    var body: some View {
        let items = model.items
        let settled = model.tabProgress == (model.tab == .edit ? 1 : 0)
        let g: CGFloat = model.appeared ? 1 : 0
        let hub = RingMetrics.hubDiameter
        ZStack {
            if layer == .surface {
                wedges(grow: g, settled: settled, labelsOnly: false)
            } else {
                wedges(grow: g, settled: settled, labelsOnly: true)
                    .opacity(model.isWorking ? 0 : 1)
                HubContent(model: model)
                    .scaleEffect(g)
                    .opacity(model.isCompleting ? 0 : 1)
                    .accessibilityHidden(model.isCompleting)
                    .allowsHitTesting(false)
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
        }
        .frame(width: side, height: side)
        .contentShape(Circle().inset(by: 4))
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                guard !model.isWorking, !model.isNavigating else { return }
                let hit = RingSlot.hit(p, center: center, count: items.count)
                if hit != model.hovered {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { model.hovered = hit }
                }
            case .ended:
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.hovered = nil }
            }
        }
        .onTapGesture { p in
            guard settled, !model.isWorking, !model.isNavigating, let i = RingSlot.hit(p, center: center, count: items.count) else { return }
            model.activate(i)
        }
        .allowsHitTesting(layer == .content)
    }

    private func wedges(grow: CGFloat, settled: Bool, labelsOnly: Bool) -> RingWedges {
        let convert = model.convertItems, edit = model.editItems
        let size: CGFloat = model.menuFolded || model.isWorking || model.screen != .ring ? 0 : 1
        return RingWedges(progress: model.tabProgress, grow: grow * size,
                   appearance: grow, hubScale: model.menuFolded ? 1.06 : 1,
                   convert: convert, edit: edit,
                   lifts: LiftVector((0..<max(convert.count, edit.count)).map { settled && $0 == model.highlightedIndex ? 1 : 0 }),
                   side: side, labelsOnly: labelsOnly)
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
    var appearance: CGFloat
    var hubScale: CGFloat
    let convert: [RingAction]
    let edit: [RingAction]
    var lifts: LiftVector
    let side: CGFloat
    let labelsOnly: Bool

    var animatableData: AnimatablePair<AnimatablePair<Double, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, LiftVector>> {
        get { AnimatablePair(AnimatablePair(progress, grow), AnimatablePair(AnimatablePair(appearance, hubScale), lifts)) }
        set {
            progress = newValue.first.first; grow = newValue.first.second
            appearance = newValue.second.first.first; hubScale = newValue.second.first.second
            lifts = newValue.second.second
        }
    }

    // The hub stays in place until the last sector has entered its surface. Only
    // then does the hub itself shrink on dismissal; opening reverses the same path.
    private var hubRadius: CGFloat { RingMetrics.hubDiameter / 2 * min(1, max(0, appearance * 2.5)) * hubScale }
    private func smooth(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
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
        let all = SectorSet(sectors: wedges.map { ($0.start, $0.end, $0.outer, shift($0)) }, grow: grow, hubRadius: hubRadius)
        // Every wedge stays in the ONE glass shape, the selected one just shifted outward by its
        // lift. Selecting used to move a wedge into a separate glass view, which cannot animate
        // (it appears and disappears), so the selection jumped from wedge to wedge.
        ZStack {
            if !labelsOnly {
                let exposed = smooth((RingMetrics.outer * grow - hubRadius) / (RingMetrics.outer - RingMetrics.hubDiameter / 2))
                Circle()
                    .fill(.black.opacity(0.18 * Double(exposed)))
                    .frame(width: max(hubRadius * 2, (RingMetrics.outer * 2 + 10) * grow),
                           height: max(hubRadius * 2, (RingMetrics.outer * 2 + 10) * grow))
                    .blur(radius: 22)
                // A faint, light frosted layer under the glass: clear glass alone looked too bare.
                // The glass still refracts it, so the lensing stays visible.
                FrostLayer().frame(width: side, height: side).clipShape(all)
                // The selection colour, under the glass so the glass refracts it like a tint;
                // it fades with the lift instead of switching on and off.
                ForEach(wedges.filter { lift($0.index) > 0.001 }, id: \.index) { w in
                    SectorShape(start: w.start, end: w.end, outer: w.outer, grow: grow, shift: shift(w), hubRadius: hubRadius)
                        .subtracting(Circle().size(width: hubRadius * 2, height: hubRadius * 2)
                            .offset(x: side / 2 - hubRadius, y: side / 2 - hubRadius))
                        .fill(Color.accentColor.opacity(0.9 * min(Double(lift(w.index)), 1)
                            * Double(smooth((RingMetrics.inner * grow - hubRadius + 2) / 10))))
                        .frame(width: side, height: side)
                }
                // One glass surface for all wedges (a multi-part shape): the glass is computed once
                // per frame instead of once per wedge — that kept the morph at 50–60 fps.
                Color.clear
                    .frame(width: side, height: side)
                    .glassEffect(RingMetrics.glass.interactive(), in: all)
            } else {
                // Native transparent panels need painted pixels to receive clicks.
                // Follow the animated glass outline, never a full-size disc that
                // remains visible on dark backgrounds after the ring is absorbed.
                all.fill(Color.white.opacity(0.01))
                    .frame(width: side, height: side)
                ForEach(wedges, id: \.index) { w in
                    labels(w)
                }
            }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(labelsOnly)
    }

    @ViewBuilder private func labels(_ w: Wedge) -> some View {
        let labelR = (w.outer + RingMetrics.inner) / 2 * grow
        let visible = Double(smooth((labelR - hubRadius - 8) / 20))
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
                .opacity(w.fromOpacity * visible)
                .position(point)
        }
        if w.index < edit.count {
            SlotLabel(action: edit[w.index], lit: lit)
                .scaleEffect((0.85 + 0.15 * w.toOpacity) * grow)
                .opacity(w.toOpacity * visible)
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
    var hubRadius: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var p = Path(ellipseIn: CGRect(x: rect.midX - hubRadius, y: rect.midY - hubRadius,
                                      width: hubRadius * 2, height: hubRadius * 2))
        for (start, end, outer, shift) in sectors {
            let sector = SectorShape(start: start, end: end, outer: outer, grow: grow, shift: shift, hubRadius: hubRadius).path(in: rect)
            p = p.union(sector)
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
        Group {
            if model.showsVideoHub { VideoHubContent(model: model) }
            else { regularContent }
        }
    }

    private var regularContent: some View {
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
                Text(action.map(resultName) ?? (model.choosingFrameFormat ? "저장할 포맷" : model.file.name))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(model.items.isEmpty ? "지원하지 않는 형식" : model.choosingFrameFormat ? "한 장 저장" : model.file.summary)
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
        if case .convert(let f) = action.kind { return model.choosingFrameFormat ? "\(f) 한 장 저장" : "\(f)로 변환" }
        return action.title
    }

    private func resultName(for action: RingAction) -> String {
        let base = model.file.baseName
        switch action.kind {
        case .convert(let f): return "\(base).\(f.lowercased())"
        case .crop: return "\(base) 자름.\(model.file.animation == nil ? model.file.url.pathExtension : "webp")"
        case .addBackground: return "\(base) 배경.png"
        case .tool: return model.file.name
        }
    }
}

/// One continuous capsule: the two tabs contract into the back button, sharing
/// the same glass track and white knob in both directions.
struct TabPill: View {
    @ObservedObject var model: RingModel
    private let s = RingMetrics.scale
    private var chipW: CGFloat { 84 * s }
    private var chipH: CGFloat { 30 * s }
    private let spacing: CGFloat = 3
    private var back: Bool { model.isSubmenu }
    private var trackW: CGFloat { back ? chipW : chipW * 2 + spacing }

    // The knob's two ends move on separate springs: the leading end sets off first and the
    // trailing end catches up, so the knob stretches and snaps back — always inside the track.
    @State private var leftEdge: CGFloat = 0
    @State private var rightEdge: CGFloat = 0

    private func edges(for tab: RingModel.Tab) -> (CGFloat, CGFloat) {
        back || tab == .convert ? (0, chipW) : (chipW + spacing, chipW * 2 + spacing)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                .frame(width: max(chipH, rightEdge - leftEdge), height: chipH)
                .offset(x: leftEdge)
            HStack(spacing: back ? 0 : spacing) {
                chip("변환", .convert)
                chip("편집", .edit)
            }
            .opacity(back ? 0 : 1)
            .animation(.easeInOut(duration: 0.08).delay(back ? 0 : 0.08), value: back)
            .allowsHitTesting(!back)
            .accessibilityHidden(back)
            Button { model.backMenu() } label: {
                Label(model.backTitle, systemImage: "chevron.left")
                    .font(.system(size: max(10.5, 13 * s), weight: .medium))
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(width: chipW, height: chipH)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .opacity(back ? 1 : 0)
            .animation(.easeInOut(duration: 0.08).delay(back ? 0.08 : 0), value: back)
            .allowsHitTesting(back)
            .accessibilityHidden(!back)
            .accessibilityIdentifier("ring.back")
        }
        .frame(width: trackW, height: chipH, alignment: .leading)
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
        .onChange(of: back) { _, _ in
            let (l, r) = edges(for: model.tab)
            withAnimation(RingMotion.menuExpansion) {
                leftEdge = l; rightEdge = r
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
                .frame(width: back ? chipW / 2 : chipW, height: chipH)
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
/// checkpoints (start, each PDF page, verification, saved); the arc eases between reports
/// and creeps forward on a fixed curve so a single long step does not look frozen. It never
/// passes 95% before the engine says the file is saved. Redrawn only while a job runs.
struct HubProgress: View {
    @ObservedObject var model: RingModel

    var body: some View {
        TimelineView(.animation(minimumInterval: nil)) { context in
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
        model.displayedProgress(at: date)
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

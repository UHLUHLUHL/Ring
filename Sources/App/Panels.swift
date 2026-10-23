import AppKit
import ImageIO
import SwiftUI

// MARK: - Shared panel chrome

private struct ToolPanelMeasureKey: EnvironmentKey {
    static let defaultValue: (CGFloat) -> Void = { _ in }
}
private struct ToolPanelReadyKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var toolPanelMeasure: (CGFloat) -> Void {
        get { self[ToolPanelMeasureKey.self] }
        set { self[ToolPanelMeasureKey.self] = newValue }
    }
    var toolPanelReady: Bool {
        get { self[ToolPanelReadyKey.self] }
        set { self[ToolPanelReadyKey.self] = newValue }
    }
}

private struct ToolPanelMeasurement: Equatable {
    let height: CGFloat
    let ready: Bool
}

struct GlassPanel<Content: View>: View {
    @Environment(\.toolPanelMeasure) private var measure
    @Environment(\.toolPanelReady) private var ready
    let title: String
    let subtitle: String
    let width: CGFloat
    let onClose: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Text(title).font(.system(size: 15, weight: .bold))
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    Spacer()
                    Text(subtitle)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 150, alignment: .trailing)
                }
            }
            .background(PanelTitleDragRegion())
            content
        }
        .padding(20)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: ToolPanelMeasurement.self) {
            ToolPanelMeasurement(height: $0.size.height, ready: ready)
        } action: { value in
            if value.ready { measure(value.height) }
        }
        .opacity(ready ? 1 : 0)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .hitTestableGlass(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}

private struct PanelTitleDragRegion:NSViewRepresentable {
    final class Region:NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (window as? RingPanel)?.titleDragView=self
        }
        override func hitTest(_ point:NSPoint)->NSView? { nil }
    }
    func makeNSView(context:Context)->Region { Region() }
    func updateNSView(_ nsView:Region,context:Context) {}
}

struct FieldLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
    }
}

/// One labelled control row of a tool panel: label column on the panel's leading edge,
/// control filling the rest up to the trailing edge, so every row shares the same two edges.
struct PanelRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 12) {
            FieldLabel(text: label)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Segmented control whose segments share the full row width. SwiftUI's segmented Picker keeps
/// its intrinsic width on macOS and sat centred in the row, so its edges matched nothing else.
struct FillSegmented<Value: CaseIterable & Hashable & RawRepresentable>: NSViewRepresentable where Value.RawValue == String {
    @Binding var selection: Value
    private let values = Array(Value.allCases)

    init(selection: Binding<Value>) { _selection = selection }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: values.map(\.rawValue), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = values.firstIndex(of: selection) ?? -1
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: FillSegmented
        init(_ parent: FillSegmented) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) {
            guard parent.values.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.values[sender.selectedSegment]
        }
    }
}

func pixelSize(of url: URL) -> CGSize {
    if ["avif", "jxl"].contains(url.pathExtension.lowercased()), let reader = try? ModernImageReader(url) {
        return reader.orientation >= 5 ? CGSize(width: reader.height, height: reader.width) : CGSize(width: reader.width, height: reader.height)
    }
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int else { return CGSize(width: 1000, height: 1000) }
    let rotated = (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
    return CGSize(width: rotated ? h:w, height: rotated ? w:h)
}

/// A bounded preview; full-resolution pixels are loaded only by the engine on save.
func panelPreview(of url:URL)->NSImage? {
    if ["avif", "jxl"].contains(url.pathExtension.lowercased()), let image = try? ImageCodec.preview(url, maxDimension: 1024) {
        return NSImage(cgImage: image, size: .zero)
    }
    guard let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
          let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
              kCGImageSourceThumbnailMaxPixelSize:1024,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return nil }
    return NSImage(cgImage:image,size:.zero)
}

// MARK: - Crop frame (Photos style)

/// Crop frame drawn over media shown in `bounds`, modelled on Photos: the
/// outside is dimmed, the frame has a thin white border with thick corner
/// brackets, and a rule-of-thirds grid appears while dragging. Drag inside to
/// move, drag a corner or edge to resize. `aspect` (pixel width / height)
/// locks the shape. `crop` is normalized to the media, top-left origin.
struct CropFrame: View {
    @Binding var crop: CGRect
    let bounds: CGRect
    let pixels: CGSize
    let aspect: Double?
    @State private var start: CGRect?
    private let minimum: CGFloat = 0.08

    private var frame: CGRect {
        CGRect(x: bounds.minX + crop.minX * bounds.width, y: bounds.minY + crop.minY * bounds.height,
               width: crop.width * bounds.width, height: crop.height * bounds.height)
    }

    var body: some View {
        let f = frame
        ZStack(alignment: .topLeading) {
            // One even-odd path, painted once: no doubled translucency.
            Path { p in p.addRect(bounds); p.addRect(f) }
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            if start != nil {
                Path { p in
                    for k in 1...2 {
                        let x = f.minX + f.width * CGFloat(k) / 3, y = f.minY + f.height * CGFloat(k) / 3
                        p.move(to: CGPoint(x: x, y: f.minY)); p.addLine(to: CGPoint(x: x, y: f.maxY))
                        p.move(to: CGPoint(x: f.minX, y: y)); p.addLine(to: CGPoint(x: f.maxX, y: y))
                    }
                }
                .stroke(.white.opacity(0.45), lineWidth: 0.5)
                .allowsHitTesting(false)
            }
            Rectangle().stroke(.white.opacity(0.9), lineWidth: 1)
                .frame(width: f.width, height: f.height).offset(x: f.minX, y: f.minY)
                .allowsHitTesting(false)
            brackets(f).allowsHitTesting(false)
            Color.clear.contentShape(Rectangle())
                .frame(width: max(1, f.width - 24), height: max(1, f.height - 24))
                .offset(x: f.minX + 12, y: f.minY + 12)
                .gesture(drag(edges: [], move: true))
            ForEach(Self.grips, id: \.self) { g in
                Color.clear.contentShape(Rectangle())
                    .frame(width: g.isCorner ? 26 : (g.ux == 0.5 ? max(1, f.width - 40) : 18),
                           height: g.isCorner ? 26 : (g.uy == 0.5 ? max(1, f.height - 40) : 18))
                    .position(x: f.minX + g.ux * f.width, y: f.minY + g.uy * f.height)
                    .gesture(drag(edges: g.edges, move: false))
            }
        }
        .animation(.easeOut(duration: 0.12), value: start != nil)
    }

    /// Photos-style L brackets: 3pt white strokes, about 18pt long, outside the border.
    private func brackets(_ f: CGRect) -> some View {
        Path { p in
            let l = min(18, f.width / 3, f.height / 3), o: CGFloat = 1.5
            for (cx, cy, sx, sy) in [(f.minX, f.minY, 1.0, 1.0), (f.maxX, f.minY, -1.0, 1.0), (f.minX, f.maxY, 1.0, -1.0), (f.maxX, f.maxY, -1.0, -1.0)] {
                let x = cx - o * sx, y = cy - o * sy
                p.move(to: CGPoint(x: x + l * sx, y: y)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + l * sy))
            }
        }
        .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .butt, lineJoin: .miter))
        .shadow(color: .black.opacity(0.35), radius: 1.5)
    }

    struct Grip: Hashable {
        let ux: CGFloat, uy: CGFloat
        var isCorner: Bool { ux != 0.5 && uy != 0.5 }
        var edges: Edge.Set {
            var e: Edge.Set = []
            if ux == 0 { e.insert(.leading) }; if ux == 1 { e.insert(.trailing) }
            if uy == 0 { e.insert(.top) }; if uy == 1 { e.insert(.bottom) }
            return e
        }
    }
    static let grips: [Grip] = [(0, 0), (0.5, 0), (1, 0), (0, 0.5), (1, 0.5), (0, 1), (0.5, 1), (1, 1)].map { Grip(ux: $0.0, uy: $0.1) }

    private func drag(edges: Edge.Set, move: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                let s = start ?? crop
                if start == nil { start = crop }
                let dx = v.translation.width / max(1, bounds.width), dy = v.translation.height / max(1, bounds.height)
                if move {
                    crop.origin = CGPoint(x: min(max(0, s.minX + dx), 1 - s.width), y: min(max(0, s.minY + dy), 1 - s.height))
                    return
                }
                var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
                if edges.contains(.leading) { minX = min(max(0, minX + dx), maxX - minimum) }
                if edges.contains(.trailing) { maxX = max(min(1, maxX + dx), minX + minimum) }
                if edges.contains(.top) { minY = min(max(0, minY + dy), maxY - minimum) }
                if edges.contains(.bottom) { maxY = max(min(1, maxY + dy), minY + minimum) }
                var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                if let aspect { r = Self.locked(r, aspect: aspect, pixels: pixels, edges: edges) }
                crop = r
            }
            .onEnded { _ in start = nil }
    }

    /// Keeps `aspect` while the dragged edges move; the opposite corner stays put.
    static func locked(_ r: CGRect, aspect: Double, pixels: CGSize, edges: Edge.Set) -> CGRect {
        let k = CGFloat(aspect) * pixels.height / max(1, pixels.width) // normalized width / height
        var w = r.width, h = r.height
        if edges.contains(.leading) || edges.contains(.trailing) { h = w / k } else { w = h * k }
        let anchorX = edges.contains(.leading) ? r.maxX : r.minX
        let anchorY = edges.contains(.top) ? r.maxY : r.minY
        let roomX = edges.contains(.leading) ? anchorX : 1 - anchorX
        let roomY = edges.contains(.top) ? anchorY : 1 - anchorY
        let fit = min(1, roomX / max(w, 0.0001), roomY / max(h, 0.0001))
        w *= fit; h *= fit
        let x = edges.contains(.leading) ? anchorX - w : (edges.contains(.trailing) ? anchorX : r.midX - w / 2)
        let y = edges.contains(.top) ? anchorY - h : (edges.contains(.bottom) ? anchorY : r.midY - h / 2)
        return CGRect(x: min(max(0, x), 1 - w), y: min(max(0, y), 1 - h), width: w, height: h)
    }

    /// Largest rectangle of `aspect` centred on `around`, inside the media.
    static func largest(aspect: Double, pixels: CGSize, around: CGRect) -> CGRect {
        let k = CGFloat(aspect) * pixels.height / max(1, pixels.width)
        var w: CGFloat = 1, h = 1 / k
        if h > 1 { h = 1; w = k }
        let cx = min(max(around.midX, w / 2), 1 - w / 2), cy = min(max(around.midY, h / 2), 1 - h / 2)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// Aspect-fit rectangle of `pixels` inside `container`.
    static func fitted(_ pixels: CGSize, in container: CGSize) -> CGRect {
        let s = min(container.width / max(1, pixels.width), container.height / max(1, pixels.height))
        let w = pixels.width * s, h = pixels.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }
}

/// Photos' aspect list as a menu, the landscape/portrait pair, the kept
/// size and reset. Shared by the photo and video crop panels.
struct CropRatioControls: View {
    @Binding var ratio: VideoCropRatio
    @Binding var portrait: Bool
    let size: String?
    let canReset: Bool
    let reset: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Picker("비율", selection: $ratio) {
                ForEach(VideoCropRatio.allCases, id: \.self) { Text($0.label(portrait: portrait)).tag($0) }
            }
            .labelsHidden().frame(width: 110, alignment: .leading).accessibilityIdentifier("crop.ratio")
            if !ratio.isSquare && ratio != .free {
                ForEach([false, true], id: \.self) { value in
                    Button { portrait = value } label: { Image(systemName: value ? "rectangle.portrait" : "rectangle") }
                        .buttonStyle(.glass).tint(portrait == value ? .accentColor : nil)
                        .accessibilityLabel(value ? "세로 비율" : "가로 비율")
                }
            }
            Spacer(minLength: 4)
            if let size { Text(verbatim: size).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary) }
            Button("재설정", action: reset).buttonStyle(.glass).disabled(!canReset)
        }
    }
}

// MARK: - Crop

struct CropPanel: View {
    @ObservedObject var model: RingModel

    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1) // normalized to the image
    @State private var ratio: VideoCropRatio = .free
    @State private var portrait = false
    @State private var image: NSImage?
    @State private var jpegSampling: JPEGSampling?
    private let pixels: CGSize
    private let orientation: Int
    /// Preview box in the picture's own shape: 380pt wide, as tall as the
    /// aspect needs up to 460pt (the 720pt window minus the panel's rows).
    /// A small inset leaves room for the corner brackets.
    private var area: CGSize {
        let inset: CGFloat = 12, aspect = pixels.width / max(1, pixels.height)
        let width = min(380 - inset, (460 - inset) * aspect)
        return CGSize(width: width + inset, height: width / aspect + inset)
    }

    init(model: RingModel) {
        self.model = model
        let source = CGImageSourceCreateWithURL(model.file.url as CFURL, nil)
        let modern = ["avif", "jxl"].contains(model.file.url.pathExtension.lowercased()) ? try? ModernImageReader(model.file.url) : nil
        let props = modern?.properties ?? source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let w = modern?.width ?? props?[kCGImagePropertyPixelWidth] as? Int ?? 1000
        let h = modern?.height ?? props?[kCGImagePropertyPixelHeight] as? Int ?? 1000
        let orient = props?[kCGImagePropertyOrientation] as? Int ?? 1
        orientation = orient
        pixels = orient >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        // Like Photos, presets start in the picture's own orientation.
        _portrait = State(initialValue: pixels.height > pixels.width)
    }

    private var aspect: Double? {
        VideoCrop(ratio: ratio, portrait: portrait).aspect(width: pixels.width, height: pixels.height)
    }

    private var fitted: CGRect {
        let a = area, inset: CGFloat = 6
        return CGRect(x: inset, y: inset, width: a.width - inset * 2, height: a.height - inset * 2)
    }

    private var cropOnScreen: CGRect {
        let f = fitted
        return CGRect(x: f.minX + crop.minX * f.width, y: f.minY + crop.minY * f.height,
                      width: crop.width * f.width, height: crop.height * f.height)
    }

    var body: some View {
        GlassPanel(title: model.regionTitle, subtitle: model.file.name, width: 420, onClose: model.backToRing) {
            preview
                .onChange(of:crop) { _,value in
                    guard case .crop = model.regionPurpose,let sampling=jpegSampling,
                          let raw=try? ImageEdits.rawRect(value,width:sampling.width,height:sampling.height,orientation:orientation) else { return }
                    let snapped=ImageEdits.displayRect(sampling.snapped(raw),width:sampling.width,height:sampling.height,orientation:orientation)
                    if abs(snapped.minX-value.minX)>0.0000001 || abs(snapped.minY-value.minY)>0.0000001 || abs(snapped.width-value.width)>0.0000001 || abs(snapped.height-value.height)>0.0000001 { crop=snapped }
                }
            PanelRow(label: "비율") {
                CropRatioControls(ratio: $ratio, portrait: $portrait, size: nil,
                                  canReset: crop != CGRect(x: 0, y: 0, width: 1, height: 1) || ratio != .free) {
                    withAnimation(.snappy) { crop = CGRect(x: 0, y: 0, width: 1, height: 1); ratio = .free }
                }
                .onChange(of: ratio) { _, _ in applyAspect() }
                .onChange(of: portrait) { _, _ in applyAspect() }
            }
            PanelRow(label: "크기") {
                HStack(spacing: 8) {
                    Text("W").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    TextField("", value: pixelBinding(\.width), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                    Text("H").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    TextField("", value: pixelBinding(\.height), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                    Text("px").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("취소", action: model.backToRing).buttonStyle(.glass)
                Button("적용") { model.applyRegion(crop) }
                    .disabled(model.isWorking)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
        .task {
            let url = model.file.url
            let (previewImg, sampling) = await Task.detached(priority: .userInitiated) {
                let img = panelPreview(of: url)
                let samp = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
                    ? (try? JPEGSampling(Data(contentsOf: url, options: .mappedIfSafe)))
                    : nil
                return (img, samp)
            }.value
            image = previewImg
            jpegSampling = sampling
        }
    }

    private var preview: some View {
        let f = fitted, c = cropOnScreen
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.06))
            if let image {
                Image(nsImage: image).resizable()
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            }
            CropFrame(crop: $crop, bounds: f, pixels: pixels, aspect: aspect)
            Text(verbatim: "\(Int(crop.width * pixels.width)) × \(Int(crop.height * pixels.height))")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor))
                .offset(x: c.minX + 8, y: c.minY + 8)
        }
        .frame(width: area.width, height: area.height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func applyAspect() {
        guard let aspect else { return }
        withAnimation(.snappy) { crop = CropFrame.largest(aspect: aspect, pixels: pixels, around: crop) }
    }

    private func pixelBinding(_ key: KeyPath<CGSize, CGFloat>) -> Binding<Int> {
        Binding(
            get: { Int((key == \CGSize.width ? crop.width : crop.height) * pixels[keyPath: key]) },
            set: { px in
                let n = min(max(CGFloat(px) / pixels[keyPath: key], 0.05), 1)
                if key == \CGSize.width { crop.size.width = n; crop.origin.x = min(crop.minX, 1 - n) }
                else { crop.size.height = n; crop.origin.y = min(crop.minY, 1 - n) }
                ratio = .free
            })
    }
}

// MARK: - Add background

struct AddBackgroundPanel: View {
    @ObservedObject var model: RingModel

    enum Background: Equatable {
        case gradient(Int), solid(Int), custom, image
    }
    enum Ratio: String, CaseIterable, Identifiable {
        case auto = "자동", square = "1:1", wide = "16:9", portrait = "4:5", tall = "9:16"
        var id: String { rawValue }
        var value: CGFloat? {
            switch self {
            case .auto: return nil
            case .square: return 1
            case .wide: return 16.0 / 9
            case .portrait: return 4.0 / 5
            case .tall: return 9.0 / 16
            }
        }
    }

    static let gradients: [[Color]] = [
        [Color(red: 1, green: 0.45, blue: 0.35), Color(red: 1, green: 0.8, blue: 0.3)],
        [Color(red: 0.55, green: 0.6, blue: 1), Color(red: 0.95, green: 0.6, blue: 0.9)],
        [Color(red: 0.3, green: 0.85, blue: 0.75), Color(red: 0.2, green: 0.5, blue: 0.95)],
        [Color(red: 0.98, green: 0.98, blue: 1), Color(red: 0.82, green: 0.86, blue: 0.95)],
        [Color(red: 0.15, green: 0.15, blue: 0.2), Color(red: 0.38, green: 0.32, blue: 0.55)],
        [Color(red: 1, green: 0.62, blue: 0.72), Color(red: 0.6, green: 0.4, blue: 1)],
        [Color(red: 0.97, green: 0.78, blue: 0.52), Color(red: 0.88, green: 0.38, blue: 0.3)],
        [Color(red: 0.4, green: 0.88, blue: 0.5), Color(red: 0.92, green: 0.95, blue: 0.35)],
    ]
    static let solids: [Color] = [.white, Color(white: 0.9), Color(white: 0.11), .red, .orange, .green, .blue, .purple]

    @State private var background: Background = .gradient(0)
    @State private var customColor: Color = .teal
    @State private var bgImage: NSImage?
    @State private var bgImageURL: URL?
    @State private var padding: Double = 160
    @State private var corner: Double = 24
    @State private var shadow: Double = 24
    @State private var ratio: Ratio = .auto
    private let image: NSImage?
    private let pixels: CGSize
    private let area = CGSize(width: 416, height: 240)

    init(model: RingModel) {
        self.model = model
        image = panelPreview(of:model.file.url)
        pixels = pixelSize(of: model.file.url)
    }

    var body: some View {
        GlassPanel(title: "배경 추가", subtitle: model.file.name, width: 456, onClose: model.backToRing) {
            preview
            VStack(alignment: .leading, spacing: 8) {
                Text("배경").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    ForEach(0..<Self.gradients.count, id: \.self) { i in
                        swatch(.gradient(i)) { LinearGradient(colors: Self.gradients[i], startPoint: .topLeading, endPoint: .bottomTrailing) }
                    }
                    Button(action: pickImage) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 15))
                            .frame(width: 36, height: 36)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.07)))
                            .overlay(selectionRing(background == .image))
                    }
                    .buttonStyle(.plain).help("이미지를 배경으로")
                }
                HStack(spacing: 8) {
                    ForEach(0..<Self.solids.count, id: \.self) { i in
                        swatch(.solid(i)) { Self.solids[i] }
                    }
                    ColorPicker("", selection: Binding(get: { customColor }, set: { customColor = $0; background = .custom }))
                        .labelsHidden().frame(width: 36, height: 36)
                        .overlay(selectionRing(background == .custom).allowsHitTesting(false))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 4) {
                sliderRow("여백", $padding, 0...400)
                sliderRow("모서리", $corner, 0...80)
                sliderRow("그림자", $shadow, 0...60)
            }
            PanelRow(label: "비율") {
                FillSegmented(selection: $ratio)
            }
            HStack(spacing: 8) {
                Button("초기화") {
                    withAnimation(.snappy) { background = .gradient(0); padding = 160; corner = 24; shadow = 24; ratio = .auto }
                }
                .buttonStyle(.glass)
                Spacer()
                Button("취소", action: model.backToRing).buttonStyle(.glass)
                Button("배경 넣어 저장", action: saveBackground)
                    .disabled(model.isWorking)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
        }
    }

    private var preview: some View {
        // Output size in pixels, then scaled to fit the preview area.
        let p = CGFloat(padding)
        let natural = CGSize(width: pixels.width + 2 * p, height: pixels.height + 2 * p)
        var out = natural
        if let value = ratio.value {
            out = natural.width / natural.height > value
                ? CGSize(width: natural.width, height: natural.width / value)
                : CGSize(width: natural.height * value, height: natural.height)
        }
        let s = min(area.width / out.width, area.height / out.height) * 0.94
        let inner = CGSize(width: out.width - 2 * p, height: out.height - 2 * p)
        let fit = min(inner.width / pixels.width, inner.height / pixels.height)
        let imgSize = CGSize(width: pixels.width * fit * s, height: pixels.height * fit * s)
        return ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.black.opacity(0.06))
            ZStack {
                backgroundFill
                if let image {
                    Image(nsImage: image).resizable()
                        .frame(width: imgSize.width, height: imgSize.height)
                        .clipShape(RoundedRectangle(cornerRadius: CGFloat(corner) * s, style: .continuous))
                        .shadow(color: .black.opacity(shadow > 0 ? 0.28 : 0), radius: CGFloat(shadow) * s, y: CGFloat(shadow) * s * 0.3)
                }
            }
            .frame(width: out.width * s, height: out.height * s)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(width: area.width, height: area.height)
        .animation(.snappy, value: ratio)
    }

    @ViewBuilder private var backgroundFill: some View {
        switch background {
        case .gradient(let i): LinearGradient(colors: Self.gradients[i], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .solid(let i): Self.solids[i]
        case .custom: customColor
        case .image:
            if let bgImage { Image(nsImage: bgImage).resizable().aspectRatio(contentMode: .fill) } else { Color.gray }
        }
    }

    private func swatch<S: View>(_ value: Background, @ViewBuilder fill: () -> S) -> some View {
        Button { withAnimation(.snappy) { background = value } } label: {
            fill()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.black.opacity(0.08)))
                .overlay(selectionRing(background == value))
        }
        .buttonStyle(.plain)
    }

    private func selectionRing(_ on: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12.5, style: .continuous)
            .stroke(Color.accentColor, lineWidth: 2.5)
            .padding(-3.5)
            .opacity(on ? 1 : 0)
    }

    private func sliderRow(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        PanelRow(label: label) {
            HStack(spacing: 12) {
                Slider(value: value, in: range)
                Text("\(Int(value.wrappedValue)) px")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    private func saveBackground() {
        let colors: [Color]
        switch background {
        case .gradient(let i):colors = Self.gradients[i]
        case .solid(let i):colors = [Self.solids[i]]
        case .custom:colors = [customColor]
        case .image:colors = [.gray]
        }
        let rgba = colors.map { color -> RGBAColor in
            let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
            return RGBAColor(red:c.redComponent,green:c.greenComponent,blue:c.blueComponent,alpha:c.alphaComponent)
        }
        model.run(.edit(.background(BackgroundOptions(colors:rgba,imageURL:background == .image ? bgImageURL:nil,
                                                    padding:padding,corner:corner,shadow:shadow,ratio:ratio.value.map(Double.init)))))
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url, let img = panelPreview(of:url) {
            bgImageURL = url
            bgImage = img
            background = .image
        }
    }
}

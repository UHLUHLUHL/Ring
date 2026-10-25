import SwiftUI
import AppKit
import QuartzCore

/// Glass for every supported macOS. macOS 26+ uses the system Liquid Glass unchanged.
/// macOS 15 has no Liquid Glass and no backdrop refraction filter, so the closest
/// reproduction is a live blur of what is really behind the window (a private
/// CABackdropLayer, which needs no screen-recording permission), raised saturation,
/// a faint chromatic fringe and a specular rim. If the private layer is missing,
/// a system material is used instead.
enum RingGlassStyle { case regular, clear }

enum RingGlassSupport {
    /// `RING_LEGACY_GLASS=1` renders the macOS 15 path on macOS 26 for comparison.
    static let forceLegacy = ProcessInfo.processInfo.environment["RING_LEGACY_GLASS"] == "1"
    static var native: Bool {
        if forceLegacy { return false }
        if #available(macOS 26, *) { return true }
        return false
    }
    /// Filter types the window server offers on this system (private, read once).
    static let filterTypes: Set<String> = {
        guard let cls = NSClassFromString("CAFilter") as? NSObject.Type,
              cls.responds(to: NSSelectorFromString("filterTypes")),
              let types = cls.perform(NSSelectorFromString("filterTypes"))?.takeUnretainedValue() as? [String] else { return [] }
        return Set(types)
    }()
    static var backdrop: Bool { NSClassFromString("CABackdropLayer") != nil && filterTypes.contains("gaussianBlur") }
}

@available(macOS 26, *)
private extension RingGlassStyle {
    func glass(interactive: Bool) -> Glass {
        let base: Glass = self == .regular ? .regular : .clear
        return interactive ? base.interactive() : base
    }
}

extension View {
    /// Replacement for `.glassEffect(_, in:)` that also runs on macOS 15.
    @ViewBuilder func ringGlass<S: Shape>(_ style: RingGlassStyle = .regular, interactive: Bool = false, in shape: S) -> some View {
        if #available(macOS 26, *), RingGlassSupport.native {
            glassEffect(style.glass(interactive: interactive), in: shape)
        } else {
            background { LegacyGlass(shape: shape, style: style) }
        }
    }

    /// Replacement for `.buttonStyle(.glass)` / `.glassProminent`.
    @ViewBuilder func ringGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *), RingGlassSupport.native {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// The macOS 15 glass surface drawn behind content.
private struct LegacyGlass<S: Shape>: View {
    let shape: S
    let style: RingGlassStyle

    var body: some View {
        ZStack {
            if RingGlassSupport.backdrop {
                BackdropBlur(radius: style == .regular ? 14 : 5, saturation: style == .regular ? 1.7 : 1.35)
            } else {
                Rectangle().fill(style == .regular ? .regularMaterial : .ultraThinMaterial)
            }
            // A light film keeps text readable on busy backgrounds.
            Rectangle().fill(Color.white.opacity(style == .regular ? 0.10 : 0.04))
        }
        .clipShape(shape)
        // Specular rim: bright where light would hit the top-left edge, fading around.
        .overlay {
            shape.stroke(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.12), .white.opacity(0.05), .white.opacity(0.35)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
        }
        // A soft inner glow along the edge suggests the curved lip of the glass.
        .overlay {
            shape.stroke(Color.white.opacity(0.18), lineWidth: 6).blur(radius: 5).clipShape(shape)
        }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .allowsHitTesting(false)
    }
}

/// Live blur of the real screen content behind the window via a private
/// backdrop layer. The window server composites it; the app never reads pixels.
private struct BackdropBlur: NSViewRepresentable {
    let radius: Double
    let saturation: Double

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        guard let type = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return view }
        let layer = type.init()
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.frame = view.bounds
        layer.setValue(true, forKey: "enabled")
        layer.setValue(1.0, forKey: "scale")
        view.layer?.addSublayer(layer)
        apply(to: layer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let layer = view.layer?.sublayers?.first { apply(to: layer) }
    }

    private func apply(to layer: CALayer) {
        var filters: [NSObject] = []
        if let blur = Self.filter("gaussianBlur") {
            blur.setValue(radius, forKey: "inputRadius")
            blur.setValue(true, forKey: "inputNormalizeEdges")
            filters.append(blur)
        }
        if let saturate = Self.filter("colorSaturate") {
            saturate.setValue(saturation, forKey: "inputAmount")
            filters.append(saturate)
        }
        // A sub-pixel colour split: the only refraction-like cue available on macOS 15.
        if let fringe = Self.filter("chromaticAberration") {
            fringe.setValue(NSValue(point: NSPoint(x: 0.9, y: 0)), forKey: "inputRedOffset")
            fringe.setValue(NSValue(point: NSPoint(x: -0.9, y: 0)), forKey: "inputBlueOffset")
            filters.append(fringe)
        }
        layer.filters = filters
    }

    private static func filter(_ type: String) -> NSObject? {
        guard RingGlassSupport.filterTypes.contains(type),
              let cls = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        return cls.perform(NSSelectorFromString("filterWithType:"), with: type)?.takeUnretainedValue() as? NSObject
    }
}

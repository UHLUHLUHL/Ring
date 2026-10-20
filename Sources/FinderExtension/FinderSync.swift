import Cocoa
import FinderSync

/// Adds "Ring으로 변환·편집" to Finder's context menu and hands the file to Ring.app.
@objc(RingFinderSync)
final class RingFinderSync: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    /// Pointer position when the context menu opened, i.e. where the user right-clicked the file.
    private var clickPoint: NSPoint?

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        clickPoint = NSEvent.mouseLocation
        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: "Ring으로 변환·편집", action: #selector(openRing(_:)), keyEquivalent: "")
        item.image = Self.glyph
        menu.addItem(item)
        return menu
    }

    @objc func openRing(_ sender: AnyObject?) {
        guard let urls=FIFinderSyncController.default().selectedItemURLs(),!urls.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "ring"
        components.host = "open"
        components.queryItems = urls.map { URLQueryItem(name:"path",value:$0.path) }
        if let p = clickPoint {
            // Without this the ring would open where the menu item was, not on the file.
            components.queryItems? += [URLQueryItem(name: "x", value: String(Int(p.x))),
                                       URLQueryItem(name: "y", value: String(Int(p.y)))]
        }
        guard let target = components.url else { return }
        // Ask Launch Services to bring Ring to the front; otherwise Finder keeps keyboard focus
        // and keys like esc never reach the ring.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(target, configuration: config)
    }

    /// Four-arc ring mark, drawn as a template so it follows the menu's text colour.
    static let glyph: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let c = NSPoint(x: rect.midX, y: rect.midY)
            NSColor.black.setStroke()
            for k in 0..<4 {
                let path = NSBezierPath()
                path.lineWidth = 2.4
                path.lineCapStyle = .round
                let start = CGFloat(k * 90 + 12), end = CGFloat(k * 90 + 78)
                path.appendArc(withCenter: c, radius: 5.6, startAngle: start, endAngle: end)
                path.stroke()
            }
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

import AppKit
import SwiftUI

enum RingWindowLayout {
    static let size = CGSize(width: 560, height: 720)
    /// Distance from the window's top edge to the ring centre.
    static let ringCenterY: CGFloat = 300
    static let dragRadius:CGFloat = (RingMetrics.hubDiameter-12)/2
    /// The part of the window the ring screen actually uses (ring + tab pill + hints),
    /// relative to the ring centre. Only this has to stay on screen.
    static let ringBlock = CGRect(x: -RingMetrics.canvas / 2, y: -RingMetrics.canvas / 2,
                                  width: RingMetrics.canvas, height: RingMetrics.canvas + 80)
}

/// Borderless, transparent panel that can take keyboard focus without activating the app first.
/// The ring is a non-activating panel that is often not key yet when the user clicks a wedge
/// (opened from Finder). Without this the first click only made the panel key and was lost.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class RingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Ring's own key handling. Runs before SwiftUI sees the key: otherwise SwiftUI used tab
    /// to move focus between buttons instead of switching 변환/편집.
    var keyHandler: ((NSEvent) -> Bool)?
    var canDragAt: ((NSPoint) -> Bool)?
    weak var titleDragView:NSView?
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // The transparent canvas may extend beyond the screen. AppKit must not
        // shrink it during a native drag and shift the fixed-size SwiftUI content.
        frameRect
    }

    override func sendEvent(_ event: NSEvent) {
        // Handle the hub before SwiftUI's ancestor tap recognizer. A representable
        // drag view under that recognizer does not consistently receive mouseDown.
        if event.type == .leftMouseDown {
            dragStart = nil
            if canDragAt?(event.locationInWindow) == true {
                dragStart = (convertPoint(toScreen: event.locationInWindow), frame.origin)
                NSCursor.closedHand.set()
                return
            }
        }
        if let start = dragStart {
            if event.type == .leftMouseDragged {
                let mouse = convertPoint(toScreen: event.locationInWindow)
                setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                       y: start.origin.y + mouse.y - start.mouse.y))
                return
            }
            if event.type == .leftMouseUp {
                dragStart = nil
                NSCursor.openHand.set()
                DebugLog.write("window dragged \(NSStringFromPoint(start.origin)) → \(NSStringFromRect(frame))")
                return
            }
        }
        if event.type == .keyDown {
            DebugLog.write("panel keyDown \(event.keyCode)")
            if keyHandler?(event) == true { return }
        }
        super.sendEvent(event)
    }
}

/// Temporary diagnostics for the esc problem (~/Library/Logs/Ring.log).
enum DebugLog {
    static func write(_ message: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Ring.log")
        let line = "\(Date()) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

@MainActor
final class RingWindowController {
    static var current: RingWindowController?

    private let panel: RingPanel
    let model: RingModel
    private var monitors: [Any] = []
    private var resignObserver: NSObjectProtocol?
    private var screenWatch: Any?

    /// Opens the ring for `url`, centred on `point` (screen coordinates, bottom-left origin).
    static func show(url: URL, selection:[URL] = [], at point: NSPoint = NSEvent.mouseLocation, center: NSPoint? = nil, hover: Int? = nil, editTab: Bool = false) {
        current?.close(animated: false)
        HomeWindow.shared.window?.orderOut(nil)
        let controller = RingWindowController(file: FileInfo(url: url,selection:selection), at: point, center: center)
        if editTab, !controller.model.file.editActions.isEmpty {
            controller.model.tab = .edit
            controller.model.tabProgress = 1
        }
        controller.model.hovered = hover
        current = controller
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Keep the chooser above the floating ring and let its own Escape key cancel it.
    static func chooseFiles(_ chooser: NSOpenPanel, completion: @escaping ([URL]) -> Void) {
        guard let controller = current else { return }
        EscapeHotKey.unregister()
        chooser.beginSheetModal(for: controller.panel) { [weak controller] response in
            guard let controller, current === controller else { return }
            EscapeHotKey.register()
            controller.bringToFront()
            if response == .OK { completion(chooser.urls) }
        }
    }

    private init(file: FileInfo, at point: NSPoint, center: NSPoint?) {
        model = RingModel(file: file)
        var size = RingWindowLayout.size
        if let frame = Self.screen(for: point)?.visibleFrame {
            model.maximumPanelHeight = frame.height - 12
            size.height = min(size.height, model.maximumPanelHeight)
        }
        model.viewportHeight = size.height
        panel = RingPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false

        let host = FirstClickHostingView(rootView: RootView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        let origin = Self.ringOrigin(for: point, center: center, size: size)
        panel.setFrameOrigin(origin)
        model.close = { [weak self] in self?.close(animated: true) }
        model.screenChanged = { [weak self] screen in self?.fitForScreen(screen) }

        NSApp.activate()
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak panel] in
            DebugLog.write("after show: appActive=\(NSApp.isActive) panelKey=\(panel?.isKeyWindow ?? false) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")")
        }

        // Keys are handled in the panel itself, and esc additionally as a hot key, because a plain
        // esc key press never arrived (see EscapeHotKey).
        panel.keyHandler = { [weak self] event in self?.model.handleKey(event) ?? false }
        panel.canDragAt = { [weak self] point in
            guard let self,!self.model.isNavigating,!self.model.isCompleting else { return false }
            if self.model.screen != .ring {
                guard let title=self.panel.titleDragView else { return false }
                let rect=title.convert(title.bounds,to:nil)
                return rect.insetBy(dx:0,dy:-8).contains(point) && point.x>rect.minX+44
            }
            let dx=point.x-self.panel.frame.width/2
            let dy=point.y-(self.panel.frame.height-RingWindowLayout.ringCenterY)
            return dx*dx+dy*dy<=RingWindowLayout.dragRadius*RingWindowLayout.dragRadius
        }
        EscapeHotKey.register()
        // Clicking anywhere outside the panel closes it, like a menu.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            DebugLog.write("outside click \(Int(NSEvent.mouseLocation.x)),\(Int(NSEvent.mouseLocation.y)) panel=\(self.map { NSStringFromRect($0.panel.frame) } ?? "-")")
            Task { @MainActor in
                guard let self,self.model.screen == .ring,!self.model.isWorking else { return }
                self.close(animated:true)
            }
        }) { monitors.append(m) }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            DebugLog.write("resign active → close")
            Task { @MainActor in
                guard let self,self.model.screen == .ring,!self.model.isWorking else { return }
                self.close(animated:true)
            }
        }
    }

    private static func screen(for point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    /// Distance from the file to the ring centre: ring radius + about half an icon + a gap,
    /// so the ring opens *beside* the file and the file stays visible (guessed values).
    private static let besideOffset: CGFloat = RingMetrics.outer + 58

    /// Ring opens to the right of the file (left when there is no room). Only the ring block is
    /// pushed back on screen, so it stays as close to the file as possible near the edges.
    private static func ringOrigin(for point: NSPoint, center: NSPoint? = nil, size: CGSize) -> NSPoint {
        if let center {
            return NSPoint(x: center.x - size.width / 2, y: center.y - (size.height - RingWindowLayout.ringCenterY))
        }
        var c = NSPoint(x: point.x + besideOffset, y: point.y)
        if let vf = screen(for: point)?.visibleFrame.insetBy(dx: 6, dy: 6) {
            let b = RingWindowLayout.ringBlock
            if c.x + b.maxX > vf.maxX { c.x = point.x - besideOffset }
            c.x = min(max(c.x, vf.minX - b.minX), vf.maxX - b.maxX)
            // ringBlock is in top-down coordinates; flip for AppKit.
            c.y = min(max(c.y, vf.minY + b.maxY), vf.maxY + b.minY)
        }
        return NSPoint(x: c.x - size.width / 2, y: c.y - (size.height - RingWindowLayout.ringCenterY))
    }

    /// Tool panels are bigger than the ring: slide the window so the whole panel is visible.
    private func fitForScreen(_ screen: RingModel.Screen) {
        guard screen != .ring, let vf = Self.screen(for: NSPoint(x: panel.frame.midX, y: panel.frame.midY))?.visibleFrame else { return }
        var f = panel.frame
        model.maximumPanelHeight = vf.height - 12
        f.size.height = min(model.viewportHeight, model.maximumPanelHeight)
        model.viewportHeight = f.height
        f.origin.x = min(max(f.origin.x, vf.minX), vf.maxX - f.width)
        f.origin.y = min(max(f.origin.y, vf.minY), vf.maxY - f.height)
        if f != panel.frame {
            panel.setFrame(f, display: true)
        }
    }

    private var closing = false

    func handleEscape() { model.escape() }

    func close(animated: Bool) {
        EscapeHotKey.unregister()
        if Self.current === self { Self.current = nil }
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
        // Always take the window down, even if a close is already running, so a faded-out
        // (invisible) panel can never be left on screen.
        let panel = self.panel
        guard animated, !closing else { panel.orderOut(nil); return }
        closing = true
        let duration = RingMotion.closeDuration
        withAnimation(RingMotion.dismissal) { model.appeared = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { panel.orderOut(nil) }
    }
}

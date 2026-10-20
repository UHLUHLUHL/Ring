import AppKit

enum AppIDs {
    static let app = "com.dlgksdnf.Ring"
    static let finderExtension = "com.dlgksdnf.Ring.FinderExtension"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var openedFromURL = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = ServiceProvider()
        NSUpdateDynamicServices()
        FinderShortcut.shared.start()
        DebugLog.write("launch: accessibility trusted=\(AXIsProcessTrusted())")
        // Launched by hand (no ring:// URL arrived) → show the setup window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if self?.openedFromURL == false { HomeWindow.shared.show() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let ring = RingWindowController.current { ring.bringToFront() }
        else { HomeWindow.shared.show() }
        return false
    }

    /// ring://open?path=/absolute/path
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let components = URLComponents(string: string) else { return }
        guard components.host == "open",
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value else { return }
        openedFromURL = true
        // `hover` / `tab` let a script open the ring in a given state for screenshots.
        let query = components.queryItems ?? []
        let selection=query.filter { $0.name == "path" }.compactMap { $0.value }.map { URL(fileURLWithPath:$0) }
        let hover = query.first(where: { $0.name == "hover" })?.value.flatMap(Int.init)
        let editTab = query.first(where: { $0.name == "tab" })?.value == "edit"
        if let g = query.first(where: { $0.name == "glass" })?.value { RingMetrics.glass = (g == "regular") ? .regular : .clear }
        // x/y: where the file was right-clicked (sent by the Finder extension).
        let x = query.first(where: { $0.name == "x" })?.value.flatMap(Double.init)
        let y = query.first(where: { $0.name == "y" })?.value.flatMap(Double.init)
        let point = (x != nil && y != nil) ? NSPoint(x: x!, y: y!) : NSEvent.mouseLocation
        let screen = query.first(where: { $0.name == "screen" })?.value
        RingPlacement.resolve(file: point) { center in
            RingWindowController.show(url: URL(fileURLWithPath: path),selection:selection,at: point, center: center, hover: hover, editTab: editTab)
            switch screen {
            case "crop": RingWindowController.current?.model.screen = .crop
            case "background": RingWindowController.current?.model.screen = .addBackground
            default: break
            }
        }
    }
}

/// Fallback entry point: Finder's 서비스 menu ("Ring으로 변환·편집").
final class ServiceProvider: NSObject {
    @objc func openRing(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let urls=pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],let url=urls.first else { return }
        Task { @MainActor in RingWindowController.show(url: url,selection:urls) }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

/// UserDefaults keys for the settings shown in the Ring window.
enum AppSettings {
    static let showShortcutHints = "showShortcutHints"
    static let shortcutKeyCode = "shortcutKeyCode"
    static let shortcutModifiers = "shortcutModifiers"
}

// Documentation-only capture harness. Uses the production views without editing Ring.
import AppKit
import SwiftUI

enum AppIDs {
    static let app = "com.dlgksdnf.Ring.DemoCapture"
    static let finderExtension = "com.dlgksdnf.Ring.FinderExtension"
}
enum AppSettings {
    static let showShortcutHints = "showShortcutHints"
    static let shortcutKeyCode = "shortcutKeyCode"
    static let shortcutModifiers = "shortcutModifiers"
}

@MainActor final class CaptureState: ObservableObject {
    @Published var model: RingModel
    let directory: URL
    init() {
        directory = ProcessInfo.processInfo.environment["RING_DEMO_MEDIA"].map { URL(fileURLWithPath: $0) } ?? Bundle.main.bundleURL.deletingLastPathComponent()
        UserDefaults.standard.set(false, forKey: AppSettings.showShortcutHints)
        model = RingModel(file: FileInfo(url: directory.appendingPathComponent("coast.png")))
    }
    func show(_ mode: Int) {
        let video = mode >= 4 && mode <= 6
        let next = RingModel(file: FileInfo(url: directory.appendingPathComponent(video ? "coast.mp4" : "coast.png")))
        next.thumbnail = NSImage(contentsOf: directory.appendingPathComponent("coast.png"))
        next.appeared = true
        if mode == 2 { next.hovered = 0 }
        if mode == 5 { next.hovered = 1 }
        if mode == 6 { next.screen = .tool(.animation(.webp)) }
        if mode == 3 || mode == 7 { next.isWorking = true; next.isCompleting = true }
        model = next
    }
}

@MainActor struct CaptureContent: View {
    @ObservedObject var state: CaptureState
    var body: some View {
        ZStack(alignment: .top) {
            Color(red: 29/255, green: 38/255, blue: 48/255)
            RootView(model: state.model).id(ObjectIdentifier(state.model))
            HStack {
                ForEach(1...7, id: \.self) { n in
                    Button(String(n)) { state.show(n) }.accessibilityLabel("Capture state \(n)")
                }
            }.padding(8)
        }
        .frame(width: 560, height: 720)
        .environment(\.colorScheme, .dark)
        .tint(.blue)
    }
}

@main struct CaptureStudio {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        app.mainMenu = menu
        let state = CaptureState()
        state.show(1)
        let window = RingPanel(contentRect: NSRect(x: 200, y: 100, width: 560, height: 720), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.hidesOnDeactivate = false
        window.hasShadow = false
        window.title = "Ring Demo Capture"
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: CaptureContent(state: state))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            app.activate(ignoringOtherApps: true)
            window.setFrame(NSRect(x: 200, y: 100, width: 560, height: 720), display: true)
            window.orderFrontRegardless()
            window.makeKey()
        }
        withExtendedLifetime((window, state)) { app.run() }
    }
}

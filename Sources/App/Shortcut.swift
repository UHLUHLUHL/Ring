import AppKit
import Carbon.HIToolbox

/// The Finder shortcut, ⌥⌘R by default and user-settable in the settings window.
///
/// It used to be ⇧R, which swallowed a capital R while renaming a file or typing in Finder's
/// search field. Any combination that does not collide with an existing macOS or Finder shortcut
/// is allowed (see ShortcutConflicts). A combination that types a character (⇧R, R, ⌥R…) is
/// watched with an event tap instead of a hot key, and is let through untouched while a text
/// field in Finder has focus, so renaming and searching still get the letter. That needs
/// Accessibility access (to read Finder's focus and to filter key events).
struct FinderHotKey: Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let standard = FinderHotKey(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(cmdKey | optionKey))

    var display: String { KeyMods(carbon: carbonModifiers).symbols + (KeyNames.name(Int(keyCode)) ?? "?") }

    /// Without ⌘ or ⌃ the key would type a character in a text field (F-keys do not).
    var typesText: Bool {
        KeyMods(carbon: carbonModifiers).isDisjoint(with: [.cmd, .control]) && !KeyNames.functionKeys.contains(Int(keyCode))
    }

    static var current: FinderHotKey {
        let d = UserDefaults.standard
        guard d.object(forKey: AppSettings.shortcutKeyCode) != nil else { return standard }
        return FinderHotKey(keyCode: UInt32(d.integer(forKey: AppSettings.shortcutKeyCode)),
                            carbonModifiers: UInt32(d.integer(forKey: AppSettings.shortcutModifiers)))
    }

    func save() {
        let d = UserDefaults.standard
        d.set(Int(keyCode), forKey: AppSettings.shortcutKeyCode)
        d.set(Int(carbonModifiers), forKey: AppSettings.shortcutModifiers)
    }

    /// Builds a shortcut from a key press, or explains why it cannot be used.
    static func from(_ event: NSEvent) -> Result<FinderHotKey, ShortcutError> {
        let code = Int(event.keyCode)
        let mods = KeyMods(event.modifierFlags)
        guard code != kVK_Escape, KeyNames.name(code) != nil else { return .failure(.unsupportedKey) }
        if let name = ShortcutConflicts.conflict(keyCode: code, modifiers: mods) { return .failure(.conflict(name)) }
        let key = FinderHotKey(keyCode: UInt32(code), carbonModifiers: mods.carbon)
        if key.typesText, !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            return .failure(.needsAccessibility)
        }
        return .success(key)
    }
}

enum ShortcutError: Error {
    case needsAccessibility, unsupportedKey, conflict(String), taken, tapFailed

    var message: String {
        switch self {
        case .needsAccessibility: return "⌘·⌃ 없는 조합은 이름 변경·검색 입력 중인지 확인해야 해서 손쉬운 사용 권한이 필요해요. 시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용에서 Ring을 켠 뒤 다시 녹화해 주세요."
        case .tapFailed: return "키 입력 감시를 시작하지 못했어요. 손쉬운 사용 권한을 확인해 주세요."
        case .unsupportedKey: return "이 키는 단축키로 쓸 수 없어요."
        case .conflict(let name): return "이미 쓰이는 단축키예요: \(name). 다른 조합을 골라 주세요."
        case .taken: return "다른 앱이 이미 쓰고 있는 조합이에요. 다른 조합을 골라 주세요."
        }
    }
}

/// Registers the Finder shortcut while Finder is the frontmost app.
@MainActor
final class FinderShortcut {
    static let shared = FinderShortcut()

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let which = id.id
            Task { @MainActor in
                if which == 2 { RingWindowController.current?.handleEscape() } else { FinderShortcut.shared.fire() }
            }
            return noErr
        }, 1, &spec, nil, &handler)

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in FinderShortcut.shared.update(finderFront: app?.bundleIdentifier == "com.apple.finder") }
        }
        update(finderFront: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder")
    }

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapKey: FinderHotKey?
    private var armed: Bool { hotKey != nil || tap != nil }

    private func update(finderFront: Bool) {
        if finderFront { RingPlacement.prefetch() }
        if finderFront, !armed {
            _ = arm(FinderHotKey.current)
        } else if !finderFront {
            disarm()
        }
    }

    private func arm(_ key: FinderHotKey) -> ShortcutError? {
        if key.typesText { return startTap(key) }
        let id = EventHotKeyID(signature: OSType(0x524E_4721), id: 1) // 'RNG!'
        guard RegisterEventHotKey(key.keyCode, key.carbonModifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr else {
            hotKey = nil
            return .taken
        }
        return nil
    }

    private func disarm() {
        if let key = hotKey { UnregisterEventHotKey(key); hotKey = nil }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil; tapSource = nil; tapKey = nil
    }

    /// Saves a new shortcut after checking that the system lets Ring use it.
    func change(to key: FinderHotKey) -> ShortcutError? {
        let wasArmed = armed
        disarm()
        if let error = arm(key) {
            disarm()
            if wasArmed { _ = arm(FinderHotKey.current) }
            return error
        }
        key.save()
        if !wasArmed { disarm() }
        return nil
    }

    // MARK: event tap for shortcuts that type a character

    private func startTap(_ key: FinderHotKey) -> ShortcutError? {
        guard AXIsProcessTrusted() else { return .needsAccessibility }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { FinderShortcut.shared.reenableTap() }
                return Unmanaged.passUnretained(event)
            }
            let consumed = MainActor.assumeIsolated { FinderShortcut.shared.handleTap(event) }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil) else { return .tapFailed }
        tap = port; tapKey = key
        tapSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return nil
    }

    fileprivate func reenableTap() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    /// True when the key press was Ring's shortcut and Finder is not editing text.
    fileprivate func handleTap(_ event: CGEvent) -> Bool {
        guard let key = tapKey, event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              UInt32(event.getIntegerValueField(.keyboardEventKeycode)) == key.keyCode else { return false }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        guard KeyMods(flags) == KeyMods(carbon: key.carbonModifiers),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder",
              !Self.finderIsEditingText() else { return false }
        fire()
        return true
    }

    /// Finder's focused element is a rename field, search field or other text input.
    private static func finderIsEditingText() -> Bool {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return false }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var focused: CFTypeRef?
        // If Finder's focus cannot be read, assume typing so a letter is never swallowed.
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return true }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element as! AXUIElement, kAXRoleAttribute as CFString, &role)
        let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
        return textRoles.contains(role as? String ?? "")
    }

    fileprivate func fire() {
        // Read the selection off the main thread; the first call triggers the
        // "Ring wants to control Finder" permission prompt.
        DispatchQueue.global(qos: .userInitiated).async {
            let selection = FinderSelection.read()
            DispatchQueue.main.async {
                guard let selection else { NSSound.beep(); return }
                RingPlacement.resolve(file: selection.point) { center in
                    RingWindowController.show(url: selection.url,selection:selection.urls,at: selection.point, center: center)
                }
            }
        }
    }
}

enum FinderSelection {
    struct Result { let url: URL; let urls:[URL]; let point: NSPoint }

    /// First selected item and the best guess of where it is on screen.
    static func read() -> Result? {
        let source = """
        tell application "Finder"
            set sel to selection
            if sel is {} then return ""
            set f to item 1 of sel
            set p to POSIX path of (f as alias)
            set paths to {}
            repeat with selectedFile in sel
                set end of paths to POSIX path of (selectedFile as alias)
            end repeat
            set loc to "none"
            try
                set dp to desktop position of f
                set loc to "desk " & (item 1 of dp) & " " & (item 2 of dp)
            end try
            if loc is "none" then
                try
                    set b to bounds of front Finder window
                    set loc to "win " & (item 1 of b) & " " & (item 2 of b) & " " & (item 3 of b) & " " & (item 4 of b)
                end try
            end if
            return {p, loc, paths}
        end tell
        """
        var error: NSDictionary?
        guard let out=NSAppleScript(source:source)?.executeAndReturnError(&error),
              let path=out.atIndex(1)?.stringValue,!path.isEmpty else { return nil }
        let url=URL(fileURLWithPath:path)
        let list=out.atIndex(3)
        let urls=(list?.numberOfItems ?? 0)>0 ? (1...list!.numberOfItems).compactMap { list!.atIndex($0)?.stringValue }.map { URL(fileURLWithPath:$0) } : [url]
        let parts=(out.atIndex(2)?.stringValue ?? "").split(separator:" ").map(String.init)
        let nums = parts.dropFirst().compactMap { Double($0) }
        // AppleScript uses top-left origin on the main display; AppKit uses bottom-left.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        func flip(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: x, y: mainHeight - y) }

        var point = NSEvent.mouseLocation
        if parts.first == "desk", nums.count == 2 {
            // Desktop position is the icon's centre-top area; nudge down onto the icon (guess).
            point = flip(nums[0], nums[1] + 24)
        } else if parts.first == "win", nums.count == 4 {
            let frame = NSRect(x: nums[0], y: mainHeight - nums[3], width: nums[2] - nums[0], height: nums[3] - nums[1])
            // Icons/rows are not exposed without Accessibility access; the pointer is usually
            // right where the user just clicked the file, so prefer it while it is inside the window.
            if !frame.contains(point) { point = NSPoint(x: frame.midX, y: frame.midY) }
        }
        return Result(url:url,urls:urls,point:point)
    }
}

/// esc while the ring is open, registered as a system hot key for exactly that time.
///
/// esc never reached the ring window as a normal key press: something in front of the app
/// (for example a tool that grabs esc globally) took it first. A registered hot key is
/// delivered to Ring directly.
@MainActor
enum EscapeHotKey {
    private static var ref: EventHotKeyRef?

    static func register() {
        guard ref == nil else { return }
        let id = EventHotKeyID(signature: OSType(0x524E_4721), id: 2)
        let status = RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &ref)
        DebugLog.write("esc hotkey register status=\(status)")
    }

    static func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

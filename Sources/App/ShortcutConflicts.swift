import AppKit
import Carbon.HIToolbox

/// Modifier keys of a shortcut, independent of AppKit/Carbon/AX encodings.
struct KeyMods: OptionSet, Hashable {
    let rawValue: Int
    static let cmd = KeyMods(rawValue: 1), shift = KeyMods(rawValue: 2), option = KeyMods(rawValue: 4), control = KeyMods(rawValue: 8)

    init(rawValue: Int) { self.rawValue = rawValue }
    init(_ flags: NSEvent.ModifierFlags) {
        var m: KeyMods = []
        if flags.contains(.command) { m.insert(.cmd) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        self = m
    }
    init(carbon: UInt32) {
        var m: KeyMods = []
        if carbon & UInt32(cmdKey) != 0 { m.insert(.cmd) }
        if carbon & UInt32(shiftKey) != 0 { m.insert(.shift) }
        if carbon & UInt32(optionKey) != 0 { m.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { m.insert(.control) }
        self = m
    }
    var carbon: UInt32 {
        var c = 0
        if contains(.cmd) { c |= cmdKey }
        if contains(.shift) { c |= shiftKey }
        if contains(.option) { c |= optionKey }
        if contains(.control) { c |= controlKey }
        return UInt32(c)
    }
    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.cmd) ? "⌘" : "")
    }
}

/// Key names from the physical key code on the ASCII-capable layout (ABC/US), so a key pressed
/// while the Korean input source is on is shown and stored as R, not ㄱ. The hot key itself is
/// registered by key code, so it fires whichever input source is selected.
enum KeyNames {
    private static let special: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]
    static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]

    static func name(_ keyCode: Int) -> String? {
        if let s = special[keyCode] { return s }
        guard let c = character(keyCode), !c.isEmpty, c.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 }) else { return nil }
        return c.uppercased()
    }

    /// Key code for a character on the ASCII-capable layout (for menu key equivalents).
    static func keyCode(for text: String) -> Int? {
        let wanted = text.lowercased()
        return (0..<128).first { special[$0] == nil && character($0) == wanted }
    }

    private static func character(_ keyCode: Int) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0, length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

/// Finds an existing macOS / Finder shortcut that a new Ring shortcut would collide with.
/// The Ring hot key is only registered while Finder is in front, so the relevant set is:
/// system shortcuts (Keyboard settings), Finder's menus, text editing in Finder's rename and
/// search fields, and user-defined App Shortcuts. Shortcuts of other apps registered as global
/// hot keys are caught when registration fails.
enum ShortcutConflicts {
    struct Entry { let keyCode: Int; let modifiers: KeyMods; let name: String }

    static func conflict(keyCode: Int, modifiers: KeyMods) -> String? {
        let all = systemShortcuts() + finderMenu() + textEditing + userAppShortcuts() + fixed
        return all.first { $0.keyCode == keyCode && $0.modifiers == modifiers }?.name
    }

    /// Enabled entries of com.apple.symbolichotkeys (what System Settings › Keyboard shows).
    private static func systemShortcuts() -> [Entry] {
        guard let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys"),
              let keys = domain["AppleSymbolicHotKeys"] as? [String: Any] else { return [] }
        return keys.compactMap { id, value in
            guard let item = value as? [String: Any], (item["enabled"] as? Bool) ?? ((item["enabled"] as? Int) == 1),
                  let params = (item["value"] as? [String: Any])?["parameters"] as? [Int], params.count == 3,
                  params[1] != 65535 else { return nil }
            let flags = NSEvent.ModifierFlags(rawValue: UInt(params[2]))
            return Entry(keyCode: params[1], modifiers: KeyMods(flags), name: "시스템 단축키 · " + (symbolicNames[Int(id) ?? -1] ?? "키보드 설정 \(id)번"))
        }
    }

    private static let symbolicNames: [Int: String] = [
        7: "키보드 접근: 메뉴 막대", 8: "키보드 접근: Dock", 9: "키보드 접근: 윈도우", 10: "키보드 접근: 도구 막대", 11: "키보드 접근: 플로팅 윈도우",
        12: "키보드 접근: 메뉴 막대", 13: "키보드 접근 켜기/끄기", 27: "다음 윈도우로 초점 이동", 28: "화면 저장", 29: "화면을 클립보드로 복사",
        30: "선택 영역 저장", 31: "선택 영역을 클립보드로 복사", 32: "Mission Control", 33: "응용 프로그램 윈도우", 36: "데스크탑 보기",
        52: "Dock 가리기", 57: "상태 메뉴에 초점", 59: "VoiceOver", 60: "이전 입력 소스", 61: "다음 입력 소스", 64: "Spotlight",
        65: "Finder 검색 윈도우", 79: "왼쪽 공간으로 이동", 81: "오른쪽 공간으로 이동", 98: "도움말 메뉴", 118: "데스크탑 1로 전환",
        119: "데스크탑 2로 전환", 120: "데스크탑 3으로 전환", 160: "Launchpad", 162: "손쉬운 사용 옵션", 175: "방해금지 모드",
        184: "스크린샷 및 기록 옵션", 190: "알림 센터", 222: "Stage Manager",
    ]

    /// Live Finder menus when Ring has Accessibility access; otherwise the snapshot below.
    private static func finderMenu() -> [Entry] {
        if AXIsProcessTrusted(), let live = liveFinderMenu(), !live.isEmpty { return live }
        return finderSnapshot.map { Entry(keyCode: $0.keyCode, modifiers: $0.modifiers, name: "Finder · " + $0.name) }
    }

    private static func liveFinderMenu() -> [Entry]? {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return nil }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else { return nil }
        var result: [Entry] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 6 else { return }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                  let list = children as? [AXUIElement] else { return }
            for child in list {
                func attribute(_ name: String) -> CFTypeRef? {
                    var value: CFTypeRef?
                    return AXUIElementCopyAttributeValue(child, name as CFString, &value) == .success ? value : nil
                }
                let title = attribute(kAXTitleAttribute) as? String ?? "?"
                let mods = attribute(kAXMenuItemCmdModifiersAttribute) as? Int ?? 0
                var code = attribute(kAXMenuItemCmdVirtualKeyAttribute) as? Int
                if code == nil, let char = attribute(kAXMenuItemCmdCharAttribute) as? String, !char.isEmpty { code = KeyNames.keyCode(for: char) }
                if let code, mods & 16 == 0 { result.append(Entry(keyCode: code, modifiers: axModifiers(mods), name: "Finder · " + title)) }
                walk(child, depth: depth + 1)
            }
        }
        walk(bar as! AXUIElement, depth: 0)
        return result
    }

    /// AX menu modifiers: bit0 ⇧, bit1 ⌥, bit2 ⌃, bit3 "no ⌘".
    private static func axModifiers(_ mods: Int) -> KeyMods {
        var m: KeyMods = mods & 8 == 0 ? [.cmd] : []
        if mods & 1 != 0 { m.insert(.shift) }
        if mods & 2 != 0 { m.insert(.option) }
        if mods & 4 != 0 { m.insert(.control) }
        return m
    }

    /// App Shortcuts the user added in Keyboard settings (global and Finder), e.g. "@~r".
    private static func userAppShortcuts() -> [Entry] {
        var tables: [[String: Any]] = []
        if let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["NSUserKeyEquivalents"] as? [String: Any] { tables.append(global) }
        if let finder = UserDefaults.standard.persistentDomain(forName: "com.apple.finder")?["NSUserKeyEquivalents"] as? [String: Any] { tables.append(finder) }
        return tables.flatMap { table in
            table.compactMap { title, value -> Entry? in
                guard let spec = value as? String, let last = spec.last else { return nil }
                var m: KeyMods = []
                for c in spec.dropLast() {
                    switch c { case "@": m.insert(.cmd); case "$": m.insert(.shift); case "~": m.insert(.option); case "^": m.insert(.control); default: break }
                }
                guard let code = KeyNames.keyCode(for: String(last)) else { return nil }
                return Entry(keyCode: code, modifiers: m, name: "사용자 앱 단축키 · " + title)
            }
        }
    }

    /// System behaviour that is not in any preference file.
    private static let fixed: [Entry] = [
        Entry(keyCode: kVK_Tab, modifiers: [.cmd], name: "앱 전환기"),
        Entry(keyCode: kVK_Tab, modifiers: [.cmd, .shift], name: "앱 전환기"),
        Entry(keyCode: kVK_ANSI_Grave, modifiers: [.cmd], name: "같은 앱의 윈도우 전환"),
        Entry(keyCode: kVK_ANSI_Grave, modifiers: [.cmd, .shift], name: "같은 앱의 윈도우 전환"),
        Entry(keyCode: kVK_ANSI_Q, modifiers: [.cmd], name: "앱 종료"),
        Entry(keyCode: kVK_Escape, modifiers: [.cmd, .option], name: "강제 종료"),
        Entry(keyCode: kVK_Space, modifiers: [.cmd, .control], name: "이모지 및 기호"),
        Entry(keyCode: kVK_ANSI_F, modifiers: [.cmd, .control], name: "전체 화면"),
        Entry(keyCode: kVK_ANSI_Q, modifiers: [.cmd, .control], name: "화면 잠금"),
    ]

    /// Text editing in Finder's rename and search fields (Cocoa key bindings).
    private static let textEditing: [Entry] = {
        var list: [Entry] = []
        let arrows = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
        for key in arrows {
            for m: KeyMods in [[.cmd], [.option], [.control], [.cmd, .shift], [.option, .shift], [.control, .shift]] {
                list.append(Entry(keyCode: key, modifiers: m, name: "텍스트 편집 · 커서 이동/선택"))
            }
        }
        for key in [kVK_Delete, kVK_ForwardDelete] {
            for m: KeyMods in [[.cmd], [.option], [.control]] { list.append(Entry(keyCode: key, modifiers: m, name: "텍스트 편집 · 지우기")) }
        }
        let emacs: [(Int, String)] = [(kVK_ANSI_A, "줄 처음으로"), (kVK_ANSI_E, "줄 끝으로"), (kVK_ANSI_K, "줄 끝까지 지우기"),
                                      (kVK_ANSI_Y, "붙여넣기"), (kVK_ANSI_D, "앞 글자 지우기"), (kVK_ANSI_H, "뒤 글자 지우기"),
                                      (kVK_ANSI_F, "앞으로"), (kVK_ANSI_B, "뒤로"), (kVK_ANSI_N, "다음 줄"), (kVK_ANSI_P, "이전 줄"),
                                      (kVK_ANSI_T, "글자 바꾸기"), (kVK_ANSI_O, "줄 삽입"), (kVK_ANSI_V, "아래로"), (kVK_ANSI_L, "가운데로")]
        for (key, name) in emacs { list.append(Entry(keyCode: key, modifiers: [.control], name: "텍스트 편집 · " + name)) }
        return list
    }()

    /// Finder (macOS 27.0.1, Korean) menu key equivalents, read via System Events on 2026-10-20.
    /// Used when Ring has no Accessibility access to read the live menus.
    private static let finderSnapshot: [(keyCode: Int, modifiers: KeyMods, name: String)] = [
        (keyCode: 53, modifiers: [.cmd, .option], name: "강제 종료..."),
        (keyCode: 53, modifiers: [.cmd, .shift, .option], name: "Finder 강제 종료"),
        (keyCode: 12, modifiers: [.cmd, .control], name: "잠금 화면"),
        (keyCode: 12, modifiers: [.cmd, .shift], name: "이한울 로그아웃…"),
        (keyCode: 12, modifiers: [.cmd, .shift, .option], name: "이한울 로그아웃"),
        (keyCode: 43, modifiers: [.cmd], name: "설정…"),
        (keyCode: 51, modifiers: [.cmd, .shift], name: "휴지통 비우기"),
        (keyCode: 51, modifiers: [.cmd, .shift, .option], name: "휴지통 비우기"),
        (keyCode: 4, modifiers: [.cmd], name: "Finder 가리기"),
        (keyCode: 4, modifiers: [.cmd, .option], name: "기타 가리기"),
        (keyCode: 45, modifiers: [.cmd], name: "새로운 Finder 윈도우"),
        (keyCode: 45, modifiers: [.cmd, .shift], name: "새로운 폴더"),
        (keyCode: 45, modifiers: [.cmd, .control], name: "선택 항목을 포함하는 새로운 폴더"),
        (keyCode: 17, modifiers: [.cmd], name: "새로운 탭"),
        (keyCode: 31, modifiers: [.cmd], name: "열기"),
        (keyCode: 31, modifiers: [.cmd, .control], name: "새로운 탭에서 열기"),
        (keyCode: 31, modifiers: [.cmd, .option], name: "열기 및 윈도우 닫기"),
        (keyCode: 13, modifiers: [.cmd], name: "윈도우 닫기"),
        (keyCode: 13, modifiers: [.cmd, .option], name: "모두 닫기"),
        (keyCode: 34, modifiers: [.cmd], name: "정보 가져오기"),
        (keyCode: 34, modifiers: [.cmd, .option], name: "인스펙터 보기"),
        (keyCode: 34, modifiers: [.cmd, .control], name: "요약 정보 가져오기"),
        (keyCode: 2, modifiers: [.cmd], name: "복제"),
        (keyCode: 2, modifiers: [.cmd, .shift, .option], name: "똑같이 복제"),
        (keyCode: 0, modifiers: [.cmd, .control], name: "가상본 만들기"),
        (keyCode: 16, modifiers: [.cmd], name: "훑어보기"),
        (keyCode: 16, modifiers: [.cmd, .option], name: "슬라이드쇼"),
        (keyCode: 15, modifiers: [.cmd], name: "원본 보기"),
        (keyCode: 17, modifiers: [.cmd, .control], name: "사이드바에 추가"),
        (keyCode: 17, modifiers: [.cmd, .shift, .control], name: "Dock에 추가"),
        (keyCode: 51, modifiers: [.cmd], name: "휴지통으로 이동"),
        (keyCode: 51, modifiers: [.cmd, .option], name: "즉시 삭제…"),
        (keyCode: 14, modifiers: [.cmd], name: "추출"),
        (keyCode: 14, modifiers: [.cmd, .control], name: "추출"),
        (keyCode: 14, modifiers: [.cmd, .option], name: "추출"),
        (keyCode: 35, modifiers: [.cmd], name: "프린트"),
        (keyCode: 6, modifiers: [.cmd], name: "오른쪽으로 회전 실행 취소"),
        (keyCode: 6, modifiers: [.cmd, .shift], name: "실행 복귀"),
        (keyCode: 7, modifiers: [.cmd], name: "오려두기"),
        (keyCode: 8, modifiers: [.cmd], name: "복사하기"),
        (keyCode: 8, modifiers: [.cmd, .option], name: "‘데스크탑’의 경로 이름을 복사"),
        (keyCode: 8, modifiers: [.cmd, .option, .control], name: "링크로 복사"),
        (keyCode: 9, modifiers: [.cmd], name: "붙여넣기"),
        (keyCode: 9, modifiers: [.cmd, .option], name: "여기로 항목 이동"),
        (keyCode: 9, modifiers: [.cmd, .shift, .option], name: "똑같이 항목 붙여넣기"),
        (keyCode: 0, modifiers: [.cmd], name: "전체 선택"),
        (keyCode: 0, modifiers: [.cmd, .option], name: "전체 선택 해제"),
        (keyCode: 3, modifiers: [.cmd], name: "검색"),
        (keyCode: 3, modifiers: [.cmd, .shift, .control], name: "이름으로 검색…"),
        (keyCode: 128, modifiers: [], name: "받아쓰기 시작"),
        (keyCode: 18, modifiers: [.cmd], name: "아이콘"),
        (keyCode: 19, modifiers: [.cmd], name: "목록"),
        (keyCode: 20, modifiers: [.cmd], name: "계층"),
        (keyCode: 21, modifiers: [.cmd], name: "갤러리"),
        (keyCode: 29, modifiers: [.cmd, .control], name: "스택 사용"),
        (keyCode: 29, modifiers: [.cmd, .option, .control], name: "없음"),
        (keyCode: 18, modifiers: [.cmd, .option, .control], name: "이름"),
        (keyCode: 19, modifiers: [.cmd, .option, .control], name: "종류"),
        (keyCode: 20, modifiers: [.cmd, .option, .control], name: "최근 사용일"),
        (keyCode: 21, modifiers: [.cmd, .option, .control], name: "추가된 날짜"),
        (keyCode: 23, modifiers: [.cmd, .option, .control], name: "수정일"),
        (keyCode: 22, modifiers: [.cmd, .option, .control], name: "크기"),
        (keyCode: 26, modifiers: [.cmd, .option, .control], name: "태그"),
        (keyCode: 18, modifiers: [.cmd, .option], name: "이름"),
        (keyCode: 19, modifiers: [.cmd, .option], name: "종류"),
        (keyCode: 23, modifiers: [.cmd, .option], name: "수정일"),
        (keyCode: 22, modifiers: [.cmd, .option], name: "크기"),
        (keyCode: 26, modifiers: [.cmd, .option], name: "태그"),
        (keyCode: 17, modifiers: [.cmd, .shift], name: "탭 막대 보기"),
        (keyCode: 42, modifiers: [.cmd, .shift], name: "모든 탭 보기"),
        (keyCode: 1, modifiers: [.cmd, .control], name: "사이드바 가리기"),
        (keyCode: 35, modifiers: [.cmd, .shift], name: "미리보기 보기"),
        (keyCode: 17, modifiers: [.cmd, .option], name: "도구 막대 가리기"),
        (keyCode: 35, modifiers: [.cmd, .option], name: "경로 막대 가리기"),
        (keyCode: 44, modifiers: [.cmd], name: "상태 막대 가리기"),
        (keyCode: 38, modifiers: [.cmd], name: "보기 옵션"),
        (keyCode: 33, modifiers: [.cmd], name: "뒤로"),
        (keyCode: 30, modifiers: [.cmd], name: "앞으로"),
        (keyCode: 126, modifiers: [.cmd], name: "상위 폴더"),
        (keyCode: 126, modifiers: [.cmd, .option], name: "상위 폴더"),
        (keyCode: 126, modifiers: [.cmd, .control], name: "새로운 윈도우에서 상위 폴더"),
        (keyCode: 126, modifiers: [.cmd, .shift], name: "시동 디스크 선택하기"),
        (keyCode: 3, modifiers: [.cmd, .shift], name: "최근 사용"),
        (keyCode: 31, modifiers: [.cmd, .shift], name: "문서"),
        (keyCode: 2, modifiers: [.cmd, .shift], name: "데스크탑"),
        (keyCode: 37, modifiers: [.cmd, .option], name: "다운로드"),
        (keyCode: 4, modifiers: [.cmd, .shift], name: "홈"),
        (keyCode: 8, modifiers: [.cmd, .shift], name: "컴퓨터"),
        (keyCode: 15, modifiers: [.cmd, .shift], name: "AirDrop"),
        (keyCode: 40, modifiers: [.cmd, .shift], name: "네트워크"),
        (keyCode: 34, modifiers: [.cmd, .shift], name: "iCloud Drive"),
        (keyCode: 1, modifiers: [.cmd, .shift], name: "공유"),
        (keyCode: 0, modifiers: [.cmd, .shift], name: "응용 프로그램"),
        (keyCode: 32, modifiers: [.cmd, .shift], name: "유틸리티"),
        (keyCode: 5, modifiers: [.cmd, .shift], name: "폴더로 이동…"),
        (keyCode: 40, modifiers: [.cmd], name: "서버에 연결…"),
        (keyCode: 46, modifiers: [.cmd], name: "최소화"),
        (keyCode: 46, modifiers: [.cmd, .option], name: "모두 최소화"),
        (keyCode: 24, modifiers: [.cmd], name: "윈도우 순환"),
        (keyCode: 48, modifiers: [.shift, .control], name: "이전 탭 보기"),
        (keyCode: 48, modifiers: [.control], name: "다음 탭 보기"),
    ]
}

import AppKit
import SwiftUI
import ServiceManagement

/// Shown when Ring is launched directly (not from the Finder menu).
struct HomeView: View {
    @State private var showingFeatures = false
    @State private var extensionEnabled: Bool?
    @AppStorage(AppSettings.showShortcutHints) private var showHints = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hotKey = FinderHotKey.current
    @State private var recording = false
    @State private var shortcutError: String?
    @State private var monitor: Any?

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Setting row: description on the left, switch on the right edge (in line with the
    /// 다시 확인 button above).
    private func settingRow<Label: View>(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) -> some View {
        HStack(alignment: .center, spacing: 12) {
            label()
            Spacer(minLength: 0)
            Toggle("", isOn: isOn).toggleStyle(.switch).labelsHidden()
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ring").font(.system(size: 26, weight: .bold))
                    Text("파일을 우클릭해서 여는 원형 변환·편집 패널")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Finder 확장 켜기", "시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램에서 Ring 확장을 켭니다.")
                step(2, "파일 우클릭 또는 \(hotKey.display)", "Finder에서 파일을 우클릭해 \"Ring으로 변환·편집\"을 고르거나, 파일을 선택한 채 \(hotKey.display)을 누릅니다. 처음 쓰면 Finder 제어 허용을 묻습니다.")
                step(3, "링에서 고르기", "칸 클릭 또는 ⇧tab으로 시계방향 선택 후 return. tab은 변환/편집 전환, esc는 닫기.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ringGlass(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            HStack(spacing: 8) {
                Circle()
                    .fill(extensionEnabled == true ? Color.green : (extensionEnabled == false ? Color.orange : Color.gray))
                    .frame(width: 8, height: 8)
                Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("다시 확인") { refresh() }.ringGlassButton().controlSize(.small)
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Finder 단축키").font(.system(size: 13, weight: .medium))
                    Text(shortcutError ?? (recording ? "새 키 조합을 누르세요. esc는 취소." : "버튼을 눌러 원하는 키 조합으로 바꿀 수 있습니다."))
                        .font(.system(size: 11)).foregroundStyle(shortcutError == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if hotKey != .standard && !recording {
                    Button("기본값") { apply(.standard) }.ringGlassButton().controlSize(.small)
                }
                Button(recording ? "입력 대기…" : hotKey.display) { recording ? stopRecording() : startRecording() }
                    .ringGlassButton().controlSize(.small)
                    .frame(minWidth: 90, alignment: .trailing)
            }

            settingRow(isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("로그인할 때 자동으로 실행").font(.system(size: 13, weight: .medium))
                    Text("\(hotKey.display) 단축키는 Ring이 켜져 있을 때만 동작합니다.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Button("링 기능 구성…") { showingFeatures = true }.ringGlassButton()
                .frame(maxWidth: .infinity, alignment: .leading)

            settingRow(isOn: $showHints) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("링 아래 단축키 안내 표시").font(.system(size: 13, weight: .medium))
                    Text("tab 탭 전환 · ⇧tab 선택 · return 실행 · esc 닫기 줄을 보여줍니다.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Text("원본은 그대로 두고, 변환·편집 결과를 원본 옆에 새 파일로 저장합니다.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("이미지 · PDF · DOCX/Markdown/HTML/RTF · 비디오\nPDF를 여러 개 선택하면 병합 순서를 지정할 수 있어요.")
                .font(.system(size:11.5)).foregroundStyle(.secondary)
                .frame(maxWidth:.infinity,alignment:.leading)

            HStack(spacing: 8) {
                Button("종료") { NSApp.terminate(nil) }.ringGlassButton()
                Button("파일 열기…",action:openFiles).ringGlassButton()
                Spacer()
                Button("확장 설정 열기") { openExtensionSettings() }.ringGlassButton()
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 520)
        .sheet(isPresented: $showingFeatures) { RingFeatureSettings() }
        .onAppear(perform: refresh)
        .onDisappear(perform: stopRecording)
    }

    private func openFiles() {
        let panel=NSOpenPanel()
        panel.canChooseDirectories=false;panel.allowsMultipleSelection=true;panel.prompt="Ring으로 열기"
        if panel.runModal() == .OK,let first=panel.urls.first {
            HomeWindow.shared.window?.orderOut(nil)
            RingWindowController.show(url:first,selection:panel.urls)
        }
    }

    private func startRecording() {
        shortcutError = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty {
                stopRecording(); return nil
            }
            switch FinderHotKey.from(event) {
            case .success(let key): apply(key)
            case .failure(let error): shortcutError = error.message
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func apply(_ key: FinderHotKey) {
        stopRecording()
        if let error = FinderShortcut.shared.change(to: key) {
            shortcutError = error.message
        } else {
            shortcutError = nil
            hotKey = key
        }
    }

    private var statusText: String {
        switch extensionEnabled {
        case true?: return "Finder 확장이 켜져 있어요"
        case false?: return "Finder 확장이 꺼져 있어요 — 설정에서 켜 주세요"
        default: return "Finder 확장 상태 확인 중…"
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func refresh() {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            p.arguments = ["-m", "-A", "-i", AppIDs.finderExtension]
            let pipe = Pipe(); p.standardOutput = pipe
            try? p.run(); p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let enabled = out.trimmingCharacters(in: .whitespaces).hasPrefix("+")
            DispatchQueue.main.async { extensionEnabled = enabled }
        }
    }

    private func openExtensionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }

}

@MainActor
final class HomeWindow {
    static let shared = HomeWindow()
    private(set) var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: HomeView())
            w.setContentSize(w.contentView!.fittingSize)
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}


private struct RingFeatureSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var revision = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("링 기능 구성").font(.title2.bold())
            Text("원하는 기능을 켜면 링에 추가돼요. 모든 칸은 항목 수에 맞춰 같은 각도로 나뉩니다.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(RingFeatures.groups, id: \.id) { group in
                GroupBox(group.title) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(group.items) { item in
                            Toggle(item.title, isOn: Binding(get: {
                                _ = revision
                                return RingFeatures.enabled(group.id, item.id)
                            }, set: { on in
                                RingFeatures.set(group.id, item.id, enabled: on)
                                revision += 1
                            }))
                            .accessibilityIdentifier("feature.\(group.id).\(item.id)")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            Text("영상 코덱은 선택한 파일에서 지원하는 항목만 표시해요. WebM에 음성 변환이 필요하면 실행 전에 확인합니다.")
                .font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("완료") { dismiss() }.ringGlassButton(prominent: true) }
        }.padding(24).frame(width: 440)
    }
}

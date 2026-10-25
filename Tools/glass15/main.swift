// Experimental: render Ring's macOS 15 glass (GlassCompat.swift) over a striped
// background on a CI runner and save a screenshot. Not part of the app.
import SwiftUI
import AppKit

struct Sample: View {
    var body: some View {
        VStack(spacing: 24) {
            Circle().fill(.clear).frame(width: 220, height: 220)
                .ringGlass(.clear, in: Circle())
            Text("변환   편집").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 24).padding(.vertical, 8)
                .ringGlass(.regular, in: Capsule())
            RoundedRectangle(cornerRadius: 30).fill(.clear).frame(width: 300, height: 90)
                .overlay(Text("패널").font(.title2.bold()))
                .ringGlass(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        }.padding(30)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let bg = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 560), styleMask: .borderless, backing: .buffered, defer: false)
let stripes = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 560)); stripes.wantsLayer = true
stripes.layer!.backgroundColor = NSColor.white.cgColor
for i in 0..<30 {
    let bar = CALayer(); bar.frame = CGRect(x: CGFloat(i) * 20, y: 0, width: 10, height: 560)
    bar.backgroundColor = NSColor(hue: CGFloat(i) / 30, saturation: 0.8, brightness: 0.9, alpha: 1).cgColor
    stripes.layer!.addSublayer(bar)
}
bg.contentView = stripes; bg.orderFrontRegardless()
let glass = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 560), styleMask: .borderless, backing: .buffered, defer: false)
glass.isOpaque = false; glass.backgroundColor = .clear; glass.level = .floating
glass.contentView = NSHostingView(rootView: Sample().frame(width: 600, height: 560))
glass.orderFrontRegardless()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
print("native:", RingGlassSupport.native, "backdrop:", RingGlassSupport.backdrop)
DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    let h = Int(NSScreen.main!.frame.height)
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R", "100,\(h - 660),600,560", "\(out)/glass15.png"]
    try? p.run(); p.waitUntilExit(); app.terminate(nil)
}
app.run()

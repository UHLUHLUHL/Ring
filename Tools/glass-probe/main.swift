// Experimental probe: does the private CABackdropLayer + displacementMap
// filter exist and visibly distort content behind a window on this macOS?
// Not part of the app. Prints a report and writes before/after screenshots.
import AppKit
import QuartzCore

func filter(_ type: String) -> NSObject? {
    guard let cls = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
    return cls.perform(NSSelectorFromString("filterWithType:"), with: type)?.takeUnretainedValue() as? NSObject
}
func inputKeys(_ f: NSObject) -> [String] {
    (f.perform(NSSelectorFromString("inputKeys"))?.takeUnretainedValue() as? [String]) ?? []
}
// R/G encode an x/y offset around 128; the bend grows toward the rim.
func lensMap(_ n: Int) -> CGImage {
    var px = [UInt8](repeating: 0, count: n * n * 4)
    for y in 0..<n { for x in 0..<n {
        let dx = Double(x) / Double(n - 1) * 2 - 1, dy = Double(y) / Double(n - 1) * 2 - 1
        let k = pow(min(1, (dx * dx + dy * dy).squareRoot()), 3), i = (y * n + x) * 4
        px[i] = UInt8(max(0, min(255, 128 + 127 * dx * k)))
        px[i + 1] = UInt8(max(0, min(255, 128 + 127 * dy * k)))
        px[i + 2] = 128; px[i + 3] = 255
    } }
    let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let types = (NSClassFromString("CAFilter") as? NSObject.Type).flatMap {
    $0.perform(NSSelectorFromString("filterTypes"))?.takeUnretainedValue() as? [String]
} ?? []
var report = [
    "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
    "CAFilter class: \(NSClassFromString("CAFilter") != nil)",
    "CABackdropLayer class: \(NSClassFromString("CABackdropLayer") != nil)",
    "filter types (\(types.count)): \(types.sorted().joined(separator: ", "))",
]
for name in ["displacementMap", "glassBackground", "glassForeground", "chromaticAberration", "gaussianBlur", "variableBlur"] {
    report.append("\(name): \(types.contains(name)) keys=\(filter(name).map(inputKeys) ?? [])")
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.main!.frame
// A striped background window gives a known pattern to distort.
let bg = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
let stripes = NSView(frame: bg.contentLayoutRect); stripes.wantsLayer = true
for i in 0..<30 {
    let bar = CALayer(); bar.frame = CGRect(x: CGFloat(i) * 20, y: 0, width: 10, height: 400)
    bar.backgroundColor = NSColor(hue: CGFloat(i) / 30, saturation: 0.8, brightness: 0.9, alpha: 1).cgColor
    stripes.layer!.addSublayer(bar)
}
stripes.layer!.backgroundColor = NSColor.white.cgColor
bg.contentView = stripes; bg.orderFrontRegardless()

let size: CGFloat = 260
let lens = NSWindow(contentRect: NSRect(x: 270, y: 170, width: size, height: size), styleMask: .borderless, backing: .buffered, defer: false)
lens.isOpaque = false; lens.backgroundColor = .clear; lens.level = .floating
let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size)); view.wantsLayer = true; lens.contentView = view
if let backdropType = NSClassFromString("CABackdropLayer") as? CALayer.Type, let disp = filter("displacementMap") {
    let backdrop = backdropType.init()
    backdrop.frame = view.bounds; backdrop.cornerRadius = size / 2; backdrop.masksToBounds = true
    disp.setValue(lensMap(256), forKey: "inputMaskImage")
    if inputKeys(disp).contains("inputAmount") { disp.setValue(80, forKey: "inputAmount") }
    backdrop.filters = [disp]
    backdrop.setValue(true, forKey: "enabled")
    backdrop.setValue(1.0, forKey: "scale")
    view.layer!.addSublayer(backdrop)
    report.append("lens: backdrop + displacementMap installed")
} else {
    report.append("lens: SKIPPED (backdrop layer or displacementMap missing)")
}
let rim = CAShapeLayer(); rim.path = CGPath(ellipseIn: view.bounds.insetBy(dx: 1, dy: 1), transform: nil)
rim.fillColor = nil; rim.strokeColor = NSColor.black.cgColor; rim.lineWidth = 2
view.layer!.addSublayer(rim)

func capture(_ name: String) {
    // Capture the background window's area in global top-left coordinates.
    let rect = "\(100),\(Int(screen.height) - 500),600,400"
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R", rect, "\(out)/\(name).png"]
    try? p.run(); p.waitUntilExit()
    report.append("capture \(name): exit \(p.terminationStatus)")
}
DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
    capture("before")   // lens hidden
    lens.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        capture("after")
        let text = report.joined(separator: "\n")
        print(text)
        try? text.write(toFile: "\(out)/report.txt", atomically: true, encoding: .utf8)
        app.terminate(nil)
    }
}
app.run()

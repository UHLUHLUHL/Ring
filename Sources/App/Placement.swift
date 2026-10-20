import AppKit

/// Picks where the ring opens: near the file, but over the emptiest part of the desktop.
///
/// Finder is asked for the desktop icon positions and the open Finder windows; candidate spots
/// around the file are scored by how much of those the ring would cover, plus a small
/// penalty for distance. Without Finder automation permission it falls back to the side of
/// the file.
enum RingPlacement {
    struct Obstacles {
        var icons: [NSRect] = []   // AppKit coordinates
        var windows: [NSRect] = []
    }

    /// Resolves the ring centre off the main thread and calls back on the main thread.
    @MainActor static func resolve(file: NSPoint, completion: @escaping @MainActor (NSPoint?) -> Void) {
        let screenFrame = (NSScreen.screens.first { NSMouseInRect(file, $0.frame, false) } ?? NSScreen.main)?.visibleFrame
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        // Claim the front right away: activation is only granted at the moment of the request,
        // not after the Finder query below.
        NSApp.activate()
        NSApp.activate(ignoringOtherApps: true)
        // Use what was read when Finder came to the front (right-clicking a file means Finder
        // is in front), so the ring opens without waiting ~0.5 s for Finder.
        if let cached, Date().timeIntervalSince(cached.date) < 20, let vf = screenFrame {
            completion(bestCenter(file: file, visible: vf, obstacles: cached.obstacles))
            prefetch()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let obstacles = readObstacles(mainHeight: mainHeight)
            if let obstacles { DispatchQueue.main.async { cached = (Date(), obstacles) } }
            let center = screenFrame.flatMap { vf in obstacles.map { bestCenter(file: file, visible: vf, obstacles: $0) } }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(center) } }
        }
    }

    // MARK: Finder

    nonisolated(unsafe) private static var cached: (date: Date, obstacles: Obstacles)?

    /// Reads desktop icons and Finder windows in the background and keeps them for the next open.
    static func prefetch() {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        DispatchQueue.global(qos: .utility).async {
            guard let o = readObstacles(mainHeight: mainHeight) else { return }
            DispatchQueue.main.async { cached = (Date(), o) }
        }
    }

    private static func readObstacles(mainHeight: CGFloat) -> Obstacles? {
        let source = """
        tell application "Finder"
            set out to ""
            repeat with f in (get every item of desktop)
                try
                    set p to desktop position of f
                    set out to out & (item 1 of p) & "," & (item 2 of p) & ";"
                end try
            end repeat
            set out to out & "|"
            try
                repeat with w in (every Finder window)
                    if collapsed of w is false then
                        set b to bounds of w
                        set out to out & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & ";"
                    end if
                end repeat
            end try
            return out
        end tell
        """
        var error: NSDictionary?
        guard let out = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else {
            DebugLog.write("placement script error: \(error ?? [:])")
            return nil
        }
        let halves = out.components(separatedBy: "|")
        func numbers(_ s: Substring) -> [CGFloat] { s.split(separator: ",").compactMap { Double($0).map { CGFloat($0) } } }
        var o = Obstacles()
        // Desktop position is taken as the icon's centre (guess); the box also covers a
        // two-line name below it.
        for item in halves[0].split(separator: ";") {
            let n = numbers(item); guard n.count == 2 else { continue }
            let y = mainHeight - n[1]
            o.icons.append(NSRect(x: n[0] - 50, y: y - 64, width: 100, height: 104))
        }
        if halves.count > 1 {
            for item in halves[1].split(separator: ";") {
                let n = numbers(item); guard n.count == 4 else { continue }
                o.windows.append(NSRect(x: n[0], y: mainHeight - n[3], width: n[2] - n[0], height: n[3] - n[1]))
            }
        }
        return o
    }

    // MARK: Scoring

    static func bestCenter(file: NSPoint, visible vf: NSRect, obstacles: Obstacles) -> NSPoint {
        let R = RingMetrics.outer + 10
        let fileBox = NSRect(x: file.x - 48, y: file.y - 60, width: 96, height: 104)
        var best = NSPoint(x: file.x + R + 58, y: file.y)
        var bestScore = Double.infinity
        for distance in [R + 64, R + 120, R + 200, R + 300] {
            for step in 0..<16 {
                let a = Double(step) * .pi / 8
                var c = NSPoint(x: file.x + distance * CGFloat(Foundation.cos(a)),
                                y: file.y + distance * CGFloat(Foundation.sin(a)))
                c = clamp(c, into: vf)
                let s = score(c, radius: R, file: file, fileBox: fileBox, obstacles: obstacles)
                if s < bestScore { bestScore = s; best = c }
            }
        }
        return best
    }

    /// Keeps the ring (and the tab pill below it) on screen.
    private static func clamp(_ p: NSPoint, into vf: NSRect) -> NSPoint {
        let b = RingWindowLayout.ringBlock
        let inner = vf.insetBy(dx: 6, dy: 6)
        return NSPoint(x: min(max(p.x, inner.minX - b.minX), inner.maxX - b.maxX),
                       y: min(max(p.y, inner.minY + b.maxY), inner.maxY + b.minY))
    }

    private static func score(_ c: NSPoint, radius R: CGFloat, file: NSPoint, fileBox: NSRect, obstacles: Obstacles) -> Double {
        // Sample points over the ring disc and the pill/hint strip under it.
        var samples: [NSPoint] = []
        for ring in [0.0, 0.45, 0.8, 1.0] {
            let count = ring == 0 ? 1 : 12
            for k in 0..<count {
                let a = Double(k) / Double(count) * 2 * .pi
                samples.append(NSPoint(x: c.x + R * CGFloat(ring * Foundation.cos(a)), y: c.y + R * CGFloat(ring * Foundation.sin(a))))
            }
        }
        for dx in stride(from: -120.0, through: 120.0, by: 60.0) {
            samples.append(NSPoint(x: c.x + dx, y: c.y - R - 40))
        }
        func covered(_ rects: [NSRect]) -> Double {
            Double(samples.filter { p in rects.contains { $0.contains(p) } }.count) / Double(samples.count)
        }
        // Covering the file itself defeats the point; desktop icons weigh most; windows a bit less.
        let hidesFile = samples.contains { fileBox.contains($0) } ? 100.0 : 0
        let icons = covered(obstacles.icons) * 10
        let windows = covered(obstacles.windows) * 4
        let distance = Double(hypot(c.x - file.x, c.y - file.y)) / 250
        return hidesFile + icons + windows + distance
    }
}

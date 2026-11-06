import AppKit
import SwiftUI

// `StatBar --readme-shots <dir>` renders README screenshots with made-up demo data (no real process
// names or machine details) and writes popover-dark.png, popover-light.png, settings-dark.png,
// settings-light.png and hero.png into <dir>.

extension Monitor {
    /// Fills every published value with plausible demo numbers. Call `stop()` first.
    func loadDemo() {
        func wave(_ n: Int, base: Double, amp: Double, phase: Double = 0, jitter: Double = 0.25) -> [Double] {
            (0..<n).map { i in
                let x = Double(i) / Double(n) * .pi * 3 + phase
                return max(0, base + amp * (sin(x) * 0.7 + sin(x * 2.3 + 1) * 0.3) + amp * jitter * sin(Double(i) * 1.7))
            }
        }
        func ring(_ vals: [Double]) -> Ring { var r = Ring(vals.count); vals.forEach { r.push($0) }; return r }

        cpu = 23; cpuUser = 15; cpuSystem = 8
        perCore = [41, 37, 28, 22, 18, 12, 9, 8, 6, 5, 4, 3]
        cpuHistory = ring(wave(24, base: 20, amp: 9))
        load = [2.14, 1.86, 1.62]
        gpu = 18; gpuMem = 1_480_000_000
        gpuHistory = ring(wave(40, base: 14, amp: 8, phase: 1))
        let gb: UInt64 = 1 << 30
        mem = MemoryResult(used: 19 * gb + gb * 8 / 10, app: 12 * gb, wired: 3 * gb + gb / 5, compressed: gb + gb / 10,
                           cached: 6 * gb, swapUsed: 0, pressureLevel: 1)
        memHistory = ring(wave(40, base: 61, amp: 1.5, phase: 2, jitter: 0.1))
        disk = .init(free: 412_000_000_000, total: 994_660_000_000, readRate: 2_400_000, writeRate: 860_000)
        net = .init(down: 3_200_000, up: 420_000, totalIn: 48_300_000_000, totalOut: 6_100_000_000)
        downHistory = ring(wave(40, base: 2_000_000, amp: 1_400_000, phase: 0.5))
        upHistory = ring(wave(40, base: 350_000, amp: 200_000, phase: 2.5))
        connection = ("Wi-Fi", -52)
        latencyMs = 18; latencyFailed = false
        sensors = .init(cpuTemp: 52, gpuTemp: 47, systemPower: 14.6,
                        fans: [.init(rpm: 2350, min: 1200, max: 5800, manual: false)])
        var b = BatteryResult()
        b.present = true; b.percent = 86; b.cycles = 112; b.health = 97
        b.timeRemaining = 412; b.temperature = 31; b.powerW = 9.8
        battery = b
        func app(_ path: String, _ name: String, _ pids: Int, _ mb: Double, _ cpu: Double, isApp: Bool = true) -> ProcGroup {
            ProcGroup(key: path, name: name, pids: Array(1000..<(1000 + pid_t(pids))), memory: UInt64(mb * 1_048_576),
                      cpu: cpu, isApp: isApp, ownedByUser: true)
        }
        processes = [
            app("/Applications/Safari.app", "Safari", 9, 1840, 12.4),
            app("/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", "WindowServer", 1, 420, 8.7, isApp: false),
            app("/System/Applications/Music.app", "Music", 3, 310, 3.1),
            app("/System/Applications/Mail.app", "Mail", 2, 262, 1.9),
            app("/System/Library/CoreServices/Finder.app", "Finder", 1, 184, 1.2),
        ]
        idleApps = [app("/System/Applications/Notes.app", "Notes", 1, 240, 0)]
        micOn = false; camOn = false
        uptime = 3 * 86400 + 4 * 3600
    }
}

@MainActor
enum ReadmeShots {
    static func run(dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        SystemInfo.chip = "M4 Pro"; SystemInfo.memTotal = 32 << 30; SystemInfo.osVersion = "26.1"
        let m = Monitor()
        m.stop()
        // let any tick that was already in flight land first, then overwrite with demo values
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            m.loadDemo()
            m.detailed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                var shots: [String: NSImage] = [:]
                for (page, pName) in [(PopoverPage.main, "popover"), (.settings, "settings")] {
                    for (dark, aName) in [(true, "dark"), (false, "light")] {
                        let img = render(ContentView(m: m, power: PowerAssertions(), fan: FanController(), page: page), dark: dark)
                        shots["\(pName)-\(aName)"] = img
                        write(img, to: "\(dir)/\(pName)-\(aName).png")
                    }
                }
                if let a = shots["popover-dark"], let b = shots["settings-light"] { write(hero(a, b), to: "\(dir)/hero.png") }
                exit(0)
            }
        }
    }

    /// Lays the view out in an off-screen window (so AppKit controls render) and captures it at 2x.
    private static func render<V: View>(_ view: V, dark: Bool) -> NSImage {
        let bg = dark ? Color(white: 0.155) : Color(white: 0.955)
        let host = NSHostingView(rootView: view.background(bg))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))   // let SwiftUI finish its first pass
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let img = NSImage(size: size); img.addRepresentation(rep)
        return img
    }

    /// Two screenshots on a gradient with rounded corners and shadows.
    private static func hero(_ left: NSImage, _ right: NSImage) -> NSImage {
        let W: CGFloat = 1280, H: CGFloat = 760
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: W, height: H)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(colors: [NSColor(red: 0.09, green: 0.10, blue: 0.20, alpha: 1),
                            NSColor(red: 0.20, green: 0.13, blue: 0.36, alpha: 1),
                            NSColor(red: 0.07, green: 0.28, blue: 0.40, alpha: 1)])!
            .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -35)

        // headline
        let p = NSMutableParagraphStyle(); p.lineSpacing = 4
        NSAttributedString(string: "StatBar", attributes: [.font: NSFont.systemFont(ofSize: 64, weight: .heavy),
                                                           .foregroundColor: NSColor.white]).draw(at: NSPoint(x: 80, y: H - 300))
        NSAttributedString(string: "Your Mac’s vitals,\nright in the menu bar.",
                           attributes: [.font: NSFont.systemFont(ofSize: 28, weight: .semibold),
                                        .foregroundColor: NSColor.white.withAlphaComponent(0.88), .paragraphStyle: p])
            .draw(in: NSRect(x: 82, y: H - 420, width: 460, height: 100))
        let bullets = "CPU · GPU · Memory · Disk · Network\nFans · Battery · Top processes\nClean · Uninstall · Optimize · Analyze"
        NSAttributedString(string: bullets, attributes: [.font: NSFont.systemFont(ofSize: 17, weight: .medium),
                                                         .foregroundColor: NSColor.white.withAlphaComponent(0.62), .paragraphStyle: p])
            .draw(in: NSRect(x: 82, y: H - 545, width: 460, height: 110))

        func place(_ img: NSImage, x: CGFloat, height: CGFloat, y: CGFloat) {
            let w = img.size.width * height / img.size.height
            let r = NSRect(x: x, y: y, width: w, height: height)
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.5); sh.shadowBlurRadius = 40
            sh.shadowOffset = NSSize(width: 0, height: -14); sh.set()
            NSColor.black.setFill(); NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18).addClip()
            img.draw(in: r)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.12).setStroke()
            let border = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18); border.lineWidth = 1; border.stroke()
        }
        place(right, x: 880, height: 600, y: 60)
        place(left, x: 590, height: 660, y: 50)
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: W, height: H)); img.addRepresentation(rep)
        return img
    }

    private static func write(_ img: NSImage, to path: String) {
        guard let rep = img.representations.first as? NSBitmapImageRep,
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let monitor = Monitor()
    private let power = PowerAssertions()
    private let fan = FanController()
    private var lastImageKey = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(toggle(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageOnly
        }

        let host = NSHostingController(rootView: ContentView(m: monitor, power: power, fan: fan))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        let tb = Toolbox.shared
        tb.monitor = monitor; tb.power = power; tb.fan = fan
        tb.onVisibilityChange = { [weak self] _ in self?.updateDetailed() }
        NotificationCenter.default.addObserver(forName: .statbarClosePopover, object: nil, queue: .main) { [weak self] _ in
            self?.popover.performClose(nil)
        }
        NSApp.mainMenu = Self.makeMainMenu()
        // Debug / power users: `StatBar --open clean|uninstall|optimize|analyze|status`
        if let i = CommandLine.arguments.firstIndex(of: "--open"), i + 1 < CommandLine.arguments.count,
           let t = ToolboxTab(rawValue: CommandLine.arguments[i + 1]) {
            DispatchQueue.main.async { tb.open(t) }
        }

        NotificationCenter.default.addObserver(forName: .statbarTick, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLabel() }
        }
        updateLabel()
        Updater.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        power.setAwake(false); power.setScreen(false)
    }

    @MainActor private func updateLabel() {
        guard let button = statusItem.button else { return }
        let s = Settings.shared
        if s.menuItems.isEmpty {
            if lastImageKey != "icon" {
                let img = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "StatBar")
                img?.isTemplate = true
                button.image = img
                lastImageKey = "icon"
            }
            return
        }
        let renderer = ImageRenderer(content: StatusLabel(m: monitor, items: s.menuItems, fahrenheit: s.fahrenheit))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let img = renderer.nsImage else { return }
        img.isTemplate = true
        button.image = img
        lastImageKey = "label"
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            updateDetailed()
        }
    }

    func popoverDidClose(_ notification: Notification) { updateDetailed() }

    private func updateDetailed() {
        monitor.detailed = popover.isShown || Toolbox.shared.visible
    }

    /// Minimal menu so standard shortcuts (copy/paste, close, quit) work while the toolbox window is open.
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title); items.forEach(m.addItem)
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: ""); it.submenu = m
            main.addItem(it)
        }
        func item(_ t: String, _ a: Selector, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; return i
        }
        sub("StatBar", [item("Hide StatBar", #selector(NSApplication.hide(_:)), "h"), .separator(),
                        item("Quit StatBar", #selector(NSApplication.terminate(_:)), "q")])
        sub("Edit", [item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                     item("Cut", #selector(NSText.cut(_:)), "x"), item("Copy", #selector(NSText.copy(_:)), "c"),
                     item("Paste", #selector(NSText.paste(_:)), "v"), item("Select All", #selector(NSText.selectAll(_:)), "a")])
        sub("Window", [item("Close", #selector(NSWindow.performClose(_:)), "w"),
                       item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")])
        return main
    }
}

// Debug: `StatBar --snapshot out.png` renders the popover + menu bar label to PNG files and exits.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let out = CommandLine.arguments[i + 1]
    let m = Monitor(); m.detailed = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
        MainActor.assumeIsolated {
            for (view, suffix, scheme) in [(AnyView(ContentView(m: m, power: PowerAssertions(), fan: FanController())), "", ColorScheme.dark),
                                           (AnyView(ContentView(m: m, power: PowerAssertions(), fan: FanController())), "-light", ColorScheme.light),
                                           (AnyView(StatusLabel(m: m, items: Set(MenuItemKind.allCases), fahrenheit: false).background(Color.white)), "-label", ColorScheme.light),
                                           (AnyView(StatusDashboard(m: m, power: PowerAssertions(), fan: FanController(), scrolls: false).frame(width: 760)), "-dash", ColorScheme.dark),
                                           (AnyView(StatusDashboard(m: m, power: PowerAssertions(), fan: FanController(), scrolls: false).frame(width: 760)), "-dash-light", ColorScheme.light)] {
                let r = ImageRenderer(content: view.environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.95)))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out.replacingOccurrences(of: ".png", with: suffix + ".png")))
                }
            }
            exit(0)
        }
    }
    NSApplication.shared.setActivationPolicy(.prohibited)
    NSApplication.shared.run()
}

// Debug: `StatBar --selftest` runs the toolbox scanners read-only and prints a summary.
if CommandLine.arguments.contains("--selftest") {
    let t0 = Date()
    let c = Cleaner()
    c.scan()
    func wait(_ cond: () -> Bool) { while !cond() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
    wait { c.phase == .scanned }
    print("CLEAN (\(String(format: "%.1f", Date().timeIntervalSince(t0)))s)")
    for cat in c.categories {
        print("  \(cat.title): \(FSUtil.fmt(cat.size)) total, \(FSUtil.fmt(cat.selectedSize)) selected, \(cat.items.count) items\(cat.needsAccess ? " [needs access]" : "")")
        for it in cat.items.prefix(4) { print("     \(it.selected ? "☑" : "☐") \(it.name) \(FSUtil.fmt(it.size)) \(it.note ?? "")") }
    }
    let u = Uninstaller(); u.load(); wait { !u.loading && !u.apps.isEmpty }
    print("UNINSTALL: \(u.apps.count) apps")
    for app in u.apps.filter({ ["Zalo", "Termius", "Google Chrome", "Macs Fan Control"].contains($0.name) }) {
        let l = Uninstaller.findLeftovers(for: app)
        print("  \(app.name) [\(app.bundleID ?? "-")] root=\(app.ownedByRoot) appstore=\(app.fromAppStore) leftovers=\(l.count)")
        for x in l.prefix(8) { print("     \(x.system ? "🔒" : "  ") \(x.kind): \(FSUtil.tilde(x.path)) \(FSUtil.fmt(x.size))") }
    }
    let a = DiskAnalyzer(); let t1 = Date()
    a.scan(FSUtil.home + "/Library"); wait { !a.scanning }
    print("ANALYZE ~/Library: \(FSUtil.fmt(a.root?.size ?? 0)), \(a.scannedFiles) files, \(a.deniedCount) denied, \(String(format: "%.1f", Date().timeIntervalSince(t1)))s")
    for n in a.root?.children.prefix(6) ?? [] { print("     \(n.name) \(FSUtil.fmt(n.size)) children=\(n.children.count)") }
    let rects = Treemap.layout([50, 25, 15, 10], in: CGRect(x: 0, y: 0, width: 100, height: 100))
    let area = rects.reduce(0) { $0 + $1.width * $1.height }
    print("TREEMAP area check: \(Int(area)) (expect 10000), rects=\(rects.map { "\(Int($0.width))x\(Int($0.height))" })")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

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

        NotificationCenter.default.addObserver(forName: .statbarTick, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLabel() }
        }
        updateLabel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        fan.reset()
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
            monitor.detailed = true
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) { monitor.detailed = false }
}

// Debug: `StatBar --snapshot out.png` renders the popover + menu bar label to PNG files and exits.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    let out = CommandLine.arguments[i + 1]
    let m = Monitor(); m.detailed = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        MainActor.assumeIsolated {
            for (view, suffix, scheme) in [(AnyView(ContentView(m: m, power: PowerAssertions(), fan: FanController())), "", ColorScheme.dark),
                                           (AnyView(ContentView(m: m, power: PowerAssertions(), fan: FanController())), "-light", ColorScheme.light),
                                           (AnyView(StatusLabel(m: m, items: Set(MenuItemKind.allCases), fahrenheit: false).background(Color.white)), "-label", ColorScheme.light)] {
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

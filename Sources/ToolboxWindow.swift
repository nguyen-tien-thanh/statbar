import SwiftUI
import AppKit

enum ToolboxTab: String, CaseIterable, Identifiable {
    case status, clean, uninstall, optimize, analyze
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .status: "gauge.with.dots.needle.67percent"
        case .clean: "sparkles"
        case .uninstall: "xmark.bin"
        case .optimize: "bolt.fill"
        case .analyze: "chart.pie.fill"
        }
    }
    var subtitle: String {
        switch self {
        case .status: "Monitor system health"
        case .clean: "Free up disk space"
        case .uninstall: "Remove apps completely"
        case .optimize: "Refresh caches and services"
        case .analyze: "Explore disk usage"
        }
    }
    var color: Color {
        switch self {
        case .status: .cpuC; case .clean: .diskC; case .uninstall: .red; case .optimize: .orange; case .analyze: .purple
        }
    }
}

final class Toolbox: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = Toolbox()
    @Published var tab: ToolboxTab = .clean
    @Published private(set) var visible = false
    var onVisibilityChange: ((Bool) -> Void)?

    let cleaner = Cleaner()
    let uninstaller = Uninstaller()
    let optimizer = Optimizer()
    let analyzer = DiskAnalyzer()

    weak var monitor: Monitor?
    weak var power: PowerAssertions?
    weak var fan: FanController?
    private var window: NSWindow?

    func open(_ t: ToolboxTab) {
        tab = t
        if window == nil, let monitor, let power, let fan {
            let view = ToolboxView(tb: self, monitor: monitor, power: power, fan: fan)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "StatBar"
            w.titlebarAppearsTransparent = true
            w.contentView = NSHostingView(rootView: view)
            w.minSize = NSSize(width: 780, height: 520)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("StatBarToolbox")
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        visible = true
        onVisibilityChange?(true)
    }

    func windowWillClose(_ notification: Notification) {
        visible = false
        onVisibilityChange?(false)
        NSApp.setActivationPolicy(.accessory)
    }
}

struct ToolboxView: View {
    @ObservedObject var tb: Toolbox
    let monitor: Monitor
    let power: PowerAssertions
    let fan: FanController

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { tb.tab }, set: { if let t = $0 { tb.tab = t } })) {
                ForEach(ToolboxTab.allCases) { t in
                    HStack(spacing: 10) {
                        Image(systemName: t.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(t.color).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(.system(size: 13, weight: .medium))
                            Text(t.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(t)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 260)
        } detail: {
            Group {
                switch tb.tab {
                case .status:
                    StatusDashboard(m: monitor, power: power, fan: fan)
                case .clean: CleanView(c: tb.cleaner)
                case .uninstall: UninstallView(u: tb.uninstaller)
                case .optimize: OptimizeView(o: tb.optimizer)
                case .analyze: AnalyzeView(a: tb.analyzer)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Shared page header for toolbox panes.
struct PaneHeader<Trailing: View>: View {
    let tab: ToolboxTab
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: tab.icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(tab.color)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 11).fill(tab.color.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title).font(.system(size: 20, weight: .bold))
                Text(subtitle ?? tab.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
    }
}

import SwiftUI
import AppKit

/// In-popover settings page (replaces the old gear dropdown menu).
struct SettingsPage: View {
    @ObservedObject var settings: Settings
    @ObservedObject var priv: Privileged
    @ObservedObject var updater: Updater
    /// The page stays in the popover's hierarchy while hidden; this says whether it is on screen.
    var visible = true
    let back: () -> Void
    // Not read in the initializer: the page is re-created on every parent update (each tick) and
    // asking SMAppService that often is wasteful. Refreshed whenever the page is shown.
    @State private var launchAtLogin = false
    @State private var fullDiskAccess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            menuBarSection
            displaySection
            generalSection
            updatesSection
            Spacer(minLength: 0)
            footer
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)   // fill the main page's height; footer sits at the bottom
        .onExitCommand(perform: visible ? back : nil)   // Esc goes back
        .onAppear { refreshLaunchAtLogin(after: 0); fullDiskAccess = FullDiskAccess.granted }
        // asked off the main thread and applied after the slide-in, so it can't stall the animation
        .onChange(of: visible) { if $0 { refreshLaunchAtLogin(after: 0.35); fullDiskAccess = FullDiskAccess.granted } }
    }

    private func refreshLaunchAtLogin(after delay: Double) {
        DispatchQueue.global(qos: .userInitiated).async {
            let on = LoginItem.enabled
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { launchAtLogin = on }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            CircleIconButton(icon: "chevron.left", help: "Back", action: back)
                .keyboardShortcut(visible ? .cancelAction : nil)
            Text("Settings").font(.system(size: 15, weight: .semibold))
            Spacer()
        }
    }

    // MARK: menu bar

    private var menuBarSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Menu bar", trailing: AnyView(
                Text(settings.menuItems.isEmpty ? "Icon only" : "\(settings.menuItems.count) shown")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)))
            Surface(padding: 8) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    ForEach(MenuItemKind.allCases) { k in
                        let on = settings.menuItems.contains(k)
                        ToggleChip(icon: k.icon, title: k.shortTitle, on: on) {
                            if on { settings.menuItems.remove(k) } else { settings.menuItems.insert(k) }
                        }
                    }
                }
                if settings.menuItems.count > 1 {
                    Divider().padding(.vertical, 8)
                    MenuOrderStrip(settings: settings)
                }
            }
        }
    }

    // MARK: display

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Display")
            Surface(padding: 12) {
                SettingRow(title: "Theme") {
                    Segmented(options: [("system", "System"), ("light", "Light"), ("dark", "Dark")], selection: settings.theme, compact: true) {
                        settings.theme = $0
                    }
                }
                Divider()
                SettingRow(title: "Refresh every") {
                    Segmented(options: [(1.0, "1s"), (2.0, "2s"), (3.0, "3s"), (5.0, "5s")], selection: settings.interval, compact: true) {
                        settings.interval = $0
                    }
                }
                Divider()
                SettingRow(title: "Temperature") {
                    Segmented(options: [(false, "°C"), (true, "°F")], selection: settings.fahrenheit, compact: true) {
                        settings.fahrenheit = $0
                    }
                }
            }
        }
    }

    // MARK: general

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("General")
            Surface(padding: 12) {
                SettingRow(title: "Full Disk Access", subtitle: fullDiskAccess ? "Granted · Clean and Analyze see everything" : "Needed to clean and analyze protected folders") {
                    if fullDiskAccess {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 15))
                    } else {
                        CapsuleButton(title: "Grant…", icon: "lock.open") { FullDiskAccess.requestGuided() }
                    }
                }
                Divider()
                SettingRow(title: "Launch at login", subtitle: "Start StatBar when you log in") {
                    Toggle("", isOn: Binding(get: { launchAtLogin }, set: { LoginItem.set($0); launchAtLogin = LoginItem.enabled }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
                Divider()
                SettingRow(title: "Touch ID for admin actions", subtitle: touchIDSubtitle) {
                    switch priv.status {
                    case .ready: CapsuleButton(title: "Disable", tint: .secondary, prominent: false) { priv.uninstall() }
                    case .outdated: CapsuleButton(title: "Update", icon: "arrow.triangle.2.circlepath") { priv.install() }
                    case .notInstalled: CapsuleButton(title: "Enable", icon: "touchid") { priv.install() }
                    }
                }
            }
        }
    }

    private var touchIDSubtitle: String {
        switch priv.status {
        case .ready: "On · fan control and cleanup use Touch ID"
        case .outdated: "Helper needs an update"
        case .notInstalled: "Off · admin password is asked each time"
        }
    }

    // MARK: updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Updates")
            Surface(padding: 12) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable().frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("StatBar \(updater.current)").font(.system(size: 12.5, weight: .semibold))
                        HStack(spacing: 4) {
                            statusIcon
                            Text(updater.statusText)
                        }
                        .font(.system(size: 10.5)).foregroundStyle(updater.updateAvailable ? Color.blue : .secondary)
                    }
                    Spacer(minLength: 6)
                    if updater.updateAvailable || updater.installing {
                        UpdateActionButton(updater: updater)
                    } else {
                        CapsuleButton(title: updater.state == .checking ? "Checking…" : "Check now", tint: .accentColor, prominent: false) {
                            updater.check(manual: true)
                        }
                        .disabled(updater.state == .checking)
                    }
                }
                .padding(.bottom, 4)
                if case .failed(let msg) = updater.install {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(msg).foregroundStyle(.secondary).lineLimit(2)
                        Spacer(minLength: 4)
                        Button("Download manually") { updater.openDownload() }.buttonStyle(.link)
                    }
                    .font(.system(size: 10.5))
                    .padding(.bottom, 4)
                }
                Divider().padding(.vertical, 4)
                SettingRow(title: "Check automatically", subtitle: "Looks for new GitHub releases every hour") {
                    Toggle("", isOn: $updater.autoCheck).toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch updater.state {
        case .checking: ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10, height: 10)
        case .upToDate: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.cpuC)
        case .available: Image(systemName: "arrow.down.circle.fill")
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .idle: EmptyView()
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button { updater.openReleasePage() } label: {
                Label("GitHub · MIT License", systemImage: "arrow.up.right.square").font(.system(size: 10.5))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            Spacer()
            CapsuleButton(title: "Quit StatBar", icon: "power", tint: .red, prominent: false) { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Menu bar order

/// The shown menu bar items, left to right as in the menu bar. Drag a pill onto another to reorder
/// (or right-click → Move Left / Move Right). The real menu bar updates live.
struct MenuOrderStrip: View {
    @ObservedObject var settings: Settings
    @State private var dragging: MenuItemKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("Order").font(.system(size: 11, weight: .semibold))
                Text("drag to rearrange").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)
            HStack(spacing: 4) {
                let shown = settings.shownItems
                ForEach(shown) { k in
                    pill(k)
                        .onDrag { dragging = k; return NSItemProvider(object: k.rawValue as NSString) }
                        .onDrop(of: [.plainText], delegate: MenuOrderDrop(target: k, settings: settings, dragging: $dragging))
                        .contextMenu {
                            Button("Move Left") { withAnimation(.easeOut(duration: 0.15)) { settings.shiftMenuItem(k, by: -1) } }
                                .disabled(k == shown.first)
                            Button("Move Right") { withAnimation(.easeOut(duration: 0.15)) { settings.shiftMenuItem(k, by: 1) } }
                                .disabled(k == shown.last)
                        }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func pill(_ k: MenuItemKind) -> some View {
        // text only, like the menu bar itself – keeps all 7 on one row
        Text(k.menuLabel).font(.system(size: 10, weight: .semibold)).lineLimit(1).fixedSize()
            .frame(minWidth: 26)
            .padding(.horizontal, 7).padding(.vertical, 5)
        .background(Capsule().fill(Color.accentColor.opacity(0.13)))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35)))
        .contentShape(Capsule())
        .help("Drag to move \(k.shortTitle) – or right-click")
    }
}

private struct MenuOrderDrop: DropDelegate {
    let target: MenuItemKind
    let settings: Settings
    @Binding var dragging: MenuItemKind?

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target else { return }
        withAnimation(.easeOut(duration: 0.15)) { settings.moveMenuItem(d, to: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

extension MenuItemKind {
    /// The caption the menu bar label uses.
    var menuLabel: String {
        switch self {
        case .cpu: "CPU"; case .gpu: "GPU"; case .mem: "MEM"; case .temp: "TEMP"
        case .net: "NET"; case .disk: "SSD"; case .battery: "BAT"
        }
    }
}

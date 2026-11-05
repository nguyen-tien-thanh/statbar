import SwiftUI
import AppKit

/// In-popover settings page (replaces the old gear dropdown menu).
struct SettingsPage: View {
    @ObservedObject var settings: Settings
    @ObservedObject var priv: Privileged
    @ObservedObject var updater: Updater
    let back: () -> Void
    @State private var launchAtLogin = LoginItem.enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            menuBarSection
            displaySection
            generalSection
            updatesSection
            footer
        }
        .padding(12)
        .onExitCommand(perform: back)   // Esc goes back
    }

    private var header: some View {
        HStack(spacing: 8) {
            CircleIconButton(icon: "chevron.left", help: "Back", action: back)
                .keyboardShortcut(.cancelAction)
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
            }
        }
    }

    // MARK: display

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Display")
            Surface(padding: 12) {
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
                    if updater.updateAvailable {
                        CapsuleButton(title: "Download \(updater.latest ?? "")", icon: "arrow.down", tint: .blue) { updater.openDownload() }
                    } else {
                        CapsuleButton(title: updater.state == .checking ? "Checking…" : "Check now", tint: .accentColor, prominent: false) {
                            updater.check(manual: true)
                        }
                        .disabled(updater.state == .checking)
                    }
                }
                .padding(.bottom, 4)
                Divider().padding(.vertical, 4)
                SettingRow(title: "Check automatically", subtitle: "Looks for new GitHub releases every few hours") {
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

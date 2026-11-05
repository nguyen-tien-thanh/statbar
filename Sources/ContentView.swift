import SwiftUI
import AppKit

enum PopoverPage { case main, settings }

struct ContentView: View {
    @ObservedObject var m: Monitor
    @ObservedObject var settings = Settings.shared
    @ObservedObject var power: PowerAssertions
    @ObservedObject var fan: FanController
    @ObservedObject var priv = Privileged.shared
    @ObservedObject var updater = Updater.shared
    @State var page: PopoverPage = .main

    var body: some View {
        ZStack(alignment: .top) {
            if page == .main {
                mainPage.transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                SettingsPage(settings: settings, priv: priv, updater: updater) { go(.main) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: 360)
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in page = .main }
    }

    private func go(_ p: PopoverPage) { withAnimation(.easeInOut(duration: 0.22)) { page = p } }

    private var mainPage: some View {
        VStack(spacing: 10) {
            header
            gauges
            activity
            thermalsAndPower
            ProcessesCard(m: m, settings: settings)
            quickToggles
            tools
            footer
        }
        .padding(12)
    }

    // MARK: header

    private var healthColor: Color {
        let s = m.health.score
        return s >= 80 ? .cpuC : s >= 60 ? .orange : .red
    }

    private var header: some View {
        let h = m.health
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
                ZStack {
                    RingGauge(fraction: Double(h.score) / 100, color: healthColor, lineWidth: 4.5)
                    Text("\(h.score)").font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                }
                .frame(width: 44, height: 44)
                .help("Health score (0–100) from CPU load, memory pressure, swap, temperature, disk space and battery")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("System \(h.label.lowercased())").font(.system(size: 15, weight: .semibold))
                        Circle().fill(healthColor).frame(width: 6, height: 6)
                    }
                    Text("\(SystemInfo.chip) · \(SystemInfo.memTotal >> 30) GB · macOS \(SystemInfo.osVersion)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Text(Fmt.uptime(m.uptime).replacingOccurrences(of: "up ", with: "Up "))
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                CircleIconButton(icon: "arrow.clockwise", help: "Refresh now") { m.refreshNow() }
                CircleIconButton(icon: "gearshape", help: "Settings") { go(.settings) }
                    .overlay(alignment: .topTrailing) {
                        if updater.updateAvailable { Circle().fill(Color.blue).frame(width: 7, height: 7).offset(x: 1, y: -1) }
                    }
            }
            if !h.issues.isEmpty || m.camOn || m.micOn {
                HStack(spacing: 5) {
                    if m.camOn { StatusChip(icon: "video.fill", text: "Camera", color: .green) }
                    if m.micOn { StatusChip(icon: "mic.fill", text: "Mic", color: .orange) }
                    ForEach(h.issues, id: \.self) { StatusChip(icon: "exclamationmark.triangle.fill", text: $0, color: .orange) }
                }
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: gauges

    private var gauges: some View {
        let used = m.disk.total > 0 ? 1 - Double(m.disk.free) / Double(m.disk.total) : 0
        let memColor: Color = m.mem.pressureLevel >= 4 ? .red : m.mem.pressureLevel >= 2 ? .orange : .memC
        return Surface(padding: 10) {
            HStack(spacing: 0) {
                GaugeTile(title: "CPU", value: "\(Int(m.cpu.rounded()))", fraction: m.cpu / 100,
                          color: m.cpu > 85 ? .red : .cpuC, detail: m.sensors.cpuTemp.map { settings.temp($0) })
                    .help(cpuTooltip)
                GaugeTile(title: "GPU", value: "\(Int(m.gpu.rounded()))", fraction: m.gpu / 100,
                          color: .gpuC, detail: m.sensors.gpuTemp.map { settings.temp($0) } ?? Fmt.bytesStr(Double(m.gpuMem)))
                    .help("GPU utilisation\nVRAM in use: \(Fmt.bytesStr(Double(m.gpuMem)))")
                GaugeTile(title: "Memory", value: "\(Int(m.memPercent.rounded()))", fraction: m.memPercent / 100, color: memColor,
                          detail: String(format: "%.1f / %d GB", Double(m.mem.used) / 1_073_741_824, SystemInfo.memTotal >> 30))
                    .help(memTooltip)
                GaugeTile(title: "Disk", value: "\(Int((used * 100).rounded()))", fraction: used, color: used > 0.9 ? .red : .diskC,
                          detail: "\(Fmt.bytesStr(Double(m.disk.free), decimals: 0)) free")
                    .onTapGesture { Tools.openStorageSettings() }
                    .help("R \(Fmt.rate(m.disk.readRate)) · W \(Fmt.rate(m.disk.writeRate))\nClick to open Storage settings")
            }
        }
    }

    private var cpuTooltip: String {
        var s = String(format: "usr %d%% · sys %d%%\nLoad average: %.2f  %.2f  %.2f", Int(m.cpuUser), Int(m.cpuSystem), m.load[0], m.load[1], m.load[2])
        if let p = SystemInfo.pCores, let e = SystemInfo.eCores { s += "\n\(p) performance + \(e) efficiency cores" }
        s += "\nPer core: " + m.perCore.map { "\(Int($0))" }.joined(separator: " ")
        if let p = m.sensors.systemPower { s += String(format: "\nSystem power: %.1f W", p) }
        return s
    }

    private var memTooltip: String {
        var s = "App: \(Fmt.bytesStr(Double(m.mem.app)))\nWired: \(Fmt.bytesStr(Double(m.mem.wired)))\nCompressed: \(Fmt.bytesStr(Double(m.mem.compressed)))\nCached files: \(Fmt.bytesStr(Double(m.mem.cached)))"
        if m.mem.swapUsed > 0 { s += "\nSwap: \(Fmt.bytesStr(Double(m.mem.swapUsed)))" }
        return s
    }

    // MARK: activity

    private var activity: some View {
        let lag: (String, Color) = {
            if m.latencyFailed { return ("Offline", .red) }
            guard let ms = m.latencyMs else { return ("…", .secondary) }
            return ("\(Int(ms)) ms", ms < 60 ? .cpuC : ms < 150 ? .orange : .red)
        }()
        return Surface(padding: 10) {
            ActivityRow(icon: "cpu", color: .cpuC, title: "Processor",
                        detail: "usr \(Int(m.cpuUser))% · sys \(Int(m.cpuSystem))%" + (m.sensors.systemPower.map { String(format: " · %.1fW", $0) } ?? ""),
                        value: "\(Int(m.cpu.rounded()))%") {
                Sparkline(values: m.cpuHistory.values, color: .cpuC, maxValue: 100)
            }
            .help(cpuTooltip)
            Divider().padding(.vertical, 6).padding(.leading, 36)
            ActivityRow(icon: m.connection.kind == "Wi-Fi" ? "wifi" : "network", color: .netC,
                        title: m.connection.kind.isEmpty ? "Network" : m.connection.kind,
                        detail: "↑ \(Fmt.rate(m.net.up))", detailTrailing: (lag.0, lag.1),
                        value: "↓ \(Fmt.rate(m.net.down))") {
                Sparkline(values: m.downHistory.values, color: .netC, secondary: m.upHistory.values, secondaryColor: .pink)
            }
            .contentShape(Rectangle())
            .onTapGesture { Tools.openNetworkSettings() }
            .help((m.connection.rssi.map { "Wi-Fi signal: \($0) dBm\n" } ?? "") + "Total since boot: ↓ \(Fmt.bytesStr(Double(m.net.totalIn))) ↑ \(Fmt.bytesStr(Double(m.net.totalOut)))\nLatency = TCP connect to 1.1.1.1\nClick to open Network settings")
        }
    }

    // MARK: thermals + power

    @ViewBuilder private var thermalsAndPower: some View {
        let hasFan = m.sensors.fans.first != nil
        if hasFan || m.battery.present {
            Surface(padding: 10) {
                if let f = m.sensors.fans.first {
                    let pct = f.max > 0 ? min(100, Int((f.rpm / f.max * 100).rounded())) : 0
                    HStack(spacing: 10) {
                        IconBadge(icon: "fan.fill", color: .fanC)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(f.rpm.formatted(.number.precision(.fractionLength(0)))) RPM").font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                                Text("\(pct)%").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                            Text(fan.mode != .auto ? "Manual · \(fan.mode.title)" : f.manual ? "Forced by another app" : "Managed by macOS")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Segmented(options: FanMode.allCases.map { ($0, $0.title) }, selection: fan.mode, tint: .fanC, compact: true) { fan.set($0) }
                            .disabled(fan.busy).opacity(fan.busy ? 0.6 : 1)
                    }
                    .help("Cool = 70% of max speed (Max when CPU > 90°C), Max = 100%.\nNeeds Touch ID / admin password. Fans return to automatic control when StatBar quits.")
                    if m.battery.present { Divider().padding(.vertical, 8).padding(.leading, 36) }
                }
                if m.battery.present { batteryRow }
            }
        }
    }

    private var batteryRow: some View {
        let b = m.battery
        let status: String = {
            if b.fullyCharged || (b.external && !b.charging && b.percent >= 99) { return "Charged" }
            if b.charging { return "Charging" + (b.timeRemaining.map { " · \(Fmt.minutes($0)) to full" } ?? "") }
            if b.external { return "Plugged in · not charging" }
            return "On battery" + (b.timeRemaining.map { " · \(Fmt.minutes($0)) left" } ?? "")
        }()
        let col: Color = b.percent <= 20 && !b.external ? .red : .batC
        let icon = b.charging ? "battery.100percent.bolt" : b.percent > 70 ? "battery.100percent" : b.percent > 40 ? "battery.50percent" : "battery.25percent"
        return VStack(spacing: 7) {
            HStack(spacing: 10) {
                IconBadge(icon: icon, color: col)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(b.percent)%").font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                        if b.external && b.adapterWatts > 0 { Text("· \(b.adapterWatts)W adapter").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                    }
                    Text(status).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Tag(text: "\(b.health)% health", color: b.health < 80 ? .orange : .secondary)
                    Text("\(b.cycles) cycles · \(settings.temp(b.temperature))").font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            }
            Meter(fraction: Double(b.percent) / 100, color: col, height: 4).padding(.leading, 36)
        }
        .contentShape(Rectangle())
        .onTapGesture { Tools.openBatterySettings() }
        .help((b.powerW > 0.05 ? String(format: "%@ %.1f W\n", b.charging ? "Charging at" : "Drawing", b.powerW) : "") + "Click to open Battery settings")
    }

    // MARK: controls

    private var quickToggles: some View {
        HStack(spacing: 8) {
            ToggleTile(icon: "cup.and.saucer.fill", title: "Keep awake", on: power.awake, tint: .orange) { power.setAwake(!power.awake) }
                .help("Prevent the Mac from sleeping while idle")
            ToggleTile(icon: "sun.max.fill", title: "Display on", on: power.screen, tint: .blue) { power.setScreen(!power.screen) }
                .help("Keep the display from turning off")
        }
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Tools")
            HStack(spacing: 6) {
                ForEach([ToolboxTab.clean, .uninstall, .optimize, .analyze]) { t in
                    ToolButton(tab: t) {
                        NotificationCenter.default.post(name: .statbarClosePopover, object: nil)
                        Toolbox.shared.open(t)
                    }
                }
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            versionBadge
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Label("Quit", systemImage: "power").font(.system(size: 10.5, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Quit StatBar")
        }
        .padding(.horizontal, 4)
    }

    /// "StatBar 1.0.0" — becomes a download button when GitHub has a newer release.
    @ViewBuilder private var versionBadge: some View {
        if updater.updateAvailable {
            CapsuleButton(title: "Update to \(updater.latest ?? "")", icon: "arrow.down.circle.fill", tint: .blue) { updater.openDownload() }
                .help("StatBar \(updater.latest ?? "") is available (you have \(updater.current)). Click to download.")
        } else {
            Button { updater.check(manual: true) } label: {
                HStack(spacing: 4) {
                    Text("StatBar \(updater.current)")
                    switch updater.state {
                    case .checking: ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
                    case .upToDate: Image(systemName: "checkmark.circle")
                    case .failed: Image(systemName: "exclamationmark.circle")
                    default: EmptyView()
                    }
                }
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help(updater.statusText + " · Click to check again")
        }
    }
}

// MARK: - Popover rows

struct StatusChip: View {
    let icon: String
    let text: String
    let color: Color
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8.5, weight: .bold))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct ActivityRow<Graph: View>: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String
    var detailTrailing: (String, Color)? = nil
    let value: String
    @ViewBuilder var graph: Graph
    var body: some View {
        HStack(spacing: 10) {
            IconBadge(icon: icon, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                HStack(spacing: 4) {
                    Text(detail)
                    if let d = detailTrailing { Text("·"); Text(d.0).foregroundStyle(d.1) }
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 6)
            Text(value).font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
            graph.frame(width: 78, height: 24)
        }
    }
}

struct ToolButton: View {
    let tab: ToolboxTab
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tab.color)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tab.color.opacity(hover ? 0.24 : 0.14)))
                Text(tab.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hover ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(tab.subtitle)
    }
}

// MARK: - Processes

struct ProcessesCard: View {
    @ObservedObject var m: Monitor
    @ObservedObject var settings: Settings
    @State private var confirmIdle = false

    private var top: [ProcGroup] {
        let sorted = settings.processSort == "mem" ? m.processes.sorted { $0.memory > $1.memory }
                                                  : m.processes.sorted { $0.cpu > $1.cpu }
        return Array(sorted.prefix(6))
    }

    var body: some View {
        Surface(padding: 10) {
            HStack {
                Text("Top Processes").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                sortButton("Memory", key: "mem").frame(width: 66, alignment: .trailing)
                sortButton("% CPU", key: "cpu").frame(width: 46, alignment: .trailing)
                Color.clear.frame(width: 18)
            }
            .padding(.bottom, 6)
            ForEach(top) { p in ProcessRow(p: p) }
            if m.processes.isEmpty { Text("Loading…").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 4) }
            if !m.idleApps.isEmpty {
                let total = m.idleApps.reduce(0) { $0 + $1.memory }
                HStack {
                    Text("\(m.idleApps.count) idle app\(m.idleApps.count > 1 ? "s" : "") using \(Fmt.bytesStr(Double(total)))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Quit") { confirmIdle = true }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.cpuC)
                        .popover(isPresented: $confirmIdle) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Quit these background apps?").font(.headline)
                                ForEach(m.idleApps) { a in Text("• \(a.name) – \(Fmt.bytesStr(Double(a.memory)))").font(.system(size: 12)) }
                                HStack {
                                    Spacer()
                                    Button("Cancel") { confirmIdle = false }
                                    Button("Quit All") {
                                        m.idleApps.forEach { ProcessSampler.quit($0, force: false) }
                                        confirmIdle = false
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { m.refreshNow() }
                                    }.keyboardShortcut(.defaultAction)
                                }
                            }
                            .padding(12).frame(width: 260)
                        }
                }
                .padding(.top, 6)
                .help(m.idleApps.map(\.name).joined(separator: ", ") + "\nBackground apps with no visible windows and ~0% CPU")
            }
        }
    }

    private func sortButton(_ title: String, key: String) -> some View {
        Button { settings.processSort = key } label: {
            Text(title).font(.system(size: 11, weight: settings.processSort == key ? .semibold : .regular))
                .foregroundStyle(settings.processSort == key ? Color.primary : Color.secondary)
        }.buttonStyle(.plain)
    }
}

struct ProcessRow: View {
    let p: ProcGroup
    @State private var hover = false
    private static var iconCache: [String: NSImage] = [:]

    private var icon: NSImage? {
        guard p.isApp else { return nil }
        if let i = Self.iconCache[p.key] { return i }
        let i = NSWorkspace.shared.icon(forFile: p.key); i.size = NSSize(width: 16, height: 16)
        Self.iconCache[p.key] = i
        return i
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let icon { Image(nsImage: icon).resizable() } else { Image(systemName: "gearshape").foregroundStyle(.secondary) }
            }
            .frame(width: 15, height: 15)
            Text(p.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
            if p.pids.count > 1 { Text("\(p.pids.count)").font(.system(size: 9)).foregroundStyle(.tertiary) }
            Spacer(minLength: 4)
            Text(Fmt.bytesStr(Double(p.memory), decimals: 2)).font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 66, alignment: .trailing)
            Text(String(format: "%.1f", p.cpu)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Color.level(p.cpu, warn: 50, crit: 80) == .secondary ? Color.primary : Color.level(p.cpu, warn: 50, crit: 80))
                .frame(width: 46, alignment: .trailing)
            Menu {
                Button("Quit") { ProcessSampler.quit(p, force: false) }.disabled(!p.ownedByUser)
                Button("Force Quit") { ProcessSampler.quit(p, force: true) }.disabled(!p.ownedByUser)
                Divider()
                Button("Reveal in Finder") { ProcessSampler.reveal(p) }
                Button("Copy PID\(p.pids.count > 1 ? "s" : "")") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p.pids.map(String.init).joined(separator: " "), forType: .string)
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18).opacity(hover ? 1 : 0.5)
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.07 : 0)))
        .padding(.horizontal, -4)
        .onHover { hover = $0 }
        .help("\(p.key)\nPID: \(p.pids.prefix(10).map(String.init).joined(separator: ", "))\(p.pids.count > 10 ? "…" : "")")
    }
}

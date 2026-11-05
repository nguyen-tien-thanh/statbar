import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var m: Monitor
    @ObservedObject var settings = Settings.shared
    @ObservedObject var power: PowerAssertions
    @ObservedObject var fan: FanController

    var body: some View {
        VStack(spacing: 8) {
            header
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                cpuCard; gpuCard; memCard; diskCard; netCard; fanCard
            }
            if m.battery.present { batteryCard }
            ProcessesCard(m: m, settings: settings)
            controlsCard
            footer
        }
        .padding(12)
        .frame(width: 360)
    }

    // MARK: header

    private var header: some View {
        let h = m.health
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: h.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 24))
                Text("\(h.score)").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                Text(h.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 6)
                Spacer()
                Button { m.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Refresh now")
            }
            HStack(spacing: 5) {
                Tag(text: SystemInfo.chip)
                Tag(text: "\(SystemInfo.memTotal >> 30) GB")
                Tag(text: "macOS \(SystemInfo.osVersion)")
                Tag(text: Fmt.uptime(m.uptime))
            }
            if !h.issues.isEmpty {
                Text(h.issues.joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(Color.orange)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: cards

    private var cpuCard: some View {
        Card {
            CardHeader(icon: "cpu", title: "CPU", color: .cpuC,
                       tag: m.sensors.cpuTemp.map { settings.temp($0) }, tagColor: .level(m.sensors.cpuTemp ?? 0, warn: 75, crit: 90))
            BigValue(value: "\(Int(m.cpu.rounded()))", unit: "%").padding(.top, 6)
            BarHistory(values: m.cpuHistory.values, color: .cpuC).frame(height: 24).padding(.vertical, 6)
            HStack(spacing: 4) {
                Text("usr \(Int(m.cpuUser))% · sys \(Int(m.cpuSystem))%")
                Spacer()
                if let p = m.sensors.systemPower { Text(String(format: "%.1fW", p)) }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(cpuTooltip)
    }

    private var cpuTooltip: String {
        var s = String(format: "Load average: %.2f  %.2f  %.2f", m.load[0], m.load[1], m.load[2])
        if let p = SystemInfo.pCores, let e = SystemInfo.eCores { s += "\n\(p) performance + \(e) efficiency cores" }
        s += "\nPer core: " + m.perCore.map { "\(Int($0))" }.joined(separator: " ")
        if m.sensors.systemPower != nil { s += "\nPower = total system power from SMC" }
        return s
    }

    private var gpuCard: some View {
        Card {
            CardHeader(icon: "square.stack.3d.up.fill", title: "GPU", color: .gpuC,
                       tag: m.sensors.gpuTemp.map { settings.temp($0) }, tagColor: .level(m.sensors.gpuTemp ?? 0, warn: 75, crit: 90))
            BigValue(value: "\(Int(m.gpu.rounded()))", unit: "%").padding(.top, 6)
            Sparkline(values: m.gpuHistory.values, color: .gpuC, maxValue: 100).frame(height: 24).padding(.vertical, 6)
            Text(m.gpu < 5 ? "idle · \(Fmt.bytesStr(Double(m.gpuMem)))" : "VRAM \(Fmt.bytesStr(Double(m.gpuMem)))")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var memCard: some View {
        let (tag, color): (String, Color) = switch m.mem.pressureLevel {
            case 4: ("Critical", Color.red)
            case 2: ("High", Color.orange)
            default: ("Normal", .cpuC)
        }
        return Card {
            CardHeader(icon: "memorychip", title: "MEM", color: .memC, tag: tag, tagColor: color)
            BigValue(value: "\(Int(m.memPercent.rounded()))", unit: "%").padding(.top, 6)
            Sparkline(values: m.memHistory.values, color: .memC, maxValue: 100).frame(height: 24).padding(.vertical, 6)
            HStack {
                Text("\(String(format: "%.1f", Double(m.mem.used) / 1_073_741_824)) / \(SystemInfo.memTotal >> 30) GB")
                Spacer()
                if m.mem.swapUsed > 0 { Text("swap \(Fmt.bytesStr(Double(m.mem.swapUsed)))") }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .help("App: \(Fmt.bytesStr(Double(m.mem.app)))\nWired: \(Fmt.bytesStr(Double(m.mem.wired)))\nCompressed: \(Fmt.bytesStr(Double(m.mem.compressed)))\nCached files: \(Fmt.bytesStr(Double(m.mem.cached)))")
    }

    private var diskCard: some View {
        let used = m.disk.total > 0 ? 1 - Double(m.disk.free) / Double(m.disk.total) : 0
        let (v, u) = Fmt.bytes(Double(m.disk.free), decimals: 0)
        return Card {
            CardHeader(icon: "internaldrive.fill", title: "Free space", color: .diskC,
                       tag: m.disk.total > 0 ? Fmt.bytesStr(Double(m.disk.total), decimals: 0) : nil)
            BigValue(value: v, unit: u).padding(.top, 6)
            Meter(fraction: used, color: used > 0.9 ? .red : .diskC).frame(height: 24, alignment: .center).padding(.vertical, 6)
            Text("R \(Fmt.rate(m.disk.readRate)) · W \(Fmt.rate(m.disk.writeRate))")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .contentShape(Rectangle())
        .onTapGesture { Tools.openStorageSettings() }
        .help("Click to open Storage settings")
    }

    private var netCard: some View {
        let (v, u) = Fmt.bytes(m.net.down)
        let lag: (String, Color) = {
            if m.latencyFailed { return ("Offline", .red) }
            guard let ms = m.latencyMs else { return ("…", .secondary) }
            if ms < 60 { return ("Low Lag \(Int(ms))ms", .cpuC) }
            if ms < 150 { return ("Lag \(Int(ms))ms", .orange) }
            return ("High Lag \(Int(ms))ms", .red)
        }()
        let tag = m.connection.kind
        return Card {
            CardHeader(icon: m.connection.kind == "Wi-Fi" ? "wifi" : "network", title: "Network", color: .netC, tag: tag)
            BigValue(value: "↓ " + v, unit: u + "/s").padding(.top, 6)
            Sparkline(values: m.downHistory.values, color: .netC, secondary: m.upHistory.values, secondaryColor: .pink)
                .frame(height: 24).padding(.vertical, 6)
            HStack(spacing: 4) {
                Text("↑ \(Fmt.rate(m.net.up))")
                Spacer(minLength: 2)
                Text(lag.0).foregroundStyle(lag.1)
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .contentShape(Rectangle())
        .onTapGesture { Tools.openNetworkSettings() }
        .help((m.connection.rssi.map { "Wi-Fi signal: \($0) dBm\n" } ?? "") + "Total since boot: ↓ \(Fmt.bytesStr(Double(m.net.totalIn))) ↑ \(Fmt.bytesStr(Double(m.net.totalOut)))\nLatency = TCP connect to 1.1.1.1")
    }

    @ViewBuilder private var fanCard: some View {
        if let f = m.sensors.fans.first {
            let pct = f.max > 0 ? Int((f.rpm / f.max * 100).rounded()) : 0
            Card {
                CardHeader(icon: "fan.fill", title: "Fan", color: .fanC, tag: "Speed \(min(pct, 100))%")
                BigValue(value: f.rpm.formatted(.number.precision(.fractionLength(0))), unit: "RPM").padding(.top, 6)
                Text(fan.mode != .auto ? "Manual · \(fan.mode.title)" : f.manual ? "Forced by another app" : "Managed by macOS")
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 4)
                HStack(spacing: 4) {
                    ForEach(FanMode.allCases, id: \.self) { mode in
                        PillButton(title: mode.title, active: fan.mode == mode, tint: .fanC.opacity(0.9)) { fan.set(mode) }
                    }
                }
                .disabled(fan.busy)
                .padding(.top, 6)
            }
            .help("Cool = 70% of max speed, Max = 100%. Requires your admin password once per session.\nFans return to automatic control when StatBar quits.")
        } else {
            Card {
                CardHeader(icon: "thermometer.medium", title: "Thermals", color: .fanC, tag: "Fanless")
                BigValue(value: m.sensors.cpuTemp.map { "\(Int(($0 * (settings.fahrenheit ? 1.8 : 1) + (settings.fahrenheit ? 32 : 0)).rounded()))" } ?? "–",
                         unit: settings.fahrenheit ? "°F" : "°C").padding(.top, 6)
                Text("GPU \(settings.temp(m.sensors.gpuTemp))").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 8)
                if m.battery.present { Text("Battery \(settings.temp(m.battery.temperature))").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
    }

    private var batteryCard: some View {
        let b = m.battery
        let status: String = {
            if b.fullyCharged || (b.external && !b.charging && b.percent >= 99) { return "Charged" }
            if b.charging { return "Charging" + (b.timeRemaining.map { " · \(Fmt.minutes($0)) to full" } ?? "") }
            if b.external { return "Plugged in · not charging" }
            return "On battery" + (b.timeRemaining.map { " · \(Fmt.minutes($0)) left" } ?? "")
        }()
        let col: Color = b.percent <= 20 && !b.external ? .red : .batC
        return Card {
            HStack(spacing: 5) {
                Image(systemName: b.charging ? "battery.100.bolt" : "battery.100").font(.system(size: 11, weight: .semibold)).foregroundStyle(col)
                Text("Battery").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text("\(b.cycles) cycles").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Tag(text: "\(b.health)% Health", color: b.health < 80 ? .orange : .secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                BigValue(value: "\(b.percent)", unit: "%", size: 26)
                if b.external && b.adapterWatts > 0 {
                    Label("\(b.adapterWatts)W", systemImage: "bolt.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    if b.powerW > 0.05 { Text(String(format: "%@ %.1fW", b.charging ? "in" : "out", b.powerW)) }
                    Text(settings.temp(b.temperature))
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
            Meter(fraction: Double(b.percent) / 100, color: col, height: 5).padding(.vertical, 5)
            Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { Tools.openBatterySettings() }
    }

    // MARK: controls

    @State private var purgeMsg: String?
    @State private var dnsMsg: String?

    private var controlsCard: some View {
        Card {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: m.camOn ? "video.fill" : "video").foregroundStyle(m.camOn ? Color.green : Color.secondary)
                    Image(systemName: m.micOn ? "mic.fill" : "mic").foregroundStyle(m.micOn ? Color.orange : Color.secondary)
                    Text(privacyText).font(.system(size: 11)).foregroundStyle(m.camOn || m.micOn ? Color.primary : Color.secondary)
                }
                .font(.system(size: 11))
                Spacer()
                PillButton(title: "Awake", icon: "cup.and.saucer.fill", active: power.awake, tint: .orange) { power.setAwake(!power.awake) }
                    .help("Prevent the Mac from sleeping while idle")
                PillButton(title: "Screen", icon: "display", active: power.screen, tint: .blue) { power.setScreen(!power.screen) }
                    .help("Keep the display on")
            }
            Divider().padding(.vertical, 8)
            HStack(spacing: 2) {
                ToolTile(icon: "memorychip", title: "Free RAM", subtitle: purgeMsg) {
                    purgeMsg = "…"
                    Tools.purgeMemory { ok in purgeMsg = ok ? "Done ✓" : "Cancelled"; m.refreshNow() }
                }
                .help("Purge inactive / file cache memory (asks for admin password)")
                ToolTile(icon: "network", title: "Flush DNS", subtitle: dnsMsg) {
                    dnsMsg = "…"
                    Tools.flushDNS { ok in dnsMsg = ok ? "Done ✓" : "Cancelled" }
                }
                ToolTile(icon: "waveform.path.ecg", title: "Activity", subtitle: "Monitor") { Tools.openActivityMonitor() }
                ToolTile(icon: "internaldrive", title: "Storage", subtitle: "Settings") { Tools.openStorageSettings() }
            }
        }
    }

    private var privacyText: String {
        switch (m.camOn, m.micOn) {
        case (true, true): "Cam + Mic in use"
        case (true, false): "Camera in use"
        case (false, true): "Mic in use"
        default: "Not in use"
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Menu {
                Section("Show in menu bar") {
                    ForEach(MenuItemKind.allCases) { k in
                        Toggle(k.title, isOn: Binding(
                            get: { settings.menuItems.contains(k) },
                            set: { on in if on { settings.menuItems.insert(k) } else { settings.menuItems.remove(k) } }))
                    }
                }
                Picker("Update every", selection: $settings.interval) {
                    Text("1 second").tag(1.0); Text("2 seconds").tag(2.0); Text("3 seconds").tag(3.0); Text("5 seconds").tag(5.0)
                }
                Toggle("Fahrenheit", isOn: $settings.fahrenheit)
                Toggle("Launch at login", isOn: Binding(get: { LoginItem.enabled }, set: { LoginItem.set($0) }))
                Divider()
                Button("Quit StatBar") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Spacer()
            Text("StatBar").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
            Spacer()
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Quit StatBar")
        }
        .padding(.horizontal, 6)
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
        Card {
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

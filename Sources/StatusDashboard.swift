import SwiftUI

/// Wide dashboard for the Status tab of the toolbox window (the menu bar popover keeps its compact layout).
struct StatusDashboard: View {
    @ObservedObject var m: Monitor
    @ObservedObject var settings = Settings.shared
    @ObservedObject var power: PowerAssertions
    @ObservedObject var fan: FanController
    var scrolls = true

    var body: some View {
        if scrolls { ScrollView { content } } else { content }
    }

    private var content: some View {
            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    healthPanel
                    quickPanel.frame(width: 250)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    cpuPanel; gpuPanel; memPanel; diskPanel
                }
                HStack(alignment: .top, spacing: 14) {
                    netPanel
                    thermalPanel.frame(width: 300)
                }
                if m.battery.present { batteryPanel }
                processPanel
            }
            .padding(20)
    }

    // MARK: - Health

    private var healthColor: Color {
        let s = m.health.score
        return s >= 80 ? .cpuC : s >= 60 ? .orange : .red
    }

    private var healthPanel: some View {
        let h = m.health
        return Panel {
            HStack(spacing: 22) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.08), lineWidth: 12)
                    Circle().trim(from: 0, to: CGFloat(h.score) / 100)
                        .stroke(AngularGradient(colors: [healthColor.opacity(0.6), healthColor], center: .center),
                                style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(h.score)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                        Text(h.label).font(.system(size: 12, weight: .semibold)).foregroundStyle(healthColor)
                    }
                }
                .frame(width: 110, height: 110)
                .animation(.easeOut(duration: 0.4), value: h.score)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: h.symbol).symbolRenderingMode(.multicolor).font(.system(size: 18))
                        Text("System health").font(.system(size: 18, weight: .bold))
                    }
                    if h.issues.isEmpty {
                        Label("Everything looks good", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12.5)).foregroundStyle(Color.cpuC)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(h.issues, id: \.self) { i in
                                Label(i, systemImage: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12.5)).foregroundStyle(.orange)
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        Tag(text: SystemInfo.chip)
                        Tag(text: "\(SystemInfo.memTotal >> 30) GB RAM")
                        Tag(text: "macOS \(SystemInfo.osVersion)")
                        Tag(text: Fmt.uptime(m.uptime))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var quickPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                PanelTitle(icon: "switch.2", title: "Quick controls", color: .accentColor)
                ControlRow(icon: "cup.and.saucer.fill", title: "Keep awake", subtitle: "Prevent idle sleep",
                           isOn: Binding(get: { power.awake }, set: { power.setAwake($0) }))
                ControlRow(icon: "display", title: "Keep screen on", subtitle: "Prevent display sleep",
                           isOn: Binding(get: { power.screen }, set: { power.setScreen($0) }))
                Divider()
                HStack(spacing: 14) {
                    PrivacyDot(icon: m.camOn ? "video.fill" : "video", title: "Camera", active: m.camOn, color: .green)
                    PrivacyDot(icon: m.micOn ? "mic.fill" : "mic", title: "Mic", active: m.micOn, color: .orange)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Metric panels

    private var cpuPanel: some View {
        Panel {
            PanelTitle(icon: "cpu", title: "CPU", color: .cpuC,
                       tag: m.sensors.cpuTemp.map { settings.temp($0) }, tagColor: .level(m.sensors.cpuTemp ?? 0, warn: 75, crit: 90))
            BigValue(value: "\(Int(m.cpu.rounded()))", unit: "%", size: 30).padding(.top, 8)
            BarHistory(values: m.cpuHistory.values, color: .cpuC).frame(height: 46).padding(.vertical, 8)
            CoreBars(values: m.perCore, pCores: SystemInfo.pCores ?? 0).frame(height: 22).padding(.bottom, 8)
            KV("User / System", "\(Int(m.cpuUser))% / \(Int(m.cpuSystem))%")
            KV("Load average", String(format: "%.2f  %.2f  %.2f", m.load[0], m.load[1], m.load[2]))
            if let p = m.sensors.systemPower { KV("System power", String(format: "%.1f W", p)) }
        }
    }

    private var gpuPanel: some View {
        Panel {
            PanelTitle(icon: "square.stack.3d.up.fill", title: "GPU", color: .gpuC,
                       tag: m.sensors.gpuTemp.map { settings.temp($0) }, tagColor: .level(m.sensors.gpuTemp ?? 0, warn: 75, crit: 90))
            BigValue(value: "\(Int(m.gpu.rounded()))", unit: "%", size: 30).padding(.top, 8)
            Sparkline(values: m.gpuHistory.values, color: .gpuC, maxValue: 100).frame(height: 76).padding(.vertical, 8)
            KV("Memory in use", Fmt.bytesStr(Double(m.gpuMem)))
            KV("State", m.gpu < 5 ? "Idle" : m.gpu < 50 ? "Active" : "Busy")
        }
    }

    private var memPanel: some View {
        let total = Double(SystemInfo.memTotal)
        let (tag, color): (String, Color) = switch m.mem.pressureLevel {
            case 4: ("Critical", .red)
            case 2: ("Pressure", .orange)
            default: ("Normal", .cpuC)
        }
        return Panel {
            PanelTitle(icon: "memorychip", title: "Memory", color: .memC, tag: tag, tagColor: color)
            BigValue(value: "\(Int(m.memPercent.rounded()))", unit: "%", size: 30).padding(.top, 8)
            Sparkline(values: m.memHistory.values, color: .memC, maxValue: 100).frame(height: 40).padding(.vertical, 8)
            StackedBar(parts: [
                (Double(m.mem.app) / total, Color.memC, "App"),
                (Double(m.mem.wired) / total, Color.orange, "Wired"),
                (Double(m.mem.compressed) / total, Color.purple, "Compressed"),
            ])
            .padding(.bottom, 8)
            KV("Used", "\(Fmt.bytesStr(Double(m.mem.used))) of \(SystemInfo.memTotal >> 30) GB")
            KV("Cached files", Fmt.bytesStr(Double(m.mem.cached)))
            KV("Swap", Fmt.bytesStr(Double(m.mem.swapUsed)))
        }
    }

    private var diskPanel: some View {
        let used = m.disk.total > 0 ? 1 - Double(m.disk.free) / Double(m.disk.total) : 0
        let (v, u) = Fmt.bytes(Double(m.disk.free), decimals: 0)
        return Panel {
            PanelTitle(icon: "internaldrive.fill", title: "Disk", color: .diskC, tag: "\(Int(used * 100))% used")
            BigValue(value: v, unit: "\(u) free", size: 30).padding(.top, 8)
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 10)
                Circle().trim(from: 0, to: used).stroke(used > 0.9 ? Color.red : Color.diskC, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(Fmt.bytesStr(Double(m.disk.total), decimals: 0)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
            .frame(width: 70, height: 70).frame(maxWidth: .infinity).padding(.vertical, 8)
            KV("Read", Fmt.rate(m.disk.readRate))
            KV("Write", Fmt.rate(m.disk.writeRate))
            Button("Open Storage settings") { Tools.openStorageSettings() }
                .buttonStyle(.link).font(.system(size: 11)).padding(.top, 4)
        }
    }

    private var netPanel: some View {
        let lag: (String, Color) = {
            if m.latencyFailed { return ("Offline", .red) }
            guard let ms = m.latencyMs else { return ("…", .secondary) }
            return ms < 60 ? ("\(Int(ms)) ms · Low", .cpuC) : ms < 150 ? ("\(Int(ms)) ms · Medium", .orange) : ("\(Int(ms)) ms · High", .red)
        }()
        return Panel {
            PanelTitle(icon: m.connection.kind == "Wi-Fi" ? "wifi" : "network", title: "Network", color: .netC,
                       tag: m.connection.kind + (m.connection.rssi.map { " · \($0) dBm" } ?? ""))
            HStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Download", systemImage: "arrow.down").font(.system(size: 11)).foregroundStyle(Color.netC)
                    BigValue(value: Fmt.bytes(m.net.down).0, unit: Fmt.bytes(m.net.down).1 + "/s", size: 26)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Label("Upload", systemImage: "arrow.up").font(.system(size: 11)).foregroundStyle(.pink)
                    BigValue(value: Fmt.bytes(m.net.up).0, unit: Fmt.bytes(m.net.up).1 + "/s", size: 26)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Latency").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(lag.0).font(.system(size: 13, weight: .semibold)).foregroundStyle(lag.1)
                }
            }
            .padding(.top, 8)
            Sparkline(values: m.downHistory.values, color: .netC, secondary: m.upHistory.values, secondaryColor: .pink)
                .frame(height: 90).padding(.vertical, 10)
            HStack {
                KV("Received since boot", Fmt.bytesStr(Double(m.net.totalIn)))
                Spacer(minLength: 30)
                KV("Sent since boot", Fmt.bytesStr(Double(m.net.totalOut)))
            }
        }
    }

    private var thermalPanel: some View {
        Panel {
            PanelTitle(icon: "thermometer.medium", title: "Thermals & fan", color: .fanC)
            VStack(spacing: 8) {
                TempRow(label: "CPU", value: m.sensors.cpuTemp, settings: settings)
                TempRow(label: "GPU", value: m.sensors.gpuTemp, settings: settings)
                if m.battery.present { TempRow(label: "Battery", value: m.battery.temperature, settings: settings) }
            }
            .padding(.vertical, 10)
            if let f = m.sensors.fans.first {
                Divider().padding(.bottom, 8)
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "fan.fill").foregroundStyle(Color.fanC)
                    BigValue(value: f.rpm.formatted(.number.precision(.fractionLength(0))), unit: "RPM", size: 22)
                    Spacer()
                    Text(f.max > 0 ? "\(min(100, Int((f.rpm / f.max * 100).rounded())))%" : "")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                Text(fan.mode != .auto ? "Manual · \(fan.mode.title)" : f.manual ? "Forced by another app" : "Managed by macOS")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 2)
                HStack(spacing: 6) {
                    ForEach(FanMode.allCases, id: \.self) { mode in
                        PillButton(title: mode.title, active: fan.mode == mode, tint: .fanC) { fan.set(mode) }
                    }
                }
                .disabled(fan.busy).padding(.top, 8)
            } else {
                Text("Fanless design").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var batteryPanel: some View {
        let b = m.battery
        let status: String = {
            if b.fullyCharged || (b.external && !b.charging && b.percent >= 99) { return "Charged" }
            if b.charging { return "Charging" + (b.timeRemaining.map { " · \(Fmt.minutes($0)) to full" } ?? "") }
            if b.external { return "Plugged in · not charging" }
            return "On battery" + (b.timeRemaining.map { " · \(Fmt.minutes($0)) left" } ?? "")
        }()
        let col: Color = b.percent <= 20 && !b.external ? .red : .batC
        return Panel {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    PanelTitle(icon: b.charging ? "battery.100.bolt" : "battery.100", title: "Battery", color: col)
                    BigValue(value: "\(b.percent)", unit: "%", size: 34)
                    Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(width: 200, alignment: .leading)
                VStack(spacing: 10) {
                    Meter(fraction: Double(b.percent) / 100, color: col, height: 10)
                    HStack(spacing: 0) {
                        Stat(title: "Health", value: "\(b.health)%", warn: b.health < 80)
                        Stat(title: "Cycles", value: "\(b.cycles)")
                        Stat(title: b.charging ? "Charging" : "Power", value: b.powerW > 0.05 ? String(format: "%.1f W", b.powerW) : "–")
                        Stat(title: "Adapter", value: b.external && b.adapterWatts > 0 ? "\(b.adapterWatts) W" : "–")
                        Stat(title: "Temperature", value: settings.temp(b.temperature))
                    }
                }
            }
        }
        .onTapGesture { Tools.openBatterySettings() }
    }

    private var processPanel: some View {
        let sorted = settings.processSort == "mem" ? m.processes.sorted { $0.memory > $1.memory } : m.processes.sorted { $0.cpu > $1.cpu }
        return Panel {
            HStack {
                PanelTitle(icon: "list.bullet.rectangle", title: "Top processes", color: .secondary)
                Spacer()
                Picker("", selection: $settings.processSort) {
                    Text("CPU").tag("cpu"); Text("Memory").tag("mem")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            HStack {
                Text("Name"); Spacer()
                Text("Memory").frame(width: 66, alignment: .trailing)
                Text("% CPU").frame(width: 46, alignment: .trailing)
                Color.clear.frame(width: 18)
            }
            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).padding(.top, 10).padding(.bottom, 2)
            ForEach(sorted.prefix(10)) { p in ProcessRow(p: p) }
            if !m.idleApps.isEmpty {
                Text("\(m.idleApps.count) idle background app(s) using \(Fmt.bytesStr(Double(m.idleApps.reduce(0) { $0 + $1.memory }))): "
                     + m.idleApps.map(\.name).joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
    }
}

// MARK: - Building blocks

private struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct PanelTitle: View {
    let icon: String
    let title: String
    let color: Color
    var tag: String? = nil
    var tagColor: Color = .secondary
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.14)))
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            if let tag { Tag(text: tag, color: tagColor) }
        }
    }
}

private struct KV: View {
    let k: String, v: String
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(v).fontWeight(.medium).monospacedDigit()
        }
        .font(.system(size: 11.5)).padding(.vertical, 2.5)
    }
}

private struct Stat: View {
    let title: String, value: String
    var warn = false
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(warn ? Color.orange : Color.primary)
            Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CoreBars: View {
    let values: [Double]
    let pCores: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(values.indices, id: \.self) { i in
                // macOS lists efficiency cores first on Apple Silicon
                let isP = i >= values.count - pCores
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2).fill(isP ? Color.cpuC : Color.teal)
                        .frame(height: max(2, 22 * min(values[i], 100) / 100))
                }
            }
        }
        .help("Per-core usage (teal = efficiency, green = performance)")
    }
}

private struct StackedBar: View {
    let parts: [(Double, Color, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(parts.indices, id: \.self) { i in
                        Rectangle().fill(parts[i].1).frame(width: max(0, geo.size.width * min(parts[i].0, 1) - 1.5))
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.primary.opacity(0.08))
                .clipShape(Capsule())
            }
            .frame(height: 8)
            HStack(spacing: 10) {
                ForEach(parts.indices, id: \.self) { i in
                    HStack(spacing: 4) {
                        Circle().fill(parts[i].1).frame(width: 6, height: 6)
                        Text(parts[i].2).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct TempRow: View {
    let label: String
    let value: Double?
    let settings: Settings
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            Meter(fraction: (value ?? 0) / 105, color: .level(value ?? 0, warn: 75, crit: 90) == .secondary ? .fanC : .level(value ?? 0, warn: 75, crit: 90), height: 6)
            Text(settings.temp(value)).font(.system(size: 12, weight: .semibold)).monospacedDigit().frame(width: 46, alignment: .trailing)
        }
    }
}

private struct ControlRow: View {
    let icon: String, title: String, subtitle: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(isOn ? Color.orange : Color.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
    }
}

private struct PrivacyDot: View {
    let icon: String, title: String
    let active: Bool
    let color: Color
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(active ? color : Color.secondary)
            Text(active ? "\(title) on" : "\(title) off").font(.system(size: 11)).foregroundStyle(active ? Color.primary : Color.secondary)
        }
        .font(.system(size: 12))
    }
}

import Foundation
import Combine
import AppKit

struct Ring {
    private(set) var values: [Double]
    init(_ n: Int) { values = Array(repeating: 0, count: n) }
    mutating func push(_ v: Double) { values.removeFirst(); values.append(v) }
}

enum MenuItemKind: String, CaseIterable, Identifiable {
    case cpu, gpu, mem, temp, net, disk, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"; case .gpu: "GPU"; case .mem: "Memory"; case .temp: "CPU temperature"
        case .net: "Network speed"; case .disk: "Free disk"; case .battery: "Battery"
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var menuItems: Set<MenuItemKind> {
        didSet { d.set(menuItems.map(\.rawValue), forKey: "menuItems") }
    }
    @Published var interval: Double { didSet { d.set(interval, forKey: "interval") } }
    @Published var processSort: String { didSet { d.set(processSort, forKey: "processSort") } }
    @Published var fahrenheit: Bool { didSet { d.set(fahrenheit, forKey: "fahrenheit") } }

    private init() {
        let items = d.stringArray(forKey: "menuItems") ?? ["cpu", "mem", "net"]
        menuItems = Set(items.compactMap(MenuItemKind.init(rawValue:)))
        let i = d.double(forKey: "interval"); interval = i > 0 ? i : 2
        processSort = d.string(forKey: "processSort") ?? "cpu"
        fahrenheit = d.bool(forKey: "fahrenheit")
    }

    func temp(_ c: Double?) -> String {
        guard let c else { return "–" }
        return fahrenheit ? "\(Int((c * 9 / 5 + 32).rounded()))°F" : "\(Int(c.rounded()))°C"
    }
}

final class Monitor: ObservableObject {
    // CPU
    @Published var cpu: Double = 0
    @Published var cpuUser: Double = 0
    @Published var cpuSystem: Double = 0
    @Published var perCore: [Double] = []
    @Published var cpuHistory = Ring(24)
    @Published var load: [Double] = [0, 0, 0]
    // GPU
    @Published var gpu: Double = 0
    @Published var gpuMem: UInt64 = 0
    @Published var gpuHistory = Ring(40)
    // Memory
    @Published var mem = MemoryResult()
    @Published var memHistory = Ring(40)
    // Disk
    @Published var disk = DiskSampler.Result()
    // Network
    @Published var net = NetworkSampler.Result()
    @Published var downHistory = Ring(40)
    @Published var upHistory = Ring(40)
    @Published var connection: (kind: String, rssi: Int?) = ("…", nil)
    @Published var latencyMs: Double?
    @Published var latencyFailed = false
    // Sensors
    @Published var sensors = SensorSampler.Result()
    @Published var battery = BatteryResult()
    // Processes
    @Published var processes: [ProcGroup] = []
    @Published var idleApps: [ProcGroup] = []
    // Privacy
    @Published var micOn = false
    @Published var camOn = false
    @Published var uptime: TimeInterval = 0

    /// true while the popover is open – enables the more expensive samplers
    var detailed = false { didSet { if detailed && !oldValue { tick(full: true) } } }
    let fanCount: Int

    private let cpuS = CPUSampler(), diskS = DiskSampler(), netS = NetworkSampler()
    private let procS = ProcessSampler(), sensorS = SensorSampler(), latency = LatencyProbe()
    private let queue = DispatchQueue(label: "statbar.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tickCount = 0
    private var cancellables = Set<AnyCancellable>()

    init() {
        fanCount = sensorS.fanCount
        start()
        Settings.shared.$interval.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.start() }
        }.store(in: &cancellables)
    }

    func start() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Settings.shared.interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick(full: false) }
        t.resume()
        timer = t
    }

    func refreshNow() { queue.async { self.tick(full: true) } }

    private func tick(full: Bool) {
        if !full { tickCount += 1 }
        let items = Settings.shared.menuItems
        let detailed = self.detailed

        let c = cpuS.sample()
        let m = MemorySampler.sample()
        let n = netS.sample()
        let g = GPUSampler.sample()
        let needTemps = detailed || items.contains(.temp)
        let s = sensorS.sample(temps: needTemps)
        let dk = (detailed || items.contains(.disk) || tickCount % 5 == 0) ? diskS.sample() : nil
        let b = (detailed || items.contains(.battery) || tickCount % 5 == 0) ? BatterySampler.sample() : nil

        var procs: [ProcGroup]?, idle: [ProcGroup]?, conn: (String, Int?)?, mic: Bool?, cam: Bool?
        if detailed {
            let p = procS.sample()
            procs = p
            idle = ProcessSampler.idleApps(from: p)
            if full || tickCount % 3 == 0 { conn = NetworkSampler.connection() }
            mic = PrivacySampler.micInUse()
            cam = PrivacySampler.cameraInUse()
            if full || tickCount % 5 == 0 { latency.probe() }
        }
        let lat = latency.lastMs, latFail = latency.failed
        let up = Date().timeIntervalSince(SystemInfo.bootTime)

        DispatchQueue.main.async {
            self.cpu = c.total; self.cpuUser = c.user; self.cpuSystem = c.system; self.perCore = c.perCore
            self.cpuHistory.push(c.total)
            self.load = CPUSampler.loadAverage()
            self.mem = m
            self.memHistory.push(Double(m.used) / Double(SystemInfo.memTotal) * 100)
            self.net = n; self.downHistory.push(n.down); self.upHistory.push(n.up)
            self.gpu = g.utilization; self.gpuMem = g.memoryUsed; self.gpuHistory.push(g.utilization)
            if needTemps { self.sensors = s } else { self.sensors.fans = s.fans }
            if let dk { self.disk = dk }
            if let b { self.battery = b }
            if let procs { self.processes = procs }
            if let idle { self.idleApps = idle }
            if let conn { self.connection = conn }
            if let mic { self.micOn = mic }
            if let cam { self.camOn = cam }
            self.latencyMs = lat; self.latencyFailed = latFail
            self.uptime = up
            NotificationCenter.default.post(name: .statbarTick, object: nil)
        }
    }

    // MARK: derived

    var memPercent: Double { Double(mem.used) / Double(SystemInfo.memTotal) * 100 }

    var health: (score: Int, label: String, symbol: String, issues: [String]) {
        var s = 100.0; var issues: [String] = []
        if cpu > 85 { s -= 15; issues.append("High CPU load") } else if cpu > 60 { s -= 6 }
        switch mem.pressureLevel {
        case 4: s -= 25; issues.append("Critical memory pressure")
        case 2: s -= 12; issues.append("Memory pressure")
        default: if memPercent > 85 { s -= 4 }
        }
        if mem.swapUsed > 4 << 30 { s -= 6; issues.append("Heavy swap usage") }
        if let t = sensors.cpuTemp { if t > 95 { s -= 20; issues.append("CPU very hot") } else if t > 80 { s -= 8; issues.append("CPU warm") } }
        if disk.total > 0 {
            let free = Double(disk.free) / Double(disk.total)
            if free < 0.05 { s -= 20; issues.append("Disk almost full") } else if free < 0.15 { s -= 7; issues.append("Low disk space") }
        }
        if battery.present && battery.health > 0 && battery.health < 80 { s -= 8; issues.append("Battery service recommended") }
        let score = max(0, min(100, Int(s.rounded())))
        let label = score >= 80 ? "Good" : score >= 60 ? "Fair" : "Poor"
        let sym = score >= 80 ? "sun.max.fill" : score >= 60 ? "cloud.sun.fill" : "cloud.bolt.rain.fill"
        return (score, label, sym, issues)
    }
}

extension Notification.Name { static let statbarTick = Notification.Name("statbarTick") }

// MARK: - Formatting

enum Fmt {
    static func bytes(_ b: Double, decimals: Int = 1) -> (String, String) {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = b, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1024; i += 1 }
        let d = i <= 1 ? 0 : (v >= 100 ? 0 : decimals)
        return (String(format: "%.\(d)f", v), units[i])
    }
    static func bytesStr(_ b: Double, decimals: Int = 1) -> String { let (v, u) = bytes(b, decimals: decimals); return "\(v) \(u)" }
    static func rate(_ b: Double) -> String { bytesStr(b) + "/s" }
    static func shortRate(_ b: Double) -> String {
        let (v, u) = bytes(b, decimals: 1); return "\(v)\(u == "B" ? "B" : String(u.prefix(1)))"
    }
    static func uptime(_ t: TimeInterval) -> String {
        let d = Int(t) / 86400, h = Int(t) % 86400 / 3600, m = Int(t) % 3600 / 60
        if d > 0 { return "up \(d) day\(d == 1 ? "" : "s"), \(h) hr\(h == 1 ? "" : "s")" }
        if h > 0 { return "up \(h) hr\(h == 1 ? "" : "s"), \(m) min" }
        return "up \(m) min"
    }
    static func minutes(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }
}

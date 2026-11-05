import Foundation
import IOKit
import IOKit.ps
import Darwin
import SystemConfiguration
import CoreWLAN
import CoreAudio
import CoreMediaIO
import Network
import AppKit

// MARK: - Static system info

enum SystemInfo {
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
    static func sysctlInt(_ name: String) -> Int? {
        var v: Int64 = 0; var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else {
            var v32: Int32 = 0; var s32 = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &v32, &s32, nil, 0) == 0 else { return nil }
            return Int(v32)
        }
        return size == 4 ? Int(Int32(truncatingIfNeeded: v)) : Int(v)
    }

    static let chip: String = {
        let s = sysctlString("machdep.cpu.brand_string") ?? "Mac"
        return s.replacingOccurrences(of: "Apple ", with: "")
    }()
    static let memTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }()
    static let pCores = sysctlInt("hw.perflevel0.logicalcpu")
    static let eCores = sysctlInt("hw.perflevel1.logicalcpu")
    static let model: String = sysctlString("hw.model") ?? ""

    static var bootTime: Date = {
        var tv = timeval(); var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        sysctl(&mib, 2, &tv, &size, nil, 0)
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }()
}

// MARK: - CPU

final class CPUSampler {
    private var prev: [(user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)] = []

    struct Result { var total: Double; var user: Double; var system: Double; var perCore: [Double] }

    func sample() -> Result {
        var numCPUs: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &info, &count) == KERN_SUCCESS,
              let info else { return Result(total: 0, user: 0, system: 0, perCore: []) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(count) * MemoryLayout<integer_t>.stride)) }

        var cur: [(UInt64, UInt64, UInt64, UInt64)] = []
        for i in 0..<Int(numCPUs) {
            let base = Int(CPU_STATE_MAX) * i
            cur.append((UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])),
                        UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])),
                        UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])),
                        UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))))
        }
        defer { prev = cur.map { (user: $0.0, sys: $0.1, idle: $0.2, nice: $0.3) } }
        guard prev.count == cur.count else { return Result(total: 0, user: 0, system: 0, perCore: Array(repeating: 0, count: cur.count)) }

        var perCore: [Double] = []
        var tu: UInt64 = 0, ts: UInt64 = 0, tt: UInt64 = 0
        for (i, c) in cur.enumerated() {
            let p = prev[i]
            let du = (c.0 &- p.user) + (c.3 &- p.nice), ds = c.1 &- p.sys, di = c.2 &- p.idle
            let total = du + ds + di
            perCore.append(total > 0 ? Double(du + ds) / Double(total) * 100 : 0)
            tu += du; ts += ds; tt += total
        }
        guard tt > 0 else { return Result(total: 0, user: 0, system: 0, perCore: perCore) }
        let u = Double(tu) / Double(tt) * 100, s = Double(ts) / Double(tt) * 100
        return Result(total: u + s, user: u, system: s, perCore: perCore)
    }

    static func loadAverage() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        return l
    }
}

// MARK: - Memory

struct MemoryResult {
    var used: UInt64 = 0, app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0, cached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var pressureLevel: Int = 1 // 1 normal, 2 warn, 4 critical
}

enum MemorySampler {
    static func sample() -> MemoryResult {
        var r = MemoryResult()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let intl = UInt64(stats.internal_page_count), purgeable = UInt64(stats.purgeable_count)
            r.app = (intl > purgeable ? intl - purgeable : 0) * page
            r.wired = UInt64(stats.wire_count) * page
            r.compressed = UInt64(stats.compressor_page_count) * page
            r.cached = (UInt64(stats.external_page_count) + purgeable) * page
            r.used = r.app + r.wired + r.compressed
        }
        var swap = xsw_usage(); var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { r.swapUsed = swap.xsu_used }
        r.pressureLevel = SystemInfo.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        return r
    }
}

// MARK: - GPU

enum GPUSampler {
    struct Result { var utilization: Double = 0; var memoryUsed: UInt64 = 0 }
    static func sample() -> Result {
        var r = Result()
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return r }
        defer { IOObjectRelease(iter) }
        var entry = IOIteratorNext(iter)
        while entry != 0 {
            if let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                if let u = stats["Device Utilization %"] as? Int { r.utilization = max(r.utilization, Double(u)) }
                if let m = stats["In use system memory"] as? Int { r.memoryUsed += UInt64(m) }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
        return r
    }
}

// MARK: - Disk

final class DiskSampler {
    private var prevRead: UInt64 = 0, prevWrite: UInt64 = 0, prevTime: Date?
    struct Result { var free: Int64 = 0; var total: Int64 = 0; var readRate: Double = 0; var writeRate: Double = 0 }

    func sample() -> Result {
        var r = Result()
        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            r.free = v.volumeAvailableCapacityForImportantUsage ?? 0
            r.total = Int64(v.volumeTotalCapacity ?? 0)
        }
        var read: UInt64 = 0, write: UInt64 = 0
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS {
            var e = IOIteratorNext(iter)
            while e != 0 {
                if let s = IORegistryEntryCreateCFProperty(e, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] {
                    read += (s["Bytes (Read)"] as? UInt64) ?? 0
                    write += (s["Bytes (Write)"] as? UInt64) ?? 0
                }
                IOObjectRelease(e); e = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)
        }
        let now = Date()
        if let pt = prevTime {
            let dt = now.timeIntervalSince(pt)
            if dt > 0 {
                r.readRate = read >= prevRead ? Double(read - prevRead) / dt : 0
                r.writeRate = write >= prevWrite ? Double(write - prevWrite) / dt : 0
            }
        }
        prevRead = read; prevWrite = write; prevTime = now
        return r
    }
}

// MARK: - Network

final class NetworkSampler {
    private var prevIn: UInt64 = 0, prevOut: UInt64 = 0, prevTime: Date?
    struct Result { var down: Double = 0; var up: Double = 0; var totalIn: UInt64 = 0; var totalOut: UInt64 = 0 }

    func sample() -> Result {
        var r = Result()
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return r }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return r }
        var inB: UInt64 = 0, outB: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.load(fromByteOffset: off, as: if_msghdr.self)
                if hdr.ifm_type == RTM_IFINFO2 {
                    let m2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(m2.ifm_index), &name) != nil {
                        let n = String(cString: name)
                        if n.hasPrefix("en") {
                            inB += m2.ifm_data.ifi_ibytes; outB += m2.ifm_data.ifi_obytes
                        }
                    }
                }
                if hdr.ifm_msglen == 0 { break }
                off += Int(hdr.ifm_msglen)
            }
        }
        r.totalIn = inB; r.totalOut = outB
        let now = Date()
        if let pt = prevTime {
            let dt = now.timeIntervalSince(pt)
            if dt > 0 {
                r.down = inB >= prevIn ? Double(inB - prevIn) / dt : 0
                r.up = outB >= prevOut ? Double(outB - prevOut) / dt : 0
            }
        }
        prevIn = inB; prevOut = outB; prevTime = now
        return r
    }

    /// "Wi-Fi" / "Ethernet" / "Offline" plus Wi-Fi RSSI when available.
    static func connection() -> (kind: String, rssi: Int?) {
        guard let store = SCDynamicStoreCreate(nil, "StatBar" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = dict["PrimaryInterface"] as? String else { return ("Offline", nil) }
        if let wifi = CWWiFiClient.shared().interface(), wifi.interfaceName == primary {
            let rssi = wifi.rssiValue()
            return ("Wi-Fi", rssi == 0 ? nil : rssi)
        }
        if primary.hasPrefix("utun") || primary.hasPrefix("ipsec") { return ("VPN", nil) }
        return ("Ethernet", nil)
    }
}

/// Measures TCP connect latency to a public endpoint.
final class LatencyProbe {
    private(set) var lastMs: Double?
    private(set) var failed = false
    private var running = false
    private let queue = DispatchQueue(label: "statbar.latency")

    func probe() {
        guard !running else { return }
        running = true
        let start = DispatchTime.now()
        let conn = NWConnection(host: "1.1.1.1", port: 443, using: .tcp)
        var finished = false
        let finish: (Double?) -> Void = { [weak self] ms in
            guard !finished else { return }
            finished = true
            conn.cancel()
            self?.lastMs = ms
            self?.failed = ms == nil
            self?.running = false
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
            case .failed, .waiting: finish(nil)
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3) { finish(nil) }
    }
}

// MARK: - Battery

struct BatteryResult {
    var present = false
    var percent = 0, cycles = 0, health = 0
    var charging = false, external = false, fullyCharged = false
    var adapterWatts = 0, timeRemaining: Int? = nil // minutes
    var temperature: Double = 0, powerW: Double = 0
}

enum BatterySampler {
    static func sample() -> BatteryResult {
        var r = BatteryResult()
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return r }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return r }
        guard (d["BatteryInstalled"] as? Bool) ?? true else { return r }
        r.present = true
        let cur = d["CurrentCapacity"] as? Int ?? 0, maxC = d["MaxCapacity"] as? Int ?? 100
        r.percent = maxC > 0 ? Int((Double(cur) / Double(maxC) * 100).rounded()) : cur
        r.cycles = d["CycleCount"] as? Int ?? 0
        let design = d["DesignCapacity"] as? Int ?? 0
        let nominal = (d["NominalChargeCapacity"] as? Int) ?? (d["AppleRawMaxCapacity"] as? Int) ?? 0
        if design > 0 { r.health = min(100, Int((Double(nominal) / Double(design) * 100).rounded())) }
        r.charging = d["IsCharging"] as? Bool ?? false
        r.external = d["ExternalConnected"] as? Bool ?? false
        r.fullyCharged = d["FullyCharged"] as? Bool ?? false
        if let a = d["AdapterDetails"] as? [String: Any] { r.adapterWatts = a["Watts"] as? Int ?? 0 }
        if let t = d["TimeRemaining"] as? Int, t > 0, t < 65535 { r.timeRemaining = t }
        r.temperature = Double(d["Temperature"] as? Int ?? 0) / 100
        let v = Double(d["Voltage"] as? Int ?? 0), a = Double(d["InstantAmperage"] as? Int ?? d["Amperage"] as? Int ?? 0)
        r.powerW = abs(v * a) / 1_000_000
        return r
    }
}

// MARK: - SMC sensors

final class SensorSampler {
    private var cpuKeys: [String] = [], gpuKeys: [String] = []
    let fanCount: Int
    let available: Bool

    struct Result { var cpuTemp: Double?; var gpuTemp: Double?; var systemPower: Double?; var fans: [Fan] = [] }
    struct Fan { var rpm: Double; var min: Double; var max: Double; var manual: Bool }

    init() {
        available = smc_open() == 0
        var fans = 0.0
        if available { _ = smc_read_double("FNum", &fans) }
        fanCount = Int(fans)
        guard available else { return }
        let n = smc_key_count()
        var buf = [CChar](repeating: 0, count: 5)
        var cpu: [String] = [], gpu: [String] = [], intelCPU: [String] = [], intelGPU: [String] = []
        for i in 0..<n {
            guard smc_key_at(Int32(i), &buf) == 0 else { continue }
            let k = String(cString: buf)
            if k.hasPrefix("Tp") || k.hasPrefix("Te") { cpu.append(k) }
            else if k.hasPrefix("Tg") { gpu.append(k) }
            else if k.hasPrefix("TC") && k.count == 4 { intelCPU.append(k) }
            else if k.hasPrefix("TG") && k.count == 4 { intelGPU.append(k) }
        }
        cpuKeys = cpu.isEmpty ? intelCPU : cpu
        gpuKeys = gpu.isEmpty ? intelGPU : gpu
    }

    private func avg(_ keys: [String]) -> Double? {
        var sum = 0.0, n = 0.0, v = 0.0
        for k in keys where smc_read_double(k, &v) == 0 && v > 5 && v < 130 { sum += v; n += 1 }
        return n > 0 ? sum / n : nil
    }

    func sample(temps: Bool) -> Result {
        var r = Result()
        guard available else { return r }
        if temps {
            r.cpuTemp = avg(cpuKeys)
            r.gpuTemp = avg(gpuKeys)
            var p = 0.0
            if smc_read_double("PSTR", &p) == 0, p > 0 { r.systemPower = p }
        }
        for i in 0..<fanCount {
            var ac = 0.0, mn = 0.0, mx = 0.0, md = 0.0
            _ = smc_read_double("F\(i)Ac", &ac); _ = smc_read_double("F\(i)Mn", &mn)
            _ = smc_read_double("F\(i)Mx", &mx); _ = smc_read_double("F\(i)Md", &md)
            r.fans.append(Fan(rpm: ac, min: mn, max: mx, manual: md == 1))
        }
        return r
    }
}

// MARK: - Camera / Microphone

enum PrivacySampler {
    static func micInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return false }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return false }
        for id in ids {
            var sAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                   mScope: kAudioObjectPropertyScopeInput,
                                                   mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 else { continue }
            // skip devices that also have output (e.g. headsets) – running state there is ambiguous
            var oAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                   mScope: kAudioObjectPropertyScopeOutput,
                                                   mElement: kAudioObjectPropertyElementMain)
            var oSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &oAddr, 0, nil, &oSize)
            var running: UInt32 = 0; var rSize = UInt32(MemoryLayout<UInt32>.size)
            var rAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(id, &rAddr, 0, nil, &rSize, &running) == noErr, running != 0, oSize == 0 { return true }
        }
        return false
    }

    static func cameraInUse() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == noErr else { return false }
        for id in ids {
            var rAddr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var running: UInt32 = 0; var u: UInt32 = 0
            if CMIOObjectGetPropertyData(id, &rAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &u, &running) == noErr, running != 0 { return true }
        }
        return false
    }
}

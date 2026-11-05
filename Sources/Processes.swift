import Foundation
import AppKit
import Darwin

struct ProcGroup: Identifiable {
    var id: String { key }
    let key: String          // bundle path or executable path
    var name: String
    var pids: [pid_t]
    var memory: UInt64
    var cpu: Double
    var isApp: Bool
    var ownedByUser: Bool
}

final class ProcessSampler {
    private let myUID = getuid()

    func sample() -> [ProcGroup] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,uid=,rss=,%cpu=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }

        let appNames: [String: String] = {
            var m: [String: String] = [:]
            for app in NSWorkspace.shared.runningApplications {
                if let p = app.bundleURL?.path, let n = app.localizedName { m[p] = n }
            }
            return m
        }()

        var groups: [String: ProcGroup] = [:]
        let selfPID = getpid()
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5, let pid = pid_t(parts[0]), let uid = UInt32(parts[1]),
                  let rss = UInt64(parts[2]), let cpu = Double(parts[3].replacingOccurrences(of: ",", with: ".")) else { continue }
            if pid == 0 || pid == selfPID { continue }
            let path = String(parts[4])

            var memory = rss * 1024
            if uid == myUID {
                var ri = rusage_info_v4()
                let ok = withUnsafeMutablePointer(to: &ri) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
                }
                if ok == 0 { memory = ri.ri_phys_footprint }
            }

            let (key, name, isApp) = Self.groupKey(path: path, appNames: appNames)
            if var g = groups[key] {
                g.pids.append(pid); g.memory += memory; g.cpu += cpu
                g.ownedByUser = g.ownedByUser && uid == myUID
                groups[key] = g
            } else {
                groups[key] = ProcGroup(key: key, name: name, pids: [pid], memory: memory, cpu: cpu,
                                        isApp: isApp, ownedByUser: uid == myUID)
            }
        }
        return Array(groups.values)
    }

    private static func groupKey(path: String, appNames: [String: String]) -> (String, String, Bool) {
        if let r = path.range(of: ".app/") {
            let bundle = String(path[..<r.lowerBound]) + ".app"
            let name = appNames[bundle] ?? (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            return (bundle, name, true)
        }
        var name = (path as NSString).lastPathComponent
        if name.hasPrefix("com.apple.") {   // e.g. com.apple.WebKit.WebContent -> WebKit WebContent
            name = String(name.dropFirst("com.apple.".count)).replacingOccurrences(of: ".", with: " ")
        }
        return (path, name, false)
    }

    // MARK: actions

    static func quit(_ g: ProcGroup, force: Bool) {
        if g.isApp, let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == g.key }) {
            _ = force ? app.forceTerminate() : app.terminate()
            return
        }
        for pid in g.pids { kill(pid, force ? SIGKILL : SIGTERM) }
    }

    static func reveal(_ g: ProcGroup) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: g.key)])
    }

    /// Regular GUI apps that are in the background, not using CPU, with no on-screen windows.
    static func idleApps(from groups: [ProcGroup]) -> [ProcGroup] {
        let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
        var onScreenPIDs = Set<pid_t>()
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
                if let p = w[kCGWindowOwnerPID as String] as? Int32 { onScreenPIDs.insert(p) }
            }
        }
        let regular = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { $0.bundleURL?.path })
        let me = Bundle.main.bundleURL.path
        return groups.filter { g in
            g.isApp && g.ownedByUser && regular.contains(g.key) && g.key != front && g.key != me &&
            !g.key.hasPrefix("/System/Library/CoreServices/Finder.app") &&
            g.cpu < 0.5 && g.memory > 300 * 1024 * 1024 &&
            g.pids.allSatisfy { !onScreenPIDs.contains($0) }
        }
    }
}

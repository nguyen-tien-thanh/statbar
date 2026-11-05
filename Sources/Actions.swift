import Foundation
import AppKit
import IOKit.pwr_mgt
import ServiceManagement

// MARK: - Keep awake

final class PowerAssertions: ObservableObject {
    @Published private(set) var awake = false
    @Published private(set) var screen = false
    private var sysID: IOPMAssertionID = 0
    private var dispID: IOPMAssertionID = 0

    func setAwake(_ on: Bool) {
        if on == awake { return }
        if on {
            awake = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "StatBar keep awake" as CFString, &sysID) == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(sysID); awake = false
        }
    }

    func setScreen(_ on: Bool) {
        if on == screen { return }
        if on {
            screen = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "StatBar keep screen on" as CFString, &dispID) == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(dispID); screen = false
        }
    }
}

// MARK: - Admin shell (password prompt via macOS)

enum Admin {
    /// Runs a shell command with administrator privileges (system password dialog). Completion on main.
    static func run(_ command: String, completion: ((Bool) -> Void)? = nil) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var ok = false
            if (try? p.run()) != nil { p.waitUntilExit(); ok = p.terminationStatus == 0 }
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

// MARK: - Fan control

enum FanMode: String, CaseIterable { case auto, cool, max
    var title: String { rawValue.capitalized }
}

final class FanController: ObservableObject {
    @Published private(set) var mode: FanMode = .auto
    @Published private(set) var busy = false

    private let modeFile: URL = FileManager.default.temporaryDirectory.appendingPathComponent("statbar-fan-mode")
    private var helperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/statbar-fan").path }

    private var helperRunning: Bool {
        guard let s = try? String(contentsOf: URL(fileURLWithPath: modeFile.path + ".pid"), encoding: .utf8),
              let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    func set(_ m: FanMode) {
        guard m != mode, !busy else { return }
        try? m.rawValue.write(to: modeFile, atomically: true, encoding: .utf8)
        if m == .auto || helperRunning { mode = m; return }   // helper picks up the file change
        busy = true
        let cmd = "\(Admin.shellQuote(helperPath)) \(getpid()) \(Admin.shellQuote(modeFile.path)) > /dev/null 2>&1 &"
        Admin.run(cmd) { [weak self] ok in
            guard let self else { return }
            self.busy = false
            if ok { self.mode = m } else { try? FanMode.auto.rawValue.write(to: self.modeFile, atomically: true, encoding: .utf8) }
        }
    }

    /// Called on quit: helper notices our pid is gone and restores auto; also write auto for a faster reset.
    func reset() { try? FanMode.auto.rawValue.write(to: modeFile, atomically: true, encoding: .utf8) }
}

// MARK: - Login item

enum LoginItem {
    static var enabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }
    static func set(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
            catch { NSLog("StatBar login item: \(error)") }
        }
    }
}

// MARK: - Misc tools

enum Tools {
    static func purgeMemory(done: @escaping (Bool) -> Void) { Admin.run("/usr/sbin/purge", completion: done) }
    static func flushDNS(done: @escaping (Bool) -> Void) {
        Admin.run("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder", completion: done)
    }
    static func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
    static func openStorageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") { NSWorkspace.shared.open(url) }
    }
    static func openBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    static func openNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") { NSWorkspace.shared.open(url) }
    }
}

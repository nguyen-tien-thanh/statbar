import Foundation
import LocalAuthentication

/// Runs the root helper. When the one-time setup is done, actions are gated by Touch ID
/// (LocalAuthentication, falling back to the account password) and executed via `sudo -n`
/// thanks to a sudoers rule that allows exactly one root-owned binary.
/// Without setup, falls back to the standard macOS admin password dialog.
final class Privileged: ObservableObject {
    static let shared = Privileged()

    static let installedPath = "/Library/PrivilegedHelperTools/local.statbar.helper"
    static let sudoersPath = "/etc/sudoers.d/statbar"
    static var bundledPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/statbar-helper").path }

    enum Status { case notInstalled, outdated, ready }
    @Published private(set) var status: Status = .notInstalled
    @Published private(set) var busy = false

    private var lastAuth: Date?
    private let reuseWindow: TimeInterval = 300

    private init() { refresh() }

    func refresh() {
        let fm = FileManager.default
        let s: Status
        if !fm.fileExists(atPath: Self.installedPath) || !fm.fileExists(atPath: Self.sudoersPath) { s = .notInstalled }
        else if !fm.contentsEqual(atPath: Self.installedPath, andPath: Self.bundledPath) { s = .outdated }
        else { s = .ready }
        DispatchQueue.main.async { self.status = s }
    }

    var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return ctx.biometryType == .touchID ? "Touch ID" : "password"
    }

    // MARK: setup

    /// One-time setup (asks for the admin password once).
    func install(completion: ((Bool) -> Void)? = nil) {
        let q = Admin.shellQuote
        let uid = getuid()
        let script = """
        set -e; \
        mkdir -p /Library/PrivilegedHelperTools; \
        cp \(q(Self.bundledPath)) \(q(Self.installedPath)); \
        chown root:wheel \(q(Self.installedPath)); chmod 755 \(q(Self.installedPath)); \
        T=$(mktemp /tmp/statbar.sudoers.XXXXXX); \
        echo '#\(uid) ALL=(root) NOPASSWD: \(Self.installedPath)' > $T; \
        /usr/sbin/visudo -cf $T > /dev/null; \
        install -m 440 -o root -g wheel $T \(q(Self.sudoersPath)); rm -f $T
        """
        busy = true
        Admin.run(script) { ok in
            self.busy = false
            self.refresh()
            completion?(ok)
        }
    }

    func uninstall(completion: ((Bool) -> Void)? = nil) {
        let q = Admin.shellQuote
        busy = true
        Admin.run("rm -f \(q(Self.sudoersPath)) \(q(Self.installedPath))") { ok in
            self.busy = false
            self.refresh()
            completion?(ok)
        }
    }

    // MARK: running

    /// Runs `statbar-helper <args>` as root. `reason` completes "StatBar wants to …".
    func run(_ args: [String], reason: String, completion: @escaping (Bool) -> Void) {
        refresh()
        guard status == .ready else {
            // First privileged action (or after an app update): one-time setup with the admin password,
            // then run the command right away without asking again.
            install { ok in
                guard ok else { completion(false); return }
                self.lastAuth = Date()
                self.sudo(args, completion: completion)
            }
            return
        }
        authenticate(reason: reason) { ok in
            guard ok else { completion(false); return }
            self.sudo(args, completion: completion)
        }
    }

    private func sudo(_ args: [String], completion: @escaping (Bool) -> Void) {
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                p.arguments = ["-n", Self.installedPath] + args
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                var success = false
                if (try? p.run()) != nil { p.waitUntilExit(); success = p.terminationStatus == 0 }
                DispatchQueue.main.async { completion(success) }
            }
    }

    private func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        if let l = lastAuth, Date().timeIntervalSince(l) < reuseWindow { completion(true); return }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { completion(false); return }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async {
                if ok { self.lastAuth = Date() }
                completion(ok)
            }
        }
    }
}

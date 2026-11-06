import AppKit
import CryptoKit
import Foundation

/// Replaces the running StatBar.app with the one inside a downloaded release DMG.
/// Every step is checked; on any failure the current app is left untouched.
enum UpdateInstaller {
    typealias Failure = Updater.UpdateError

    /// The bundle must live in a normal, writable folder (not the DMG, not App Translocation).
    static func canReplace(_ app: URL) -> Bool {
        let path = app.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") { return false }
        let parent = app.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parent) && FileManager.default.isWritableFile(atPath: path)
    }

    /// Verify the DMG and stage its app next to the current one (same volume). Runs off the main thread.
    /// Returns the staged app; nothing is replaced yet – see `swap(staged:)`.
    static func prepare(dmg: URL, expectedVersion: String, digest: String?) throws -> URL {
        let fm = FileManager.default
        let target = Bundle.main.bundleURL

        // 1. Integrity: GitHub publishes a SHA-256 for every release asset.
        if let digest, digest.hasPrefix("sha256:") {
            let data = try Data(contentsOf: dmg, options: .mappedIfSafe)
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hex == digest.dropFirst("sha256:".count).lowercased() else { throw Failure(message: "Download is corrupted (checksum mismatch)") }
        }

        // 2. Mount read-only, out of sight.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        var keepWork = false
        defer { if !keepWork { try? fm.removeItem(at: work) } }
        let mnt = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mnt, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noverify", "-noautoopen", "-readonly", "-mountpoint", mnt.path]) == 0 else {
            throw Failure(message: "Couldn't open the downloaded disk image")
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mnt.path, "-force"]) }

        // 3. It has to be StatBar, the version we expect, and an intact code signature.
        guard let newApp = (try? fm.contentsOfDirectory(at: mnt, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")) else {
            throw Failure(message: "No app found in the update")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { throw Failure(message: "Update is not StatBar") }
        guard let v = info["CFBundleShortVersionString"] as? String, v == expectedVersion else {
            throw Failure(message: "Unexpected version in the update")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path]) == 0 else {
            throw Failure(message: "Update's code signature is invalid")
        }

        // 4. Copy next to the current app (same volume) so the later swap is atomic.
        let staged = work.appendingPathComponent(target.lastPathComponent)
        guard run("/usr/bin/ditto", [newApp.path, staged.path]) == 0 else { throw Failure(message: "Couldn't copy the update") }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        keepWork = true
        return staged
    }

    /// Atomically replace the running app's bundle with a staged copy from `prepare`.
    static func swap(staged: URL) throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: staged.deletingLastPathComponent()) }
        guard fm.fileExists(atPath: staged.path) else { throw Failure(message: "The downloaded update was removed – try again") }
        do {
            _ = try fm.replaceItemAt(Bundle.main.bundleURL, withItemAt: staged, backupItemName: nil, options: [])
        } catch {
            throw Failure(message: "Couldn't replace the app: \(error.localizedDescription)")
        }
    }

    /// Quit, and reopen the (now updated) bundle once this process is gone.
    @MainActor static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                       "sh", String(getpid()), Bundle.main.bundleURL.path]
        do { try p.run() } catch {
            Updater.shared.openDownload()
            return
        }
        NSApp.terminate(nil)
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

import AppKit
import Foundation

/// Checks GitHub Releases for a newer StatBar. Runs on launch and from an hourly timer;
/// the network request itself is made at most every `minInterval` unless the user asks.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repo = "nguyen-tien-thanh/statbar"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases")!

    enum State: Equatable { case idle, checking, upToDate, available, failed(String) }

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    @Published private(set) var state: State = .idle
    @Published private(set) var latest: String?
    @Published private(set) var releaseURL: URL?
    @Published private(set) var downloadURL: URL?
    private var downloadDigest: String?     // "sha256:…" from the GitHub asset, when provided

    /// Progress of an in-app update: download → verify/stage → ready (ask to restart) → swap + relaunch.
    enum InstallState: Equatable { case none, downloading(Double), installing, ready, failed(String) }
    @Published private(set) var install: InstallState = .none
    var installing: Bool { if case .downloading = install { return true }; return install == .installing }
    /// Verified copy of the new app waiting next to the current one; swapped in on restart or quit.
    private var staged: URL?
    private var progressObservation: NSKeyValueObservation?
    @Published var autoCheck: Bool = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoUpdateCheck"); if autoCheck { check() } }
    }

    // < the 1 h timer period (which has 10 min tolerance), so every hourly tick really checks
    private let minInterval: TimeInterval = 55 * 60
    private var timer: Timer?
    private var lastChecked: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }

    var updateAvailable: Bool { state == .available }

    var statusText: String {
        switch state {
        case .idle: return lastChecked.map { "Checked \(Self.relative($0))" } ?? "Not checked yet"
        case .checking: return "Checking GitHub…"
        case .upToDate: return "Up to date"
        case .available: return "Version \(latest ?? "") is available"
        case .failed(let msg): return "Couldn't check: \(msg)"
        }
    }

    private static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    func start() {
        // Restore the last known result so the badge survives relaunches without a request.
        if let v = UserDefaults.standard.string(forKey: "latestVersion"), Self.isNewer(v, than: current) {
            latest = v
            releaseURL = UserDefaults.standard.url(forKey: "latestReleaseURL")
            downloadURL = UserDefaults.standard.url(forKey: "latestDownloadURL")
            downloadDigest = UserDefaults.standard.string(forKey: "latestDownloadDigest")
            state = .available
        }
        check(manual: Self.debugInstall)
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in Updater.shared.check() }
        }
        timer?.tolerance = 600
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Updater.shared.check() }
        }
    }

    /// `manual` bypasses the auto-check setting and the rate limit.
    func check(manual: Bool = false) {
        guard state != .checking, !installing, install != .ready else { return }
        if !manual {
            guard autoCheck else { return }
            if let t = lastChecked, Date().timeIntervalSince(t) < minInterval { return }
        }
        state = .checking
        Task {
            do {
                lastChecked = Date()
                guard let r = try await Self.fetchLatest() else { state = .upToDate; return }   // no releases yet
                latest = r.version; releaseURL = r.page; downloadURL = r.dmg; downloadDigest = r.digest
                let d = UserDefaults.standard
                d.set(r.version, forKey: "latestVersion"); d.set(r.page, forKey: "latestReleaseURL"); d.set(r.dmg, forKey: "latestDownloadURL")
                d.set(r.digest, forKey: "latestDownloadDigest")
                state = Self.isNewer(r.version, than: current) ? .available : .upToDate
                // Debug: `StatBar --install-update` installs right away (used to test the update flow end to end)
                if state == .available && Self.debugInstall { installUpdate() }
            } catch {
                state = .failed((error as? UpdateError)?.message ?? "Offline")
            }
        }
    }

    /// Opens the DMG download (or the release page) in the browser.
    func openDownload() {
        NSWorkspace.shared.open(downloadURL ?? releaseURL ?? Self.releasesPage)
    }

    func openReleasePage() { NSWorkspace.shared.open(releaseURL ?? Self.releasesPage) }

    /// Can this copy replace itself? Not when run from the DMG, App Translocation or a folder we can't write.
    var canSelfUpdate: Bool { UpdateInstaller.canReplace(Bundle.main.bundleURL) }

    /// One click: download the DMG and verify it in the background, then ask to restart.
    /// Falls back to opening the download in the browser when the app can't replace itself.
    func installUpdate() {
        guard !installing else { return }
        if install == .ready { restartToUpdate(); return }
        guard updateAvailable, let url = downloadURL, let version = latest, canSelfUpdate else { openDownload(); return }
        install = .downloading(0)
        let digest = downloadDigest
        let task = URLSession.shared.downloadTask(with: url) { tmp, resp, err in
            // `tmp` is deleted when this handler returns, so move it first.
            var dmg: URL?
            if let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("StatBar-\(version)-\(UUID().uuidString).dmg")
                if (try? FileManager.default.moveItem(at: tmp, to: dest)) != nil { dmg = dest }
            }
            let failure = err?.localizedDescription ?? "Download failed"
            Task { @MainActor in
                let u = Updater.shared
                u.progressObservation = nil
                guard let dmg else { u.install = .failed(failure); return }
                u.install = .installing
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try UpdateInstaller.prepare(dmg: dmg, expectedVersion: version, digest: digest) }
                    try? FileManager.default.removeItem(at: dmg)
                    Task { @MainActor in
                        let u = Updater.shared
                        switch result {
                        case .success(let app): u.staged = app; u.install = .ready; u.askToRestart(version)
                        case .failure(let e): u.install = .failed((e as? UpdateError)?.message ?? e.localizedDescription)
                        }
                    }
                }
            }
        }
        progressObservation = task.progress.observe(\.fractionCompleted) { p, _ in
            let f = p.fractionCompleted
            Task { @MainActor in
                if case .downloading = Updater.shared.install { Updater.shared.install = .downloading(f) }
            }
        }
        task.resume()
    }

    /// Debug: `--install-update` installs right away; `--install-update-later` also answers "Later" and quits.
    private static var debugInstall: Bool { CommandLine.arguments.contains { $0.hasPrefix("--install-update") } }

    private func askToRestart(_ version: String) {
        if CommandLine.arguments.contains("--install-update-later") { NSApp.terminate(nil); return }
        let a = NSAlert()
        a.messageText = "StatBar \(version) is ready"
        a.informativeText = "Restart StatBar now to finish updating? If you choose Later, the update is installed the next time StatBar quits."
        a.icon = NSApp.applicationIconImage
        a.addButton(withTitle: "Restart Now")
        a.addButton(withTitle: "Later")
        NotificationCenter.default.post(name: .statbarClosePopover, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { restartToUpdate() }
    }

    /// Swap the staged app in, quit and reopen.
    func restartToUpdate() {
        guard install == .ready else { return }
        do { try swapStaged() } catch {
            install = .failed((error as? UpdateError)?.message ?? error.localizedDescription); return
        }
        UpdateInstaller.relaunch()
    }

    /// Called when the app quits: install a staged update chosen "Later" (no relaunch).
    func installPendingOnQuit() { try? swapStaged() }

    private func swapStaged() throws {
        guard let app = staged else { return }
        staged = nil
        try UpdateInstaller.swap(staged: app)
    }

    // MARK: - GitHub

    struct UpdateError: Error { let message: String }
    private struct Release: Decodable {
        let tag_name: String; let html_url: URL; let draft: Bool; let prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
    }

    private static func fetchLatest() async throws -> (version: String, page: URL, dmg: URL?, digest: String?)? {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("StatBar/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")",
                     forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 404: return nil
        case 403, 429: throw UpdateError(message: "GitHub rate limit")
        case let c: throw UpdateError(message: "GitHub error \(c)")
        }
        let r = try JSONDecoder().decode(Release.self, from: data)
        let asset = r.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        return (normalize(r.tag_name), r.html_url, asset?.browser_download_url, asset?.digest)
    }

    // MARK: - Versions

    static func normalize(_ tag: String) -> String {
        var s = tag.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("v") { s.removeFirst() }
        return s
    }

    /// Numeric dotted compare: "1.10.0" > "1.9.2". Pre-release suffixes ("-beta") are ignored.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            normalize(s).split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

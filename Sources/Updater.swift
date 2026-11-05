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
    @Published var autoCheck: Bool = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoUpdateCheck"); if autoCheck { check() } }
    }

    private let minInterval: TimeInterval = 6 * 3600
    private var timer: Timer?
    private var lastChecked: Date? {
        get { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "lastUpdateCheck") }
    }

    var updateAvailable: Bool { state == .available }

    func start() {
        // Restore the last known result so the badge survives relaunches without a request.
        if let v = UserDefaults.standard.string(forKey: "latestVersion"), Self.isNewer(v, than: current) {
            latest = v
            releaseURL = UserDefaults.standard.url(forKey: "latestReleaseURL")
            downloadURL = UserDefaults.standard.url(forKey: "latestDownloadURL")
            state = .available
        }
        check()
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
        guard state != .checking else { return }
        if !manual {
            guard autoCheck else { return }
            if let t = lastChecked, Date().timeIntervalSince(t) < minInterval { return }
        }
        state = .checking
        Task {
            do {
                lastChecked = Date()
                guard let r = try await Self.fetchLatest() else { state = .upToDate; return }   // no releases yet
                latest = r.version; releaseURL = r.page; downloadURL = r.dmg
                let d = UserDefaults.standard
                d.set(r.version, forKey: "latestVersion"); d.set(r.page, forKey: "latestReleaseURL"); d.set(r.dmg, forKey: "latestDownloadURL")
                state = Self.isNewer(r.version, than: current) ? .available : .upToDate
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

    // MARK: - GitHub

    struct UpdateError: Error { let message: String }
    private struct Release: Decodable {
        let tag_name: String; let html_url: URL; let draft: Bool; let prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
    }

    private static func fetchLatest() async throws -> (version: String, page: URL, dmg: URL?)? {
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
        let dmg = r.assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browser_download_url
        return (normalize(r.tag_name), r.html_url, dmg)
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

import Foundation
import AppKit

struct AppEntry: Identifiable, Hashable {
    var id: String { path }
    let path: String
    let name: String
    let bundleID: String?
    let version: String?
    var size: Int64?
    let lastUsed: Date?
    let fromAppStore: Bool
    let ownedByRoot: Bool
}

struct Leftover: Identifiable {
    var id: String { path }
    let path: String
    let kind: String
    var size: Int64
    var selected = true
    let system: Bool        // lives under /Library – needs admin rights
}

final class Uninstaller: ObservableObject {
    @Published var apps: [AppEntry] = []
    @Published var loading = false
    @Published var selection: String?
    @Published var leftovers: [Leftover] = []
    @Published var findingLeftovers = false
    @Published var working = false
    @Published var message: String?

    private let fm = FileManager.default
    var selectedApp: AppEntry? { apps.first { $0.path == selection } }

    // MARK: listing

    func load() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            var paths: [String] = []
            for root in ["/Applications", FSUtil.home + "/Applications"] {
                for p in FSUtil.children(root) {
                    if p.hasSuffix(".app") { paths.append(p) }
                    else if (try? self.fm.attributesOfItem(atPath: p)[.type] as? FileAttributeType) == .typeDirectory {
                        paths += FSUtil.children(p).filter { $0.hasSuffix(".app") }
                    }
                }
            }
            let me = Bundle.main.bundlePath
            var list: [AppEntry] = []
            for p in paths where p != me {
                if let e = Self.entry(for: p) { list.append(e) }
            }
            list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async { self.apps = list; self.loading = false }
            // sizes in the background
            for e in list {
                let s = FSUtil.size(e.path)
                DispatchQueue.main.async {
                    if let i = self.apps.firstIndex(where: { $0.path == e.path }) { self.apps[i].size = s }
                }
            }
        }
    }

    static func entry(for path: String) -> AppEntry? {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil { return nil }
        let b = Bundle(path: path)
        let bid = b?.bundleIdentifier
        if let bid, bid.hasPrefix("com.apple.") { return nil }
        let info = b?.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var lastUsed: Date?
        if let item = MDItemCreate(nil, path as CFString),
           let d = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date { lastUsed = d }
        let owner = (try? FileManager.default.attributesOfItem(atPath: path)[.ownerAccountID] as? NSNumber)?.intValue ?? -1
        return AppEntry(path: path, name: name, bundleID: bid,
                        version: info["CFBundleShortVersionString"] as? String,
                        size: nil, lastUsed: lastUsed,
                        fromAppStore: FSUtil.exists(path + "/Contents/_MASReceipt"),
                        ownedByRoot: owner == 0)
    }

    /// Add an app dropped onto the window (if it is not already listed) and select it.
    func addDropped(_ url: URL) {
        guard url.pathExtension == "app" else { return }
        if !apps.contains(where: { $0.path == url.path }), let e = Self.entry(for: url.path) { apps.insert(e, at: 0) }
        select(url.path)
    }

    // MARK: leftovers

    func select(_ path: String?) {
        selection = path
        leftovers = []
        message = nil
        guard let app = selectedApp else { return }
        findingLeftovers = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.findLeftovers(for: app)
            DispatchQueue.main.async {
                guard self.selection == app.path else { return }
                self.leftovers = found
                self.findingLeftovers = false
            }
        }
    }

    static func findLeftovers(for app: AppEntry) -> [Leftover] {
        let home = FSUtil.home, lib = home + "/Library"
        let name = app.name
        var results: [Leftover] = []
        var seen = Set<String>()

        func add(_ p: String, _ kind: String, system: Bool = false) {
            guard !seen.contains(p), FSUtil.exists(p), !p.hasPrefix(app.path) else { return }
            seen.insert(p)
            results.append(Leftover(path: p, kind: kind, size: FSUtil.size(p), system: system))
        }
        /// entries in dir whose name equals `id` or starts with "id." (e.g. com.foo.app.plist, com.foo.app.helper)
        func matching(_ dir: String, _ id: String) -> [String] {
            FSUtil.children(dir).filter {
                let n = ($0 as NSString).lastPathComponent
                return n == id || n.hasPrefix(id + ".")
            }
        }

        if let bid = app.bundleID {
            add(lib + "/Application Support/" + bid, "Application Support")
            for p in matching(lib + "/Caches", bid) { add(p, "Cache") }
            for p in matching(lib + "/Preferences", bid) { add(p, "Preferences") }
            for p in matching(lib + "/Preferences/ByHost", bid) { add(p, "Preferences") }
            add(lib + "/Saved Application State/\(bid).savedState", "Saved state")
            add(lib + "/Containers/" + bid, "Container")
            add(lib + "/Application Scripts/" + bid, "Scripts")
            for p in matching(lib + "/HTTPStorages", bid) { add(p, "Web data") }
            add(lib + "/WebKit/" + bid, "Web data")
            add(lib + "/Cookies/\(bid).binarycookies", "Cookies")
            add(lib + "/Logs/" + bid, "Logs")
            for p in matching(lib + "/LaunchAgents", bid) { add(p, "Launch agent") }
            for p in FSUtil.children(lib + "/Group Containers") {
                let n = (p as NSString).lastPathComponent
                if n == "group." + bid || n.hasSuffix("." + bid) { add(p, "Group container") }
            }
            for dir in ["/Library/LaunchAgents", "/Library/LaunchDaemons", "/Library/PrivilegedHelperTools"] {
                for p in matching(dir, bid) { add(p, "System launch item", system: true) }
            }
            for p in matching("/Library/Preferences", bid) { add(p, "System preferences", system: true) }
            for p in matching("/Library/Caches", bid) { add(p, "System cache", system: true) }
        }
        // name-based folders (only distinctive names)
        if name.count >= 4 {
            add(lib + "/Application Support/" + name, "Application Support")
            add(lib + "/Caches/" + name, "Cache")
            add(lib + "/Logs/" + name, "Logs")
            add("/Library/Application Support/" + name, "System support files", system: true)
        }
        return results.sorted { $0.size > $1.size }
    }

    // MARK: uninstall

    func uninstall(permanently: Bool) {
        guard let app = selectedApp else { return }
        working = true
        message = nil

        // 1. quit the app if running
        if let bid = app.bundleID {
            for r in NSRunningApplication.runningApplications(withBundleIdentifier: bid) { r.terminate() }
        }
        let items = leftovers.filter(\.selected)
        DispatchQueue.global(qos: .userInitiated).async {
            if let bid = app.bundleID {
                for _ in 0..<50 where !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
                    usleep(100_000)
                }
                // unload user launch agents before removing them
                for l in items where l.kind == "Launch agent" {
                    Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())", l.path])
                }
            }
            // 2. user-level items
            let userItems = items.filter { !$0.system }.map(\.path)
            var failed = FSUtil.remove(userItems, permanently: permanently)
            // 3. the app bundle itself
            var appFailed = !FSUtil.remove([app.path], permanently: permanently).isEmpty
            let systemItems = items.filter(\.system).map(\.path)

            DispatchQueue.main.async {
                let finish: () -> Void = {
                    self.working = false
                    let gone = !FSUtil.exists(app.path)
                    if gone {
                        self.apps.removeAll { $0.path == app.path }
                        self.selection = nil
                        self.leftovers = []
                    }
                    self.message = gone
                        ? "\(app.name) removed" + (failed.isEmpty ? "." : " – \(failed.count) item(s) could not be removed.")
                        : "Could not remove \(app.name)."
                }
                let doSystem: () -> Void = {
                    guard !systemItems.isEmpty else { finish(); return }
                    // System-wide files: standard macOS admin prompt (kept separate from the Touch ID helper on purpose)
                    let cmd = systemItems.map { p -> String in
                        let q = Admin.shellQuote(p)
                        return p.contains("/LaunchDaemons/") || p.contains("/LaunchAgents/")
                            ? "launchctl bootout system \(q) 2>/dev/null; rm -rf \(q)" : "rm -rf \(q)"
                    }.joined(separator: "; ")
                    Admin.run(cmd) { ok in
                        if !ok { failed += systemItems }
                        finish()
                    }
                }
                if appFailed {
                    // root-owned bundle (e.g. App Store): helper moves it to your Trash, gated by Touch ID
                    Privileged.shared.run(["trash-app", app.path, String(getuid())], reason: "move \(app.name) to the Trash") { ok in
                        appFailed = !ok
                        doSystem()
                    }
                } else { doSystem() }
            }
        }
    }
}

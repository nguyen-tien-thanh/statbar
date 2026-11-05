import Foundation
import AppKit

struct CleanItem: Identifiable {
    var id: String { path }
    let path: String
    let name: String
    var size: Int64
    var selected: Bool
    var note: String? = nil
}

struct CleanCategory: Identifiable {
    let id: String
    let title: String
    let icon: String
    let detail: String
    var items: [CleanItem]
    var expanded = false
    var permanentOnly = false          // e.g. emptying the Trash
    var needsAccess = false            // could not read – Full Disk Access needed
    var size: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { items.filter(\.selected).reduce(0) { $0 + $1.size } }
}

final class Cleaner: ObservableObject {
    enum Phase: Equatable { case idle, scanning, scanned, cleaning, done }
    @Published var phase: Phase = .idle
    @Published var progress = ""
    @Published var categories: [CleanCategory] = []
    @Published var permanent = false
    @Published var result: (freed: Int64, trashed: Int64, failed: [String])?

    private var home: String { FSUtil.home }

    var selectedTotal: Int64 { categories.reduce(0) { $0 + $1.selectedSize } }

    func scan(keepResult: Bool = false) {
        phase = .scanning; categories = []
        if !keepResult { result = nil }
        DispatchQueue.global(qos: .userInitiated).async {
            let cats = self.buildCategories()
            DispatchQueue.main.async {
                self.categories = cats.filter { !$0.items.isEmpty || $0.needsAccess }
                self.phase = .scanned
            }
        }
    }

    private func status(_ s: String) { DispatchQueue.main.async { self.progress = s } }

    private func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    private func items(in dir: String, select: (String) -> (Bool, String?)) -> [CleanItem] {
        FSUtil.children(dir).compactMap { p in
            let name = (p as NSString).lastPathComponent
            status(FSUtil.tilde(p))
            let size = FSUtil.size(p)
            guard size > 0 else { return nil }
            let (sel, note) = select(name)
            return CleanItem(path: p, name: name, size: size, selected: sel, note: note)
        }
        .sorted { $0.size > $1.size }
    }

    private func buildCategories() -> [CleanCategory] {
        let lib = home + "/Library"
        let running = runningBundleIDs()
        let me = Bundle.main.bundleIdentifier ?? ""
        var cats: [CleanCategory] = []

        // 1. User caches
        let neverTouch: Set<String> = ["CloudKit", "com.apple.bird", "com.apple.CloudDocs", "com.apple.HomeKit",
                                        "com.apple.ap.adprivacyd", "FamilyCircle", "com.apple.akd", me]
        var caches = items(in: lib + "/Caches") { name in
            if running.contains(where: { name == $0 || name.hasPrefix($0 + ".") }) { return (false, "app is running") }
            if name.hasPrefix("com.apple.") { return (false, "system cache") }
            return (true, nil)
        }
        caches.removeAll { neverTouch.contains($0.name) }
        cats.append(CleanCategory(id: "caches", title: "User caches", icon: "archivebox",
                                  detail: "App caches in ~/Library/Caches. Apps rebuild them as needed.", items: caches))

        // 2. Logs
        cats.append(CleanCategory(id: "logs", title: "Logs & crash reports", icon: "doc.text",
                                  detail: "~/Library/Logs", items: items(in: lib + "/Logs") { _ in (true, nil) }))

        // 3. Developer junk
        let dev: [(String, String, Bool)] = [
            (lib + "/Developer/Xcode/DerivedData", "Xcode DerivedData", true),
            (lib + "/Developer/Xcode/iOS DeviceSupport", "iOS DeviceSupport", true),
            (lib + "/Developer/Xcode/watchOS DeviceSupport", "watchOS DeviceSupport", true),
            (lib + "/Developer/CoreSimulator/Caches", "Simulator caches", true),
            (home + "/.npm/_cacache", "npm cache", true),
            (home + "/.gradle/caches", "Gradle caches", true),
            (home + "/.cargo/registry/cache", "Cargo registry cache", true),
            (home + "/.cache", "~/.cache (may contain downloaded models)", false),
        ]
        var devItems: [CleanItem] = []
        for (p, name, sel) in dev where FSUtil.exists(p) {
            status(FSUtil.tilde(p))
            let s = FSUtil.size(p)
            if s > 0 { devItems.append(CleanItem(path: p, name: name, size: s, selected: sel)) }
        }
        cats.append(CleanCategory(id: "dev", title: "Developer junk", icon: "hammer",
                                  detail: "Build products and package-manager caches. Re-downloaded or rebuilt on demand.",
                                  items: devItems.sorted { $0.size > $1.size }))

        // 4. Trash
        let trash = home + "/.Trash"
        status("~/.Trash")
        let readable = (try? FileManager.default.contentsOfDirectory(atPath: trash)) != nil
        var trashCat = CleanCategory(id: "trash", title: "Trash", icon: "trash",
                                     detail: "Items already in your Trash. Emptying is permanent.",
                                     items: readable ? items(in: trash) { _ in (true, nil) } : [],
                                     permanentOnly: true)
        trashCat.needsAccess = !readable
        cats.append(trashCat)
        return cats
    }

    func clean() {
        phase = .cleaning
        let permanent = self.permanent
        let cats = categories
        DispatchQueue.global(qos: .userInitiated).async {
            var freed: Int64 = 0, trashed: Int64 = 0, failed: [String] = []
            for c in cats {
                for it in c.items where it.selected {
                    self.status(FSUtil.tilde(it.path))
                    let perm = permanent || c.permanentOnly
                    if FSUtil.remove([it.path], permanently: perm).isEmpty {
                        if perm { freed += it.size } else { trashed += it.size }
                    } else { failed.append(it.path) }
                }
            }
            DispatchQueue.main.async {
                self.result = (freed, trashed, failed)
                self.scan(keepResult: true)
            }
        }
    }

    /// Empty the Trash through Finder (works without Full Disk Access; macOS asks for Automation permission once).
    func emptyTrashViaFinder(completion: @escaping (Bool) -> Void) {
        Shell.async("/usr/bin/osascript", ["-e", "tell application \"Finder\" to empty trash"]) { ok in
            completion(ok); self.scan()
        }
    }

    static func openFullDiskAccessSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(u) }
    }
}

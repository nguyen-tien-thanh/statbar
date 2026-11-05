import Foundation

struct OptTask: Identifiable {
    enum State { case idle, running, done, failed }
    let id: String
    let title: String
    let detail: String
    let icon: String
    let needsAdmin: Bool
    var selected: Bool
    var state: State = .idle
}

final class Optimizer: ObservableObject {
    @Published var tasks: [OptTask] = [
        OptTask(id: "purge", title: "Free up RAM", detail: "Purge inactive memory and disk caches.", icon: "memorychip", needsAdmin: true, selected: true),
        OptTask(id: "dns", title: "Flush DNS cache", detail: "Fixes sites that don't load after DNS / VPN changes.", icon: "network", needsAdmin: true, selected: true),
        OptTask(id: "ls", title: "Rebuild Launch Services", detail: "Fixes duplicate entries in “Open With” and wrong default apps.", icon: "square.stack.3d.up", needsAdmin: false, selected: true),
        OptTask(id: "ql", title: "Reset Quick Look", detail: "Fixes missing or stale previews and thumbnails.", icon: "eye", needsAdmin: false, selected: true),
        OptTask(id: "dock", title: "Restart Dock", detail: "Refreshes Dock, Launchpad and Mission Control.", icon: "dock.rectangle", needsAdmin: false, selected: false),
        OptTask(id: "finder", title: "Restart Finder", detail: "Fixes a stuck or slow Finder.", icon: "folder", needsAdmin: false, selected: false),
        OptTask(id: "spotlight", title: "Rebuild Spotlight index", detail: "Fixes broken search. Re-indexing takes a while and uses CPU.", icon: "magnifyingglass", needsAdmin: true, selected: false),
    ]
    @Published var running = false

    private let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    func runSelected() {
        guard !running else { return }
        running = true
        for i in tasks.indices { tasks[i].state = .idle }
        next(from: 0)
    }

    private func next(from i: Int) {
        guard i < tasks.count else { running = false; return }
        guard tasks[i].selected else { next(from: i + 1); return }
        tasks[i].state = .running
        perform(tasks[i].id) { ok in
            self.tasks[i].state = ok ? .done : .failed
            self.next(from: i + 1)
        }
    }

    private func perform(_ id: String, done: @escaping (Bool) -> Void) {
        switch id {
        case "purge": Privileged.shared.run(["purge"], reason: "free up memory", completion: done)
        case "dns": Privileged.shared.run(["flushdns"], reason: "flush the DNS cache", completion: done)
        case "spotlight": Privileged.shared.run(["reindex"], reason: "rebuild the Spotlight index", completion: done)
        case "ls": Shell.async(lsregister, ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"], completion: done)
        case "ql":
            DispatchQueue.global().async {
                let a = Shell.run("/usr/bin/qlmanage", ["-r"]), b = Shell.run("/usr/bin/qlmanage", ["-r", "cache"])
                DispatchQueue.main.async { done(a == 0 && b == 0) }
            }
        case "dock": Shell.async("/usr/bin/killall", ["Dock"], completion: done)
        case "finder": Shell.async("/usr/bin/killall", ["Finder"], completion: done)
        default: done(false)
        }
    }
}

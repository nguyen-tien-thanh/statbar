import Foundation
import AppKit

final class DiskNode: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let isDir: Bool
    var size: Int64 = 0
    var children: [DiskNode] = []
    weak var parent: DiskNode?
    var isAggregate = false   // "N smaller items"
    var smallBytes: Int64 = 0
    var smallCount = 0

    init(name: String, path: String, isDir: Bool, parent: DiskNode?) {
        self.name = name; self.path = path; self.isDir = isDir; self.parent = parent
    }
    var canDrill: Bool { isDir && !isAggregate && !children.isEmpty }
}

final class DiskAnalyzer: ObservableObject {
    @Published var root: DiskNode?
    @Published var current: DiskNode?
    @Published var scanning = false
    @Published var scannedFiles = 0
    @Published var scannedBytes: Int64 = 0
    @Published var currentPath = ""
    @Published var deniedCount = 0
    private var cancelFlag = false

    private let keepChildren = 40
    private let fileThreshold: Int64 = 20 * 1024 * 1024      // files smaller than this are aggregated
    private let pruneBelow: Int64 = 50 * 1024 * 1024         // folders smaller than this drop their subtree

    func cancel() { cancelFlag = true }

    func scan(_ path: String) {
        guard !scanning else { return }
        scanning = true; cancelFlag = false
        scannedFiles = 0; scannedBytes = 0; deniedCount = 0
        root = nil; current = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = self.walk(path)
            DispatchQueue.main.async {
                self.root = r; self.current = r; self.scanning = false
            }
        }
    }

    private func walk(_ path: String) -> DiskNode? {
        guard let cs = strdup(path) else { return nil }
        defer { free(cs) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cs, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return nil }
        defer { fts_close(fts) }

        let skip: Set<String> = path == "/" ? ["/System/Volumes", "/Volumes", "/dev", "/cores"] : ["/System/Volumes"]
        var stack: [DiskNode] = []
        var root: DiskNode?
        var files = 0, bytes: Int64 = 0, denied = 0
        var lastUI = Date()

        while let ent = fts_read(fts) {
            if cancelFlag { break }
            let e = ent.pointee
            let p = String(cString: e.fts_path)
            switch Int32(e.fts_info) {
            case FTS_D:
                if skip.contains(p) { fts_set(fts, ent, FTS_SKIP); continue }
                let node = DiskNode(name: e.fts_level == 0 ? p : (p as NSString).lastPathComponent,
                                    path: p, isDir: true, parent: stack.last)
                if root == nil { root = node }
                stack.append(node)
            case FTS_DP:
                guard let node = stack.popLast() else { break }
                finalize(node)
                if let parent = stack.last { parent.children.append(node); parent.size += node.size }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                let size = Int64(e.fts_statp.pointee.st_blocks) * 512
                files += 1; bytes += size
                guard let dir = stack.last else {
                    // scanning a single file
                    let n = DiskNode(name: p, path: p, isDir: false, parent: nil); n.size = size; return n
                }
                dir.size += size
                if size >= fileThreshold {
                    let n = DiskNode(name: (p as NSString).lastPathComponent, path: p, isDir: false, parent: dir)
                    n.size = size
                    dir.children.append(n)
                } else { dir.smallBytes += size; dir.smallCount += 1 }
            case FTS_DNR, FTS_ERR, FTS_NS:
                denied += 1
                // unreadable directories are reported as FTS_D followed by FTS_DNR (no FTS_DP): close them here
                if let top = stack.last, top.path == p, stack.count > 1 {
                    stack.removeLast()
                    finalize(top)
                    if let parent = stack.last { parent.children.append(top); parent.size += top.size }
                }
            default: break
            }
            if files % 3000 == 0, Date().timeIntervalSince(lastUI) > 0.15 {
                lastUI = Date()
                let f = files, b = bytes, d = denied
                DispatchQueue.main.async { self.scannedFiles = f; self.scannedBytes = b; self.currentPath = p; self.deniedCount = d }
            }
        }
        // cancelled midway: close open folders so partial results are still browsable
        while let node = stack.popLast() {
            finalize(node)
            if let parent = stack.last { parent.children.append(node); parent.size += node.size }
        }
        let f = files, b = bytes, d = denied
        DispatchQueue.main.async { self.scannedFiles = f; self.scannedBytes = b; self.deniedCount = d }
        return root
    }

    private func finalize(_ node: DiskNode) {
        if node.size < pruneBelow && node.parent != nil {
            node.children = []
            return
        }
        node.children.sort { $0.size > $1.size }
        var aggBytes = node.smallBytes, aggCount = node.smallCount
        if node.children.count > keepChildren {
            for c in node.children[keepChildren...] { aggBytes += c.size; aggCount += 1 }
            node.children.removeLast(node.children.count - keepChildren)
        }
        if aggBytes > 0 {
            let agg = DiskNode(name: "\(aggCount) smaller item\(aggCount == 1 ? "" : "s")", path: node.path, isDir: false, parent: node)
            agg.size = aggBytes; agg.isAggregate = true
            node.children.append(agg)
            node.children.sort { $0.size > $1.size }
        }
    }

    // MARK: navigation / actions

    func drill(_ n: DiskNode) { if n.canDrill { current = n } }
    func up() { if let p = current?.parent { current = p } }

    var breadcrumb: [DiskNode] {
        var out: [DiskNode] = []; var n = current
        while let x = n { out.insert(x, at: 0); n = x.parent }
        return out
    }

    func trash(_ n: DiskNode) -> Bool {
        guard !n.isAggregate, FSUtil.remove([n.path], permanently: false).isEmpty else { return false }
        n.parent?.children.removeAll { $0 === n }
        var p = n.parent
        while let x = p { x.size -= n.size; p = x.parent }
        objectWillChange.send()
        return true
    }
}

// MARK: - Squarified treemap

enum Treemap {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var rects = [CGRect](repeating: .zero, count: values.count)
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return rects }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var remaining = rect
        var i = 0
        func worst(_ row: [Double], _ side: Double) -> Double {
            let s = row.reduce(0, +); guard s > 0, let mx = row.max(), let mn = row.min(), mn > 0 else { return .infinity }
            return max(side * side * mx / (s * s), (s * s) / (side * side * mn))
        }
        while i < areas.count {
            if areas[i] <= 0 { i += 1; continue }
            let side = Double(min(remaining.width, remaining.height))
            var row = [areas[i]], idx = [i]
            var j = i + 1
            while j < areas.count, areas[j] > 0, worst(row + [areas[j]], side) <= worst(row, side) {
                row.append(areas[j]); idx.append(j); j += 1
            }
            let sum = row.reduce(0, +)
            let thick = CGFloat(sum / side)
            if remaining.width >= remaining.height {
                var y = remaining.minY
                for (k, a) in zip(idx, row) {
                    let h = CGFloat(a) / thick
                    rects[k] = CGRect(x: remaining.minX, y: y, width: thick, height: h); y += h
                }
                remaining = CGRect(x: remaining.minX + thick, y: remaining.minY, width: max(0, remaining.width - thick), height: remaining.height)
            } else {
                var x = remaining.minX
                for (k, a) in zip(idx, row) {
                    let w = CGFloat(a) / thick
                    rects[k] = CGRect(x: x, y: remaining.minY, width: w, height: thick); x += w
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + thick, width: remaining.width, height: max(0, remaining.height - thick))
            }
            i = j
        }
        return rects
    }
}

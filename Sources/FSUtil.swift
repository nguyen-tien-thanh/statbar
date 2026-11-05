import Foundation
import AppKit

enum FSUtil {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Allocated size on disk of a file or directory tree (does not follow symlinks or cross volumes).
    static func size(_ path: String, cancel: (() -> Bool)? = nil) -> Int64 {
        var total: Int64 = 0
        guard let cs = strdup(path) else { return 0 }
        defer { free(cs) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cs, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }
        var n = 0
        while let ent = fts_read(fts) {
            let info = Int32(ent.pointee.fts_info)
            if info == FTS_F || info == FTS_SL || info == FTS_SLNONE || info == FTS_DEFAULT, let st = ent.pointee.fts_statp {
                total += Int64(st.pointee.st_blocks) * 512
            }
            n += 1
            if n % 2000 == 0, cancel?() == true { break }
        }
        return total
    }

    static func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

    static func children(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0 != ".DS_Store" && $0 != ".localized" }
            .map { (dir as NSString).appendingPathComponent($0) }
    }

    static func isWritableParent(_ p: String) -> Bool {
        FileManager.default.isWritableFile(atPath: (p as NSString).deletingLastPathComponent)
    }

    static func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    static func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }

    /// Removes items. Returns paths that failed.
    static func remove(_ paths: [String], permanently: Bool) -> [String] {
        var failed: [String] = []
        for p in paths {
            let url = URL(fileURLWithPath: p)
            do {
                if permanently { try FileManager.default.removeItem(at: url) }
                else { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            } catch { failed.append(p) }
        }
        return failed
    }

    static func reveal(_ p: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
}

enum Shell {
    /// Runs a program synchronously (call off the main thread). Returns exit status.
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func async(_ path: String, _ args: [String], completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = run(path, args) == 0
            DispatchQueue.main.async { completion(ok) }
        }
    }
}

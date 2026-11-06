import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AnalyzeView: View {
    @ObservedObject var a: DiskAnalyzer
    @State private var hovered: UUID?
    /// Items picked for deletion – may span several folders.
    @State private var marked: [UUID: DiskNode] = [:]
    /// Non-empty while the "Move to Trash?" confirmation is up.
    @State private var pendingTrash: [DiskNode] = []
    @State private var toast: TrashToast?
    @State private var dropTarget = false

    /// Name of the startup disk ("Macintosh HD"). Scanning it covers Home too (/Users is part of it).
    static let diskName = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "Macintosh HD"

    private let palette: [Color] = [.diskC, .purple, .cpuC, .orange, .pink, .teal, .memC, .indigo, .mint, .red]

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(tab: .analyze, subtitle: "Scan your whole disk or any folder. Drop a folder here to scan it.") {
                HStack(spacing: 6) {
                    if let r = a.root {
                        Button { a.scan(r.path) } label: { Image(systemName: "arrow.clockwise") }
                            .help("Scan \(label(r)) again")
                    }
                    Button { a.scan("/") } label: { Label("Scan Disk", systemImage: "internaldrive") }
                        .help("Scan all of \(Self.diskName), including your Home folder")
                    Button { choose() } label: { Label("Choose Folder…", systemImage: "folder") }
                }
                .disabled(a.scanning)
            }
            Divider()
            if a.scanning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Scanning… \(a.scannedFiles.formatted()) files · \(FSUtil.fmt(a.scannedBytes))").font(.headline).monospacedDigit()
                    Text(FSUtil.tilde(a.currentPath)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 480)
                    Button("Stop") { a.cancel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let cur = a.current {
                breadcrumb
                GeometryReader { geo in treemap(cur, size: geo.size) }
                    .frame(minHeight: 220)
                    .padding(.horizontal, 16)
                list(cur).frame(minHeight: 180)
                    .overlay(alignment: .bottom) { if let t = toast { toastView(t).padding(10) } }
                if a.deniedCount > 0 {
                    HStack {
                        Image(systemName: "lock").foregroundStyle(.orange)
                        Text("\(a.deniedCount) folder(s) could not be read. Grant Full Disk Access for complete results.")
                        Spacer()
                        Button("Open Settings") { Cleaner.openFullDiskAccessSettings() }
                    }
                    .font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 6)
                }
                Divider()
                actionBar
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "chart.pie").font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text("See what's using your disk").font(.headline)
                    Text("Scans all of \(Self.diskName), including your Home folder – or pick any folder (or drop one here).\nmacOS may ask for access to Desktop, Documents and Downloads.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        Button { a.scan("/") } label: { Label("Scan Disk", systemImage: "internaldrive") }.buttonStyle(.borderedProminent)
                        Button { choose() } label: { Label("Choose Folder…", systemImage: "folder") }
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in
            guard !a.scanning, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
                DispatchQueue.main.async { a.scan(url.path) }
            }
            return true
        }
        .overlay(dropTarget && !a.scanning ? RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3).padding(6) : nil)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { !pendingTrash.isEmpty }, set: { if !$0 { pendingTrash = [] } })) {
            Button("Move to Trash", role: .destructive) { performTrash(pendingTrash); pendingTrash = [] }
            Button("Cancel", role: .cancel) { pendingTrash = [] }
        } message: { Text(confirmMessage) }
        .onChange(of: a.root?.id) { _ in marked = [:]; toast = nil }   // new scan → fresh selection
    }

    // MARK: selection

    private func isMarked(_ n: DiskNode) -> Bool { marked[n.id] != nil }

    /// A selected folder that already contains `n` (so `n` goes with it).
    private func coveringAncestor(_ n: DiskNode) -> DiskNode? {
        var p = n.parent
        while let x = p { if marked[x.id] != nil { return x }; p = x.parent }
        return nil
    }

    private func canSelect(_ n: DiskNode) -> Bool { a.protectionReason(n) == nil && coveringAncestor(n) == nil }

    private func toggle(_ n: DiskNode) {
        if marked.removeValue(forKey: n.id) != nil { return }
        guard canSelect(n) else { return }
        marked = marked.filter { !a.isAncestor(n, of: $0.value) }   // its contents no longer count separately
        marked[n.id] = n
    }

    /// Single click: open a folder, select a file.
    private func activate(_ n: DiskNode) {
        if n.canDrill { a.drill(n) } else if canSelect(n) || isMarked(n) { toggle(n) }
    }

    private var markedTotal: Int64 { marked.values.reduce(0) { $0 + $1.size } }

    // MARK: trash + undo

    private var confirmTitle: String {
        pendingTrash.count == 1 ? "Move “\(pendingTrash[0].name)” to the Trash?" : "Move \(pendingTrash.count) items to the Trash?"
    }

    private var confirmMessage: String {
        let total = FSUtil.fmt(pendingTrash.reduce(0) { $0 + $1.size })
        if pendingTrash.count == 1 { return "\(total) · \(FSUtil.tilde(pendingTrash[0].path))\nYou can undo right after." }
        let names = pendingTrash.sorted { $0.size > $1.size }.prefix(4).map { "• \($0.name)" }.joined(separator: "\n")
        let more = pendingTrash.count > 4 ? "\n…and \(pendingTrash.count - 4) more" : ""
        return "\(total) in total\n\(names)\(more)\nYou can undo right after."
    }

    private func performTrash(_ nodes: [DiskNode]) {
        let r = a.moveToTrash(nodes)
        for it in r.moved { marked.removeValue(forKey: it.node.id) }
        let freed = r.moved.reduce(Int64(0)) { $0 + $1.node.size }
        var text = r.moved.count == 1 ? "Moved “\(r.moved[0].node.name)” to the Trash" : "Moved \(r.moved.count) items to the Trash"
        if !r.moved.isEmpty { text += " · \(FSUtil.fmt(freed))" }
        if !r.failed.isEmpty { text += r.moved.isEmpty ? "Couldn't move \(r.failed.count) item(s)" : " · \(r.failed.count) failed" }
        withAnimation(.easeOut(duration: 0.2)) { toast = TrashToast(text: text, items: r.moved, isError: r.moved.isEmpty) }
    }

    private func undo(_ t: TrashToast) {
        let n = a.restore(t.items)
        withAnimation(.easeOut(duration: 0.2)) {
            toast = TrashToast(text: n == t.items.count ? "Restored \(n) item\(n == 1 ? "" : "s")" : "Restored \(n) of \(t.items.count) items",
                               items: [], isError: n < t.items.count)
        }
    }

    // MARK: bottom bar + toast

    private var actionBar: some View {
        HStack(spacing: 10) {
            if marked.isEmpty {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text("Tick files or folders to free up space. Click a folder to open it.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(marked.count) item\(marked.count == 1 ? "" : "s") selected").font(.system(size: 12.5, weight: .semibold))
                    Text("\(FSUtil.fmt(markedTotal)) will be freed").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("Deselect All") { withAnimation(.easeOut(duration: 0.15)) { marked = [:] } }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) { pendingTrash = Array(marked.values) } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent).tint(.red)
                .keyboardShortcut(.delete, modifiers: .command)
                .help("Move the selected items to the Trash (⌘⌫)")
            }
        }
        .controlSize(.regular)
        .frame(minHeight: 34)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .animation(.easeOut(duration: 0.15), value: marked.isEmpty)
    }

    private func toastView(_ t: TrashToast) -> some View {
        HStack(spacing: 10) {
            Image(systemName: t.isError ? "exclamationmark.triangle.fill" : "trash.fill")
                .foregroundStyle(t.isError ? Color.orange : Color.secondary)
            Text(t.text).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 8)
            if !t.items.isEmpty {
                Button("Undo") { undo(t) }.keyboardShortcut("z", modifiers: .command)
                Button("Show in Trash") { NSWorkspace.shared.open(URL(fileURLWithPath: FSUtil.home + "/.Trash")) }
            }
            Button { withAnimation { toast = nil } } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: t.id) {                       // auto-hide; Undo stays available for 10 s
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if toast?.id == t.id { withAnimation { toast = nil } }
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: FSUtil.home)
        p.prompt = "Scan"; p.message = "Choose a folder to analyze"
        if p.runModal() == .OK, let u = p.url { a.scan(u.path) }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button { a.up() } label: { Image(systemName: "chevron.left") }.disabled(a.current?.parent == nil)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(a.breadcrumb.enumerated()), id: \.element.id) { i, n in
                        if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
                        Button(i == 0 ? label(n) : n.name) { a.current = n }
                            .buttonStyle(.plain).font(.system(size: 12, weight: n === a.current ? .semibold : .regular))
                    }
                }
            }
            Spacer()
            Text(FSUtil.fmt(a.current?.size ?? 0)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// Root label: the disk's name for "/", otherwise the (~-shortened) folder path.
    private func label(_ n: DiskNode) -> String { n.path == "/" ? Self.diskName : FSUtil.tilde(n.path) }

    private func color(_ i: Int, _ n: DiskNode) -> Color {
        n.isAggregate ? Color.gray.opacity(0.5) : palette[i % palette.count].opacity(n.isDir ? 0.85 : 0.55)
    }

    private func treemap(_ cur: DiskNode, size: CGSize) -> some View {
        let kids = cur.children.filter { $0.size > 0 }
        let rects = Treemap.layout(kids.map { Double($0.size) }, in: CGRect(origin: .zero, size: size))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(kids.enumerated()), id: \.element.id) { i, n in
                let r = rects[i].insetBy(dx: 1, dy: 1)
                if r.width > 1 && r.height > 1 {
                    let on = isMarked(n), covered = !on && coveringAncestor(n) != nil
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color(i, n))
                        .opacity(covered ? 0.55 : 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(
                            on ? Color.accentColor : Color.white.opacity(hovered == n.id ? 0.9 : 0), lineWidth: on ? 3 : 2))
                        .overlay(alignment: .topTrailing) {
                            // check badge: always shown when selected, on hover when selectable
                            if r.width > 26 && r.height > 26 && (on || (hovered == n.id && canSelect(n))) {
                                Button { toggle(n) } label: {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(on ? Color.accentColor : Color.white)
                                        .background(Circle().fill(on ? Color.white : Color.black.opacity(0.25)).padding(1))
                                }
                                .buttonStyle(.plain).padding(4)
                                .help(on ? "Deselect" : "Select for deletion")
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if r.width > 60 && r.height > 30 {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(n.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                    Text(FSUtil.fmt(n.size)).font(.system(size: 10)).opacity(0.85)
                                }
                                .foregroundStyle(.white).padding(5)
                            }
                        }
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .onHover { hovered = $0 ? n.id : (hovered == n.id ? nil : hovered) }
                        .onTapGesture { activate(n) }
                        .help("\(n.name) – \(FSUtil.fmt(n.size))\n" + (n.canDrill ? "Click to open" : canSelect(n) ? "Click to select" : a.protectionReason(n) ?? ""))
                        .contextMenu { menu(n) }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func list(_ cur: DiskNode) -> some View {
        List {
            ForEach(Array(cur.children.enumerated()), id: \.element.id) { i, n in
                HStack(spacing: 8) {
                    checkbox(n)
                    RoundedRectangle(cornerRadius: 2).fill(color(i, n)).frame(width: 10, height: 10)
                    Image(systemName: n.isAggregate ? "ellipsis.circle" : n.isDir ? "folder.fill" : "doc.fill")
                        .foregroundStyle(.secondary).frame(width: 16)
                    Text(n.name).font(.system(size: 12, weight: isMarked(n) ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    // Always laid out (fixed width) and only faded in on hover, so hovering never changes the
                    // row's size or shifts the columns – inserting them on hover made the list jump.
                    let showActions = hovered == n.id && !n.isAggregate
                    HStack(spacing: 2) {
                        RowAction(icon: "magnifyingglass", help: "Reveal in Finder") { FSUtil.reveal(n.path) }
                        RowAction(icon: "trash", help: "Move to Trash…", tint: .red) { pendingTrash = [n] }
                            .opacity(canSelect(n) ? 1 : 0)
                            .allowsHitTesting(canSelect(n))
                    }
                    .frame(width: 46, alignment: .trailing)
                    .opacity(showActions ? 1 : 0)
                    .allowsHitTesting(showActions)
                    let frac = cur.size > 0 ? Double(n.size) / Double(cur.size) : 0
                    Meter(fraction: frac, color: palette[i % palette.count], height: 5).frame(width: 90)
                    Text(String(format: "%.0f%%", frac * 100)).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    Text(FSUtil.fmt(n.size)).font(.system(size: 11.5, weight: .medium)).monospacedDigit().frame(width: 74, alignment: .trailing)
                    if n.canDrill { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    else { Color.clear.frame(width: 7) }
                }
                .frame(height: 22)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 5).fill(
                    isMarked(n) ? Color.accentColor.opacity(0.14) : hovered == n.id ? Color.primary.opacity(0.06) : .clear))
                .onHover { hovered = $0 ? n.id : (hovered == n.id ? nil : hovered) }
                .onTapGesture { activate(n) }
                .contextMenu { menu(n) }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder private func menu(_ n: DiskNode) -> some View {
        if n.canDrill { Button("Open") { a.drill(n) } }
        Button("Reveal in Finder") { FSUtil.reveal(n.path) }
        if !n.isAggregate {
            Divider()
            if isMarked(n) { Button("Deselect") { toggle(n) } }
            else { Button("Select") { toggle(n) }.disabled(!canSelect(n)) }
            Button("Move to Trash…", role: .destructive) { pendingTrash = [n] }.disabled(!canSelect(n) && !isMarked(n))
        }
    }

    /// Circle checkbox; a lock when the item can't be deleted, a faint tick when its folder is already selected.
    @ViewBuilder private func checkbox(_ n: DiskNode) -> some View {
        if n.isAggregate {
            Color.clear.frame(width: 16, height: 16)
        } else if let reason = a.protectionReason(n) {
            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(width: 16, height: 16).help(reason)
        } else if let parent = coveringAncestor(n) {
            Image(systemName: "checkmark.circle").font(.system(size: 14)).foregroundStyle(Color.accentColor.opacity(0.5))
                .frame(width: 16, height: 16).help("Included with “\(parent.name)”")
        } else {
            Button { toggle(n) } label: {
                Image(systemName: isMarked(n) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isMarked(n) ? Color.accentColor : Color.secondary.opacity(0.7))
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isMarked(n) ? "Deselect" : "Select for deletion")
        }
    }
}

/// Toast shown after moving items to the Trash (with Undo while `items` is non-empty).
struct TrashToast: Equatable {
    let id = UUID()
    let text: String
    let items: [TrashedItem]
    var isError = false
    static func == (l: TrashToast, r: TrashToast) -> Bool { l.id == r.id }
}

/// Small icon button that appears on row hover.
private struct RowAction: View {
    let icon: String
    let help: String
    var tint: Color = .secondary
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover ? (tint == .secondary ? Color.primary : tint) : Color.secondary)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hover ? 0.1 : 0)))
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help)
    }
}

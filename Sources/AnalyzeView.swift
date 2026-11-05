import SwiftUI
import AppKit

struct AnalyzeView: View {
    @ObservedObject var a: DiskAnalyzer
    @State private var hovered: UUID?
    @State private var toTrash: DiskNode?

    private let palette: [Color] = [.diskC, .purple, .cpuC, .orange, .pink, .teal, .memC, .indigo, .mint, .red]

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(tab: .analyze) {
                HStack(spacing: 6) {
                    Button("Home") { a.scan(FSUtil.home) }
                    Button("Macintosh HD") { a.scan("/") }
                    Button("Choose…") { choose() }
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
                if a.deniedCount > 0 {
                    HStack {
                        Image(systemName: "lock").foregroundStyle(.orange)
                        Text("\(a.deniedCount) folder(s) could not be read. Grant Full Disk Access for complete results.")
                        Spacer()
                        Button("Open Settings") { Cleaner.openFullDiskAccessSettings() }
                    }
                    .font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 6)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "chart.pie").font(.system(size: 44)).foregroundStyle(.tertiary)
                    Text("Choose what to analyze").font(.headline)
                    Text("Scanning your Home folder may ask for access to Desktop, Documents and Downloads.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button("Scan Home") { a.scan(FSUtil.home) }.buttonStyle(.borderedProminent)
                        Button("Scan Macintosh HD") { a.scan("/") }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .confirmationDialog("Move “\(toTrash?.name ?? "")” to the Trash?", isPresented: Binding(get: { toTrash != nil }, set: { if !$0 { toTrash = nil } })) {
            Button("Move to Trash", role: .destructive) { if let n = toTrash { _ = a.trash(n) }; toTrash = nil }
        } message: { Text("\(FSUtil.fmt(toTrash?.size ?? 0)) · \(FSUtil.tilde(toTrash?.path ?? ""))") }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.directoryURL = URL(fileURLWithPath: FSUtil.home)
        if p.runModal() == .OK, let u = p.url { a.scan(u.path) }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button { a.up() } label: { Image(systemName: "chevron.left") }.disabled(a.current?.parent == nil)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(a.breadcrumb.enumerated()), id: \.element.id) { i, n in
                        if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary) }
                        Button(i == 0 ? FSUtil.tilde(n.name) : n.name) { a.current = n }
                            .buttonStyle(.plain).font(.system(size: 12, weight: n === a.current ? .semibold : .regular))
                    }
                }
            }
            Spacer()
            Text(FSUtil.fmt(a.current?.size ?? 0)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

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
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color(i, n))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(hovered == n.id ? 0.9 : 0), lineWidth: 2))
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
                        .onTapGesture(count: 2) { a.drill(n) }
                        .help("\(n.name) – \(FSUtil.fmt(n.size))\(n.canDrill ? "\nDouble-click to open" : "")")
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
                    RoundedRectangle(cornerRadius: 2).fill(color(i, n)).frame(width: 10, height: 10)
                    Image(systemName: n.isAggregate ? "ellipsis.circle" : n.isDir ? "folder.fill" : "doc.fill")
                        .foregroundStyle(.secondary).frame(width: 16)
                    Text(n.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    let frac = cur.size > 0 ? Double(n.size) / Double(cur.size) : 0
                    Meter(fraction: frac, color: palette[i % palette.count], height: 5).frame(width: 90)
                    Text(String(format: "%.0f%%", frac * 100)).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                    Text(FSUtil.fmt(n.size)).font(.system(size: 11.5, weight: .medium)).monospacedDigit().frame(width: 74, alignment: .trailing)
                    if n.canDrill { Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary) }
                    else { Color.clear.frame(width: 7) }
                }
                .contentShape(Rectangle())
                .background(hovered == n.id ? Color.primary.opacity(0.06) : .clear)
                .onHover { hovered = $0 ? n.id : (hovered == n.id ? nil : hovered) }
                .onTapGesture(count: 2) { a.drill(n) }
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
            Button("Move to Trash…", role: .destructive) { toTrash = n }
        }
    }
}

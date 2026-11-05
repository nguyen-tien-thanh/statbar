import SwiftUI

struct CleanView: View {
    @ObservedObject var c: Cleaner
    @State private var confirm = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(tab: .clean) {
                if c.phase == .scanned || c.phase == .done {
                    Button("Rescan") { c.scan() }
                }
            }
            Divider()
            content
            if c.phase == .scanned || c.phase == .done { Divider(); bottomBar }
        }
        .onAppear { if c.phase == .idle { c.scan() } }
    }

    @ViewBuilder private var content: some View {
        switch c.phase {
        case .idle, .scanning, .cleaning:
            VStack(spacing: 10) {
                ProgressView()
                Text(c.phase == .cleaning ? "Cleaning…" : "Scanning…").font(.headline)
                Text(c.progress).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .scanned, .done:
            ScrollView {
                VStack(spacing: 10) {
                    if let r = c.result { resultBanner(r) }
                    ForEach($c.categories) { $cat in CategoryCard(cat: $cat, cleaner: c) }
                    if c.categories.isEmpty {
                        Text("Nothing to clean 🎉").font(.headline).foregroundStyle(.secondary).padding(40)
                    }
                }
                .padding(16)
            }
        }
    }

    private func resultBanner(_ r: (freed: Int64, trashed: Int64, failed: [String])) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                if r.freed > 0 { Text("Freed \(FSUtil.fmt(r.freed))").font(.headline) }
                if r.trashed > 0 {
                    Text("Moved \(FSUtil.fmt(r.trashed)) to the Trash – empty the Trash to reclaim the space.")
                        .font(r.freed > 0 ? .system(size: 12) : .headline)
                }
                if r.freed == 0 && r.trashed == 0 { Text("Nothing was removed.").font(.headline) }
                if !r.failed.isEmpty {
                    Text("\(r.failed.count) item(s) could not be removed (in use or protected).").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.1)))
    }

    private var bottomBar: some View {
        HStack {
            Toggle("Delete permanently (skip Trash)", isOn: $c.permanent).toggleStyle(.checkbox)
                .help("When off, items are moved to the Trash so you can restore them.")
            Spacer()
            Text("Selected: \(FSUtil.fmt(c.selectedTotal))").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Button {
                confirm = true
            } label: {
                Text("Clean").frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(c.selectedTotal == 0)
            .confirmationDialog("Clean \(FSUtil.fmt(c.selectedTotal))?", isPresented: $confirm) {
                Button(c.permanent ? "Delete permanently" : "Move to Trash", role: .destructive) { c.clean() }
            } message: {
                Text(c.permanent ? "Selected items will be deleted permanently. This cannot be undone."
                                 : "Selected items will be moved to the Trash. Items already in the Trash are deleted permanently.")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

private struct CategoryCard: View {
    @Binding var cat: CleanCategory
    let cleaner: Cleaner

    private var allSelected: Bool { !cat.items.isEmpty && cat.items.allSatisfy(\.selected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { allSelected },
                                         set: { v in for i in cat.items.indices { cat.items[i].selected = v } }))
                    .toggleStyle(.checkbox).labelsHidden().disabled(cat.items.isEmpty)
                Image(systemName: cat.icon).font(.system(size: 15)).foregroundStyle(Color.diskC).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cat.title).font(.system(size: 13, weight: .semibold))
                    Text(cat.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if cat.needsAccess {
                    Button("Empty Trash") { cleaner.emptyTrashViaFinder { _ in } }
                    Button("Grant access…") { Cleaner.openFullDiskAccessSettings() }
                        .help("StatBar can't read the Trash without Full Disk Access. You can still empty it via Finder.")
                } else {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(FSUtil.fmt(cat.selectedSize)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        Text("of \(FSUtil.fmt(cat.size))").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Button { withAnimation(.easeOut(duration: 0.15)) { cat.expanded.toggle() } } label: {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(cat.expanded ? 90 : 0))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).frame(width: 20)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture { if !cat.items.isEmpty { withAnimation(.easeOut(duration: 0.15)) { cat.expanded.toggle() } } }

            if cat.expanded {
                Divider().padding(.horizontal, 12)
                VStack(spacing: 0) {
                    ForEach($cat.items) { $item in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $item.selected).toggleStyle(.checkbox).labelsHidden()
                            Text(item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                            if let n = item.note { Tag(text: n) }
                            Spacer()
                            Text(FSUtil.fmt(item.size)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                            Button { FSUtil.reveal(item.path) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Reveal in Finder")
                        }
                        .padding(.vertical, 4).padding(.horizontal, 12)
                        .help(FSUtil.tilde(item.path))
                    }
                }
                .padding(.leading, 30).padding(.vertical, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
    }
}

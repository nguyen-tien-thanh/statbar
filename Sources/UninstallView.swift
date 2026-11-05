import SwiftUI
import UniformTypeIdentifiers

struct UninstallView: View {
    @ObservedObject var u: Uninstaller
    @State private var query = ""
    @State private var sort = "name"
    @State private var confirm = false
    @State private var permanent = false
    @State private var dropTarget = false

    private var filtered: [AppEntry] {
        var list = u.apps
        if !query.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(query) } }
        switch sort {
        case "size": list.sort { ($0.size ?? 0) > ($1.size ?? 0) }
        case "used": list.sort { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        default: break
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(tab: .uninstall, subtitle: "Remove apps together with their leftover files. Drop an app here.") {
                Button { u.load() } label: { Image(systemName: "arrow.clockwise") }.help("Reload app list")
            }
            Divider()
            HSplitView {
                appList.frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                detail.frame(minWidth: 340, maxWidth: .infinity)
            }
        }
        .onAppear { if u.apps.isEmpty { u.load() } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { u.addDropped(url) } }
                }
            }
            return true
        }
        .overlay(dropTarget ? RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 3).padding(6) : nil)
    }

    private var appList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search apps", text: $query).textFieldStyle(.roundedBorder)
                Picker("", selection: $sort) {
                    Text("Name").tag("name"); Text("Size").tag("size"); Text("Least used").tag("used")
                }
                .labelsHidden().fixedSize()
            }
            .padding(10)
            if u.loading && u.apps.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, selection: Binding(get: { u.selection }, set: { u.select($0) })) { app in
                    AppRow(app: app).tag(app.path)
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let app = u.selectedApp {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.system(size: 18, weight: .bold))
                        Text([app.version.map { "Version \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack(spacing: 6) {
                            if app.fromAppStore { Tag(text: "App Store") }
                            if let d = app.lastUsed { Tag(text: "Last used \(d.formatted(.relative(presentation: .named)))") }
                        }
                    }
                    Spacer()
                }
                .padding(16)
                Divider()
                if u.findingLeftovers {
                    HStack { ProgressView().controlSize(.small); Text("Looking for leftover files…").foregroundStyle(.secondary) }
                        .padding(16)
                    Spacer()
                } else {
                    List {
                        Section {
                            HStack {
                                Image(systemName: "app").frame(width: 18)
                                Text("Application").font(.system(size: 12, weight: .medium))
                                Text(FSUtil.tilde(app.path)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(app.size.map(FSUtil.fmt) ?? "…").font(.system(size: 11)).monospacedDigit()
                            }
                        }
                        Section(u.leftovers.isEmpty ? "No leftover files found" : "Leftover files") {
                            ForEach($u.leftovers) { $l in
                                HStack(spacing: 8) {
                                    Toggle("", isOn: $l.selected).toggleStyle(.checkbox).labelsHidden()
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 4) {
                                            Text(l.kind).font(.system(size: 12, weight: .medium))
                                            if l.system { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.orange).help("System-wide file – asks for your admin password") }
                                        }
                                        Text(FSUtil.tilde(l.path)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(FSUtil.fmt(l.size)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                                    Button { FSUtil.reveal(l.path) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                }
                Divider()
                HStack {
                    if let m = u.message { Text(m).font(.system(size: 12)).foregroundStyle(.secondary) }
                    Spacer()
                    Toggle("Delete permanently", isOn: $permanent).toggleStyle(.checkbox)
                    let total = (app.size ?? 0) + u.leftovers.filter(\.selected).reduce(0) { $0 + $1.size }
                    Button(role: .destructive) { confirm = true } label: {
                        if u.working { ProgressView().controlSize(.small) } else { Text("Uninstall · \(FSUtil.fmt(total))") }
                    }
                    .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                    .disabled(u.working || u.findingLeftovers)
                    .confirmationDialog("Uninstall \(app.name)?", isPresented: $confirm) {
                        Button(permanent ? "Delete permanently" : "Move to Trash", role: .destructive) { u.uninstall(permanently: permanent) }
                    } message: {
                        Text("The app will be quit if it is running. \(u.leftovers.filter(\.selected).count) leftover item(s) will also be removed."
                             + (u.leftovers.contains { $0.selected && $0.system } ? " System-wide files need your admin password." : ""))
                    }
                }
                .padding(12)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text("Select an app, or drop one here").foregroundStyle(.secondary)
                if let m = u.message { Text(m).font(.system(size: 12)).foregroundStyle(.green) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AppRow: View {
    let app: AppEntry
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(app.lastUsed.map { "Used \($0.formatted(.relative(presentation: .named)))" } ?? "Never used")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(app.size.map(FSUtil.fmt) ?? "…").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

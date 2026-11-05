import SwiftUI

struct OptimizeView: View {
    @ObservedObject var o: Optimizer

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(tab: .optimize) { EmptyView() }
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($o.tasks) { $t in
                        HStack(spacing: 12) {
                            Toggle("", isOn: $t.selected).toggleStyle(.checkbox).labelsHidden().disabled(o.running)
                            Image(systemName: t.icon).font(.system(size: 15)).foregroundStyle(.orange).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(t.title).font(.system(size: 13, weight: .semibold))
                                    if t.needsAdmin {
                                        Image(systemName: "touchid").font(.system(size: 11)).foregroundStyle(.pink)
                                            .help("Needs admin rights – confirmed with Touch ID")
                                    }
                                }
                                Text(t.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            state(t.state)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.045)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Text("Tasks marked with Touch ID run with admin rights.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { o.runSelected() } label: {
                    if o.running { ProgressView().controlSize(.small) } else { Text("Run selected").frame(minWidth: 100) }
                }
                .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large)
                .disabled(o.running || !o.tasks.contains(where: \.selected))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    @ViewBuilder private func state(_ s: OptTask.State) -> some View {
        switch s {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Failed or cancelled")
        }
    }
}

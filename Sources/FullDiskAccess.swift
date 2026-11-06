import AppKit
import SwiftUI

/// Full Disk Access: macOS never lists an app under Privacy & Security › Full Disk Access by itself – the
/// user has to add it with "+" (or drag it in). So instead of just opening Settings we show a small guide
/// next to it with a draggable StatBar icon, and watch for the permission to arrive.
enum FullDiskAccess {
    /// Reading the TCC folder only works with Full Disk Access.
    static var granted: Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: "/Library/Application Support/com.apple.TCC")) != nil
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Opens the Full Disk Access pane together with the drag-in guide.
    @MainActor static func requestGuided() {
        NSWorkspace.shared.open(settingsURL)
        FDAGuide.shared.show()
    }
}

@MainActor
final class FDAGuide: NSObject, NSWindowDelegate {
    static let shared = FDAGuide()
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
                            backing: .buffered, defer: false)
            p.title = "Full Disk Access"
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isFloatingPanel = true
            p.level = .floating                       // stays above System Settings
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            p.delegate = self
            p.contentView = NSHostingView(rootView: FDAGuideView { [weak self] in self?.panel?.close() })
            panel = p
        }
        guard let p = panel else { return }
        // to the right of where System Settings opens (screen centre)
        if let s = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: min(s.maxX - p.frame.width - 24, s.midX + 330), y: s.midY - p.frame.height / 2 + 40))
        }
        p.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {}
}

private struct FDAGuideView: View {
    let close: () -> Void
    @State private var granted = FullDiskAccess.granted
    @State private var waited = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 14) {
            if granted {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(.green).padding(.top, 40)
                Text("Full Disk Access granted").font(.system(size: 15, weight: .semibold))
                Text("StatBar can now clean and analyze everything.").font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 0)
                Button("Done", action: close).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Text("Give StatBar Full Disk Access").font(.system(size: 15, weight: .semibold)).padding(.top, 30)
                // the icon itself can be dropped onto the list in System Settings
                VStack(spacing: 6) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable().frame(width: 64, height: 64)
                        .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                        .help("Drag me into the Full Disk Access list")
                    Text("Drag this icon into the list").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(Color.accentColor.opacity(0.6)))

                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Drag the icon above into the Full Disk Access list – or click **+** and choose **StatBar** in Applications.")
                    step(2, "Turn on the switch next to StatBar.")
                    step(3, "If StatBar is already listed but access doesn't work, remove it with **−** and add it again.")
                }
                .font(.system(size: 11.5))
                Spacer(minLength: 0)
                HStack {
                    Button("Open Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                    Spacer()
                    if waited >= 8 {
                        // macOS often applies the permission only after a restart of the app
                        Button("Quit & Reopen") { UpdateInstaller.relaunch() }.help("Some Macs apply the permission only after StatBar restarts")
                    } else {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small).scaleEffect(0.7)
                            Text("Waiting…").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 16)
        .frame(width: 300, height: 400)
        .onReceive(timer) { _ in
            guard !granted else { return }
            if FullDiskAccess.granted { withAnimation { granted = true } } else { waited += 1 }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                .frame(width: 17, height: 17).background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

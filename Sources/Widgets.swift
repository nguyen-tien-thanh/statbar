import SwiftUI

// Building blocks for the popover + in-popover settings page.

/// Circular progress ring, starts at 12 o'clock.
struct RingGauge: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 6
    var body: some View {
        let f = min(max(fraction, 0), 1)
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(f, 0.002))
                .stroke(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.35), value: f)
    }
}

/// Ring with the value in the middle, title + one detail line underneath.
struct GaugeTile: View {
    let title: String
    let value: String
    var unit: String = "%"
    let fraction: Double
    let color: Color
    var detail: String? = nil
    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RingGauge(fraction: fraction, color: color, lineWidth: 5.5)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(unit).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary)
                }
                .lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 7)
            }
            .frame(width: 58, height: 58)
            Text(title).font(.system(size: 11, weight: .semibold))
            Text(detail ?? " ").font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// Small rounded square with a tinted SF Symbol.
struct IconBadge: View {
    let icon: String
    let color: Color
    var size: CGFloat = 26
    var body: some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(color.opacity(0.16)))
    }
}

/// Uppercase caption above a group.
struct SectionLabel: View {
    let title: String
    var trailing: AnyView? = nil
    init(_ title: String, trailing: AnyView? = nil) { self.title = title; self.trailing = trailing }
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).kerning(0.6).foregroundStyle(.secondary)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 4)
    }
}

/// Grouped surface with no inner padding opinions beyond a default.
struct Surface<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
    }
}

/// Pill-style segmented control with an animated selection.
struct Segmented<T: Hashable>: View {
    let options: [(value: T, label: String)]
    let selection: T
    var tint: Color = .accentColor
    var compact = false
    let onSelect: (T) -> Void
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i], on = o.value == selection
                Button { withAnimation(.easeOut(duration: 0.18)) { onSelect(o.value) } } label: {
                    Text(o.label)
                        .font(.system(size: 11, weight: on ? .semibold : .medium))
                        .lineLimit(1).fixedSize()
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.8))
                        .padding(.horizontal, compact ? 8 : 10).padding(.vertical, 4)
                        .frame(maxWidth: compact ? nil : .infinity)
                        .background {
                            if on { Capsule().fill(tint).matchedGeometryEffect(id: "sel", in: ns) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}

/// Square-ish toggle tile: icon, title, On/Off state.
struct ToggleTile: View {
    let icon: String
    let title: String
    let on: Bool
    let tint: Color
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(on ? tint : Color.primary.opacity(0.1)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 11.5, weight: .semibold))
                    Text(on ? "On" : "Off").font(.system(size: 10)).foregroundStyle(on ? tint : .secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(on ? tint.opacity(0.14) : Color.primary.opacity(hover ? 0.08 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Compact selectable chip (menu bar item picker).
struct ToggleChip: View {
    let icon: String
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).frame(width: 14)
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12)).foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.6))
            }
            .foregroundStyle(on ? Color.primary : Color.primary.opacity(0.75))
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(on ? Color.accentColor.opacity(0.13) : Color.primary.opacity(hover ? 0.08 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(on ? Color.accentColor.opacity(0.45) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Title (+ optional subtitle) on the left, any control on the right.
struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let subtitle { Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 7)
    }
}

/// Circular icon button used in headers.
struct CircleIconButton: View {
    let icon: String
    var help: String = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(hover ? Color.primary : Color.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.12 : 0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Small filled capsule button.
struct CapsuleButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color = .accentColor
    var prominent = true
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(prominent ? Color.white : tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(prominent ? tint.opacity(hover ? 0.85 : 1) : tint.opacity(hover ? 0.2 : 0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

extension MenuItemKind {
    var icon: String {
        switch self {
        case .cpu: "cpu"; case .gpu: "square.stack.3d.up"; case .mem: "memorychip"; case .temp: "thermometer.medium"
        case .net: "arrow.up.arrow.down"; case .disk: "internaldrive"; case .battery: "battery.75percent"
        }
    }
    var shortTitle: String {
        switch self {
        case .temp: "Temperature"; case .net: "Network"; case .disk: "Disk"
        default: title
        }
    }
}

/// "Update to x.y.z" → "Downloading 42%" → "Installing…" → app quits and reopens.
struct UpdateActionButton: View {
    @ObservedObject var updater: Updater
    var body: some View {
        switch updater.install {
        case .downloading(let p):
            progressPill(Text("Downloading \(Int(p * 100))%")) {
                ProgressView(value: p).progressViewStyle(.circular).controlSize(.mini).scaleEffect(0.75).frame(width: 12, height: 12)
            }
        case .installing:
            progressPill(Text("Installing…")) {
                ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 12, height: 12)
            }
        case .failed(let msg):
            CapsuleButton(title: "Retry update", icon: "arrow.clockwise", tint: .orange) { updater.installUpdate() }
                .help("Update failed: \(msg)\nClick to try again, or download it manually from Settings.")
        case .none:
            if updater.canSelfUpdate {
                CapsuleButton(title: "Update to \(updater.latest ?? "")", icon: "arrow.down.circle.fill", tint: .blue) { updater.installUpdate() }
                    .help("StatBar \(updater.latest ?? "") is available (you have \(updater.current)).\nClick to download it – StatBar quits, updates itself and reopens.")
            } else {
                CapsuleButton(title: "Download \(updater.latest ?? "")", icon: "arrow.down.circle.fill", tint: .blue) { updater.openDownload() }
                    .help("Move StatBar to the Applications folder to enable one-click updates.")
            }
        }
    }

    private func progressPill<I: View>(_ label: Text, @ViewBuilder icon: () -> I) -> some View {
        HStack(spacing: 5) {
            icon()
            label.font(.system(size: 11, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(Color.blue)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.blue.opacity(0.14)))
    }
}

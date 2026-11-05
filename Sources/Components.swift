import SwiftUI

struct Card<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct Tag: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color == .secondary ? Color.secondary : color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill((color == .secondary ? Color.primary : color).opacity(0.13)))
            .lineLimit(1)
    }
}

struct CardHeader: View {
    let icon: String
    let title: String
    let color: Color
    var tag: String? = nil
    var tagColor: Color = .secondary
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let tag { Tag(text: tag, color: tagColor) }
        }
    }
}

struct BigValue: View {
    let value: String
    let unit: String
    var size: CGFloat = 22
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
            Text(unit).font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .lineLimit(1).minimumScaleFactor(0.7)
    }
}

struct BarHistory: View {
    let values: [Double]
    let color: Color
    var body: some View {
        GeometryReader { geo in
            let n = max(values.count, 1)
            let gap: CGFloat = 2
            let w = max(1, (geo.size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(values.indices, id: \.self) { i in
                    let v = min(max(values[i], 0), 100)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(LinearGradient(colors: [color, color.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                        .frame(width: w, height: max(2, geo.size.height * v / 100))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var maxValue: Double? = nil
    var secondary: [Double]? = nil
    var secondaryColor: Color = .purple

    private func path(_ vals: [Double], in size: CGSize, top: Double, closed: Bool) -> Path {
        var p = Path()
        guard vals.count > 1 else { return p }
        let step = size.width / CGFloat(vals.count - 1)
        func y(_ v: Double) -> CGFloat { size.height - CGFloat(min(v, top) / top) * (size.height - 2) - 1 }
        p.move(to: CGPoint(x: 0, y: y(vals[0])))
        for i in 1..<vals.count {
            let p0 = CGPoint(x: CGFloat(i - 1) * step, y: y(vals[i - 1]))
            let p1 = CGPoint(x: CGFloat(i) * step, y: y(vals[i]))
            let mid = (p0.x + p1.x) / 2
            p.addCurve(to: p1, control1: CGPoint(x: mid, y: p0.y), control2: CGPoint(x: mid, y: p1.y))
        }
        if closed {
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.addLine(to: CGPoint(x: 0, y: size.height))
            p.closeSubpath()
        }
        return p
    }

    var body: some View {
        GeometryReader { geo in
            let top = max(maxValue ?? ((values + (secondary ?? [])).max() ?? 1) * 1.15, 0.0001)
            ZStack {
                path(values, in: geo.size, top: top, closed: true)
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                path(values, in: geo.size, top: top, closed: false)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                if let secondary {
                    path(secondary, in: geo.size, top: top, closed: false)
                        .stroke(secondaryColor.opacity(0.8), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

struct Meter: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 8
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

struct PillButton: View {
    let title: String
    var icon: String? = nil
    let active: Bool
    var tint: Color = .accentColor
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(Capsule().fill(active ? tint : Color.primary.opacity(hover ? 0.16 : 0.09)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ToolTile: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                Text(title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                if let subtitle { Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hover ? 0.1 : 0.0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

extension Color {
    static func level(_ v: Double, warn: Double = 60, crit: Double = 85) -> Color {
        v >= crit ? Color.red : v >= warn ? Color.orange : .secondary
    }
    static let cpuC = Color(red: 0.30, green: 0.80, blue: 0.55)
    static let gpuC = Color(red: 1.0, green: 0.62, blue: 0.30)
    static let memC = Color(red: 0.95, green: 0.78, blue: 0.40)
    static let diskC = Color(red: 0.40, green: 0.62, blue: 1.0)
    static let netC = Color(red: 0.25, green: 0.75, blue: 1.0)
    static let fanC = Color(red: 0.85, green: 0.65, blue: 0.40)
    static let batC = Color(red: 0.35, green: 0.85, blue: 0.40)
}

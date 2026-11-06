import SwiftUI

/// Compact, iStat-style stacked text rendered into a template image for the menu bar.
struct StatusLabel: View {
    let m: Monitor
    let items: Set<MenuItemKind>
    let fahrenheit: Bool
    var order: [MenuItemKind] = Settings.shared.menuOrder

    var body: some View {
        HStack(spacing: 6) {
            ForEach(order.filter { items.contains($0) }) { k in cell(k) }
        }
        .foregroundStyle(Color.black)
        .padding(.horizontal, 1)
        .frame(height: 22)
    }

    @ViewBuilder private func cell(_ k: MenuItemKind) -> some View {
        switch k {
        case .cpu: stat("CPU", "\(Int(m.cpu.rounded()))%")
        case .gpu: stat("GPU", "\(Int(m.gpu.rounded()))%")
        case .mem: stat("MEM", "\(Int(m.memPercent.rounded()))%")
        case .temp:
            let t = m.sensors.cpuTemp.map { fahrenheit ? $0 * 9 / 5 + 32 : $0 }
            stat("TEMP", t.map { "\(Int($0.rounded()))°" } ?? "–")
        case .disk:
            let (v, u) = Fmt.bytes(Double(m.disk.free), decimals: 0)
            stat("SSD", v + String(u.prefix(1)))
        case .battery: stat("BAT", "\(m.battery.percent)%")
        case .net:
            VStack(alignment: .trailing, spacing: -1) {
                Text("\(Fmt.shortRate(m.net.up)) ↑")
                Text("\(Fmt.shortRate(m.net.down)) ↓")
            }
            .font(.system(size: 9, weight: .semibold).monospacedDigit())
            .frame(width: 50, alignment: .trailing)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: -2) {
            Text(label).font(.system(size: 7.5, weight: .bold))
            Text(value).font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
        .frame(minWidth: 28)
    }
}

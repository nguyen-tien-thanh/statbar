// Renders the app icon into an .iconset folder. usage: swift make_icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.15, blue: 0.13, alpha: 1), NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1)])!
        .draw(in: bg, angle: -90)
    // bars
    let colors: [NSColor] = [.init(red: 0.30, green: 0.80, blue: 0.55, alpha: 1), .init(red: 0.95, green: 0.78, blue: 0.40, alpha: 1),
                             .init(red: 0.40, green: 0.62, blue: 1.0, alpha: 1), .init(red: 1.0, green: 0.55, blue: 0.35, alpha: 1)]
    let heights: [CGFloat] = [0.42, 0.62, 0.34, 0.52]
    let bw = r.width * 0.12, gap = r.width * 0.07
    let total = bw * 4 + gap * 3
    var x = r.midX - total / 2
    let base = r.minY + r.height * 0.2
    for i in 0..<4 {
        let h = r.height * heights[i]
        colors[i].setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: base, width: bw, height: h), xRadius: bw * 0.35, yRadius: bw * 0.35).fill()
        x += bw + gap
    }
    // pulse line
    let line = NSBezierPath()
    line.lineWidth = max(1, r.width * 0.035); line.lineCapStyle = .round; line.lineJoinStyle = .round
    let y0 = r.minY + r.height * 0.78
    line.move(to: NSPoint(x: r.minX + r.width * 0.12, y: y0))
    line.line(to: NSPoint(x: r.minX + r.width * 0.38, y: y0))
    line.line(to: NSPoint(x: r.minX + r.width * 0.46, y: y0 + r.height * 0.09))
    line.line(to: NSPoint(x: r.minX + r.width * 0.54, y: y0 - r.height * 0.09))
    line.line(to: NSPoint(x: r.minX + r.width * 0.62, y: y0))
    line.line(to: NSPoint(x: r.minX + r.width * 0.88, y: y0))
    NSColor.white.withAlphaComponent(0.9).setStroke()
    line.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! draw(base).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base).png"))
    try! draw(base * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(base)x\(base)@2x.png"))
}

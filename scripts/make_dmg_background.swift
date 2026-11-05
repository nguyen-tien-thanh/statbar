// Renders the DMG window background (1x + 2x PNG). usage: swift make_dmg_background.swift <outdir>
// Layout (points, top-left origin) must match the icon positions in build.sh:
//   StatBar.app (160,175)   Applications (480,175)   guide (500,345)   window 640x440
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let W: CGFloat = 640, H: CGFloat = 440

func draw(scale: CGFloat) -> Data {
    let px = Int(W * scale), py = Int(H * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: py, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    let base = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: base.cgContext, flipped: true)
    // flip so we can think in Finder's top-left coordinates
    let t = NSAffineTransform(); t.translateX(by: 0, yBy: H); t.scaleX(by: 1, yBy: -1); t.concat()

    // background
    NSGradient(colors: [NSColor(red: 0.975, green: 0.975, blue: 0.98, alpha: 1),
                        NSColor(red: 0.925, green: 0.93, blue: 0.945, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, x: CGFloat, y: CGFloat,
              width: CGFloat, align: NSTextAlignment = .center) {
        let p = NSMutableParagraphStyle(); p.alignment = align; p.lineSpacing = 2
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color, .paragraphStyle: p]
        NSAttributedString(string: s, attributes: a).draw(with: NSRect(x: x, y: y, width: width, height: 200),
                                                         options: [.usesLineFragmentOrigin])
    }
    let ink = NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1)
    let muted = NSColor(red: 0.42, green: 0.43, blue: 0.47, alpha: 1)
    let accent = NSColor(red: 0.16, green: 0.47, blue: 0.96, alpha: 1)

    // title
    text("Kéo StatBar vào Applications để cài đặt", 19, .semibold, ink, x: 0, y: 30, width: W)
    text("Drag StatBar onto the Applications folder", 12.5, .regular, muted, x: 0, y: 58, width: W)

    // arrow between the two icons
    let ay: CGFloat = 168, ax0: CGFloat = 245, ax1: CGFloat = 395
    let shaft = NSBezierPath()
    shaft.lineWidth = 5; shaft.lineCapStyle = .round
    shaft.setLineDash([0.1, 12], count: 2, phase: 0)
    shaft.move(to: NSPoint(x: ax0, y: ay)); shaft.line(to: NSPoint(x: ax1 - 18, y: ay))
    accent.withAlphaComponent(0.85).setStroke(); shaft.stroke()
    let head = NSBezierPath()
    head.lineWidth = 5; head.lineCapStyle = .round; head.lineJoinStyle = .round
    head.move(to: NSPoint(x: ax1 - 14, y: ay - 13)); head.line(to: NSPoint(x: ax1, y: ay)); head.line(to: NSPoint(x: ax1 - 14, y: ay + 13))
    accent.setStroke(); head.stroke()

    // first-launch card
    let card = NSRect(x: 24, y: 272, width: W - 48, height: 148)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
    NSColor.white.withAlphaComponent(0.85).setFill(); cardPath.fill()
    NSColor(white: 0, alpha: 0.08).setStroke(); cardPath.lineWidth = 1; cardPath.stroke()

    // numbered badge
    let badge = NSRect(x: 48, y: 296, width: 24, height: 24)
    NSColor(red: 1.0, green: 0.62, blue: 0.18, alpha: 1).setFill()
    NSBezierPath(ovalIn: badge).fill()
    text("!", 15, .bold, .white, x: badge.minX, y: badge.minY + 2.5, width: badge.width)

    let tx: CGFloat = 84, tw: CGFloat = 300
    text("Lần đầu mở bị macOS chặn?", 15, .semibold, ink, x: tx, y: 298, width: tw, align: .left)
    text("StatBar chưa đăng ký với Apple nên macOS sẽ hỏi lại một lần. Mở \u{201C}Hướng dẫn cài đặt\u{201D}, bấm nút để vào thẳng System Settings rồi chọn \u{201C}Open Anyway\u{201D}.",
         12, .regular, muted, x: tx, y: 322, width: tw, align: .left)
    text("Blocked on first launch? Open the guide \u{2192}", 11, .medium, accent, x: tx, y: 388, width: tw, align: .left)

    // small arrow pointing to the guide icon
    let g = NSBezierPath(); g.lineWidth = 2.5; g.lineCapStyle = .round; g.lineJoinStyle = .round
    g.move(to: NSPoint(x: 400, y: 345)); g.line(to: NSPoint(x: 438, y: 345))
    g.move(to: NSPoint(x: 430, y: 338)); g.line(to: NSPoint(x: 438, y: 345)); g.line(to: NSPoint(x: 430, y: 352))
    accent.withAlphaComponent(0.7).setStroke(); g.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! draw(scale: 1).write(to: URL(fileURLWithPath: "\(out)/background.png"))
try! draw(scale: 2).write(to: URL(fileURLWithPath: "\(out)/background@2x.png"))

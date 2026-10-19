// Renders Player/AppIcon.icns: a deep-violet squircle with a forward "flick" play glyph and motion streaks.
import AppKit
_ = NSApplication.shared
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        let inset = s * 0.1, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
        let shape = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
        NSGraphicsContext.current?.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor(white: 0, alpha: 0.35); sh.shadowBlurRadius = s * 0.025; sh.shadowOffset = NSSize(width: 0, height: -s * 0.012); sh.set()
        NSColor.black.setFill(); shape.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSGradient(colors: [NSColor(red: 0.32, green: 0.16, blue: 0.95, alpha: 1), NSColor(red: 0.95, green: 0.22, blue: 0.55, alpha: 1)])!
            .draw(in: shape, angle: -55)
        NSGradient(colors: [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0)])!
            .draw(in: NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: r.width * 0.22, yRadius: r.width * 0.22), angle: -90)
        // play triangle, slightly right of centre
        let c = NSPoint(x: r.midX + r.width * 0.07, y: r.midY), h = r.width * 0.42
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: c.x - h * 0.42, y: c.y + h / 2))
        tri.line(to: NSPoint(x: c.x + h * 0.5, y: c.y))
        tri.line(to: NSPoint(x: c.x - h * 0.42, y: c.y - h / 2))
        tri.close()
        tri.lineJoinStyle = .round; tri.lineWidth = h * 0.12
        NSColor.white.setFill(); NSColor.white.setStroke(); tri.fill(); tri.stroke()
        // motion streaks
        for (i, len) in [0.16, 0.23, 0.16].enumerated() {
            let y = c.y + CGFloat(i - 1) * h * 0.26
            let x1 = c.x - h * 0.62, x0 = x1 - r.width * CGFloat(len)
            let p = NSBezierPath(); p.move(to: NSPoint(x: x0, y: y)); p.line(to: NSPoint(x: x1, y: y))
            p.lineWidth = h * 0.085; p.lineCapStyle = .round
            NSColor(white: 1, alpha: 0.55 + 0.2 * Double(1 - abs(i - 1))).setStroke(); p.stroke()
        }
        return true
    }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let dir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (n, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(n).png"))
}

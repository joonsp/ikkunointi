// Renders Resources/AppIcon.icns: a dwindle layout of three tiles with a Hyprland-style
// gradient border on the focused one. Run: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // macOS icon grid: ~10% margin, squircle-ish rounded square.
    let body = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let bg = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(srgbRed: 0.09, green: 0.10, blue: 0.16, alpha: 1),
                        NSColor(srgbRed: 0.04, green: 0.05, blue: 0.09, alpha: 1)])!.draw(in: bg, angle: -90)

    let pad = s * 0.075, gap = s * 0.035
    let inner = body.insetBy(dx: pad, dy: pad)
    let leftW = (inner.width - gap) * 0.55
    let left = CGRect(x: inner.minX, y: inner.minY, width: leftW, height: inner.height)
    let rightX = left.maxX + gap, rightW = inner.maxX - rightX
    let topH = (inner.height - gap) / 2
    let topRight = CGRect(x: rightX, y: inner.minY + topH + gap, width: rightW, height: topH)
    let bottomRight = CGRect(x: rightX, y: inner.minY, width: rightW, height: topH)
    let r = s * 0.045
    for tile in [topRight, bottomRight] {
        NSColor(srgbRed: 0.20, green: 0.23, blue: 0.33, alpha: 1).setFill()
        NSBezierPath(roundedRect: tile, xRadius: r, yRadius: r).fill()
    }
    // Focused tile with gradient border (rgba(33ccff) -> rgba(00ff99), 45deg).
    NSColor(srgbRed: 0.13, green: 0.15, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(roundedRect: left, xRadius: r, yRadius: r).fill()
    let lw = max(1, s * 0.022)
    let ring = NSBezierPath(roundedRect: left.insetBy(dx: lw / 2, dy: lw / 2), xRadius: r, yRadius: r)
    ring.lineWidth = lw
    ctx.saveGState()
    ctx.addPath(ring.cgPath)
    ctx.setLineWidth(lw)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    NSGradient(colors: [NSColor(srgbRed: 0.2, green: 0.8, blue: 1, alpha: 1), NSColor(srgbRed: 0, green: 1, blue: 0.6, alpha: 1)])!
        .draw(in: left, angle: 45)
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")

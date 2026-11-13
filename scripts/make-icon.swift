// Renders Support/AppIcon.icns: the Pulse ring on a deep glass-like squircle.
//   swift scripts/make-icon.swift
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: 824 pt body centered in 1024, continuous corners.
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: body, xRadius: 186 * s, yRadius: 186 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [
        NSColor(red: 0.16, green: 0.12, blue: 0.36, alpha: 1),
        NSColor(red: 0.06, green: 0.10, blue: 0.24, alpha: 1),
    ])!.draw(in: body, angle: -90)
    // Soft coral and blue glows, like the wallpaper the panel floats over.
    NSGradient(colors: [NSColor(red: 0.98, green: 0.50, blue: 0.32, alpha: 0.55), .clear])!
        .draw(fromCenter: NSPoint(x: 250 * s, y: 180 * s), radius: 0, toCenter: NSPoint(x: 250 * s, y: 180 * s), radius: 520 * s, options: [])
    NSGradient(colors: [NSColor(red: 0.20, green: 0.45, blue: 1.0, alpha: 0.45), .clear])!
        .draw(fromCenter: NSPoint(x: 860 * s, y: 760 * s), radius: 0, toCenter: NSPoint(x: 860 * s, y: 760 * s), radius: 480 * s, options: [])
    // Top sheen.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.16), .clear])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.18).setStroke()
    shape.lineWidth = 3 * s
    shape.stroke()

    // The ring: track, three-quarter arc, center dot.
    let center = NSPoint(x: 512 * s, y: 512 * s)
    let radius = 230 * s
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = 64 * s
    NSColor.white.withAlphaComponent(0.22).setStroke()
    track.stroke()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 270, clockwise: true)
    arc.lineWidth = 64 * s
    arc.lineCapStyle = .round
    NSColor.white.setStroke()
    arc.stroke()

    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 70 * s, y: center.y - 70 * s, width: 140 * s, height: 140 * s)).fill()

    // The "waiting for you" badge.
    NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 700 * s, y: 690 * s, width: 104 * s, height: 104 * s)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try png.write(to: iconset.appending(path: name))
    }
}
try render(size: 1024).representation(using: .png, properties: [:])!.write(to: root.appending(path: "docs/icon.png"))
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Support/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
print("Wrote Support/AppIcon.icns and docs/icon.png")

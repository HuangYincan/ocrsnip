import AppKit

// Canonical, resolution-independent artwork. No fonts or external image tools required.
func drawIcon() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 88, y: 88, width: 848, height: 848), xRadius: 190, yRadius: 190)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor(srgbRed: 0.13, green: 0.22, blue: 0.68, alpha: 1).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [
        NSColor(srgbRed: 0.16, green: 0.25, blue: 0.70, alpha: 1),
        NSColor(srgbRed: 0.25, green: 0.43, blue: 0.95, alpha: 1)
    ])!.draw(in: tile, angle: 65)
    NSColor.white.withAlphaComponent(0.16).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    // Rounded capture corners remain legible in the 16px representation.
    NSColor.white.setStroke()
    for (x, y, dx, dy) in [(282.0, 742.0, 1.0, -1.0), (742, 742, -1, -1),
                           (282, 282, 1, 1), (742, 282, -1, 1)] {
        let corner = NSBezierPath()
        corner.lineWidth = 38
        corner.lineCapStyle = .round
        corner.lineJoinStyle = .round
        corner.move(to: NSPoint(x: x, y: y + dy * 102))
        corner.line(to: NSPoint(x: x, y: y))
        corner.line(to: NSPoint(x: x + dx * 102, y: y))
        corner.stroke()
    }

    // A geometric T and two text strokes communicate OCR without a wordmark.
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 370, y: 578, width: 284, height: 52), xRadius: 13, yRadius: 13).fill()
    NSBezierPath(roundedRect: NSRect(x: 486, y: 416, width: 52, height: 190), xRadius: 13, yRadius: 13).fill()
    NSColor.white.withAlphaComponent(0.55).setFill()
    NSBezierPath(roundedRect: NSRect(x: 373, y: 349, width: 140, height: 25), xRadius: 12, yRadius: 12).fill()
    NSBezierPath(roundedRect: NSRect(x: 538, y: 349, width: 112, height: 25), xRadius: 12, yRadius: 12).fill()

    NSColor(srgbRed: 0.45, green: 0.98, blue: 0.80, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 666, y: 179, width: 180, height: 180)).fill()
    let check = NSBezierPath()
    check.lineWidth = 20
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.move(to: NSPoint(x: 716, y: 268))
    check.line(to: NSPoint(x: 746, y: 238))
    check.line(to: NSPoint(x: 797, y: 298))
    NSColor(srgbRed: 0.10, green: 0.28, blue: 0.42, alpha: 1).setStroke()
    check.stroke()
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

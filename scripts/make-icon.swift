import AppKit

// Draws the Navette app icon (a weaving shuttle going back and forth on a teal-to-indigo tile) into the
// given AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift Navette/Resources/Assets.xcassets/AppIcon.appiconset [icon.png]
// The optional second argument also writes a 512 px copy (used by the README).
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// A curved stroke ending in an arrow head: one direction of the shuttle's travel.
func drawArrow(center: NSPoint, radius: CGFloat, from start: CGFloat, to end: CGFloat, width: CGFloat, alpha: CGFloat) {
    let arc = NSBezierPath()
    arc.lineWidth = width
    arc.lineCapStyle = .round
    arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: end < start)
    color(1, 1, 1, alpha).setStroke()
    arc.stroke()

    // The head sits at the end of the arc, pointing along its tangent.
    let angle = end * .pi / 180
    let tip = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    let direction = angle + (end < start ? -1 : 1) * .pi / 2
    let head = NSBezierPath()
    let size = width * 2.1
    head.move(to: NSPoint(x: tip.x + cos(direction) * size, y: tip.y + sin(direction) * size))
    head.line(to: NSPoint(x: tip.x + cos(direction + 2.2) * size, y: tip.y + sin(direction + 2.2) * size))
    head.line(to: NSPoint(x: tip.x + cos(direction - 2.2) * size, y: tip.y + sin(direction - 2.2) * size))
    head.close()
    color(1, 1, 1, alpha).setFill()
    head.fill()
}

func drawShuttle(in context: CGContext) {
    context.saveGState()
    context.translateBy(x: 512, y: 512)
    context.rotate(by: -22 * .pi / 180)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -16)
    shadow.set()
    // The shuttle: a pointed oval.
    let body = NSBezierPath()
    body.move(to: NSPoint(x: -330, y: 0))
    body.curve(to: NSPoint(x: 330, y: 0), controlPoint1: NSPoint(x: -160, y: 200), controlPoint2: NSPoint(x: 160, y: 200))
    body.curve(to: NSPoint(x: -330, y: 0), controlPoint1: NSPoint(x: 160, y: -200), controlPoint2: NSPoint(x: -160, y: -200))
    body.close()
    NSGradient(starting: color(1, 1, 1), ending: color(0.90, 0.95, 1.0))!.draw(in: body, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // The bobbin of thread it carries.
    let bobbin = NSBezierPath(roundedRect: NSRect(x: -150, y: -58, width: 300, height: 116), xRadius: 58, yRadius: 58)
    NSGradient(starting: color(1.0, 0.78, 0.25), ending: color(0.98, 0.45, 0.20))!.draw(in: bobbin, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    bobbin.addClip()
    color(1, 1, 1, 0.35).setStroke()
    for offset in stride(from: -190, through: 190, by: 38) {
        let thread = NSBezierPath()
        thread.lineWidth = 9
        thread.move(to: NSPoint(x: CGFloat(offset) - 30, y: -70))
        thread.line(to: NSPoint(x: CGFloat(offset) + 30, y: 70))
        thread.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    context.restoreGState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0.08, 0.72, 0.65), ending: color(0.39, 0.40, 0.95))!.draw(in: tile, angle: -60)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    // There and back: one arrow above the shuttle, one below.
    drawArrow(center: NSPoint(x: 512, y: 250), radius: 520, from: 122, to: 62, width: 30, alpha: 0.55)
    drawArrow(center: NSPoint(x: 512, y: 774), radius: 520, from: 302, to: 242, width: 30, alpha: 0.55)
    NSGraphicsContext.restoreGraphicsState()

    drawShuttle(in: context)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let variants: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for variant in variants {
    let suffix = variant.scale == 2 ? "@2x" : ""
    let filename = "icon_\(variant.points)x\(variant.points)\(suffix).png"
    try render(pixels: variant.points * variant.scale).write(to: output.appendingPathComponent(filename))
    images.append(["size": "\(variant.points)x\(variant.points)", "idiom": "mac", "filename": filename, "scale": "\(variant.scale)x"])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
if CommandLine.arguments.count > 2 {
    try render(pixels: 512).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
print("AppIcon written to \(output.path)")

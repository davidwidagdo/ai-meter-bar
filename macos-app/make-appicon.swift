// Regenerates AppIcon.png (1024x1024); build.sh turns the PNG into the bundle's AppIcon.icns.
import AppKit

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("could not create bitmap") }

func rgb(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

let ink = rgb(0x17181A)
let cream = rgb(0xEFE8DA)
let red = rgb(0xD8361E)
let pivot = NSPoint(x: 512, y: 176)
let arcRadius: CGFloat = 400

func point(_ radius: CGFloat, _ degrees: CGFloat) -> NSPoint {
    NSPoint(x: pivot.x + radius * cos(degrees * .pi / 180), y: pivot.y + radius * sin(degrees * .pi / 180))
}

func scaleArc(from: CGFloat, to: CGFloat, width: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.appendArc(withCenter: pivot, radius: arcRadius, startAngle: from, endAngle: to, clockwise: true)
    path.lineWidth = width
    color.setStroke()
    path.stroke()
}

func tick(_ degrees: CGFloat, length: CGFloat, width: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: point(arcRadius, degrees))
    path.line(to: point(arcRadius + length, degrees))
    path.lineWidth = width
    color.setStroke()
    path.stroke()
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// The standard macOS icon grid leaves a margin around the rounded square.
let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 22
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
ink.setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()

// A flat studio VU meter: paths and solid colours only, no SF Symbol or brand mark.
let face = NSBezierPath(roundedRect: NSRect(x: 172, y: 286, width: 680, height: 452), xRadius: 58, yRadius: 58)
cream.setFill()
face.fill()
face.addClip()

let redStart: CGFloat = 67.2
scaleArc(from: 128, to: redStart, width: 9, color: ink)
scaleArc(from: redStart, to: 52, width: 18, color: red)
let ticks = 11
for index in 0..<ticks {
    let degrees = 128 - CGFloat(index) * (76 / CGFloat(ticks - 1))
    let major = index % 2 == 0
    tick(degrees, length: major ? 84 : 52, width: major ? 15 : 11, color: degrees < redStart + 0.8 ? red : ink)
}

let needleAngle: CGFloat = 78.4
let normal = NSPoint(x: cos((needleAngle + 90) * .pi / 180), y: sin((needleAngle + 90) * .pi / 180))
let tip = point(462, needleAngle)
let needle = NSBezierPath()
needle.move(to: NSPoint(x: pivot.x + normal.x * 8, y: pivot.y + normal.y * 8))
needle.line(to: NSPoint(x: tip.x + normal.x * 3, y: tip.y + normal.y * 3))
needle.line(to: NSPoint(x: tip.x - normal.x * 3, y: tip.y - normal.y * 3))
needle.line(to: NSPoint(x: pivot.x - normal.x * 8, y: pivot.y - normal.y * 8))
needle.close()
ink.setFill()
needle.fill()
NSBezierPath(ovalIn: NSRect(x: 428, y: 202, width: 168, height: 168)).fill()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")

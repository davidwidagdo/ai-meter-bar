// Regenerates AppIcon.png (1024x1024); build.sh turns the PNG into the bundle's AppIcon.icns.
import AppKit

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let center = NSPoint(x: 512, y: 512)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("could not create bitmap") }

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func disc(_ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
}

func downward(_ path: NSBezierPath, _ top: NSColor, _ bottom: NSColor) {
    NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)
}

func rim(outer: CGFloat, inner: CGFloat, top: CGFloat, bottom: CGFloat) {
    let ring = disc(outer)
    ring.append(disc(inner).reversed)
    downward(ring, NSColor.white.withAlphaComponent(top), NSColor.white.withAlphaComponent(bottom))
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// The standard macOS icon grid leaves a margin around the rounded square.
let tileRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let tile = NSBezierPath(roundedRect: tileRect, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
rgb(0x090C16).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()
downward(tile, rgb(0x232C45), rgb(0x090C16))

let tileEdge = NSBezierPath(roundedRect: tileRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
tileEdge.append(NSBezierPath(roundedRect: tileRect.insetBy(dx: 4.5, dy: 4.5), xRadius: 181, yRadius: 181).reversed)
downward(tileEdge, NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0.02))

// A magic-eye tuning indicator in the macOS 27 wallpaper palette: paths and gradients only.
downward(disc(352), rgb(0x8A93B4), rgb(0x0C1020))
rgb(0x05070F).setFill()
disc(332).fill()

let lensRadius: CGFloat = 316
NSGraphicsContext.saveGraphicsState()
disc(lensRadius).addClip()
NSGradient(colors: [rgb(0xFFF1CF), rgb(0xFFC45A), rgb(0xF4822B), rgb(0xD8432F), rgb(0x8A3F7E), rgb(0x2F3F8C), rgb(0x141D4A)],
           atLocations: [0.18, 0.34, 0.5, 0.64, 0.78, 0.92, 1], colorSpace: .sRGB)?
    .draw(fromCenter: center, radius: 0, toCenter: center, radius: lensRadius, options: [])

let sheen = NSBezierPath(ovalIn: NSRect(x: 212, y: 572, width: 600, height: 250))
downward(sheen, NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0))

let wedgeHalfAngle: CGFloat = 21
for (spread, alpha) in [(5, 0.3), (2.5, 0.55), (0, 1)] as [(CGFloat, CGFloat)] {
    let wedge = NSBezierPath()
    wedge.move(to: center)
    wedge.appendArc(withCenter: center, radius: 350, startAngle: 90 - wedgeHalfAngle - spread, endAngle: 90 + wedgeHalfAngle + spread)
    wedge.close()
    rgb(0x070B1C, alpha).setFill()
    wedge.fill()
}
NSGraphicsContext.restoreGraphicsState()

rim(outer: lensRadius, inner: lensRadius - 6, top: 0.55, bottom: 0.06)
downward(disc(76), rgb(0x2E3654), rgb(0x090C18))
rim(outer: 76, inner: 72, top: 0.30, bottom: 0.02)

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")

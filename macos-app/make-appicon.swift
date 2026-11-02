// Regenerates AppIcon.png (1024x1024): a rounded-rect blue-to-teal gradient with a
// white bolt drawn as a path. build.sh turns the PNG into the bundle's AppIcon.icns.
//
//   swift make-appicon.swift            # writes AppIcon.png next to this file
//   swift make-appicon.swift out.png    # custom output path
//
import AppKit

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("could not create bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let full = NSRect(x: 0, y: 0, width: size, height: size)

// Rounded-rect (macOS squircle ratio) background with a blue -> teal gradient.
let bg = NSBezierPath(roundedRect: full, xRadius: size * 0.2237, yRadius: size * 0.2237)
bg.addClip()
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.10, green: 0.52, blue: 0.97, alpha: 1),  // blue (top)
    NSColor(srgbRed: 0.02, green: 0.70, blue: 0.76, alpha: 1),  // teal (bottom)
])!
gradient.draw(in: full, angle: -90)

// White lightning bolt drawn as a path: SF Symbols may not be used in app icons.
let boltPoints: [(CGFloat, CGFloat)] = [
    (0.58, 1.00), (0.06, 0.44), (0.40, 0.44), (0.30, 0.00), (0.84, 0.58), (0.50, 0.58),
]
let boltHeight = size * 0.56
let originX = (size - boltHeight * 0.78) / 2 - boltHeight * 0.06
let originY = (size - boltHeight) / 2
let bolt = NSBezierPath()
for (i, p) in boltPoints.enumerated() {
    let point = NSPoint(x: originX + p.0 * boltHeight, y: originY + p.1 * boltHeight)
    if i == 0 { bolt.move(to: point) } else { bolt.line(to: point) }
}
bolt.close()
bolt.lineJoinStyle = .round
bolt.lineWidth = size * 0.02
NSColor.white.set()
bolt.fill()
bolt.stroke()

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")

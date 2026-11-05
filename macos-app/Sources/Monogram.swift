import Cocoa

// Generated monograms, so a profile or launcher icon never copies a brand mark.
enum Monogram {
    static func letter(for name: String) -> String {
        name.first.map { String($0).uppercased() } ?? "?"
    }

    private static func draw(letter: String, hex: String, rect: NSRect, radius: CGFloat) {
        UI.color(hex: hex).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: rect.height * 0.47, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: letter, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    static func image(letter: String, hex: String, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(letter: letter, hex: hex, rect: rect, radius: size * 0.3)
            return true
        }
    }

    private static func png(letter: String, hex: String, pixels: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let side = CGFloat(pixels)
        // The standard macOS icon grid leaves a margin around the rounded square.
        draw(letter: letter, hex: hex, rect: NSRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 0.1, dy: side * 0.1), radius: side * 0.18)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    // Hands the caller an .icns that exists only for the duration of the closure.
    static func withIcon<T>(letter: String, hex: String, _ body: (URL?) throws -> T) rethrows -> T {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("aimeterbar-icon-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: folder) }
        let set = folder.appendingPathComponent("icon.iconset")
        let icns = folder.appendingPathComponent("icon.icns")
        guard (try? fm.createDirectory(at: set, withIntermediateDirectories: true)) != nil else { return try body(nil) }
        for base in [16, 32, 128, 256, 512] {
            try? png(letter: letter, hex: hex, pixels: base)?.write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
            try? png(letter: letter, hex: hex, pixels: base * 2)?.write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
        }
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        tool.arguments = ["-c", "icns", set.path, "-o", icns.path]
        tool.standardError = FileHandle.nullDevice
        guard (try? tool.run()) != nil else { return try body(nil) }
        tool.waitUntilExit()
        return try body(tool.terminationStatus == 0 ? icns : nil)
    }
}

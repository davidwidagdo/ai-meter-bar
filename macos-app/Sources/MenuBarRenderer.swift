import Cocoa

// One template image holds the icon and all columns, so macOS tints it for the menu bar.
enum MenuBarRenderer {
    enum State {
        case normal, lowQuota, needsLogin, working

        var symbol: String {
            switch self {
            case .normal:     return "gauge.with.dots.needle.67percent"
            case .lowQuota:   return "exclamationmark.triangle.fill"
            case .needsLogin: return "bolt.slash.fill"
            case .working:    return "arrow.triangle.2.circlepath"
            }
        }
    }

    struct Column {
        struct Row {
            let label: String
            let value: String
        }

        let rows: [Row]
        // Reserves the widest value, so items in the menu bar do not shift with each sample.
        var valueSample = ""
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    // Template images use only alpha, so this must stay fully opaque; do not use labelColor.
    private static let attrs: [NSAttributedString.Key: Any] =
        [.font: font, .foregroundColor: NSColor.black]

    private static func width(_ s: String) -> CGFloat {
        s.isEmpty ? 0 : ceil(NSAttributedString(string: s, attributes: attrs).size().width)
    }

    static func image(state: State, columns: [Column]) -> NSImage {
        let barH = NSStatusBar.system.thickness            // ~22pt
        let iconSize: CGFloat = 14
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let icon = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)

        guard !columns.isEmpty else {
            let img = icon ?? NSImage(size: NSSize(width: iconSize, height: iconSize))
            img.isTemplate = true
            return img
        }

        // Font metrics, not string metrics: an arrow's fallback font would shift the baselines.
        let lineH = min(ceil(font.ascender - font.descender + font.leading), floor(barH / 2))

        let iconGap: CGFloat = 3, labelGap: CGFloat = 3, colGap: CGFloat = 7
        let labelW = columns.map { col in col.rows.map { width($0.label) }.max() ?? 0 }
        let valueW = columns.map { col in
            max(width(col.valueSample), col.rows.map { width($0.value) }.max() ?? 0)
        }
        let colW = columns.indices.map { labelW[$0] + (labelW[$0] > 0 ? labelGap : 0) + valueW[$0] }
        let totalW = iconSize + iconGap + colW.reduce(0, +)
            + colGap * CGFloat(columns.count - 1) + 2

        let img = NSImage(size: NSSize(width: totalW, height: barH))
        img.lockFocus()

        // Icon, vertically centered (unflipped coords: origin bottom-left).
        if let icon = icon {
            let iy = (barH - iconSize) / 2
            icon.draw(in: NSRect(x: 0, y: iy, width: iconSize, height: iconSize),
                      from: .zero, operation: .sourceOver, fraction: 1)
        }

        var x = iconSize + iconGap
        for (i, col) in columns.enumerated() {
            let blockH = lineH * CGFloat(col.rows.count)
            let base = (barH - blockH) / 2                  // 1 row centers, 2 rows fill
            let valueX = x + labelW[i] + (labelW[i] > 0 ? labelGap : 0)
            for (r, row) in col.rows.enumerated() {
                let y = base + blockH - CGFloat(r + 1) * lineH
                if !row.label.isEmpty {
                    NSAttributedString(string: row.label, attributes: attrs)
                        .draw(at: NSPoint(x: x, y: y))
                }
                NSAttributedString(string: row.value, attributes: attrs)
                    .draw(at: NSPoint(x: valueX, y: y))
            }
            x += colW[i] + colGap
        }

        img.unlockFocus()
        img.isTemplate = true
        return img
    }
}

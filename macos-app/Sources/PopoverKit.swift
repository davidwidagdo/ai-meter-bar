import Cocoa

enum UI {
    // Every card's rows share these, so tiles, names and actions line up down the panel.
    static let tileSize: CGFloat = 30
    static let rowHeight: CGFloat = 40
    static let subRowHeight: CGFloat = 30
    static let actionWidth: CGFloat = 28
    static let cardPadding: CGFloat = 8
    static let rowSide: CGFloat = 6
    static let panelInset = cardPadding + rowSide

    static func insets(vertical: CGFloat = 0) -> NSEdgeInsets {
        NSEdgeInsets(top: vertical, left: rowSide, bottom: vertical, right: rowSide)
    }

    static let warn = dynamic(light: 0x8A3D07, dark: 0xFFA94D)
    static let critical = dynamic(light: 0x9B1C13, dark: 0xFFA39B)
    static let ok = dynamic(light: 0x14602F, dark: 0x5FD38A)

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            color(rgb: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }

    private static func color(rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    static func color(hex: String) -> NSColor {
        color(rgb: Int(hex.dropFirst(), radix: 16) ?? 0x5A5F6A)
    }

    static func label(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .monospacedDigitSystemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    static func sectionTitle(_ text: String) -> NSTextField {
        label(text, size: 12.5, weight: .semibold, color: .secondaryLabelColor)
    }

    static func wrappingLabel(_ text: String = "", size: CGFloat = 12, color: NSColor = .secondaryLabelColor, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.preferredMaxLayoutWidth = width
        fix(label, width: width)
        return label
    }

    static func symbol(_ name: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, description: String? = nil) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    static func row(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = spacing
        return stack
    }

    static func column(_ views: [NSView], spacing: CGFloat = 2) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    static func fix(_ view: NSView, width: CGFloat? = nil, height: CGFloat? = nil) {
        view.translatesAutoresizingMaskIntoConstraints = false
        if let width = width { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
        if let height = height { view.heightAnchor.constraint(equalToConstant: height).isActive = true }
    }

    static func flexible(_ view: NSView) {
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    static func gap(width: CGFloat) -> NSView {
        let view = NSView()
        fix(view, width: width, height: 1)
        return view
    }

    static func spacer() -> NSView {
        let view = NSView()
        flexible(view)
        return view
    }
}

final class ClosureButton: NSButton {
    var onClick: (() -> Void)?

    convenience init(title: String, primary: Bool = false, onClick: (() -> Void)? = nil) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        self.onClick = onClick
        target = self
        action = #selector(fire)
        if primary { keyEquivalent = "\r" }
    }

    convenience init(symbol: String, label: String, tint: NSColor = .secondaryLabelColor, onClick: (() -> Void)? = nil) {
        self.init(frame: .zero)
        image = UI.symbol(symbol, description: label)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = tint
        toolTip = label
        setAccessibilityLabel(label)
        self.onClick = onClick
        target = self
        action = #selector(fire)
        UI.fix(self, width: UI.actionWidth, height: UI.actionWidth)
    }

    @objc private func fire() {
        onClick?()
    }
}

// Plain fill, not glass: Liquid Glass is for chrome and these cards hold dense text.
final class CardView: NSView {
    // Set when the card acts as one button, so its text and padding take the click too.
    var clickTarget: NSButton?

    init(_ content: NSView, padding: CGFloat = UI.cardPadding) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard clickTarget != nil else { return super.hitTest(point) }
        return !isHidden && frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { clickTarget != nil }

    override func mouseDown(with event: NSEvent) {
        guard let clickTarget else { return super.mouseDown(with: event) }
        clickTarget.performClick(nil)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 18
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
    }
}

final class MeterView: NSView {
    var cell: QuotaCell = .unknown {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 5)
    }

    override func draw(_ dirtyRect: NSRect) {
        // No bar for an empty value, but the slot stays so its text keeps the same line.
        guard !cell.isUnknown else { return }
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2.5, yRadius: 2.5).fill()
        guard cell.fraction > 0 else { return }
        let width = max(3, bounds.width * CGFloat(min(1, cell.fraction)))
        let color: NSColor
        switch cell.level {
        case .normal:   color = .controlAccentColor
        case .low:      color = UI.warn
        case .critical: color = UI.critical
        }
        color.withAlphaComponent(cell.isStale ? 0.45 : 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: 2.5, yRadius: 2.5).fill()
    }
}

final class QuotaColumn: NSStackView {
    static let width: CGFloat = 54
    private let value = UI.label(size: 12, weight: .medium)
    private let meter = MeterView()

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
        addArrangedSubview(value)
        addArrangedSubview(meter)
        UI.fix(self, width: Self.width)
        meter.translatesAutoresizingMaskIntoConstraints = false
        meter.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func set(_ cell: QuotaCell, spoken: String) {
        value.stringValue = cell.text
        switch cell.level {
        case _ where cell.isUnknown: value.textColor = .secondaryLabelColor
        case .normal:   value.textColor = .labelColor
        case .low:      value.textColor = UI.warn
        case .critical: value.textColor = UI.critical
        }
        meter.cell = cell
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityLabel(spoken)
    }

    static func spoken(owner: String, window: String, cell: QuotaCell, showLeft: Bool) -> String {
        if cell.notReported { return "\(owner), \(window), not reported" }
        guard !cell.isUnknown else { return "\(owner), \(window), unknown" }
        let number = cell.text.replacingOccurrences(of: "~", with: "about ").replacingOccurrences(of: "%", with: " percent")
        return "\(owner), \(window), \(number) \(showLeft ? "left" : "used")"
    }
}

final class StatusDot: NSView {
    var filled: Bool { didSet { needsDisplay = true } }

    init(filled: Bool) {
        self.filled = filled
        super.init(frame: .zero)
        setAccessibilityElement(false)
        UI.fix(self, width: 7, height: 7)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        if filled {
            UI.ok.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        } else {
            NSColor.secondaryLabelColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.25
            ring.stroke()
        }
    }
}

final class TileView: NSImageView {
    init(letter: String, hex: String) {
        super.init(frame: .zero)
        configure(Monogram.image(letter: letter, hex: hex, size: UI.tileSize))
    }

    init(mark: ProviderMark) {
        super.init(frame: .zero)
        configure(mark.tile(size: UI.tileSize))
    }

    init(symbol: String, hex: String) {
        super.init(frame: .zero)
        // One configuration, so the white palette keeps the 15 pt semibold size.
        let style = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold).applying(.init(paletteColors: [.white]))
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(style)
        configure(NSImage(size: NSSize(width: UI.tileSize, height: UI.tileSize), flipped: false) { rect in
            UI.color(hex: hex).setFill()
            NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.3, yRadius: rect.height * 0.3).fill()
            if let glyph = glyph {
                let size = glyph.size
                glyph.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
            }
            return true
        })
    }

    required init?(coder: NSCoder) { nil }

    func set(letter: String, hex: String) {
        image = Monogram.image(letter: letter, hex: hex, size: UI.tileSize)
    }

    private func configure(_ tile: NSImage) {
        image = tile
        imageScaling = .scaleNone
        setAccessibilityElement(false)
        UI.fix(self, width: UI.tileSize, height: UI.tileSize)
    }
}

import Cocoa

final class UsageHistoryWindowController: NSWindowController, NSWindowDelegate,
                                          NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let week = UsageHistoryWindowController.statValue()
    private let month = UsageHistoryWindowController.statValue()
    private let peak = UsageHistoryWindowController.statValue()
    private var rows: [DayUsage] = []
    private var maxTotal: UInt64 = 1
    var onClose: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Meter Bar — Usage History"
        self.init(window: window)
        window.delegate = self
        window.isReleasedWhenClosed = false
        buildUI()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        configureColumns()
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.gridStyleMask = []
        // Let the last column absorb slack so widths fit and nothing is clipped.
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder

        // Round on a wrapper: layer-backing the scroll view breaks its column tiling.
        let tableBox = NSView()
        tableBox.translatesAutoresizingMaskIntoConstraints = false
        tableBox.wantsLayer = true
        tableBox.layer?.cornerRadius = 10
        tableBox.layer?.cornerCurve = .continuous
        tableBox.layer?.masksToBounds = true
        tableBox.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: tableBox.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: tableBox.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: tableBox.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: tableBox.trailingAnchor),
        ])

        let summaryBar = NSStackView(views: [
            stat("Last 7 days", week), stat("Last 30 days", month), stat("Today's peak", peak),
        ])
        summaryBar.orientation = .horizontal
        summaryBar.distribution = .fillEqually
        summaryBar.spacing = 10
        summaryBar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(summaryBar)
        content.addSubview(tableBox)
        NSLayoutConstraint.activate([
            summaryBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            summaryBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            summaryBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tableBox.topAnchor.constraint(equalTo: summaryBar.bottomAnchor, constant: 12),
            tableBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tableBox.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tableBox.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func configureColumns() {
        func col(_ id: String, _ title: String, width: CGFloat) -> NSTableColumn {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = 60          // allow columns to compress so none is clipped
            // Numbers sit on the right, so their header does too.
            if id != "date" { c.headerCell.alignment = .right }
            return c
        }
        // Widths sum below the window's content area so all four columns fit.
        table.addTableColumn(col("date", "Date", width: 92))
        table.addTableColumn(col("down", "↓ Download", width: 122))
        table.addTableColumn(col("up", "↑ Upload", width: 122))
        table.addTableColumn(col("total", "Total", width: 128))
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func present() {
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // Without a bezel the first tile leaves the last column too wide; refit once.
        window?.contentView?.layoutSubtreeIfNeeded()
        table.sizeLastColumnToFit()
    }

    private func reload() {
        rows = UsageStore.shared.history()
        maxTotal = max(1, rows.map { $0.total }.max() ?? 1)

        let binary = Settings.shared.useBinaryUnits
        let now = Date()
        let (rx7, tx7) = UsageStore.totals(rows, days: 7, today: now)
        let (rx30, tx30) = UsageStore.totals(rows, days: 30, today: now)
        week.stringValue = "↓ \(ByteFormatter.total(rx7, binary: binary)) ↑ \(ByteFormatter.total(tx7, binary: binary))"
        month.stringValue = "↓ \(ByteFormatter.total(rx30, binary: binary)) ↑ \(ByteFormatter.total(tx30, binary: binary))"
        let today = UsageStore.shared.today
        peak.stringValue = "↓ \(ByteFormatter.speed(today.peakDown, binary: binary)) ↑ \(ByteFormatter.speed(today.peakUp, binary: binary))"

        table.reloadData()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let usage = rows[row]
        let binary = Settings.shared.useBinaryUnits

        if column.identifier.rawValue == "total" {
            let cell = BarCell()
            cell.fraction = CGFloat(Double(usage.total) / Double(maxTotal))
            cell.text = ByteFormatter.total(usage.total, binary: binary)
            return cell
        }

        switch column.identifier.rawValue {
        case "date": return TextCell(usage.day, alignment: .left)
        case "down": return TextCell(ByteFormatter.total(usage.rx, binary: binary), alignment: .right)
        case "up":   return TextCell(ByteFormatter.total(usage.tx, binary: binary), alignment: .right)
        default:     return nil
        }
    }

    private static func statValue() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func stat(_ title: String, _ value: NSTextField) -> NSView {
        let column = UI.column([UI.label(title, size: 11.5, color: .secondaryLabelColor), value], spacing: 3)
        return GlassPanel.wrap(column, cornerRadius: 12, padding: 10)
    }
}

// Centred on the row like the Total cell, so every column shares one baseline.
private final class TextCell: NSView {
    init(_ text: String, alignment: NSTextAlignment) {
        super.init(frame: .zero)
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = alignment
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

// A table cell that draws a subtle proportional bar behind right-aligned text.
private final class BarCell: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var text: String = "" { didSet { field.stringValue = text; needsDisplay = true } }

    private let field = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = .right
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.backgroundColor = .clear
        field.isBordered = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let w = max(0, min(1, fraction)) * bounds.width
        let barRect = NSRect(x: 0, y: 3, width: w, height: bounds.height - 6)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 3, yRadius: 3).fill()
    }
}

import Cocoa

// Settings is a compact utility window: small controls, 30 pt rows and one width for every tab.
enum SettingsUI {
    static let width: CGFloat = 420
    static let rowHeight: CGFloat = 30
    static let tileSize: CGFloat = 22
    static let actionSize: CGFloat = 18
    static let fieldWidth: CGFloat = 236
    static let textSize = NSFont.smallSystemFontSize
    private static let listPadding: CGFloat = 4
    static let rowWidth = width - listPadding * 2

    @discardableResult
    static func small<Control: NSControl>(_ control: Control) -> Control {
        control.controlSize = .small
        control.font = .systemFont(ofSize: textSize)
        return control
    }

    static func button(_ title: String, onClick: @escaping () -> Void) -> ClosureButton {
        small(ClosureButton(title: title, onClick: onClick))
    }

    static func check(_ title: String) -> NSButton {
        small(NSButton(checkboxWithTitle: title, target: nil, action: nil))
    }

    static func toggle(_ label: String) -> NSSwitch {
        let toggle = NSSwitch()
        toggle.controlSize = .mini
        toggle.setAccessibilityLabel(label)
        return toggle
    }

    static func popup(_ titles: [String]) -> NSPopUpButton {
        let popup = small(NSPopUpButton())
        popup.addItems(withTitles: titles)
        return popup
    }

    static func field(_ placeholder: String, width: CGFloat = fieldWidth) -> NSTextField {
        let field = small(NSTextField())
        field.placeholderString = placeholder
        UI.fix(field, width: width)
        return field
    }

    static func title(_ text: String) -> NSTextField {
        UI.label(text, size: 12, weight: .semibold, color: .secondaryLabelColor)
    }

    static func note(_ text: String = "", width: CGFloat = width) -> NSTextField {
        UI.wrappingLabel(text, size: 11, width: width)
    }

    static func detail(_ text: String) -> NSTextField {
        UI.label(text, size: 10.5, color: .secondaryLabelColor)
    }

    static func formLabel(_ text: String) -> NSTextField {
        let label = UI.label(text, size: 11.5, weight: .medium)
        label.alignment = .right
        return label
    }

    static func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 7
        grid.columnSpacing = 8
        for index in 0..<grid.numberOfRows { grid.row(at: index).yPlacement = .center }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 96
        return grid
    }

    static func list(_ rows: NSStackView) -> CardView {
        let card = CardView(rows, padding: listPadding, radius: 10)
        UI.fix(card, width: width)
        return card
    }

    static func switchRow(_ tile: NSView, _ name: String, _ detail: String, _ toggle: NSSwitch) -> NSView {
        let names = UI.column([UI.label(name, size: 12, weight: .semibold), Self.detail(detail)], spacing: 0)
        UI.flexible(names)
        return row([tile, names, toggle])
    }

    static func row(_ views: [NSView]) -> NSStackView {
        let row = UI.row(views, spacing: 8)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        UI.fix(row, width: rowWidth, height: rowHeight)
        return row
    }

    static func column(_ views: [NSView]) -> NSStackView {
        UI.column(views, spacing: 8)
    }
}

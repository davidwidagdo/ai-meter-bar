import Cocoa

final class SettingsGeneralTab {
    var onOpenUsageHistory: (() -> Void)?
    var isLoginItemEnabled: () -> Bool = { false }

    private let intervalOptions = MeterSchedule.options
    private lazy var intervalPopup = SettingsUI.popup(intervalOptions.map { $0 == 1 ? "1 second" : "\($0) seconds" })
    private let interfacePopup = SettingsUI.popup([])
    private let startAtLoginCheck = SettingsUI.check("Start at Login")
    private let notifyCheck = SettingsUI.check("Notify me when something needs attention")
    private(set) lazy var view: NSView = build()

    var startAtLogin: Bool { startAtLoginCheck.state == .on }

    private func build() -> NSView {
        let lowPower = UI.label("\(MeterSchedule.lowPowerInterval) s in Low Power Mode", size: 11, color: .secondaryLabelColor)
        let quit = SettingsUI.button("Quit AI Meter Bar") { NSApp.terminate(nil) }
        quit.hasDestructiveAction = true
        let history = SettingsUI.button("Usage History") { [weak self] in self?.onOpenUsageHistory?() }
        let reset = SettingsUI.button("Reset Today…") { Self.resetUsage() }
        let log = SettingsUI.button("Open Log") {
            if !AppMode.isDemo { NSWorkspace.shared.open(Log.fileURL) }
        }
        let form = SettingsUI.grid([
            [SettingsUI.formLabel("Update every:"), UI.row([intervalPopup, lowPower], spacing: 8)],
            [SettingsUI.formLabel("Wi-Fi interface:"), interfacePopup],
            [NSGridCell.emptyContentView, startAtLoginCheck],
            [NSGridCell.emptyContentView, notifyCheck],
            [SettingsUI.formLabel("Usage:"), UI.row([history, reset], spacing: 6)],
            [SettingsUI.formLabel("Troubleshooting:"), log],
            [NSGridCell.emptyContentView, quit],
        ])
        let note = SettingsUI.note("Notifications: a sign-in failed, a VPN dropped by itself, or a quota at 10% or less, once per reset.")
        return SettingsUI.column([form, note])
    }

    func load() {
        _ = view
        let s = Settings.shared
        intervalPopup.selectItem(at: intervalOptions.firstIndex(of: s.updateInterval) ?? 1)
        interfacePopup.removeAllItems()
        interfacePopup.addItem(withTitle: "Automatic (Wi-Fi)")
        interfacePopup.item(at: 0)?.representedObject = ""
        for name in NetworkInterface.all() {
            interfacePopup.addItem(withTitle: name)
            interfacePopup.lastItem?.representedObject = name
        }
        let override = s.wifiInterfaceOverride
        let index = (0..<interfacePopup.numberOfItems).first {
            (interfacePopup.item(at: $0)?.representedObject as? String) == override
        }
        if index == nil, !override.isEmpty {
            // An unplugged adapter stays chosen, so an unrelated Save keeps it.
            interfacePopup.addItem(withTitle: "\(override) (not connected)")
            interfacePopup.lastItem?.representedObject = override
            interfacePopup.select(interfacePopup.lastItem)
        } else {
            interfacePopup.selectItem(at: index ?? 0)
        }
        startAtLoginCheck.state = isLoginItemEnabled() ? .on : .off
        notifyCheck.state = s.notifyAttention ? .on : .off
    }

    func save(to s: Settings) {
        s.updateInterval = intervalOptions[safe: intervalPopup.indexOfSelectedItem] ?? 2
        s.wifiInterfaceOverride = (interfacePopup.selectedItem?.representedObject as? String) ?? ""
        s.notifyAttention = notifyCheck.state == .on
    }

    private static func resetUsage() {
        let alert = NSAlert()
        alert.messageText = "Reset today's usage?"
        alert.informativeText = "Today's download and upload go back to zero. Earlier days stay."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reset").hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn, !AppMode.isDemo else { return }
        UsageStore.shared.resetToday()
    }
}

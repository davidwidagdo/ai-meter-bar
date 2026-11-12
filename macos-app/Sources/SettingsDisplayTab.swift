import Cocoa

final class SettingsDisplayTab {
    var vpnServices: () -> [VPNService] = { [] }

    private let modePopup = SettingsUI.popup(MenuBarMode.allCases.map(\.title))
    private let unitControl = SettingsUI.small(NSSegmentedControl(labels: ["% Left", "% Used"], trackingMode: .selectOne, target: nil, action: nil))
    private let binaryCheck = SettingsUI.check("Use binary units (1024 / KiB)")
    private let codexSwitch = SettingsUI.toggle("Show Codex in the bar")
    private let antigravitySwitch = SettingsUI.toggle("Show Antigravity in the bar")
    private var toolSwitches: [AITool: NSSwitch] = [:]
    private let toolRows = UI.column([], spacing: 0)
    private let vpnRows = UI.column([], spacing: 0)
    private var vpnSwitches: [String: NSSwitch] = [:]
    private(set) lazy var view: NSView = build()

    private func build() -> NSView {
        unitControl.setAccessibilityLabel("Show usage as")
        let form = SettingsUI.grid([
            [SettingsUI.formLabel("Menu bar shows:"), modePopup],
            [SettingsUI.formLabel("Quota as:"), unitControl],
            [NSGridCell.emptyContentView, binaryCheck],
        ])
        let vpnNote = SettingsUI.note("Hiding a VPN only removes its row; its profile stays in its own app.")
        return SettingsUI.column([form, SettingsUI.title("Other Tools"), SettingsUI.list(toolRows),
                                  SettingsUI.title("VPN"), SettingsUI.list(vpnRows), vpnNote])
    }

    func load() {
        _ = view
        let s = Settings.shared
        modePopup.selectItem(at: MenuBarMode.allCases.firstIndex(of: s.menuBarMode) ?? 0)
        unitControl.selectedSegment = s.usageShowLeft ? 0 : 1
        binaryCheck.state = s.useBinaryUnits ? .on : .off
        codexSwitch.state = s.showCodex ? .on : .off
        antigravitySwitch.state = s.showAntigravity ? .on : .off
        rebuildTools()
        rebuildVPNs()
    }

    func save(to s: Settings) {
        s.menuBarMode = MenuBarMode.allCases[safe: modePopup.indexOfSelectedItem] ?? s.menuBarMode
        s.usageShowLeft = unitControl.selectedSegment == 0
        s.useBinaryUnits = binaryCheck.state == .on
        s.showCodex = codexSwitch.state == .on
        s.showAntigravity = antigravitySwitch.state == .on
        // A hidden tool with no switch right now (not used lately) stays hidden.
        let listed = Set(toolSwitches.keys.map(\.rawValue))
        s.hiddenTools = s.hiddenTools.subtracting(listed).union(toolSwitches.filter { $0.value.state == .off }.map(\.key.rawValue))
        // A hidden VPN that macOS no longer lists stays hidden if it comes back.
        let listedVPNs = Set(vpnSwitches.keys)
        s.hiddenVPNs = s.hiddenVPNs.subtracting(listedVPNs).union(vpnSwitches.filter { $0.value.state == .off }.keys)
    }

    // Rebuilt on every open, so a tool first used while the app runs gets its switch.
    private func rebuildTools() {
        toolRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        toolSwitches.removeAll()
        let size = SettingsUI.tileSize
        toolRows.addArrangedSubview(SettingsUI.switchRow(TileView(mark: .openAI, size: size), "Codex", "Current account, read live", codexSwitch))
        toolRows.addArrangedSubview(SettingsUI.switchRow(TileView(mark: .antigravity, size: size), "Antigravity", "Quota while its app is open", antigravitySwitch))
        let hidden = Settings.shared.hiddenTools
        for status in LocalTools.listed() {
            let toggle = SettingsUI.toggle("Show \(status.tool.displayName) in the bar")
            toggle.state = hidden.contains(status.tool.rawValue) ? .off : .on
            toolSwitches[status.tool] = toggle
            toolRows.addArrangedSubview(SettingsUI.switchRow(TileView(mark: status.tool.mark, size: size), status.tool.displayName,
                                                             "Shown when used in the last 30 days", toggle))
        }
    }

    // One switch per VPN macOS lists, like the profile switches.
    private func rebuildVPNs() {
        vpnRows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        vpnSwitches.removeAll()
        let services = vpnServices()
        guard !services.isEmpty else {
            vpnRows.addArrangedSubview(SettingsUI.row([UI.label("No VPN in System Settings yet.", size: 11, color: .secondaryLabelColor)]))
            return
        }
        let hidden = Settings.shared.hiddenVPNs
        for service in services {
            let toggle = SettingsUI.toggle("Show \(service.name) in the bar")
            toggle.state = hidden.contains(service.id) ? .off : .on
            vpnSwitches[service.id] = toggle
            let tile = TileView(symbol: "lock.shield", hex: ProfileTint.graphite, size: SettingsUI.tileSize)
            vpnRows.addArrangedSubview(SettingsUI.switchRow(tile, service.name, VPNController.appName(for: service.provider), toggle))
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

import Foundation

enum VPNStatus: Equatable {
    case off, connecting, connected, disconnecting, invalid
}

// A VPN account as macOS lists it. The VPN app keeps its profile and password; none of it is here.
struct VPNService: Equatable {
    let id: String
    let name: String
    let provider: String?
    var status: VPNStatus
}

enum VPNServiceList {
    private static let line = try? NSRegularExpression(
        pattern: #"^\s*\*?\s*\(([^)]*)\)\s+([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\s+(.*)$"#)

    // Reads `scutil --nc list`. A name may hold quotes, so it runs from first quote to last.
    static func parse(_ text: String) -> [VPNService] {
        guard let line = line else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { raw in
            let row = String(raw)
            let range = NSRange(row.startIndex..., in: row)
            guard let match = line.firstMatch(in: row, range: range), match.numberOfRanges == 4,
                  let state = Range(match.range(at: 1), in: row), let id = Range(match.range(at: 2), in: row),
                  let rest = Range(match.range(at: 3), in: row) else { return nil }
            let tail = row[rest]
            guard let open = tail.firstIndex(of: "\""), let close = tail.lastIndex(of: "\""), open < close else { return nil }
            let name = String(tail[tail.index(after: open)..<close])
            guard !name.isEmpty else { return nil }
            return VPNService(id: String(row[id]), name: name, provider: provider(in: tail[tail.index(after: close)...]),
                              status: status(String(row[state])))
        }
    }

    static func status(_ word: String) -> VPNStatus {
        switch word.trimmingCharacters(in: .whitespaces).lowercased() {
        case "connected":     return .connected
        case "connecting":    return .connecting
        case "disconnecting": return .disconnecting
        case "invalid":       return .invalid
        default:              return .off
        }
    }

    // The bracket names the VPN app, as in [VPN:com.example.vpn]; system VPNs have none.
    private static func provider(in tail: Substring) -> String? {
        guard let start = tail.range(of: "[VPN:"), let end = tail[start.upperBound...].firstIndex(of: "]") else { return nil }
        let bundle = String(tail[start.upperBound..<end])
        return bundle.isEmpty ? nil : bundle
    }
}

struct VPNRowModel: Equatable {
    enum Action: Equatable { case connect, disconnect, wait, openApp }

    let detail: String
    let isUp: Bool
    let warns: Bool
    let action: Action

    static func make(_ service: VPNService, connectedSince: Date?, failed: Bool, now: Date) -> VPNRowModel {
        if failed, service.status != .connected {
            return VPNRowModel(detail: "Couldn't connect, open its app", isUp: false, warns: true, action: .openApp)
        }
        switch service.status {
        case .connected:
            let age = connectedSince.map { RelativeAge.short(now.timeIntervalSince($0)) }
            let detail = age.map { $0 == "now" ? "Connected" : "Connected · \($0)" } ?? "Connected"
            return VPNRowModel(detail: detail, isUp: true, warns: false, action: .disconnect)
        // A connect can hang, or reassert on a new network, so it can always be stopped.
        case .connecting:
            return VPNRowModel(detail: "Connecting…", isUp: false, warns: false, action: .disconnect)
        case .disconnecting:
            return VPNRowModel(detail: "Disconnecting…", isUp: false, warns: false, action: .wait)
        case .off:
            return VPNRowModel(detail: "Off", isUp: false, warns: false, action: .connect)
        case .invalid:
            return VPNRowModel(detail: "Needs setup in its app", isUp: false, warns: true, action: .openApp)
        }
    }
}

struct VPNPanelRow: Equatable {
    let id: String
    let name: String
    let model: VPNRowModel
}

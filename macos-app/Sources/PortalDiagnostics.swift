import Foundation

enum PortalDiagnostics {
    private static let chapMarkers = ["chap-id", "chap-challenge", "hexmd5("]

    static func usesChap(html: String) -> Bool {
        let lower = html.lowercased()
        return chapMarkers.contains { lower.contains($0) }
    }

    static func report(connected: Bool, page: CaptivePage?, marker: String, hostKind: String, ownAddresses: [String]) -> [String] {
        var lines = [connected ? "Internet: reachable." : "Internet: not reachable."]
        guard let page = page else {
            lines.append("Portal page: no answer.")
            return lines
        }
        if page.status == 511 {
            lines.append("Portal page: HTTP 511, the network requires sign-in.")
        } else {
            lines.append("Portal page: HTTP \(page.status.map(String.init) ?? "?"), \(page.hops) redirect(s), host is \(hostKind).")
        }
        if page.overWiFi == false {
            lines.append("Link: this page did not arrive over Wi-Fi, so the app will not sign in to it.")
        }
        lines.append(page.form == nil ? "Login form: not found." : "Login form: found.")
        let trimmed = marker.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            lines.append("Portal marker: not set.")
        } else if !PortalMarker.isUsable(trimmed, ownAddresses: ownAddresses) {
            lines.append("Portal marker: ignored, it matches this app's own addresses. Use text only your portal's page shows.")
        } else {
            let found = PortalMarker.matches(page: page, marker: trimmed, ownAddresses: ownAddresses)
            lines.append(found ? "Portal marker: found." : "Portal marker: not found on this page.")
        }
        if usesChap(html: page.html) {
            lines.append("CHAP: this portal may hash the password, which is not supported.")
        }
        return lines
    }
}

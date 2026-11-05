import Foundation

func testPortalDiagnostics() {
    let form = "<form action=\"/login\"><input name=\"username\" type=\"text\"><input name=\"password\" type=\"password\"></form>"
    let url = URL(string: "http://portal.example/login")
    let probe = URL(string: "http://captive.apple.com/hotspot-detect.html")
    let own = ["http://captive.apple.com/hotspot-detect.html", "http://10.9.8.1/login"]
    var lines = PortalDiagnostics.report(connected: false, page: CaptivePage(url: url, html: form, hops: 1, status: 200), marker: "zq-marker", hostKind: "portal", ownAddresses: own)
    T.expect(lines.contains("Internet: not reachable."), "offline reported")
    T.expect(lines.contains("Portal page: HTTP 200, 1 redirect(s), host is portal."), "page reported")
    T.expect(lines.contains("Login form: found."), "form reported")
    T.expect(lines.contains("Portal marker: not found on this page."), "marker missing reported")

    lines = PortalDiagnostics.report(connected: true, page: nil, marker: "", hostKind: "other", ownAddresses: own)
    T.eq(lines, ["Internet: reachable.", "Portal page: no answer."], "no page")

    lines = PortalDiagnostics.report(connected: false, page: CaptivePage(url: url, html: "x", hops: 1, status: 511), marker: "portal.example", hostKind: "other", ownAddresses: own)
    T.expect(lines.contains("Portal page: HTTP 511, the network requires sign-in."), "511 detected")
    T.expect(lines.contains("Portal marker: found."), "marker in the redirect host")

    lines = PortalDiagnostics.report(connected: false, page: CaptivePage(url: probe, html: "x", status: 200), marker: "hotspot", hostKind: "other", ownAddresses: own)
    T.expect(lines.contains { $0.hasPrefix("Portal marker: ignored") }, "unusable marker is named")

    func marker(_ page: CaptivePage, _ value: String) -> Bool { PortalMarker.matches(page: page, marker: value, ownAddresses: own) }
    T.eq(marker(CaptivePage(url: probe, html: "x"), "hotspot"), false, "probe address is not proof")
    T.eq(marker(CaptivePage(url: probe, html: own[0]), "hotspot"), false, "echoed probe address is not proof")
    T.eq(marker(CaptivePage(url: URL(string: "http://10.9.8.1/login"), html: "404"), "login"), false, "gateway address is not proof")
    T.eq(marker(CaptivePage(url: URL(string: "http://10.9.8.1/login"), html: "404"), "10.9"), false, "gateway number is not proof")
    T.eq(marker(CaptivePage(url: probe, html: "x"), "portal.example"), false, "hop 0 address is not proof")
    T.eq(marker(CaptivePage(url: URL(string: "http://foreign.example/s?continue=zq-marker"), html: "x", hops: 1), "zq-marker"), false, "redirect query is not proof")
    T.eq(marker(CaptivePage(url: url, html: "x", hops: 1), "portal.example"), true, "redirect host counts")
    T.eq(marker(CaptivePage(url: probe, html: "Welcome to ZQ-Marker"), "zq-marker"), true, "page text counts")

    let hotel = CaptivePage(url: URL(string: "http://hotel.example/grand-hotel/login"), html: "x", hops: 1).summary(hostKind: "other")
    T.expect(!hotel.contains("grand-hotel") && !hotel.contains("hotel.example"), "log line hides site and host")
    T.expect(hotel.contains("path depth 2"), "log line keeps the shape")

    T.eq(PortalDiagnostics.usesChap(html: "<input name=\"chap-id\">"), true, "chap field")
    T.eq(PortalDiagnostics.usesChap(html: form), false, "plain form")
    let joined = lines.joined()
    T.expect(!joined.contains("portal.example"), "report never prints the host")
}

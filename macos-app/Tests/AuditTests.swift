import Foundation

func testAuditRun2() {
    // The password is bound to the destination it was saved for.
    let bound = PortalSecret(password: "p\"w\n1", binding: PortalSecret.binding(loginURL: " http://portal.example/login ", marker: " Hotspot "))
    T.eq(PortalSecret.decode(bound.encoded()), bound, "a bound secret survives a round trip, odd characters included")
    T.expect(bound.allows(loginURL: "http://portal.example/login", marker: "Hotspot"), "the saved destination is allowed, spaces ignored")
    T.expect(!bound.allows(loginURL: "http://other.example/login", marker: "Hotspot"), "another Login URL is refused")
    T.expect(!bound.allows(loginURL: "http://portal.example/login", marker: "Other"), "another marker is refused")
    T.expect(!bound.allows(loginURL: "", marker: ""), "cleared settings are refused")
    let legacy = PortalSecret.decode(Data("plain-pass".utf8))
    T.eq(legacy, PortalSecret(password: "plain-pass", binding: nil), "an item from before bindings reads as its password")
    T.expect(legacy?.allows(loginURL: "http://anything.example", marker: "") == true, "an unbound item still signs in until the next save")
    T.eq(PortalSecret(password: "x", binding: nil).encoded(), Data("x".utf8), "an unbound secret is stored as the plain password")
    T.eq(PortalSecret.decode(Data(#"{"v":2,"password":"a","binding":"b"}"#.utf8))?.binding, nil, "an unknown version is not read as bound")
    T.eq(PortalSecret.decode(Data(#"{"v":1,"password":"a","binding":"b","x":1}"#.utf8))?.binding, nil, "extra keys are not read as bound")
    T.eq(PortalSecret.decode(Data([0xFF, 0xFE])), nil, "bytes that are not text hold no password")

    let url = "http://portal.example/login"
    T.eq(PortalSecret.forSave(typed: nil, stored: nil, loginURL: url, marker: ""), nil, "nothing typed and nothing stored writes nothing")
    T.eq(PortalSecret.forSave(typed: "new", stored: nil, loginURL: url, marker: "m")?.binding, "\(url)\nm", "a typed password is bound to the saved destination")
    T.eq(PortalSecret.forSave(typed: nil, stored: legacy, loginURL: url, marker: "")?.password, "plain-pass", "an unbound item gets bound with its own password")
    let saved = PortalSecret(password: "pw", binding: PortalSecret.binding(loginURL: url, marker: ""))
    T.eq(PortalSecret.forSave(typed: nil, stored: saved, loginURL: url, marker: ""), nil, "no change writes nothing")
    T.eq(PortalSecret.forSave(typed: "pw", stored: saved, loginURL: url, marker: ""), saved, "a retyped password writes, so the item is made anew")
    T.eq(PortalSecret.forSave(typed: nil, stored: saved, loginURL: "http://new.example/login", marker: "")?.password, "pw",
         "a new Login URL rebinds the stored password")
    T.eq(PortalSecret.forSave(typed: "", stored: saved, loginURL: url, marker: "")?.password, "", "clearing the field clears the password")
    T.eq(PortalSecret.forSave(typed: nil, stored: PortalSecret(password: "", binding: nil), loginURL: url, marker: ""), nil,
         "an empty stored password is not rewritten")

    // A page is judged by the addresses its connection used.
    let own: Set<String> = ["192.0.2.10", "fe80::1c2d:3e4f:5a6b:7c8d"]
    T.expect(PageOrigin.isThisMac(remote: "127.0.0.1", ownAddresses: own), "loopback is this Mac")
    T.expect(PageOrigin.isThisMac(remote: "::1", ownAddresses: own), "IPv6 loopback is this Mac")
    T.expect(PageOrigin.isThisMac(remote: "192.0.2.10", ownAddresses: own), "this Mac's LAN address is this Mac")
    T.expect(PageOrigin.isThisMac(remote: "FE80::1C2D:3E4F:5A6B:7C8D%en0", ownAddresses: own), "zone and case are ignored")
    T.expect(PageOrigin.isThisMac(remote: "::ffff:127.0.0.1", ownAddresses: own), "a mapped loopback address is this Mac")
    T.expect(!PageOrigin.isThisMac(remote: "192.0.2.1", ownAddresses: own), "the gateway is not this Mac")
    T.expect(!PageOrigin.isThisMac(remote: "::ffff:192.0.2.1", ownAddresses: own), "a mapped gateway address is not this Mac")
    T.expect(!PageOrigin.isThisMac(remote: "fe80::1%en0", ownAddresses: own), "a link-local router is not this Mac")
    T.expect(PageOrigin.isThisMac(remote: "fe80::1%en0", ownAddresses: own.union(["fe80::1"])), "which is why lo0's fe80::1 stays out of the own set")
    T.expect(!PageOrigin.isThisMac(remote: nil, ownAddresses: own), "an unknown address blocks nothing")
    T.eq(PageOrigin.cameOverWiFi(local: "192.0.2.10", wifiAddresses: ["192.0.2.10"]), true, "the Wi-Fi address means Wi-Fi")
    T.eq(PageOrigin.cameOverWiFi(local: "10.8.0.2", wifiAddresses: ["192.0.2.10"]), false, "a tunnel address means another link")
    T.eq(PageOrigin.cameOverWiFi(local: nil, wifiAddresses: ["192.0.2.10"]), nil, "an unknown local address is unknown")
    T.eq(PageOrigin.cameOverWiFi(local: "192.0.2.10", wifiAddresses: nil), nil, "no known Wi-Fi interface is unknown")
    T.eq(PageOrigin.cameOverWiFi(local: "192.0.2.10", wifiAddresses: []), nil, "a Wi-Fi interface with no address is unknown")
    T.eq(CaptivePage(url: nil, html: "").overWiFi, nil, "a page has no link verdict unless one is given")

    // A live read that answers with nothing clears the last reading; no answer keeps it.
    T.eq(LiveRead<Int>.reading(2).next(keeping: 1), 2, "a new reading replaces the last")
    T.eq(LiveRead<Int>.empty.next(keeping: 1), nil, "an empty answer clears the last reading")
    T.eq(LiveRead<Int>.unavailable.next(keeping: 1), 1, "no answer keeps the last reading")

    // Vendor files: never through a link, and bounded.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aimeterbar-audit-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let real = folder.appendingPathComponent("real.json"), link = folder.appendingPathComponent("link.json")
    try? Data("{}".utf8).write(to: real)
    try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    T.eq(SafeFile.read(real), Data("{}".utf8), "a regular file of this user is read")
    T.eq(SafeFile.read(link), nil, "a symlink is refused on open")
    T.eq(SafeFile.read(folder), nil, "a folder is refused")
    T.eq(SafeFile.read(folder.appendingPathComponent("missing")), nil, "a missing file is nil")
    T.eq(SafeFile.read(URL(fileURLWithPath: "/etc/hosts")), nil, "a file owned by another user is refused")
    let big = folder.appendingPathComponent("big.log")
    try? Data(repeating: 0x61, count: 100).write(to: big)
    T.eq(SafeFile.tail(big, maxBytes: 10)?.data.count, 10, "a tail never reads past its bound")
}

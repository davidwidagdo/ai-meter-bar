import Foundation

func testLoginOutcome() {
    T.eq(LoginOutcome.slept(wallElapsed: 667, uptimeElapsed: 2.1), true, "real case: slept 11 minutes")
    T.eq(LoginOutcome.slept(wallElapsed: 2, uptimeElapsed: 2), false, "no sleep")
    T.eq(LoginOutcome.slept(wallElapsed: 40, uptimeElapsed: 38), false, "slow network is not sleep")

    T.eq(LoginOutcome.verdict(slept: true, confirmed: true, portalStillAsking: false), .loggedIn, "confirmed wins")
    T.eq(LoginOutcome.verdict(slept: true, confirmed: false, portalStillAsking: false), .unconfirmed, "slept, no network")
    T.eq(LoginOutcome.verdict(slept: true, confirmed: false, portalStillAsking: true), .unconfirmed, "session may lapse in sleep")
    T.eq(LoginOutcome.verdict(slept: false, confirmed: false, portalStillAsking: true), .rejected, "portal still asks")
    T.eq(LoginOutcome.verdict(slept: false, confirmed: false, portalStillAsking: false), .unconfirmed, "no evidence of rejection")
}

func testLoginThrottle() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var throttle = LoginThrottle()
    T.expect(throttle.allowsAttempt(now: t0), "new throttle allows")

    throttle.recordRejected(now: t0)
    T.expect(!throttle.allowsAttempt(now: t0.addingTimeInterval(59)), "first rejection blocks 59s")
    T.expect(throttle.allowsAttempt(now: t0.addingTimeInterval(60)), "first rejection allows at 60s")

    throttle.recordRejected(now: t0)
    T.expect(!throttle.allowsAttempt(now: t0.addingTimeInterval(299)), "second rejection blocks 299s")
    T.expect(throttle.allowsAttempt(now: t0.addingTimeInterval(300)), "second rejection allows at 300s")

    throttle.recordRejected(now: t0)
    T.expect(!throttle.allowsAttempt(now: t0.addingTimeInterval(899)), "third rejection blocks 899s")
    T.expect(throttle.allowsAttempt(now: t0.addingTimeInterval(900)), "third rejection allows at 900s")

    throttle.recordRejected(now: t0)
    T.expect(!throttle.allowsAttempt(now: t0.addingTimeInterval(899)), "fourth rejection stays capped")
    T.expect(throttle.allowsAttempt(now: t0.addingTimeInterval(900)), "cap is 900s")

    throttle.reset()
    T.expect(throttle.allowsAttempt(now: t0), "reset allows at once")
}

func testPostGuard() {
    let p = "http://portal.example/login", g = "10.0.0.1"
    func allows(_ url: String, _ portal: String?, _ gateway: String?, _ marker: Bool) -> Bool {
        PostGuard.allows(target: URL(string: url)!, portal: portal.flatMap { URL(string: $0) }, gateway: gateway, markerSet: marker)
    }
    T.eq(allows("http://portal.example/login", p, g, true), true, "configured portal")
    T.eq(allows("http://PORTAL.example/login", p, g, false), true, "host case ignored")
    T.eq(allows("http://10.0.0.1/login", p, g, true), true, "gateway with marker")
    T.eq(allows("http://10.0.0.1/login", p, g, false), false, "gateway without marker")
    T.eq(allows("http://evil.example/login", p, g, true), false, "other host")
    T.eq(allows("http://portal.example.evil.example/login", p, g, true), false, "suffix trick")
    T.eq(allows("ftp://portal.example/x", p, g, true), false, "other scheme")
    T.eq(allows("http://any.example/login", nil, nil, false), false, "nothing configured")
    T.eq(allows("http://any.example/login", "", nil, true), false, "empty portal host")

    T.eq(PostGuard.allows(target: nil, portal: URL(string: p), gateway: g, markerSet: true), false, "unreadable form target")
    let secure = "https://portal.example/login"
    T.eq(allows("http://portal.example/login", secure, g, false), false, "form cannot drop TLS")
    T.eq(allows("https://portal.example/other", secure, g, false), true, "same https portal")
    T.eq(allows("https://portal.example:443/other", secure, g, false), true, "explicit default port")
    T.eq(allows("http://portal.example:80/login", p, g, false), true, "explicit plain port")
    T.eq(allows("http://portal.example:8081/collect", p, g, false), false, "other port")
    T.eq(allows("https://portal.example/login", p, g, false), true, "form may upgrade to https")
    T.eq(allows("https://portal.example:8443/login", p, g, false), false, "upgrade on another port")
    T.eq(allows("http://10.0.0.1/login", secure, g, true), false, "https portal never uses the gateway")

    T.eq(PostGuard.gatewayHolds(proven: "10.9.8.1", current: "172.16.0.1", markerSet: true), false, "network changed after the match")
    T.eq(PostGuard.gatewayHolds(proven: "10.9.8.1", current: "10.9.8.1", markerSet: true), true, "same gateway")
    T.eq(PostGuard.gatewayHolds(proven: "10.9.8.1", current: nil, markerSet: true), false, "gateway gone")
    T.eq(PostGuard.gatewayHolds(proven: "10.9.8.1", current: "172.16.0.1", markerSet: false), true, "no marker, no gateway route")

    for (url, want, name) in [
        ("http://portal.example/login", true, "http redirect"),
        ("https://portal.example/login", true, "https redirect"),
        ("http://10.0.0.1/login", true, "private gateway redirect"),
        ("file:///etc/hosts", false, "file redirect"),
        ("ftp://portal.example/x", false, "ftp redirect"),
        ("http://localhost:8080/", false, "localhost redirect"),
        ("http://LOCALHOST/", false, "localhost case"),
        ("http://x.localhost/", false, "localhost suffix"),
        ("http://127.0.0.1/", false, "loopback redirect"),
        ("http://127.1/", false, "short loopback"),
        ("http://2130706433/", false, "decimal loopback"),
        ("http://0.0.0.0/", false, "any address"),
        ("http://[::1]/", false, "ipv6 loopback"),
        ("http://[::ffff:127.0.0.1]/", false, "mapped loopback"),
    ] {
        T.eq(RedirectPolicy.allows(URL(string: url)!), want, name)
    }

    let host = "portal.example"
    T.eq(PostGuard.hostKind(URL(string: "http://portal.example/x"), portalHost: host, gateway: g), "portal", "kind portal")
    T.eq(PostGuard.hostKind(URL(string: "http://10.0.0.1/x"), portalHost: host, gateway: g), "gateway", "kind gateway")
    T.eq(PostGuard.hostKind(URL(string: "http://other.example/x"), portalHost: host, gateway: g), "other", "kind other")
    T.eq(PostGuard.hostKind(nil, portalHost: host, gateway: g), "other", "kind nil")
}

import Foundation

func testLoginForm() {
    let base = URL(string: "http://portal.example/hotspot-detect.html")

    // MikroTik redirect.html as served to a logged-out client.
    let meta = """
    <html><head><title>...</title>
    <meta http-equiv="refresh" content="0; url=http://portal.example/login?dst=http%3A%2F%2Fcaptive.apple.com%2F">
    <meta http-equiv="pragma" content="no-cache"></head><body></body></html>
    """
    T.eq(LoginFormParser.redirectURL(html: meta, base: base)?.absoluteString,
         "http://portal.example/login?dst=http%3A%2F%2Fcaptive.apple.com%2F", "meta refresh target")

    let js = "<script>location.href = unescape('http%3A%2F%2Fportal.example%2Fstatus');</script>"
    T.eq(LoginFormParser.redirectURL(html: js, base: base)?.absoluteString,
         "http://portal.example/status", "js unescape target")

    let replace = "<script>window.location.replace(\"/login\");</script>"
    T.eq(LoginFormParser.redirectURL(html: replace, base: base)?.absoluteString,
         "http://portal.example/login", "js location.replace target")

    let relative = "<meta http-equiv='refresh' content='0;URL=/login'>"
    T.eq(LoginFormParser.redirectURL(html: relative, base: base)?.absoluteString,
         "http://portal.example/login", "relative meta target")

    let lookalike = "<script>var geolocation = 'http://tracker.example/';</script>"
    T.expect(LoginFormParser.redirectURL(html: lookalike, base: base) == nil, "lookalike variable ignored")

    let template = "<meta http-equiv=\"refresh\" content=\"0; url=$(link-redirect)\">"
    T.expect(LoginFormParser.redirectURL(html: template, base: base) == nil, "unexpanded template ignored")

    let success = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
    T.expect(LoginFormParser.redirectURL(html: success, base: base) == nil, "no redirect on success page")

    // MikroTik login.html: a hidden "sendin" form precedes the real one.
    let login = """
    <meta http-equiv="refresh" content="30; url=/login">
    <form name="sendin" action="http://portal.example/login" method="post">
      <input type="hidden" name="username" /><input type="hidden" name="password" />
    </form>
    <form name="login" action="http://portal.example/login" method="post" onSubmit="return doLogin()">
      <input type="hidden" name="dst" value="" /><input type="hidden" name="popup" value="true" />
      <input name="username" type="text" /><input name="password" type="password" />
    </form>
    """
    T.expect(LoginFormParser.redirectURL(html: login, base: base) == nil, "form page is not followed")
    let form = LoginFormParser.parse(html: login)
    T.eq(form?.fields.map(\.name) ?? [], ["dst", "popup", "username", "password"], "real login form picked")
    let filled = Dictionary(uniqueKeysWithValues: form?.filled(username: "u", password: "p#1") ?? [])
    T.eq(filled["username"] ?? "", "u", "username filled")
    T.eq(filled["password"] ?? "", "p#1", "password filled")
    T.eq(filled["popup"] ?? "", "true", "hidden field kept")

    // MikroTik status.html: its status button assigns document.location.
    let status = """
    <meta http-equiv="refresh" content="60">
    <form action="http://portal.example/logout" name="logout"><input type="submit" value="Log out"></form>
    <button onclick="document.location='http://portal.example/user?subs='; return false;">status</button>
    """
    T.expect(LoginFormParser.isSessionPage(html: status), "status page is a live session")
    T.expect(LoginFormParser.redirectURL(html: status, base: base) == nil, "status page is not followed")
    T.expect(!LoginFormParser.isSessionPage(html: login), "login page is not a session")

    let unquoted = "<form action=/login method=post><input type=text name=user><input type=password name=pass></form>"
    let bare = LoginFormParser.parse(html: unquoted)
    T.eq(bare?.action ?? "", "/login", "unquoted action")
    T.eq(bare?.fields.map(\.name) ?? [], ["user", "pass"], "unquoted names")
    T.eq(bare?.fields.map(\.type) ?? [], ["text", "password"], "unquoted types")
    let dataAttrs = #"<form action="/l"><input data-type="x" type="password" data-name="y" name="pw"></form>"#
    T.eq(LoginFormParser.parse(html: dataAttrs)?.fields.first?.type ?? "", "password", "data-type is not read as type")
    T.eq(LoginFormParser.parse(html: dataAttrs)?.fields.first?.name ?? "", "pw", "data-name is not read as name")
    T.eq(CaptivePage(url: nil, html: login).route, nil, "a page has no route unless one is given")

    let named = URL(string: "http://portal.example/login?dst=x")!
    T.eq(PortalRoute.url(URL(string: "http://portal.example:8080/login")!, portalHost: "portal.example", gateway: "10.0.0.1").absoluteString,
         "http://10.0.0.1:8080/login", "the portal's port is kept")
    T.eq(PortalRoute.url(named, portalHost: "PORTAL.example", gateway: "10.0.0.1").absoluteString,
         "http://10.0.0.1/login?dst=x", "portal name goes to the gateway")
    T.eq(PortalRoute.url(named, portalHost: "other.example", gateway: "10.0.0.1").absoluteString,
         named.absoluteString, "other hosts stay as they are")
    T.eq(PortalRoute.url(named, portalHost: "portal.example", gateway: nil).absoluteString,
         named.absoluteString, "no gateway, no rewrite")
    let secure = URL(string: "https://portal.example/login")!
    T.eq(PortalRoute.url(secure, portalHost: "portal.example", gateway: "10.0.0.1").absoluteString,
         secure.absoluteString, "https stays on the portal's name")

    let flood = String(repeating: "<form <meta ", count: 80_000)
    let started = Date()
    let huge = CaptivePage(url: nil, html: flood)
    T.expect(huge.form == nil && !huge.isLoggedIn, "unclosed tags hold no form")
    T.expect(LoginFormParser.redirectURL(html: flood, base: nil) == nil, "unclosed tags hold no redirect")
    T.expect(Date().timeIntervalSince(started) < 5, "unclosed tags parse in linear time")
}

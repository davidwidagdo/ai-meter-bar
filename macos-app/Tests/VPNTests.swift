import Foundation

func testVPN() {
    let listing = """
    Available network connection services in the current set (*=enabled):
    * (Connected)      0A1B2C3D-0000-4000-8000-000000000001 VPN (com.example.vpn) "Office"          [VPN:com.example.vpn]
    * (Disconnected)   0A1B2C3D-0000-4000-8000-000000000002 VPN (com.example.vpn) "Home "Lab" [2]" [VPN:com.example.vpn]
      (Connecting)     0a1b2c3d-0000-4000-8000-000000000003 IPSec             "Spaces in name"     [IPSec]
    * (Disconnecting)  0A1B2C3D-0000-4000-8000-000000000004 VPN (com.other.app) "Other"           [VPN:com.other.app]
    * (Invalid)        0A1B2C3D-0000-4000-8000-000000000005 VPN (com.example.vpn) "Broken"          [VPN:com.example.vpn]
    * (Disconnected)   not-an-id VPN "Skipped"
    * (Disconnected)   0A1B2C3D-0000-4000-8000-000000000006 VPN (com.example.vpn) no name here
    garbage
    """
    let services = VPNServiceList.parse(listing)
    T.eq(services.map(\.name), ["Office", "Home \"Lab\" [2]", "Spaces in name", "Other", "Broken"], "names, quotes and brackets kept")
    T.eq(services.first?.id, "0A1B2C3D-0000-4000-8000-000000000001", "service ID")
    T.eq(services.map(\.status), [.connected, .off, .connecting, .disconnecting, .invalid], "states, invalid kept apart")
    T.eq(VPNServiceList.status("Unknown"), .off, "an unknown word counts as off")
    T.eq(services.map(\.provider), ["com.example.vpn", "com.example.vpn", nil, "com.other.app", "com.example.vpn"], "VPN app from the bracket")
    T.eq(VPNServiceList.visible(services, hidden: ["0A1B2C3D-0000-4000-8000-000000000002"]).map(\.name),
         ["Office", "Spaces in name", "Other", "Broken"], "a hidden VPN leaves the panel by its ID")
    T.eq(VPNServiceList.visible(services, hidden: []).count, 5, "nothing hidden")
    T.eq(VPNServiceList.parse(""), [], "empty output")
    T.eq(VPNServiceList.parse("Available network connection services in the current set (*=enabled):\n"), [], "header only")

    let now = Date(timeIntervalSince1970: 100_000)
    func model(_ status: VPNStatus, since: Date? = nil, failed: Bool = false) -> VPNRowModel {
        VPNRowModel.make(VPNService(id: "x", name: "Office", provider: nil, status: status), connectedSince: since, failed: failed, now: now)
    }
    T.eq(model(.connected, since: now.addingTimeInterval(-4300)).detail, "Connected · 1h", "connected with its age")
    T.eq(model(.connected, since: now.addingTimeInterval(-20)).detail, "Connected", "just connected")
    T.eq(model(.connected).detail, "Connected", "connected before the app saw it")
    T.eq(model(.connected).action, .disconnect, "a connected row disconnects")
    T.expect(model(.connected).isUp, "connected shows the filled dot")
    T.eq(model(.off).action, .connect, "an off row connects")
    T.eq(model(.off).detail, "Off", "off")
    T.eq(model(.connecting).action, .disconnect, "a hanging connect can be stopped")
    T.eq(model(.disconnecting).action, .wait, "no second click while disconnecting")
    T.eq(model(.off, failed: true).action, .openApp, "a failed connect offers the VPN app")
    T.expect(model(.off, failed: true).warns, "a failed connect is marked")
    T.eq(model(.connected, failed: true).action, .disconnect, "a late connect clears the failure")
    T.eq(model(.invalid).action, .openApp, "an invalid VPN points to its app")
    T.expect(model(.invalid).warns, "an invalid VPN is marked")
}

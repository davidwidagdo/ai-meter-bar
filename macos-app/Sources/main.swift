import Cocoa

if CommandLine.arguments.contains("--dump-status") {
    DumpStatus.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu-bar only: no Dock icon, no main window.
app.setActivationPolicy(.accessory)
app.run()

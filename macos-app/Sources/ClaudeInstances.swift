import Cocoa

struct ClaudeInstance: Equatable {
    let pid: pid_t
    let folder: String
}

enum ClaudeInstances {
    enum OpenError: Error {
        case claudeNotFound
    }

    static let bundleID = "com.anthropic.claudefordesktop"

    static func running() -> [ClaudeInstance] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map { app in
            let directory = ProcessArgs.userDataDir(arguments(pid: app.processIdentifier))
            let folder = directory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ProfileNames.defaultFolder
            return ClaudeInstance(pid: app.processIdentifier, folder: folder)
        }
    }

    private static func arguments(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return ProcessArgs.parse(Data(buffer.prefix(size)))
    }

    static func open(profile: ClaudeProfile, completion: @escaping (Error?) -> Void) {
        guard !AppMode.isDemo else {
            completion(nil)
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            completion(OpenError.claudeNotFound)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // Without a new instance, macOS would only bring another running profile to the front.
        configuration.createsNewApplicationInstance = true
        if profile.folder != ProfileNames.defaultFolder {
            configuration.arguments = ["--user-data-dir=\(profile.url.path)"]
        }
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    static func bringToFront(_ instance: ClaudeInstance) {
        NSRunningApplication(processIdentifier: instance.pid)?.activate()
    }
}

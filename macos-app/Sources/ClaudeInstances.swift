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
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !apps.isEmpty else { return [] }
        let folders = ClaudeProfiles.scan().map(\.folder)
        return apps.compactMap { app in
            let directory = ProcessArgs.userDataDir(ProcessArgs.read(pid: app.processIdentifier))
            guard let folder = ClaudeProfiles.runningFolder(userDataDir: directory, root: ClaudeProfiles.supportRoot,
                                                            folders: folders) else { return nil }
            return ClaudeInstance(pid: app.processIdentifier, folder: folder)
        }
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

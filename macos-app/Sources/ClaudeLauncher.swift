import Foundation

enum LauncherError: Error, Equatable {
    case invalidName, exists, compileFailed, signFailed, moveFailed
}

// Builds a small app that opens one profile, so no Automator step or permission prompt is needed.
enum ClaudeLauncher {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    }

    static func script(folder: String) -> String {
        #"do shell script "/usr/bin/open -n -a Claude --args " & quoted form of ("--user-data-dir=" & POSIX path of (path to home folder) & "Library/Application Support/\#(folder)")"#
    }

    static func exists(name: String, in directory: URL = defaultDirectory) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(ProfileNames.launcherName(name)).path)
    }

    // Only a launcher this app built goes; another app with the same name stays.
    @discardableResult
    static func moveToTrash(name: String, in directory: URL = defaultDirectory,
                            trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Bool {
        let app = directory.appendingPathComponent(ProfileNames.launcherName(name))
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              info["CFBundleIdentifier"] as? String == ProfileNames.launcherIdentifier(name) else { return false }
        return (try? trash(app)) != nil
    }

    static func build(name: String, icon: URL? = nil, into directory: URL = defaultDirectory) throws -> URL {
        guard !AppMode.isDemo, ProfileNames.isValid(name) else { throw LauncherError.invalidName }
        let fm = FileManager.default
        let destination = directory.appendingPathComponent(ProfileNames.launcherName(name))
        guard !fm.fileExists(atPath: destination.path) else { throw LauncherError.exists }

        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let workspace = directory.appendingPathComponent(".aimeterbar-\(UUID().uuidString)")
        do { try fm.createDirectory(at: workspace, withIntermediateDirectories: true) } catch { throw LauncherError.moveFailed }
        defer { try? fm.removeItem(at: workspace) }

        let app = workspace.appendingPathComponent(destination.lastPathComponent)
        guard run("/usr/bin/osacompile", ["-o", app.path, "-e", script(folder: ProfileNames.folderName(name))]) else {
            throw LauncherError.compileFailed
        }
        guard configure(app: app, name: name) else { throw LauncherError.compileFailed }
        if let icon = icon {
            let target = app.appendingPathComponent("Contents/Resources/applet.icns")
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: icon, to: target)
        }
        guard run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]),
              run("/usr/bin/codesign", ["--verify", "--strict", app.path]) else {
            throw LauncherError.signFailed
        }
        do { try fm.moveItem(at: app, to: destination) } catch { throw LauncherError.moveFailed }
        return destination
    }

    private static func configure(app: URL, name: String) -> Bool {
        let url = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              var info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return false }
        info["CFBundleIdentifier"] = ProfileNames.launcherIdentifier(name)
        info["LSUIElement"] = true
        guard let output = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0) else { return false }
        return (try? output.write(to: url)) != nil
    }

    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

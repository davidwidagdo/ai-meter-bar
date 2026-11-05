import Foundation

enum ProfileNameCheck: Equatable {
    case ok, empty, invalid, taken
}

enum ProfileNames {
    private static let pattern = #"\A[A-Za-z0-9][A-Za-z0-9 -]{0,31}\z"#
    private static let folderPrefix = "Claude-"
    static let defaultFolder = "Claude"
    static let defaultName = "Default"

    private static func slug(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).split(separator: " ").joined(separator: "-")
    }

    static func isValid(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespaces).range(of: pattern, options: .regularExpression) != nil
    }

    static func check(_ raw: String, existing: [String]) -> ProfileNameCheck {
        let name = raw.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return .empty }
        guard isValid(name) else { return .invalid }
        let taken = ([defaultName] + existing).map { $0.lowercased() }
        return taken.contains(slug(name).lowercased()) ? .taken : .ok
    }

    static func folderName(_ raw: String) -> String {
        folderPrefix + slug(raw)
    }

    static func launcherName(_ raw: String) -> String {
        "Claude - \(raw.trimmingCharacters(in: .whitespaces)).app"
    }

    static func launcherIdentifier(_ raw: String) -> String {
        "com.davidwidagdo.aimeterbar.launcher.\(slug(raw).lowercased())"
    }

    // A launcher rebuilds the folder from the name, so an older folder with spaces cannot have one.
    static func canHaveLauncher(_ profile: ClaudeProfile) -> Bool {
        isValid(profile.name) && folderName(profile.name) == profile.folder
    }

    static func displayName(folder: String) -> String? {
        if folder == defaultFolder { return defaultName }
        guard folder.hasPrefix(folderPrefix), folder.count > folderPrefix.count else { return nil }
        return String(folder.dropFirst(folderPrefix.count))
    }
}

struct ClaudeProfile: Equatable {
    let folder: String
    let name: String
    let url: URL
}

enum ProfileCreateError: Error, Equatable {
    case invalidName, exists, failed
}

enum ClaudeProfiles {
    static var supportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    // Never reuses an existing folder: it may hold another account's sign-in.
    static func create(name: String, root: URL = supportRoot) throws -> ClaudeProfile {
        guard !AppMode.isDemo, ProfileNames.isValid(name) else { throw ProfileCreateError.invalidName }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let folder = ProfileNames.folderName(trimmed)
        let url = root.appendingPathComponent(folder)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw ProfileCreateError.exists }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw ProfileCreateError.failed
        }
        return ClaudeProfile(folder: folder, name: trimmed, url: url)
    }

    static func listed() -> [ClaudeProfile] {
        AppMode.isDemo ? DemoData.profiles : scan()
    }

    static func find(name: String, in profiles: [ClaudeProfile]) -> ClaudeProfile? {
        let folder = ProfileNames.folderName(name)
        return profiles.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.folder.caseInsensitiveCompare(folder) == .orderedSame
        }
    }

    static func scan(root: URL = supportRoot) -> [ClaudeProfile] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))) ?? []
        return entries.compactMap { url -> ClaudeProfile? in
            guard let name = ProfileNames.displayName(folder: url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            return ClaudeProfile(folder: url.lastPathComponent, name: name, url: url)
        }.sorted {
            if ($0.folder == ProfileNames.defaultFolder) != ($1.folder == ProfileNames.defaultFolder) {
                return $0.folder == ProfileNames.defaultFolder
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

enum ProcessArgs {
    private static let flag = "--user-data-dir="

    static func userDataDir(_ args: [String]) -> String? {
        args.first { $0.hasPrefix(flag) }.map { String($0.dropFirst(flag.count)) }
    }

    // KERN_PROCARGS2 layout: argc, executable path, padding, argv, then the environment.
    static func parse(_ raw: Data) -> [String] {
        guard raw.count > MemoryLayout<Int32>.size else { return [] }
        let argc = raw.prefix(4).enumerated().reduce(0) { $0 + Int($1.element) << ($1.offset * 8) }
        let parts = raw.dropFirst(4).split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        guard parts.count > 1 else { return [] }
        return Array(parts.dropFirst().prefix(argc))
    }
}

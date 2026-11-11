import Foundation

// Rotates to a single ".1" backup past a size cap, so the log can never grow without bound.
enum Log {
    static let fileURL: URL = {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AIMeterBar.log")
    }()

    private static let backupURL = fileURL.appendingPathExtension("1")
    private static let maxBytes = 256 * 1024
    // Callers write from main, the network queue and global queues; one queue keeps lines whole.
    private static let queue = DispatchQueue(label: "com.davidwidagdo.aimeterbar.log")

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        queue.sync {
            if formatter.timeZone != .current { formatter.timeZone = .current }
            let line = "\(formatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            rotateIfNeeded()

            // First write creates the file; later writes append.
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                try? data.write(to: fileURL)
                return
            }
            // The throwing API: the older one raises an uncatchable NSException on a full disk.
            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // A failed log write must not take the app down.
            }
        }
    }

    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > maxBytes else { return }
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
    }
}

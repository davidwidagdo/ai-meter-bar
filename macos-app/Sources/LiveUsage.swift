import Foundation

private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var result: CodexReading?
    private var finished = false
    private let now: Date
    private let maxBytes = 1_000_000

    init(now: Date) { self.now = now }

    func consume(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if chunk.isEmpty || buffer.count + chunk.count > maxBytes {
            finish()
            return
        }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            if let reading = CodexAppServerParser.reading(fromLine: line, now: now) {
                result = reading
                finish()
                return
            }
            if CodexAppServerParser.isReply(line) {
                finish()
                return
            }
        }
    }

    private func finish() {
        finished = true
        done.signal()
    }

    func wait(timeout: TimeInterval) -> CodexReading? {
        _ = done.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

// Starts Codex's own tool once and ends it, so the bar never touches the Codex login.
enum CodexAppServer {
    private static let candidates = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
    ]
    private static let timeout: TimeInterval = 8

    static func read(now: Date = Date()) -> CodexReading? {
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server"]
        // The caller's folder could hold project settings the tool would load.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // An npm install starts with env node, and a login item gets only the system PATH.
        var environment = ProcessInfo.processInfo.environment
        let folder = (path as NSString).deletingLastPathComponent
        environment["PATH"] = ([folder, "/opt/homebrew/bin", "/usr/local/bin"] + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let reader = LineReader(now: now)
        output.fileHandleForReading.readabilityHandler = { reader.consume($0.availableData) }
        guard (try? process.run()) != nil else {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        // A tool that exits early must not take this app down with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let requests = [
            #"{"method":"initialize","id":1,"params":{"clientInfo":{"name":"ai_meter_bar","title":"AI Meter Bar","version":"2.0.0"}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"method":"account/rateLimits/read","id":\#(CodexAppServerParser.requestID)}"#,
        ]
        try? input.fileHandleForWriting.write(contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8))
        let reading = reader.wait(timeout: timeout)
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        LocalCommand.stop(process)
        return reading
    }
}

// Asks the server Antigravity already runs on this Mac; nothing leaves the loopback address.
enum AntigravityServer {
    private static let binarySuffix = "/Antigravity.app/Contents/Resources/bin/language_server"
    private static let route = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    private static let maxBytes = 4_000_000

    static func read(now: Date = Date()) -> AntigravityLive? {
        guard let pid = serverPID(), let token = ProcessArgs.value(of: "--csrf_token", in: ProcessArgs.read(pid: pid)),
              let listing = LocalCommand.output("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN", "-Fn"]) else { return nil }
        for port in LoopbackPorts.parse(String(decoding: listing, as: UTF8.self)) {
            if let live = request(port: port, token: token).flatMap({ AntigravityStatusParser.live(from: $0, now: now) }) { return live }
        }
        return nil
    }

    private static func serverPID() -> pid_t? {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(capacity) * 2)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        return pids.prefix(Int(count)).first { pid in
            proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path).hasSuffix(binarySuffix)
        }
    }

    private static func request(port: Int, token: String) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(route)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = Data(#"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","locale":"en"}}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let box = ReplyBox()
        session.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200 && (data?.count ?? 0) <= maxBytes
            box.finish(ok ? data : nil)
        }.resume()
        return box.wait(timeout: 3)
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var data: Data?

    func finish(_ value: Data?) {
        lock.lock()
        data = value
        lock.unlock()
        done.signal()
    }

    func wait(timeout: TimeInterval) -> Data? {
        _ = done.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

enum LocalCommand {
    static func output(_ path: String, _ arguments: [String], timeout: TimeInterval = 2) -> Data? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    static func stop(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }
        process.terminate()
        for _ in 0..<20 where process.isRunning { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

struct LiveUsage {
    var codex: CodexReading?
    var antigravity: AntigravityLive?

    mutating func update() {
        // A hidden tool is not asked, so the bar handles no session value it will not show.
        if Settings.shared.showCodex { codex = CodexAppServer.read() ?? codex }
        if Settings.shared.showAntigravity { antigravity = AntigravityServer.read() ?? antigravity }
    }
}

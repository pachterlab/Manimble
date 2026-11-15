import Foundation
import AppKit
import Metal

enum EngineError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// Talks JSON lines to the Python engine (manim worker + source patcher).
final class Engine {
    private var proc: Process?
    private var stdin: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private let lock = NSLock()
    private var buffer = Data()
    var onEvent: (([String: Any]) -> Void)?
    /// The engine process ended without `stop` (it crashed, or could not start): its exit status, on the main queue.
    var onExit: ((Int32) -> Void)?
    private var stopping = false
    static let logURL = URL(fileURLWithPath: NSString(string: "~/Library/Logs/manimble.log").expandingTildeInPath)
    /// A line from the app in the log, for problems only the app sees (the log is what a bug report attaches).
    static func note(_ s: String) {
        let fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        let line = Data(("[app] " + s + "\n").utf8)
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    /// The app's version, the Mac's and its graphics, written at the top of the log.
    static var systemSummary: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        var translated: Int32 = 0, size = MemoryLayout<Int32>.size
        sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = translated == 1 ? "x86_64 under Rosetta" : "x86_64"
        #endif
        var model = [CChar](repeating: 0, count: 256), n = 256
        sysctlbyname("hw.model", &model, &n, nil, 0)
        let gpu = MTLCreateSystemDefaultDevice()
        return "Manimble \(version) (\(arch)) on \(String(cString: model)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString); "
            + "GPU \(gpu?.name ?? "none")\(gpu.map { $0.hasUnifiedMemory ? "" : " (separate memory)" } ?? "")"
    }

    /// The end of what the engine wrote to its log, to show when it stopped.
    static func logTail(_ lines: Int = 12) -> String {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Prefer an explicit or saved choice, then the environment the setup window (or
    /// install_manimble.sh) installed, then a checkout-local environment and login PATH.
    static func findPython() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["MANIMBLE_PYTHON"] { candidates.append(env) }
        if let saved = UserDefaults.standard.string(forKey: "python") { candidates.append(saved) }

        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(support.appendingPathComponent("Manimble/python/bin/python").path)
        }
        // Also support running Manimble.app directly from a source checkout.
        let appDirectory = Bundle.main.bundleURL.deletingLastPathComponent()
        let checkout = appDirectory.appendingPathComponent("../..").standardizedFileURL
        candidates.append(checkout.appendingPathComponent(".venv/bin/python").path)

        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        sh.arguments = ["-lc", "which -a python3 python 2>/dev/null"]
        let pipe = Pipe()
        sh.standardOutput = pipe; sh.standardError = FileHandle.nullDevice
        if (try? sh.run()) != nil {
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            candidates += out.split(separator: "\n").map(String.init)
        }
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        var seen = Set<String>()
        for c in candidates where fm.isExecutableFile(atPath: c) && !isDeveloperToolsStub(c) && seen.insert(c).inserted {
            if canImportManim(c) { return c }
        }
        return nil
    }

    /// /usr/bin/python3 (and python) is Apple's shim: on a Mac without the Command Line Tools or Xcode, running it
    /// shows the "install the command line developer tools" dialog instead of starting a Python.
    static func isDeveloperToolsStub(_ path: String) -> Bool {
        guard path.hasPrefix("/usr/bin/python") else { return false }
        let fm = FileManager.default
        return !fm.fileExists(atPath: "/Library/Developer/CommandLineTools/usr/bin/python3")
            && !fm.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/python3")
    }

    private static func canImportManim(_ python: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-c", "import manim, PIL"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let deadline = Date().addingTimeInterval(25)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); return false }
        return p.terminationStatus == 0
    }

    static func enginePath() -> String {
        if let r = Bundle.main.resourcePath, FileManager.default.fileExists(atPath: r + "/engine") { return r + "/engine" }
        if let e = ProcessInfo.processInfo.environment["MANIMBLE_ENGINE"] { return e }
        // running from a checkout (apps/macos): the shared engine lives two levels up
        return FileManager.default.currentDirectoryPath + "/../../engine"
    }

    func start(python: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-u", "-m", "manimble.rpc"]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = Engine.enginePath()
        env["MANIMBLE_PYTHON"] = python
        env["PYTHONUNBUFFERED"] = "1"
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin", "/Library/TeX/texbin", Setup.tinyTeXBin] + path.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { result, item in
                if !result.contains(item) { result.append(item) }
            }
            .joined(separator: ":")
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        FileManager.default.createFile(atPath: Engine.logURL.path, contents: nil)
        // appending, so the app's own lines (`note`) and the engine's never overwrite each other
        let fd = open(Engine.logURL.path, O_WRONLY | O_APPEND)
        p.standardError = fd >= 0 ? FileHandle(fileDescriptor: fd, closeOnDealloc: true) : nil
        Engine.note(Engine.systemSummary)
        p.terminationHandler = { [weak self] proc in self?.ended(proc) }
        stopping = false
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.feed(d)
        }
        try p.run()
        proc = p
        stdin = inPipe.fileHandleForWriting
    }

    var isRunning: Bool { proc?.isRunning ?? false }
    var pid: Int32? { proc?.processIdentifier }

    func stop() {
        stopping = true
        stdin?.closeFile()
        proc?.terminate()
    }

    /// The process is gone: every call still waiting for its answer fails now rather than never returning.
    private func ended(_ p: Process) {
        DispatchQueue.main.async { [weak self] in
            guard let self, p === self.proc else { return }       // an engine replaced since (Choose Python…)
            self.lock.lock(); let waiting = self.pending; self.pending = [:]; self.lock.unlock()
            for c in waiting.values { c.resume(throwing: EngineError.message("The Manimble engine stopped")) }
            self.stdin = nil
            if !self.stopping { self.onExit?(p.terminationStatus) }
        }
    }

    private func feed(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 10) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if obj["event"] != nil {
            DispatchQueue.main.async { self.onEvent?(obj) }
            return
        }
        guard let id = obj["id"] as? Int else { return }
        lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
        if let err = obj["error"] as? String { c?.resume(throwing: EngineError.message(err)); return }
        let result = obj["result"] ?? [String: Any]()
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])) ?? Data()
        c?.resume(returning: data)
    }

    func raw(_ cmd: String, _ args: [String: Any] = [:]) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            let id = nextID; nextID += 1
            pending[id] = cont
            lock.unlock()
            var req = args
            req["id"] = id
            req["cmd"] = cmd
            guard let data = try? JSONSerialization.data(withJSONObject: req), let stdin = stdin else {
                lock.lock(); pending.removeValue(forKey: id); lock.unlock()
                cont.resume(throwing: EngineError.message("engine not running"))
                return
            }
            var line = data; line.append(10)
            do { try stdin.write(contentsOf: line) }          // a closed pipe (the engine gone) throws, not traps
            catch {
                lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
                c?.resume(throwing: EngineError.message("The Manimble engine stopped"))
            }
        }
    }

    func call<T: Decodable>(_ cmd: String, _ args: [String: Any] = [:], as: T.Type) async throws -> T {
        let d = try await raw(cmd, args)
        return try JSONDecoder().decode(T.self, from: d)
    }
}

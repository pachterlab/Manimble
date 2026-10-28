import Foundation
import AppKit

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
        let logURL = URL(fileURLWithPath: NSString(string: "~/Library/Logs/manimble.log").expandingTildeInPath)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        p.standardError = try? FileHandle(forWritingTo: logURL)
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

    func stop() {
        stdin?.closeFile()
        proc?.terminate()
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
            stdin.write(line)
        }
    }

    func call<T: Decodable>(_ cmd: String, _ args: [String: Any] = [:], as: T.Type) async throws -> T {
        let d = try await raw(cmd, args)
        return try JSONDecoder().decode(T.self, from: d)
    }
}

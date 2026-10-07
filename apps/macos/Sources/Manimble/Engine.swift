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

    /// The saved choice, $MANIMBLE_PYTHON, then every python3/python on the login shell's PATH (plus the usual
    /// Homebrew locations): the first one that can import manim and Pillow wins.
    static func findPython() -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let saved = UserDefaults.standard.string(forKey: "python") { candidates.append(saved) }
        if let env = ProcessInfo.processInfo.environment["MANIMBLE_PYTHON"] { candidates.append(env) }
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
        for c in candidates where fm.isExecutableFile(atPath: c) && seen.insert(c).inserted {
            if canImportManim(c) { return c }
        }
        return nil
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

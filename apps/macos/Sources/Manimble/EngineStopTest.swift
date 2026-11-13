import AppKit

/// MANIMBLE_TEST_ENGINESTOP: headless check that the engine dying mid-edit doesn't leave the app waiting: the
/// edit queue finishes, the engine starts again on the same working copy, and the next edit works. Runs on the
/// hello deck; enginestop.log in MANIMBLE_TEST_OUT.
extension MainController {
    func engineStopTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        try? "".write(toFile: dir + "enginestop.log", atomically: true, encoding: .utf8)
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "enginestop.log") }
        func settle() async { await queueTail?.value; try? await Task.sleep(nanoseconds: 800_000_000) }
        func id(_ v: String) -> Int? { scene?.objects?.first(where: { $0.value.value == v }).flatMap { Int($0.key) } }
        Task { @MainActor in
            await selectScene("Shapes")
            await settle()
            guard let cap = id("drag, resize, retype"), let head = id("Shapes, lines and text"), let pid = engine.pid,
                  let ws = workspace else { log("setup"); exit(1) }
            commitText(head, "kept heading", shared: false)               // an unsaved edit the restart must keep
            await settle()
            commitText(cap, "lost with the engine", shared: false)
            for _ in 0..<100 where busy == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }   // the edit is with the engine
            log("an edit in flight when the engine dies: \(queuedWork > 0 && busy > 0)")
            kill(pid, SIGKILL)
            let t0 = Date()
            for _ in 0..<80 where queuedWork > 0 { try? await Task.sleep(nanoseconds: 100_000_000) }
            log("queue finished after the engine died: \(queuedWork == 0) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s; stops seen=\(engineStops)")
            for _ in 0..<120 where !(engine.isRunning && engine.pid != pid && scene?.status == "ready") {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            await reloadState()
            let text = (try? String(contentsOf: ws.work.appendingPathComponent("slides.py"), encoding: .utf8)) ?? ""
            log("engine running again=\(engine.isRunning && engine.pid != pid) same working copy=\(workspace === ws) slides=\(state?.scenes.count ?? 0) unsaved edit kept=\(text.contains("kept heading"))")
            if let c = id("drag, resize, retype") ?? id("lost with the engine") { commitText(c, "after restart", shared: false) }
            await settle()
            let after = (try? String(contentsOf: ws.work.appendingPathComponent("slides.py"), encoding: .utf8)) ?? ""
            log("edit after restart landed=\(after.contains("after restart"))")
            log("done")
            exit(0)
        }
    }
}

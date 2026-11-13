import AppKit

/// MANIMBLE_TEST_WORKSPACE: headless check of the working copy. Save right after a move waits for it; Save
/// writes back a package's edits, a new folder and a deleted file; Revert removes new files and leaves no undo
/// step. Runs on the hello deck with `lib/` (Python), `data/` (no Python) and `extra.txt` added; workspace.log in
/// MANIMBLE_TEST_OUT.
extension MainController {
    func workspaceTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        try? "".write(toFile: dir + "workspace.log", atomically: true, encoding: .utf8)
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "workspace.log") }
        func settle() async { await queueTail?.value; try? await Task.sleep(nanoseconds: 800_000_000) }
        guard let ws = workspace else { log("no workspace"); exit(1) }
        let fm = FileManager.default
        func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "<none>" }
        func isLink(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true }
        func waitSaved() async { for _ in 0..<120 where busy > 0 || editsInFlight { try? await Task.sleep(nanoseconds: 250_000_000) }
                                 try? await Task.sleep(nanoseconds: 500_000_000) }
        Task { @MainActor in
            await selectScene("Shapes")
            await settle()
            guard let box = scene?.objects?.first(where: { $0.value.value == "Rectangle" }).flatMap({ Int($0.key) }) else { log("no box"); exit(1) }
            let orig = ws.original.appendingPathComponent("slides.py")
            let before = read(orig)

            // Save pressed while a move is still on its way
            selection = box
            canvas.overrides[box] = Override(dx: 90, dy: 0)
            commitMove(box, 90, 0)
            log("in flight at Save: \(editsInFlight)")
            saveToOriginal()
            await waitSaved()
            let boxLine = { (t: String) in t.split(separator: "\n").first { $0.contains("box = Rectangle(") }.map { $0.trimmingCharacters(in: .whitespaces) } ?? "-" }
            log("original after Save: moved=\(read(orig) != before) | \(boxLine(read(orig)))")

            // folders: a package is a real copy, other folders link to the original
            let lib = ws.work.appendingPathComponent("lib"), data = ws.work.appendingPathComponent("data")
            log("lib is a copy=\(!isLink(lib)) data is a link=\(isLink(data))")
            try? (read(lib.appendingPathComponent("shapes.py")) + "EDITED = True\n").write(to: lib.appendingPathComponent("shapes.py"), atomically: true, encoding: .utf8)
            try? fm.createDirectory(at: ws.work.appendingPathComponent("figures"), withIntermediateDirectories: true)
            try? "X = 1\n".write(to: ws.work.appendingPathComponent("figures/new.py"), atomically: true, encoding: .utf8)
            try? fm.removeItem(at: ws.work.appendingPathComponent("extra.txt"))
            log("before Save the original's lib edited=\(read(ws.original.appendingPathComponent("lib/shapes.py")).contains("EDITED"))")
            log("changed: \(ws.changedFiles)")
            saveToOriginal()
            await waitSaved()
            log("after Save: lib edited=\(read(ws.original.appendingPathComponent("lib/shapes.py")).contains("EDITED")) figures/new.py=\(fm.fileExists(atPath: ws.original.appendingPathComponent("figures/new.py").path)) extra.txt gone=\(!fm.fileExists(atPath: ws.original.appendingPathComponent("extra.txt").path)) modified=\(ws.isModified)")

            // Revert: new files go, edits go, no undo step leads back
            try? "Y = 2\n".write(to: ws.work.appendingPathComponent("scratch_new.py"), atomically: true, encoding: .utf8)
            if let cap = scene?.objects?.first(where: { $0.value.value == "drag, resize, retype" }).flatMap({ Int($0.key) }) {
                commitText(cap, "to be reverted", shared: false)
            }
            await settle(); await reloadState()
            log("before Revert: can undo=\(state?.canUndo ?? false) changed=\(ws.changedFiles)")
            revertWorkingCopy()
            await settle(); await reloadState()
            log("after Revert: scratch_new.py gone=\(!fm.fileExists(atPath: ws.work.appendingPathComponent("scratch_new.py").path)) caption back=\(read(ws.work.appendingPathComponent("slides.py")).contains("drag, resize, retype")) can undo=\(state?.canUndo ?? true) modified=\(ws.isModified)")
            // a command running in the terminal is seen (Close asks about it), and closing the deck ends the shells
            terminal.start(in: ws.work.path, original: ws.original.path)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            log("terminal at its prompt runs: \(terminal.runningCommands)")
            terminal.type("sleep 30\r")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            log("terminal running: \(terminal.runningCommands)")
            terminal.terminateAll()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            log("after closing the shells: \(terminal.runningCommands)")
            log("done")
            exit(0)
        }
    }
}

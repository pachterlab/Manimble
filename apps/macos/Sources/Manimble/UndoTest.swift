import AppKit
import SwiftTerm

/// MANIMBLE_TEST_UNDO: headless check that Edit ▸ Undo acts on what is being typed in: the Python code pane, a
/// terminal's shell line, and the deck only when the slide has focus. Runs on the hello example deck; undo.log in
/// MANIMBLE_TEST_OUT.
extension MainController {
    func undoTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        try? "".write(toFile: dir + "undo.log", atomically: true, encoding: .utf8)
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "undo.log") }
        func settle() async { await queueTail?.value; try? await Task.sleep(nanoseconds: 800_000_000) }
        let undoItem = NSApp.mainMenu?.items.lazy.compactMap { $0.submenu?.item(withTitle: "Undo") }.first
        func menuUndo() -> Bool {
            guard let u = undoItem, let a = u.action else { return false }
            let enabled = (u.target as? NSMenuItemValidation)?.validateMenuItem(u) ?? false
            if enabled { NSApp.sendAction(a, to: u.target, from: u) }
            return enabled
        }
        func caption() -> String {
            scene?.objects?.values.first(where: { $0.value == "drag, resize, retype" || $0.value == "undo me" })?.value ?? "-"
        }
        Task { @MainActor in
            await selectScene("Shapes")
            await settle()
            guard let oid = scene?.objects?.first(where: { $0.value.value == "drag, resize, retype" }).flatMap({ Int($0.key) }) else {
                log("no caption"); exit(1)
            }
            commitText(oid, "undo me", shared: false)
            await settle()
            log("deck edit: caption='\(caption())'")

            // the code pane: ⌘Z takes back typing, not the deck's edit
            window.makeFirstResponder(sourceView)
            let before = sourceView.string
            sourceView.setSelectedRange(NSRange(location: (before as NSString).length, length: 0))
            sourceView.insertText("\n# typed", replacementRange: sourceView.selectedRange())
            sourceView.breakUndoCoalescing()
            log("code pane typed: \(sourceView.string.hasSuffix("# typed"))")
            log("code pane undo enabled: \(menuUndo())")
            await settle()
            log("code pane after undo: back to its text=\(sourceView.string == before) caption='\(caption())'")

            // a terminal: ⌘Z is the shell's undo (Ctrl-_), the deck stays as it is
            let term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
            window.contentView?.addSubview(term)
            term.startProcess(executable: "/bin/zsh", args: ["-f"], environment: ["TERM=xterm-256color", "PS1=$ "], execName: "zsh")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for _ in 0..<30 where !(NSApp.keyWindow === window && window.firstResponder === term) {
                NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(term)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            log("terminal has focus: \(NSApp.keyWindow === window && window.firstResponder === term)")
            term.send(txt: "echo ab")
            try? await Task.sleep(nanoseconds: 500_000_000)
            log("terminal undo enabled: \(menuUndo())")
            try? await Task.sleep(nanoseconds: 500_000_000)
            term.send(txt: "Z\r")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let screen = String(data: term.getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
            let lines = screen.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("$") }
            log("terminal printed: \(lines.first ?? "-") (typed 'echo ab', ⌘Z, 'Z')")
            await settle()
            log("caption after terminal undo: '\(caption())'")
            term.terminate(); term.removeFromSuperview()

            // the slide: ⌘Z undoes the deck
            window.makeFirstResponder(canvas)
            log("slide undo enabled: \(menuUndo())")
            await settle()
            log("caption after slide undo: '\(caption())'")
            log("done")
            exit(0)
        }
    }
}

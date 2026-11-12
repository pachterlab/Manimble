import AppKit
import SwiftTerm

/// MANIMBLE_TEST_CLIPBOARD: headless check of what each Edit command acts on in each place it can be given: the
/// slide, the code pane, an inspector field, a terminal, and another window with or without a text box. Runs on
/// the hello example deck; clipboard.log in MANIMBLE_TEST_OUT.
extension MainController {
    func clipboardTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        try? "".write(toFile: dir + "clipboard.log", atomically: true, encoding: .utf8)
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "clipboard.log") }
        func settle() async { await queueTail?.value; try? await Task.sleep(nanoseconds: 800_000_000) }
        func item(_ t: String) -> NSMenuItem? { NSApp.mainMenu?.items.lazy.compactMap { $0.submenu?.item(withTitle: t) }.first }
        let names = ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All", "Find…", "Find Next"]
        func row(_ place: String) {
            let cells = names.compactMap { n -> String? in
                guard let i = item(n), let a = i.action, let r = i.target as? NSObject else { return nil }
                let on = (r as? NSMenuItemValidation)?.validateMenuItem(i) ?? false
                let to = r.forwardingTarget(for: a).map { "\(type(of: $0))" } ?? "\(type(of: r))"
                return "\(n)=\(on ? to : "off")"
            }
            log("\(place): " + cells.joined(separator: "  "))
        }
        func press(_ n: String) { if let i = item(n), let a = i.action, (i.target as? NSMenuItemValidation)?.validateMenuItem(i) == true { NSApp.sendAction(a, to: i.target, from: i) } }
        func pasteboard() -> String { NSPasteboard.general.string(forType: .string) ?? "-" }
        Task { @MainActor in
            await selectScene("Shapes")
            await settle()
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)

            window.makeFirstResponder(canvas); canvas.selectAllObjects()
            row("slide, all selected")

            window.makeFirstResponder(sourceView)
            sourceView.setSelectedRange(NSRange(location: 0, length: 5))
            row("code pane")
            press("Copy"); log("  copy in the code pane: '\(pasteboard())' (its first 5 characters: '\((sourceView.string as NSString).substring(to: 5))')")

            if let field = textField { window.makeFirstResponder(field) }
            row("inspector text box")

            let term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
            window.contentView?.addSubview(term)
            term.startProcess(executable: "/bin/zsh", args: ["-f"], environment: ["TERM=xterm-256color", "PS1=$ "], execName: "zsh")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            window.makeFirstResponder(term)
            canvas.selectAllObjects()
            for _ in 0..<30 where !(NSApp.keyWindow === window && window.firstResponder === term) {
                NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(term)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let objects = canvas.selectedIDs.count
            log("  terminal has focus: \(NSApp.keyWindow === window && window.firstResponder === term), \(objects) objects selected")
            row("terminal, nothing selected")
            press("Select All")
            row("terminal, after Select All")
            press("Copy"); log("  copy in the terminal starts with: '\(pasteboard().prefix(2))'")
            press("Find…"); try? await Task.sleep(nanoseconds: 300_000_000)
            log("  find in the terminal opened its find bar: \(term.subviews.contains { "\(type(of: $0))".contains("Find") })")
            window.makeFirstResponder(term)
            press("Cut"); await settle()
            log("  cut in the terminal left the slide's \(objects) selected objects: \(scene?.objects?.count ?? 0 >= objects)")
            term.terminate(); term.removeFromSuperview()

            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            let plain = NSView(frame: other.contentView!.bounds)
            other.contentView?.addSubview(plain)
            for _ in 0..<30 where NSApp.keyWindow !== other {
                NSApp.activate(ignoringOtherApps: true); other.makeKeyAndOrderFront(nil); other.makeFirstResponder(nil)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            log("  other window is key: \(NSApp.keyWindow === other)")
            row("another window")
            let notes = NSTextView(frame: other.contentView!.bounds); notes.allowsUndo = true
            other.contentView?.addSubview(notes); other.makeFirstResponder(notes)
            notes.insertText("note", replacementRange: notes.selectedRange()); notes.breakUndoCoalescing()
            row("another window's text box")
            press("Undo"); log("  undo in the other window's text: '\(notes.string)'")
            other.orderOut(nil)
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas)
            log("done")
            exit(0)
        }
    }
}

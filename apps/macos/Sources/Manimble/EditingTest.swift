import AppKit
import SwiftTerm

/// MANIMBLE_TEST_EDITING: headless check of Select All on the slide, the Edit menu acting on the code editor and
/// the terminal, typing into text again after an undo, and a show that starts on the slide on screen and comes
/// back to the one it ended on. Runs on the hello example deck; editing.log in MANIMBLE_TEST_OUT.
extension MainController {
    func editingTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        try? "".write(toFile: dir + "editing.log", atomically: true, encoding: .utf8)
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "editing.log") }
        func settle() async { await queueTail?.value; try? await Task.sleep(nanoseconds: 800_000_000) }
        func menuItem(_ title: String) -> NSMenuItem? {
            NSApp.mainMenu?.items.lazy.compactMap { $0.submenu?.item(withTitle: title) }.first
        }
        Task { @MainActor in
            await selectScene("Shapes")
            await settle()

            // Select All on the slide
            window.makeFirstResponder(canvas)
            selectAll(nil)
            log("select all: \(canvas.selectedIDs.count) selected of \(canvas.stop?.visible.count ?? 0) visible")

            // text typed again after an undo starts from the slide's text, not the inspector's last copy
            guard let oid = scene?.objects?.first(where: { $0.value.value == "drag, resize, retype" }).flatMap({ Int($0.key) }) else {
                log("no caption"); exit(1)
            }
            selection = oid
            commitText(oid, "edited caption", shared: false)
            await settle()
            log("after edit: slide='\(scene?.objects?[String(oid)]?.value ?? "-")' inspector='\(textField?.stringValue ?? "-")'")
            doUndo(redo: false)
            await settle()
            selection = oid
            log("after undo: slide='\(scene?.objects?[String(oid)]?.value ?? "-")' inspector='\(textField?.stringValue ?? "-")'")
            if let o = scene?.objects?[String(oid)], beginInlineText(oid, o, at: nil), let ed = window.firstResponder as? NSTextView {
                log("typing again starts from: '\(ed.string)'")
                canvas.finishTextEdit(commit: false)
            } else { log("inline editor did not open") }
            await settle()

            // the show starts on the slide on screen, and leaving it comes back to the slide it was on
            await selectScene("Shapes")
            play(fromCurrent: true)
            for _ in 0..<200 { try? await Task.sleep(nanoseconds: 100_000_000); if player != nil { break } }
            if let p = player {
                try? await Task.sleep(nanoseconds: 600_000_000)
                log("stills show opens on: \(p.presenterPage(p.pageIndex).scene ?? "-")")
                p.next(); try? await Task.sleep(nanoseconds: 400_000_000)
                log("stills show after next: \(p.presenterPage(p.pageIndex).scene ?? "-") build \(p.presenterPage(p.pageIndex).build)")
                p.exit(); await settle()
                log("editor after leaving stills show: \(sceneName ?? "-") build \(stopIndex)")
            } else { log("no stills show") }

            await selectScene("Shapes")
            present(fromCurrent: true)
            for _ in 0..<1200 { try? await Task.sleep(nanoseconds: 100_000_000); if animatedPlayer != nil { break } }
            if let p = animatedPlayer {
                try? await Task.sleep(nanoseconds: 600_000_000)
                log("animated show opens on: \(p.currentSlide?.scene ?? "-")")
                p.next(); try? await Task.sleep(nanoseconds: 400_000_000)
                p.next(); try? await Task.sleep(nanoseconds: 400_000_000)
                log("animated show after 2 nexts: \(p.currentSlide?.scene ?? "-") build \(p.currentSlide?.index ?? -1)")
                p.exit(); await settle()
                log("editor after leaving animated show: \(sceneName ?? "-") build \(stopIndex)")
            } else { log("no animated show") }

            // Paste, Copy and Select All go to the code editor or terminal being typed in
            log("key window is the deck window: \(NSApp.keyWindow === window)")
            if let paste = menuItem("Paste"), let router = paste.target as? NSObject {
                window.makeFirstResponder(canvas)
                log("paste on the slide goes to: \(type(of: router.forwardingTarget(for: paste.action!) ?? "nil"))")
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString("x = 1", forType: .string)
                window.makeFirstResponder(sourceView)
                let enabled = (router as? NSMenuItemValidation)?.validateMenuItem(paste) ?? false
                log("paste in the code editor goes to: \(type(of: router.forwardingTarget(for: paste.action!) ?? "nil")) enabled=\(enabled)")
                let term = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
                window.contentView?.addSubview(term)
                window.makeFirstResponder(term)
                log("paste in a terminal goes to: \(type(of: router.forwardingTarget(for: paste.action!) ?? "nil"))")
                if let all = menuItem("Select All") {
                    log("select all in a terminal goes to: \(type(of: router.forwardingTarget(for: all.action!) ?? "nil"))")
                }
                term.removeFromSuperview()
                window.makeFirstResponder(canvas)
            } else { log("no Paste item") }
            log("done")
            exit(0)
        }
    }
}

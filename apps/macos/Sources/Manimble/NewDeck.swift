import AppKit

extension MainController {
    // MARK: new deck

    /// File ▸ New Deck…: make a project folder holding a one-slide deck (the same files an import writes) and open it.
    @objc func newDeck() {
        guard confirmClose(for: "creating a new deck") else { return }
        let save = NSSavePanel()
        save.message = "Where should the new deck be created? A folder with this name is made."
        save.nameFieldStringValue = "Untitled Deck"
        save.prompt = "Create Deck"
        save.canCreateDirectories = true
        guard save.runModal() == .OK, let dest = save.url else { return }
        let deck = dest.appendingPathComponent("deck")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: deck.path) else {
            alert("Could not create the deck", "\(dest.lastPathComponent) already holds a deck. Open it with File ▸ Open Deck or Project…, or choose another name.")
            return
        }
        do {
            try fm.createDirectory(at: deck, withIntermediateDirectories: true)
            try fm.createDirectory(at: dest.appendingPathComponent("assets"), withIntermediateDirectories: true)
            try MainController.newDeckFiles(title: dest.lastPathComponent).forEach { name, text in
                try text.write(to: deck.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        } catch {
            alert("Could not create the deck", "\(error.localizedDescription)")
            return
        }
        open(deck: deck.path, confirmed: true)
    }

    /// A title slide laid out like Slide ▸ New Slide ▸ Title Slide, on the importer's common.py and manim.cfg.
    static func newDeckFiles(title: String) -> [(String, String)] {
        let quoted = "\"" + title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        return [
            ("common.py", """
            \"\"\"Shared base class for the deck.\"\"\"

            from pathlib import Path

            from manim import *
            from manim_slides import Slide

            ASSETS = Path(__file__).resolve().parent.parent / "assets"


            class Deck(Slide):
                skip_reversing = True

            """),
            ("slides.py", """
            \"\"\"Slides of the deck.\"\"\"

            from common import *


            class Title(Deck):
                def construct(self):
                    title = Text(\(quoted), font_size=64).move_to((0, 0.7, 0))  # manimble
                    self.add(title)  # manimble
                    subtitle = Text("Subtitle", font_size=32, color=GREY_B).move_to((0, -0.8, 0))  # manimble
                    self.add(subtitle)  # manimble

            """),
            ("order.txt", "Title\n"),
            ("manim.cfg", "[CLI]\nbackground_color = #000000\npixel_width = 1280\npixel_height = 720\nframe_rate = 30\n"),
        ]
    }

    // MARK: no deck open

    /// Closing the window closes the deck; the app keeps running so another can be made or opened.
    func closeDeck() {
        closeAnimationPreview()
        workspace?.discard(); workspace = nil
        state = nil; sceneName = nil; scene = nil; selection = nil
        sourceDraft = nil; sourceEditBase = nil; sourceEditSceneName = nil; sourceFocused = false
        canvas.stop = nil
        sourceView.string = ""
        notesBox.setText("")
        suppressTable = true; table.reloadData(); suppressTable = false
        rebuildSteps()
        window.isDocumentEdited = false
        window.title = "Manimble"; window.subtitle = ""
    }

    /// Clicking the Dock icon with the window closed brings it back and asks for a deck.
    func reopenWindow() {
        window.makeKeyAndOrderFront(nil)
        if workspace == nil { chooseDeck() }
    }

    /// With no deck open: make a new one or open one.
    func chooseDeck() {
        let a = NSAlert()
        a.messageText = "No deck is open"
        a.informativeText = "Create a new deck, or open a deck folder, project folder or .manimble package."
        a.addButton(withTitle: "New Deck…"); a.addButton(withTitle: "Open…"); a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: newDeck()
        case .alertSecondButtonReturn: openDeck()
        default: break
        }
    }
}

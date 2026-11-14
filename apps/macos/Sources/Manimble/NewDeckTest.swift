import AppKit

/// MANIMBLE_TEST_NEWDECK: headless check that a new deck's slides follow their code. Closes the launch deck, makes
/// a deck the way File ▸ New Deck does (twice at the same place, as when a deck is deleted and made again), then
/// changes the first slide's code from outside (as an agent would) and on the canvas; newdeck.log in MANIMBLE_TEST_OUT.
extension MainController {
    func newDeckTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        try? "".write(toFile: dir + "newdeck.log", atomically: true, encoding: .utf8)
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "newdeck.log") }
        let fm = FileManager.default
        func title() -> String { scene?.objects?.values.map(\.value).sorted().joined(separator: " | ") ?? "-" }
        func waitIdle() async {
            for _ in 0..<160 where busy > 0 || editsInFlight || workspace == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
        }
        func make(_ name: String, theme: DeckTheme?) -> String {
            let dest = URL(fileURLWithPath: dir + name)
            try? fm.removeItem(at: dest)
            let deck = dest.appendingPathComponent("deck")
            try? fm.createDirectory(at: deck, withIntermediateDirectories: true)
            try? fm.createDirectory(at: dest.appendingPathComponent("assets"), withIntermediateDirectories: true)
            for (n, t) in MainController.newDeckFiles(title: name, theme: theme) {
                try? t.write(to: deck.appendingPathComponent(n), atomically: true, encoding: .utf8)
            }
            return deck.path
        }
        /// Waits up to `seconds` for the canvas to show `text`, as the refresh timer would.
        func shows(_ text: String, within seconds: Int) async -> Bool {
            for _ in 0..<(seconds * 4) {
                if title().contains(text) { return true }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            return false
        }
        Task { @MainActor in
            for (round, theme) in [(1, DeckTheme.all.first), (2, DeckTheme.all.dropFirst().first)] {
                closeDeck()
                open(deck: make("Untitled Deck", theme: theme ?? nil), confirmed: true)
                try? await Task.sleep(nanoseconds: 500_000_000)
                await waitIdle()
                guard let ws = workspace else { log("round \(round): no workspace"); exit(1) }
                log("round \(round) theme=\(theme?.name ?? "none") opened: slide=\(sceneName ?? "-") shows: \(title())")
                let f = ws.work.appendingPathComponent("slides.py")
                // an agent rewrites the title
                let code = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
                try? code.replacingOccurrences(of: "\"Subtitle\"", with: "\"Agent subtitle \(round)\"")
                    .write(to: f, atomically: true, encoding: .utf8)
                log("round \(round) agent edit shown: \(await shows("Agent subtitle \(round)", within: 20)) | \(title()) | status=\(state?.scenes.first?.status ?? "-")")
                // and an agent adds a second slide
                let more = ((try? String(contentsOf: f, encoding: .utf8)) ?? "") + """

                    class Second(Deck):
                        def construct(self):
                            self.add(Text("Second slide"))

                    """
                try? more.write(to: f, atomically: true, encoding: .utf8)
                try? "Title\nSecond\n".write(to: ws.work.appendingPathComponent("order.txt"), atomically: true, encoding: .utf8)
                for _ in 0..<40 where state?.scenes.count != 2 { try? await Task.sleep(nanoseconds: 250_000_000) }
                log("round \(round) slides: \(state?.scenes.map { "\($0.name):\($0.status)" } ?? [])")
                try? (try? String(contentsOf: f, encoding: .utf8))?.replacingOccurrences(of: "Agent subtitle \(round)", with: "Second agent edit \(round)")
                    .write(to: f, atomically: true, encoding: .utf8)
                log("round \(round) second agent edit shown: \(await shows("Second agent edit \(round)", within: 20)) | \(title())")
                // an edit on the canvas
                if let sub = scene?.objects?.first(where: { $0.value.value.contains("Second agent edit") }).flatMap({ Int($0.key) }) {
                    commitText(sub, "Canvas edit \(round)", shared: false)
                    await waitIdle()
                    log("round \(round) canvas edit shown: \(await shows("Canvas edit \(round)", within: 20)) | \(title())")
                }
            }
            // an agent replaces the starter slide with slides of its own: the canvas moves to the show's first
            closeDeck()
            open(deck: make("Untitled Deck", theme: nil), confirmed: true)
            try? await Task.sleep(nanoseconds: 500_000_000)
            await waitIdle()
            guard let ws = workspace else { log("round 3: no workspace"); exit(1) }
            log("round 3 opened: slide=\(sceneName ?? "-") shows: \(title())")
            let f = ws.work.appendingPathComponent("slides.py")
            try? """
                from common import *


                class Intro(Deck):
                    def construct(self):
                        self.add(Text("Agent intro"))


                class Methods(Deck):
                    def construct(self):
                        self.add(Text("Agent methods"))

                """.write(to: f, atomically: true, encoding: .utf8)
            try? "Intro\nMethods\n".write(to: ws.work.appendingPathComponent("order.txt"), atomically: true, encoding: .utf8)
            log("round 3 replaced slides shown: \(await shows("Agent intro", within: 20)) | slide=\(sceneName ?? "-") shows: \(title()) | navigator: \(navigatorScenes.map(\.name))")
            // the project moved in the Finder while open: Save refuses rather than make a partial deck at the old place
            if let ws = workspace {
                let project = ws.original.deletingLastPathComponent()
                let moved = project.deletingLastPathComponent().appendingPathComponent("Moved Deck")
                try? fm.removeItem(at: moved)
                try? fm.moveItem(at: project, to: moved)
                var err = "none"
                do { try ws.save() } catch { err = error.localizedDescription }
                log("save after move: modified=\(ws.isModified) refused=\(err != "none") old place recreated=\(fm.fileExists(atPath: project.path)) | \(err.prefix(70))")
            }
            log("done")
            exit(0)
        }
    }
}

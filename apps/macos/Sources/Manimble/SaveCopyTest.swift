import AppKit

/// MANIMBLE_TEST_SAVECOPY: headless check of a new deck's way to disk. Makes a deck as File ▸ New Deck does, adds a
/// picture and a data file a slide reads, edits on the canvas and saves a project copy while the edit is still on its
/// way; opens the copy and checks every slide renders there; packages it, opens the package, edits and saves.
/// savecopy.log in MANIMBLE_TEST_OUT.
extension MainController {
    func saveCopyTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        try? "".write(toFile: dir + "savecopy.log", atomically: true, encoding: .utf8)
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "savecopy.log") }
        let fm = FileManager.default
        func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "<none>" }
        func values() -> String { scene?.objects?.values.map(\.value).sorted().joined(separator: " | ") ?? "-" }
        func waitIdle() async {
            try? await Task.sleep(nanoseconds: 500_000_000)
            for _ in 0..<240 where busy > 0 || editsInFlight || workspace == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
        }
        func waitRendered() async {
            for _ in 0..<240 where state?.scenes.contains(where: { $0.status != "ready" && $0.status != "error" }) ?? true {
                try? await Task.sleep(nanoseconds: 250_000_000); await reloadState()
            }
        }
        func files(_ u: URL) -> [String] {
            let base = u.standardizedFileURL.path + "/"
            return (fm.enumerator(at: u, includingPropertiesForKeys: nil)?.compactMap { ($0 as? URL)?.standardizedFileURL.path }
                .filter { !$0.contains("/media/") && !$0.contains("/slides/") }.map { String($0.dropFirst(base.count)) } ?? []).sorted()
        }
        Task { @MainActor in
            closeDeck()
            let src = URL(fileURLWithPath: dir + "src/Copy Test")
            try? fm.removeItem(at: src.deletingLastPathComponent())
            let deck = src.appendingPathComponent("deck")
            try? fm.createDirectory(at: deck, withIntermediateDirectories: true)
            try? fm.createDirectory(at: src.appendingPathComponent("assets"), withIntermediateDirectories: true)
            for (n, t) in MainController.newDeckFiles(title: "Copy Test", theme: DeckTheme.all.first) {
                try? t.write(to: deck.appendingPathComponent(n), atomically: true, encoding: .utf8)
            }
            open(deck: deck.path, confirmed: true)
            await waitIdle()
            guard let ws = workspace else { log("no workspace"); exit(1) }
            log("opened: \(sceneName ?? "-") | \(values())")

            // a picture in assets, and a slide that reads a data file in the deck folder
            let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            try? png.representation(using: .png, properties: [:])?.write(to: ws.work.deletingLastPathComponent().appendingPathComponent("assets/pic.png"))
            try? "From the data file\n".write(to: ws.work.appendingPathComponent("caption.txt"), atomically: true, encoding: .utf8)
            let f = ws.work.appendingPathComponent("slides.py")
            try? (read(f) + """

                class Data(Deck):
                    def construct(self):
                        self.add(ImageMobject(str(ASSETS / "pic.png")).to_edge(UP))
                        self.add(Text(open(Path(__file__).parent / "caption.txt").read().strip()))

                """).write(to: f, atomically: true, encoding: .utf8)
            try? "Title\nData\n".write(to: ws.work.appendingPathComponent("order.txt"), atomically: true, encoding: .utf8)
            await reloadState(); await waitRendered()
            log("slides: \(state?.scenes.map { "\($0.name):\($0.status)" } ?? [])")

            // an edit on the canvas, still on its way when the copy is asked for
            await selectScene("Title"); await waitIdle()
            if let sub = scene?.objects?.first(where: { $0.value.value == "Subtitle" }).flatMap({ Int($0.key) }) {
                commitText(sub, "Edited before the copy", shared: false)
            }
            log("edit in flight at Save Project Copy: \(editsInFlight)")
            let parent = URL(fileURLWithPath: dir + "copies")
            try? fm.removeItem(at: parent); try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            saveProjectCopy(in: parent)
            await waitIdle()
            guard let copy = (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil))?.first else {
                log("no copy made"); exit(1)
            }
            log("copy: \(copy.lastPathComponent)")
            log("copy files: \(files(copy))")
            let copyDeck = try? PortableProject.deckURL(in: copy)
            log("copy has the edit: \(copyDeck.map { read($0.appendingPathComponent("slides.py")).contains("Edited before the copy") } ?? false)")
            log("original untouched: \(!read(deck.appendingPathComponent("slides.py")).contains("Edited before the copy")) | working copy still edited: \(ws.isModified)")

            // the copy opens and renders on its own
            closeDeck()
            openProject(at: copy)
            await waitIdle(); await waitRendered()
            log("copy opened: \(workspace?.original.path.hasPrefix(copy.resolvingSymlinksInPath().path) ?? false) | title: \(window.title)")
            log("copy slides: \(state?.scenes.map { "\($0.name):\($0.status)" } ?? []) errors: \(state?.scenes.compactMap(\.error) ?? [])")
            await selectScene("Data"); await waitIdle()
            log("copy's Data slide: \(values())")

            // package it, open the package, edit, save: where does the save go?
            let pkg = URL(fileURLWithPath: dir + "copies/Copy Test.manimble")
            if let w = workspace { savePortableProject(workspace: w, destination: pkg, archive: true) }
            await waitIdle()
            log("package made: \(fm.fileExists(atPath: pkg.path))")
            closeDeck()
            openProject(at: pkg)
            await waitIdle(); await waitRendered()
            log("package opened at: \(workspace?.original.path ?? "-")")
            await selectScene("Title"); await waitIdle()
            if let sub = scene?.objects?.first(where: { $0.value.value == "Edited before the copy" }).flatMap({ Int($0.key) }) {
                commitText(sub, "Edited in the package", shared: false)
            }
            await waitIdle()
            let pkgBefore = (try? fm.attributesOfItem(atPath: pkg.path))?[.modificationDate] as? Date
            saveToOriginal()
            await waitIdle()
            let pkgAfter = (try? fm.attributesOfItem(atPath: pkg.path))?[.modificationDate] as? Date
            log("after Save: package file changed=\(pkgBefore != pkgAfter) | saved into: \(workspace?.original.path ?? "-")")
            let unpacked = ProcessInfo.processInfo.environment["MANIMBLE_TEST_UNPACK"] ?? "-"
            log("unpacked folder has the edit: \(read(URL(fileURLWithPath: unpacked + "/Copy Test/deck/slides.py")).contains("Edited in the package")) | recent: \(RecentDecks.paths.first ?? "-")")
            log("done")
            exit(0)
        }
    }
}

import AppKit

extension MainController {
    /// Format ▸ Hyperlink… (⌘K) and the text box's right-click menu: a box for the URL the text opens when it is
    /// clicked in a show. An empty box (or Remove Link) takes the link off.
    @objc func hyperlinkPressed() {
        guard let s = selection, let o = objInfo, o.kind == "text" || o.kind == "tex" else { return }
        let current = o.format?.link
        let a = NSAlert()
        a.messageText = current == nil ? "Add Hyperlink" : "Edit Hyperlink"
        a.informativeText = "Clicking this text in a slideshow or Presenter View opens the link."
        let field = NSTextField(string: current ?? "")
        field.placeholderString = "https://example.com"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        a.accessoryView = field
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Cancel")
        if current != nil { a.addButton(withTitle: "Remove Link") }
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: window) { [weak self] r in
            guard let self else { return }
            let url: String
            switch r {
            case .alertFirstButtonReturn: url = MainController.normalizedLink(field.stringValue)
            case .alertThirdButtonReturn: url = ""
            default: return
            }
            guard url != (current ?? "") else { return }
            self.submit { [weak self] in await self?.runEdit(["op": "link", "oid": s, "url": url]) }
        }
    }

    /// What was typed, as a URL to open: a bare "example.com" gets https://, a typed scheme (mailto:, file:, …) stays.
    static func normalizedLink(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        if t.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil { return t }
        if t.hasPrefix("/") || t.hasPrefix("~") { return URL(fileURLWithPath: (t as NSString).expandingTildeInPath).absoluteString }
        return "https://" + t
    }
}

extension MainController {
    /// Headless check of hyperlinks (MANIMBLE_TEST_LINK=deck): the right-click item, adding a link, the stills
    /// show's link regions, removing it. link.log in MANIMBLE_TEST_OUT.
    func linkTest() {
        let env = ProcessInfo.processInfo.environment
        let dir = (env["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "link.log") }
        Task { @MainActor in
            guard let oid = scene?.objects?.first(where: { $0.value.kind == "text" }).flatMap({ Int($0.key) }) else { log("no text"); return }
            selection = oid
            log("menu: \(canvasMenu()?.items.map { $0.title } ?? [])")
            log("normalized: \(MainController.normalizedLink(" example.com/x ")) \(MainController.normalizedLink("mailto:a@b.c"))")
            submit { [weak self] in await self?.runEdit(["op": "link", "oid": oid, "url": MainController.normalizedLink("example.com/x")]) }
            await queueTail?.value
            selection = oid
            log("after add: link=\(objInfo?.format?.link ?? "-") menu=\(canvasMenu()?.items.first?.title ?? "-")")
            guard let d = try? await engine.call("deck_pages", as: DeckPages.self) else { log("no deck"); return }
            let playable = d.slides.filter { $0.error == nil && !$0.pages.isEmpty }
            let p = SlidePlayer(screen: NSScreen.main ?? NSScreen.screens[0])
            p.play(slides: playable.map { $0.pages }, links: playable.map { $0.links ?? [] }, startSlide: 0, visible: false)
            if let r = playable.first?.links?.first?.first {
                log("region: \(r.x0) \(r.x1) \(r.y0) \(r.y1) \(r.url)")
                log("hit: \(p.link(at: CGPoint(x: (r.x0 + r.x1) / 2, y: (r.y0 + r.y1) / 2))?.absoluteString ?? "nil") miss: \(p.link(at: CGPoint(x: 0.02, y: 0.98))?.absoluteString ?? "nil")")
            } else { log("no region") }
            submit { [weak self] in await self?.runEdit(["op": "link", "oid": oid, "url": ""]) }
            await queueTail?.value
            selection = oid
            log("after remove: link=\(objInfo?.format?.link ?? "-")")
            log("done")
        }
    }
}

extension PresentDeck.LinkRegion {
    /// The region under a point given as fractions of the slide (y from the top).
    static func url(at p: CGPoint, in regions: [PresentDeck.LinkRegion]) -> URL? {
        let x = Double(p.x), y = Double(p.y)
        // the last one drawn wins where linked texts overlap
        return regions.last { $0.x0 <= x && x <= $0.x1 && $0.y0 <= y && y <= $0.y1 }.flatMap { URL(string: $0.url) }
    }
}

import AppKit

/// One match of a deck-wide search: the `index`-th match in the text of object `oid` on slide `scene`, first shown
/// in build `stop`.
struct FindMatch: Decodable {
    var scene: String
    var oid: Int
    var stop: Int
    var index: Int
    var kind: String
    var value: String
    var match: String
    var editable: Bool

    var key: String { "\(scene):\(kind):\(oid):\(stop):\(index)" }
    /// In the speaker notes (`notes`: the slide's, `buildNotes`: build `stop`'s own) rather than on the slide.
    var inNotes: Bool { kind == "notes" || kind == "buildNotes" }
}

struct FindResult: Decodable {
    var ok: Bool
    var error: String?
    var matches: [FindMatch]?
}

struct ReplaceResult: Decodable {
    var ok: Bool?
    var error: String?
    var message: String?
    var count: Int?
    var changed: ChangedLines?
}

/// Far right of the Home bar: search every slide's text and formulas (match case, whole word, regular expression,
/// and the speaker notes too), step through the matches, and replace one or all of them from the popover under the replace button.
final class FindBar: NSStackView {
    let field = NSSearchField()
    let caseButton = FindBar.toggle("Aa", "Match case")
    let wordButton = FindBar.toggle("ab", "Whole word", underline: true)
    let regexButton = FindBar.toggle(".*", "Regular expression (Python syntax; $1 or \\1 in the replacement names a group)")
    let notesButton = FormatBar.button("note.text", "N", "Check notes: search the speaker notes too (slide and build notes)", toggle: true)
    let prev = FormatBar.button("chevron.up", "↑", "Previous match (⇧↩)")
    let next = FormatBar.button("chevron.down", "↓", "Next match (↩)")
    let replaceButton = FormatBar.button("arrow.left.arrow.right", "⇄", "Find and replace (⌥⌘F)", toggle: true)
    let count = NSTextField(labelWithString: "")
    let replaceField = NSTextField(string: "")
    let replaceOne = NSButton(title: "Replace", target: nil, action: nil)
    let replaceAll = NSButton(title: "Replace All", target: nil, action: nil)
    lazy var popover: NSPopover = makePopover()

    var matches: [FindMatch] = []
    var current: Int?                       // index into matches of the one on screen
    var shownKey: String?                   // the match last brought on screen
    var generation = 0                      // a search still running when a newer one starts is dropped

    static func toggle(_ title: String, _ tip: String, underline: Bool = false) -> NSButton {
        let b = NSButton(title: "", target: nil, action: nil)
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)]
        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        b.attributedTitle = NSAttributedString(string: title, attributes: attrs)
        b.bezelStyle = .texturedRounded
        b.setButtonType(.pushOnPushOff)
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 2
        translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "Search slides"
        field.toolTip = "Find text in every slide (⌘F); ↩ next match, ⇧↩ previous"
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.font = Theme.font(12)
        field.controlSize = .small
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 160).isActive = true
        count.font = Theme.font(10); count.textColor = .secondaryLabelColor
        count.alignment = .center
        count.translatesAutoresizingMaskIntoConstraints = false
        count.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
        for b in [prev, next, replaceButton] { b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium) }
        notesButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        notesButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        for v: NSView in [field, count, caseButton, wordButton, regexButton, notesButton, prev, next, replaceButton] { addArrangedSubview(v) }
        setCustomSpacing(6, after: count)
        setCustomSpacing(6, after: notesButton)
        setCustomSpacing(6, after: next)
        replaceField.placeholderString = "Replace with"
        replaceField.font = Theme.font(12)
        replaceField.translatesAutoresizingMaskIntoConstraints = false
        replaceField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        replaceOne.toolTip = "Replace the selected match, then go to the next one"
        replaceAll.toolTip = "Replace every match on every slide, and in the notes when they are checked (one undo step)"
        for b in [replaceOne, replaceAll] { b.bezelStyle = .rounded; b.controlSize = .small; b.font = Theme.font(11) }
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func makePopover() -> NSPopover {
        let p = NSPopover()
        p.behavior = .semitransient
        let row = NSStackView(views: [replaceField, replaceOne, replaceAll])
        row.orientation = .horizontal; row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        let vc = NSViewController(); vc.view = row
        p.contentViewController = vc
        return p
    }

    var options: [String: Any] {
        ["query": field.stringValue, "case": caseButton.state == .on, "word": wordButton.state == .on,
         "regex": regexButton.state == .on, "notes": notesButton.state == .on]
    }

    /// The count label and which controls apply.
    func update(error: String? = nil) {
        let has = !matches.isEmpty
        prev.isEnabled = has; next.isEnabled = has
        replaceOne.isEnabled = has; replaceAll.isEnabled = has
        count.toolTip = error
        if let error {
            count.stringValue = "⚠︎"; count.textColor = .systemOrange
            field.toolTip = error
            return
        }
        count.textColor = .secondaryLabelColor
        field.toolTip = "Find text in every slide (⌘F); ↩ next match, ⇧↩ previous"
        if field.stringValue.isEmpty { count.stringValue = "" }
        else if !has { count.stringValue = "0" }
        else if let c = current { count.stringValue = "\(c + 1)/\(matches.count)" }
        else { count.stringValue = "\(matches.count)" }
    }
}

extension MainController: NSSearchFieldDelegate {
    func wireFindBar(_ f: FindBar) {
        f.field.delegate = self
        f.field.target = self; f.field.action = #selector(findFieldChanged(_:))
        for b in [f.caseButton, f.wordButton, f.regexButton, f.notesButton] { b.target = self; b.action = #selector(findOptionChanged(_:)) }
        f.prev.target = self; f.prev.action = #selector(findPrevious(_:))
        f.next.target = self; f.next.action = #selector(findNext(_:))
        f.replaceButton.target = self; f.replaceButton.action = #selector(toggleReplacePopover(_:))
        f.replaceField.target = self; f.replaceField.action = #selector(replaceCurrent(_:))
        f.replaceOne.target = self; f.replaceOne.action = #selector(replaceCurrent(_:))
        f.replaceAll.target = self; f.replaceAll.action = #selector(replaceEverything(_:))
    }

    var findBar: FindBar? { formatBar?.find }

    /// ↩ in the search field goes to the next match, ⇧↩ to the previous one, Esc clears the search.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard let f = findBar, control === f.field else { return false }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if NSEvent.modifierFlags.contains(.shift) { findPrevious(nil) } else { findNext(nil) }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            f.field.stringValue = ""; f.matches = []; f.current = nil; f.update()
            window.makeFirstResponder(canvas)
            return true
        }
        return false
    }

    // MARK: menu

    @objc func showFind(_ sender: Any?) {
        guard let f = findBar else { return }
        window.makeFirstResponder(f.field)
        f.field.currentEditor()?.selectAll(nil)
    }

    @objc func showFindReplace(_ sender: Any?) {
        guard let f = findBar else { return }
        if !f.popover.isShown { f.replaceButton.state = .on; f.popover.show(relativeTo: f.replaceButton.bounds, of: f.replaceButton, preferredEdge: .minY) }
        window.makeFirstResponder(f.field.stringValue.isEmpty ? f.field : f.replaceField)
    }

    @objc func toggleReplacePopover(_ sender: NSButton) {
        guard let f = findBar else { return }
        if f.popover.isShown { f.popover.performClose(nil); f.replaceButton.state = .off; return }
        showFindReplace(sender)
    }

    // MARK: searching

    @objc func findFieldChanged(_ sender: NSSearchField) { Task { @MainActor in await self.runFind(keep: false) } }
    @objc func findOptionChanged(_ sender: NSButton) { Task { @MainActor in await self.runFind(keep: false) } }

    /// Search the deck again. `keep`: stay on the match shown before (after an edit), else start from the slide on
    /// screen without moving to it.
    func runFind(keep: Bool) async {
        guard let f = findBar, workspace != nil else { return }
        f.generation += 1
        let gen = f.generation
        let before = f.current.flatMap { f.matches.indices.contains($0) ? f.matches[$0] : nil }
        guard !f.field.stringValue.isEmpty else { f.matches = []; f.current = nil; f.update(); return }
        let r: FindResult
        do { r = try await engine.call("find", f.options, as: FindResult.self) }
        catch { if gen == f.generation { f.matches = []; f.current = nil; f.update(error: "\(error)") }; return }
        guard gen == f.generation else { return }
        f.matches = r.matches ?? []
        f.current = nil
        if keep, let b = before {
            // the same match if it is still there, else the first one after where it was
            f.current = f.matches.firstIndex { $0.key == b.key } ?? firstMatch(atOrAfter: b)
        }
        f.update(error: r.ok ? nil : r.error)
    }

    /// Show order of a slide (hidden slides included), for ordering matches against a position.
    private func showIndex(_ scene: String) -> Int { state?.scenes.firstIndex { $0.name == scene } ?? Int.max }

    private func firstMatch(atOrAfter m: FindMatch) -> Int? {
        guard let f = findBar else { return nil }
        let s = showIndex(m.scene)
        return f.matches.firstIndex { showIndex($0.scene) > s || ($0.scene == m.scene && ($0.oid, $0.index) >= (m.oid, m.index)) }
    }

    /// The match after (or before) the one on screen; with none on screen, the first one from the slide shown.
    private func step(_ forward: Bool) -> Int? {
        guard let f = findBar, !f.matches.isEmpty else { return nil }
        let n = f.matches.count
        if let c = f.current, f.matches.indices.contains(c), shownMatch(f.matches[c]) {
            return (c + (forward ? 1 : n - 1)) % n
        }
        let here = showIndex(sceneName ?? "")
        if forward { return f.matches.firstIndex { showIndex($0.scene) >= here } ?? 0 }
        return f.matches.lastIndex { showIndex($0.scene) <= here } ?? n - 1
    }

    /// The match is on screen: the selected object of the slide shown, or its notes tab open on that build.
    private func shownMatch(_ m: FindMatch) -> Bool {
        guard sceneName == m.scene else { return false }
        if !m.inNotes { return selection == m.oid }
        return findBar?.shownKey == m.key && stopIndex == m.stop && drawerShowsNotes
            && drawer.page == (m.kind == "notes" ? .notes : .buildNotes)
    }

    @objc func findNext(_ sender: Any?) { Task { @MainActor in await self.goToMatch(forward: true) } }
    @objc func findPrevious(_ sender: Any?) { Task { @MainActor in await self.goToMatch(forward: false) } }

    func goToMatch(forward: Bool) async {
        guard let f = findBar else { return }
        if f.matches.isEmpty { await runFind(keep: false) }
        guard let i = step(forward) else { f.update(); if !f.field.stringValue.isEmpty { NSSound.beep() }; return }
        await show(i)
    }

    /// Bring match `i` on screen: its slide, the build that first shows it, the object selected (for a match in the
    /// notes, the build and the notes tab, leaving the typing in the search field).
    func show(_ i: Int) async {
        guard let f = findBar, f.matches.indices.contains(i) else { return }
        let m = f.matches[i]
        f.current = i; f.update()
        if sceneName != m.scene { await selectScene(m.scene) }
        guard sceneName == m.scene, let stops = scene?.stops else { return }
        if stops.indices.contains(m.stop), stopIndex != m.stop { stopIndex = m.stop; applyStop() }
        if m.inNotes {
            selection = nil
            drawer.show(m.kind == "notes" ? .notes : .buildNotes)
            if drawer.isHidden { setDrawerOpen(true) }
        } else if scene?.objects?[String(m.oid)] != nil { selection = m.oid }
        f.shownKey = m.key
        f.current = i; f.update()
    }

    // MARK: replacing

    @objc func replaceCurrent(_ sender: Any?) {
        guard let f = findBar, !f.field.stringValue.isEmpty else { return }
        submit { [weak self] in
            guard let self, let f = self.findBar else { return }
            await self.runFind(keep: true)
            // the first press only shows the match it would replace
            guard let c = f.current, f.matches.indices.contains(c), self.shownMatch(f.matches[c]) else {
                await self.goToMatch(forward: true); return
            }
            let m = f.matches[c]
            guard m.editable else {
                self.toast("This text is made by code, so it cannot be replaced here; edit it in the Python source", error: true)
                await self.goToMatch(forward: true); return
            }
            var req = f.options
            req["replacement"] = f.replaceField.stringValue
            req["scene"] = m.scene; req["oid"] = m.oid; req["index"] = m.index; req["stop"] = m.stop; req["kind"] = m.kind
            self.busy += 1
            let r: ReplaceResult?
            var failure: String?
            do { r = try await self.engine.call("replace", req, as: ReplaceResult.self) } catch { r = nil; failure = "\(error)" }
            self.busy -= 1
            if r?.ok == true { self.lastChanged = r?.changed; self.toast("Replaced · \(m.match) → \(f.replaceField.stringValue)") }
            else { self.toast(failure ?? r?.error ?? "replace failed", error: true) }
            await self.loadScene(m.scene, keepStop: true)
            await self.reloadState()
            await self.runFind(keep: true)
            // a replacement that still matches the search stays put: move on past it
            if r?.ok == true, let i = f.current, f.matches[i].key == m.key { f.current = (i + 1) % f.matches.count }
            if r?.ok == true, let i = f.current { await self.show(i) }
        }
    }

    @objc func replaceEverything(_ sender: Any?) {
        guard let f = findBar, !f.field.stringValue.isEmpty else { return }
        var req = f.options
        req["replacement"] = f.replaceField.stringValue
        req["all"] = true
        submit { [weak self] in
            guard let self else { return }
            self.busy += 1
            self.busyText = "Replacing on every slide…"
            let r: ReplaceResult?
            var failure: String?
            do { r = try await self.engine.call("replace", req, as: ReplaceResult.self) } catch { r = nil; failure = "\(error)" }
            self.busy -= 1; self.busyText = "Rendering…"
            if r?.ok == true { self.lastChanged = r?.changed; self.toast("Saved · \(r?.message ?? "replaced")") }
            else { self.toast(failure ?? r?.error ?? "replace failed", error: true) }
            if let n = self.sceneName { await self.loadScene(n, keepStop: true) }
            await self.reloadState()
            await self.runFind(keep: false)
        }
    }
}

extension MainController {
    /// MANIMBLE_TEST_FIND=<deck>: search, step through the matches, replace one, replace all, undo; find.log and
    /// find-*.png in MANIMBLE_TEST_OUT.
    func findTest() {
        let out = ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? NSTemporaryDirectory()
        var lines: [String] = []
        func log(_ s: String) { lines.append(s); try? lines.joined(separator: "\n").write(toFile: out + "/find.log", atomically: true, encoding: .utf8) }
        func shot(_ n: String) {
            guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/find-\(n).png"))
        }
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        Task { @MainActor in
            guard let f = self.findBar else { log("no find bar"); return }
            await wait(1)
            self.showFind(nil)
            log("focused: \(self.window.firstResponder === f.field.currentEditor())")
            f.field.stringValue = "e"; await self.runFind(keep: false)
            log("e: \(f.matches.count) matches, label \(f.count.stringValue)")
            for _ in 0..<3 {
                await self.goToMatch(forward: true)
                log("next -> \(self.sceneName ?? "-") build \(self.stopIndex) sel \(self.selection.map(String.init) ?? "-") label \(f.count.stringValue)")
            }
            await self.goToMatch(forward: false)
            log("prev -> \(self.sceneName ?? "-") sel \(self.selection.map(String.init) ?? "-") label \(f.count.stringValue)")
            shot("next")
            f.caseButton.state = .on; f.field.stringValue = "E"; await self.runFind(keep: false)
            log("E case: \(f.matches.count)")
            f.caseButton.state = .off; f.wordButton.state = .on; f.field.stringValue = "the"; await self.runFind(keep: false)
            log("the word: \(f.matches.map(\.value))")
            f.wordButton.state = .off; f.regexButton.state = .on; f.field.stringValue = "("; await self.runFind(keep: false)
            log("bad regex: label \(f.count.stringValue) tip \(f.count.toolTip ?? "-")")
            f.field.stringValue = "(\\w+)ing"; await self.runFind(keep: false)
            log("regex: \(f.matches.map(\.match))")
            f.regexButton.state = .off
            f.notesButton.state = .on; f.field.stringValue = "notes"; await self.runFind(keep: false)
            log("notes on: \(f.matches.map { "\($0.scene)/\($0.kind)/\($0.stop)" })")
            await self.goToMatch(forward: true)
            log("notes next -> \(self.sceneName ?? "-") build \(self.stopIndex) page \(self.drawer.page) open \(!self.drawer.isHidden) sel \(self.selection.map(String.init) ?? "-") field focused \(self.window.firstResponder === f.field.currentEditor())")
            shot("notes")
            self.showFindReplace(nil); f.replaceField.stringValue = "NOTES"
            self.replaceCurrent(nil); await self.queueTail?.value
            self.replaceCurrent(nil); await self.queueTail?.value
            log("replaced in notes: \(self.scene?.notes ?? "-") / build \(self.scene?.buildNotes ?? [])")
            f.notesButton.state = .off; f.field.stringValue = "notes"; await self.runFind(keep: false)
            log("notes off: \(f.matches.count)")
            f.popover.performClose(nil)
            f.field.stringValue = "Manim"; await self.runFind(keep: false)
            self.showFindReplace(nil); f.replaceField.stringValue = "MANIM"
            shot("popover")
            self.replaceCurrent(nil); await self.queueTail?.value
            log("first replace press shows: \(self.sceneName ?? "-") sel \(self.selection.map(String.init) ?? "-")")
            self.replaceCurrent(nil); await self.queueTail?.value
            log("after replace: \(f.matches.count) left; title \(self.scene?.objects?["0"]?.value ?? "-")")
            f.field.stringValue = "o"; f.replaceField.stringValue = "0"; await self.runFind(keep: false)
            let before = f.matches.count
            self.replaceEverything(nil); await self.queueTail?.value
            log("replace all: \(before) -> \(f.matches.count); title \(self.scene?.objects?["0"]?.value ?? "-")")
            shot("all")
            self.window.makeFirstResponder(self.canvas); self.undo(); await self.queueTail?.value
            await self.runFind(keep: false)
            log("after undo: \(f.matches.count) matches of o")
            log("done")
        }
    }
}

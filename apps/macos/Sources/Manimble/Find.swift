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
    var start: Int?                     // the match in `value`, in characters (Unicode scalars)
    var end: Int?
    var glyphs: [Int]?                  // the match as a range of the non-space characters of `value` (text objects)

    var key: String { "\(scene):\(kind):\(oid):\(stop):\(index)" }
    /// In the speaker notes (`notes`: the slide's, `buildNotes`: build `stop`'s own) rather than on the slide.
    var inNotes: Bool { kind == "notes" || kind == "buildNotes" }
}

/// A search match drawn on the canvas: object `oid`, the range of its non-space characters (nil: the whole
/// object), and whether it is the match stepped to.
struct FindMark {
    var oid: Int
    var glyphs: (Int, Int)?
    var current: Bool
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

/// Far right of the Home bar, laid out like VS Code's find widget: a chevron that drops the replace row down under
/// the bar, the search box with match case, whole word, regular expression and speaker-notes toggles inside it, the
/// match count, previous/next and close.
final class FindBar: NSStackView {
    let field = LiveTextField()
    let caseButton = FindBar.toggle("Aa", "Match case")
    let wordButton = FindBar.toggle("ab", "Whole word", underline: true)
    let regexButton = FindBar.toggle(".*", "Regular expression (Python syntax; $1 or \\1 in the replacement names a group)")
    let notesButton = FindBar.toggle(symbol: "note.text", "Check notes: search the speaker notes too (slide and build notes)")
    let prev = FindBar.icon("arrow.up", "Previous match (⇧↩)")
    let next = FindBar.icon("arrow.down", "Next match (↩)")
    let close = FindBar.icon("xmark", "Clear the search (Esc)")
    let replaceButton = FindBar.icon("chevron.right", "Toggle replace (⌥⌘F)", toggle: true)
    let count = NSTextField(labelWithString: "")
    let replaceField = NSTextField(string: "")
    let replaceOne = FindBar.icon(image: FindBar.replaceIcon(all: false), "Replace (↩): the selected match, then go to the next one")
    let replaceAll = FindBar.icon(image: FindBar.replaceIcon(all: true), "Replace All: every match on every slide, and in the notes when they are checked (one undo step)")
    private(set) lazy var findBox = FindInput(field, buttons: [caseButton, wordButton, regexButton, notesButton])
    private(set) lazy var replaceBox = FindInput(replaceField, buttons: [])
    /// The replace row, dropped down under the Home bar over the canvas; `attachReplaceRow` puts it in the window.
    let replaceRow = NSView()

    var matches: [FindMatch] = []
    var current: Int?                       // index into matches of the one on screen
    var shownKey: String?                   // the match last brought on screen
    var generation = 0                      // a search still running when a newer one starts is dropped
    var onUpdate: (() -> Void)?             // the matches or the current one changed: redraw their highlights

    var replaceShown: Bool { !replaceRow.isHidden }

    /// An option toggle inside the search box: lit with the accent colour while on.
    static func toggle(_ title: String, _ tip: String, underline: Bool = false) -> NSButton {
        let b = FindButton(title: "", target: nil, action: nil)
        var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor]
        if underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        b.attributedTitle = NSAttributedString(string: title, attributes: attrs)
        return FindButton.style(b, tip, toggle: true, width: 22, height: 18)
    }

    static func toggle(symbol: String, _ tip: String) -> NSButton {
        let b = FindButton(title: "", target: nil, action: nil)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        return FindButton.style(b, tip, toggle: true, width: 22, height: 18)
    }

    /// A borderless icon button beside the boxes.
    static func icon(_ symbol: String = "", image: NSImage? = nil, _ tip: String, toggle: Bool = false) -> NSButton {
        let b = FindButton(title: "", target: nil, action: nil)
        b.image = image ?? NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        b.lightsWhenOn = false
        return FindButton.style(b, tip, toggle: toggle, width: 24, height: 22)
    }

    /// VS Code's replace and replace-all icons: the old letters small at the top right, an arrow down into the new
    /// letters knocked out of a box at the bottom left.
    static func replaceIcon(all: Bool) -> NSImage {
        let w: CGFloat = all ? 20 : 16
        let img = NSImage(size: NSSize(width: w, height: 16), flipped: true) { _ in
            let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7.5, weight: .semibold), .foregroundColor: NSColor.black]
            let old = NSAttributedString(string: all ? "ab" : "b", attributes: small)
            old.draw(at: NSPoint(x: w - old.size().width, y: -1.5))
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 7, y: 3)); arrow.line(to: NSPoint(x: 4.5, y: 3))
            arrow.curve(to: NSPoint(x: 3, y: 4.5), controlPoint1: NSPoint(x: 3.6, y: 3), controlPoint2: NSPoint(x: 3, y: 3.6))
            arrow.line(to: NSPoint(x: 3, y: 7))
            arrow.move(to: NSPoint(x: 1.4, y: 5.6)); arrow.line(to: NSPoint(x: 3, y: 7.4)); arrow.line(to: NSPoint(x: 4.6, y: 5.6))
            arrow.lineWidth = 1; NSColor.black.setStroke(); arrow.stroke()
            let box = NSRect(x: 0.5, y: 8.5, width: all ? 11 : 8, height: 7)
            NSColor.black.setFill(); NSBezierPath(roundedRect: box, xRadius: 1.5, yRadius: 1.5).fill()
            let new = NSAttributedString(string: all ? "ac" : "c", attributes: small)
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            new.draw(at: NSPoint(x: box.midX - new.size().width / 2, y: box.minY - 2))
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        img.isTemplate = true
        return img
    }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 2
        translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "Find"
        field.toolTip = "Find text in every slide (⌘F); ↩ next match, ⇧↩ previous"
        replaceField.placeholderString = "Replace"
        findBox.widthAnchor.constraint(equalToConstant: 250).isActive = true
        count.font = Theme.font(12); count.textColor = .labelColor
        count.lineBreakMode = .byClipping
        count.translatesAutoresizingMaskIntoConstraints = false
        count.widthAnchor.constraint(equalToConstant: 68).isActive = true
        for v: NSView in [replaceButton, findBox, count, prev, next, close] { addArrangedSubview(v) }
        replaceButton.widthAnchor.constraint(equalToConstant: 18).isActive = true
        setCustomSpacing(4, after: replaceButton)
        setCustomSpacing(6, after: findBox)

        replaceRow.isHidden = true
        replaceRow.wantsLayer = true
        replaceRow.translatesAutoresizingMaskIntoConstraints = false
        Theme.layerColors(replaceRow) {
            $0.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            $0.layer?.borderColor = NSColor.separatorColor.cgColor
        }
        replaceRow.layer?.borderWidth = 1
        replaceRow.layer?.cornerRadius = 6
        replaceRow.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]   // the bottom ones (unflipped)
        replaceRow.shadow = NSShadow()
        replaceRow.layer?.shadowOpacity = 0.3; replaceRow.layer?.shadowRadius = 4; replaceRow.layer?.shadowOffset = NSSize(width: 0, height: -2)
        for v: NSView in [replaceBox, replaceOne, replaceAll] { replaceRow.addSubview(v) }
        NSLayoutConstraint.activate([
            replaceBox.topAnchor.constraint(equalTo: replaceRow.topAnchor, constant: 5),
            replaceBox.bottomAnchor.constraint(equalTo: replaceRow.bottomAnchor, constant: -6),
            replaceOne.leadingAnchor.constraint(equalTo: replaceBox.trailingAnchor, constant: 6),
            replaceOne.centerYAnchor.constraint(equalTo: replaceBox.centerYAnchor),
            replaceAll.leadingAnchor.constraint(equalTo: replaceOne.trailingAnchor, constant: 4),
            replaceAll.centerYAnchor.constraint(equalTo: replaceBox.centerYAnchor),
        ])
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Put the replace row in `root` (above the views after the bar), hanging from the bottom of `bar` with its box
    /// lined up under the search box.
    func attachReplaceRow(in root: NSView, below bar: NSView) {
        root.addSubview(replaceRow, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            replaceRow.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: -1),
            replaceRow.leadingAnchor.constraint(equalTo: replaceButton.leadingAnchor, constant: -6),
            replaceRow.trailingAnchor.constraint(equalTo: close.trailingAnchor, constant: 6),
            replaceBox.leadingAnchor.constraint(equalTo: findBox.leadingAnchor),
            replaceBox.widthAnchor.constraint(equalTo: findBox.widthAnchor),
        ])
    }

    func setReplaceShown(_ on: Bool) {
        replaceRow.isHidden = !on
        replaceButton.state = on ? .on : .off
        replaceButton.image = NSImage(systemSymbolName: on ? "chevron.down" : "chevron.right", accessibilityDescription: "Toggle replace")
    }

    var options: [String: Any] {
        ["query": field.stringValue, "case": caseButton.state == .on, "word": wordButton.state == .on,
         "regex": regexButton.state == .on, "notes": notesButton.state == .on]
    }

    /// The count label and which controls apply.
    func update(error: String? = nil) {
        defer { onUpdate?() }
        let has = !matches.isEmpty
        prev.isEnabled = has; next.isEnabled = has
        replaceOne.isEnabled = has; replaceAll.isEnabled = has
        count.toolTip = error
        if let error {
            count.stringValue = "⚠︎ Error"; count.textColor = .systemOrange
            field.toolTip = error
            return
        }
        field.toolTip = "Find text in every slide (⌘F); ↩ next match, ⇧↩ previous"
        count.textColor = has || field.stringValue.isEmpty ? .labelColor : .systemRed
        if field.stringValue.isEmpty { count.stringValue = "No results"; count.textColor = .secondaryLabelColor }
        else if !has { count.stringValue = "No results" }
        else if let c = current { count.stringValue = "\(c + 1) of \(matches.count)" }
        else { count.stringValue = "? of \(matches.count)" }
    }
}

/// A text field that sends its action on every keystroke, for searching as you type.
final class LiveTextField: NSTextField {
    override func textDidChange(_ n: Notification) {
        super.textDidChange(n)
        sendAction(action, to: target)
    }
}

/// A rounded box holding a borderless text field with small buttons inside its right end; its border takes the
/// accent colour while the field is being typed in.
final class FindInput: NSView {
    private var editing = false

    init(_ field: NSTextField, buttons: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5; layer?.borderWidth = 1
        Theme.layerColors(self) { $0.restyle() }
        field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.font(13)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true; field.cell?.wraps = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [field] + buttons)
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 1
        row.setCustomSpacing(4, after: field)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSControl.textDidBeginEditingNotification, object: field, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.editing = true; self?.restyle() }
        }
        nc.addObserver(forName: NSControl.textDidEndEditingNotification, object: field, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.editing = false; self?.restyle() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = (editing ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
    }
}

/// A borderless button of the find widget: dims its icon when disabled and, as an option toggle, fills with the
/// accent colour while on.
final class FindButton: NSButton {
    var lightsWhenOn = true

    static func style(_ b: FindButton, _ tip: String, toggle: Bool, width: CGFloat, height: CGFloat) -> NSButton {
        b.isBordered = false
        b.setButtonType(toggle ? .pushOnPushOff : .momentaryChange)
        (b.cell as? NSButtonCell)?.highlightsBy = []
        b.contentTintColor = .labelColor
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        b.heightAnchor.constraint(equalToConstant: height).isActive = true
        return b
    }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.35 } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        if lightsWhenOn && state == .on {
            let p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            NSColor.controlAccentColor.withAlphaComponent(0.3).setFill(); p.fill()
            NSColor.controlAccentColor.setStroke(); p.stroke()
        } else if isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        }
        super.draw(dirtyRect)
    }
}

extension MainController {
    func wireFindBar(_ f: FindBar) {
        f.field.delegate = self; f.replaceField.delegate = self
        f.field.target = self; f.field.action = #selector(findFieldChanged(_:))
        for b in [f.caseButton, f.wordButton, f.regexButton, f.notesButton] { b.target = self; b.action = #selector(findOptionChanged(_:)) }
        f.prev.target = self; f.prev.action = #selector(findPrevious(_:))
        f.next.target = self; f.next.action = #selector(findNext(_:))
        f.close.target = self; f.close.action = #selector(closeFind(_:))
        f.replaceButton.target = self; f.replaceButton.action = #selector(toggleReplaceRow(_:))
        f.replaceField.target = self; f.replaceField.action = #selector(replaceCurrent(_:))
        f.replaceOne.target = self; f.replaceOne.action = #selector(replaceCurrent(_:))
        f.replaceAll.target = self; f.replaceAll.action = #selector(replaceEverything(_:))
        f.onUpdate = { [weak self] in self?.canvas.findMarksChanged(); self?.markNotesMatch() }
        canvas.findMarks = { [weak self] in self?.findMarksOnSlide() ?? [] }
    }

    /// Every match on the slide and build shown, highlighted on the canvas (the current one stronger). A match whose
    /// text has changed since the search is left out: its character range no longer fits.
    func findMarksOnSlide() -> [FindMark] {
        guard let f = findBar, !f.matches.isEmpty, let name = sceneName, let stop = canvas.stop else { return [] }
        return f.matches.indices.compactMap { i in
            let m = f.matches[i]
            guard m.scene == name, !m.inNotes, stop.box(of: m.oid) != nil,
                  canvas.sceneObjects[String(m.oid)]?.value.replacingOccurrences(of: " \n", with: " ") == m.value else { return nil }
            return FindMark(oid: m.oid, glyphs: m.glyphs.flatMap { $0.count == 2 ? ($0[0], $0[1]) : nil }, current: i == f.current)
        }
    }

    /// The current match, when it is in the notes tab shown, highlighted in that tab's text (the others cleared).
    func markNotesMatch() {
        guard let f = findBar else { return }
        let m = f.current.flatMap { f.matches.indices.contains($0) ? f.matches[$0] : nil }
        let shown = m.flatMap { $0.inNotes && shownMatch($0) ? $0 : nil }
        for box in [notesBox, buildNotesBox] {
            if let m = shown, let s = m.start, let e = m.end, box === (m.kind == "notes" ? notesBox : buildNotesBox) {
                box.highlight(in: m.value, from: s, to: e)
            } else { box.highlight(in: nil, from: 0, to: 0) }
        }
    }

    var findBar: FindBar? { formatBar?.find }

    /// ↩ in the search field goes to the next match, ⇧↩ to the previous one, Esc clears the search.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard let f = findBar else { return false }
        if control === f.replaceField, sel == #selector(NSResponder.cancelOperation(_:)) { closeFind(nil); return true }
        guard control === f.field else { return false }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            if NSEvent.modifierFlags.contains(.shift) { findPrevious(nil) } else { findNext(nil) }
            return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) { closeFind(nil); return true }
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
        f.setReplaceShown(true)
        window.makeFirstResponder(f.field.stringValue.isEmpty ? f.field : f.replaceField)
    }

    @objc func toggleReplaceRow(_ sender: NSButton) {
        guard let f = findBar else { return }
        if f.replaceShown { f.setReplaceShown(false); return }
        showFindReplace(sender)
    }

    /// ✕ or Esc: clear the search, fold the replace row away and go back to the canvas.
    @objc func closeFind(_ sender: Any?) {
        guard let f = findBar else { return }
        f.field.stringValue = ""; f.matches = []; f.current = nil; f.update()
        f.setReplaceShown(false)
        window.makeFirstResponder(canvas)
    }

    // MARK: searching

    @objc func findFieldChanged(_ sender: NSTextField) { Task { @MainActor in await self.runFind(keep: false) } }
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
            log("marks: " + self.findMarksOnSlide().map { m in
                "\(m.oid)\(m.current ? "*" : "") " + (m.glyphs.flatMap { g in self.canvas.stop?.glyphBoxes(m.oid, g.0, g.1) }
                    .map { $0.map { "[\(Int($0.x0)),\(Int($0.y0)) \(Int($0.w))x\(Int($0.h))]" }.joined() } ?? "whole")
            }.joined(separator: " "))
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
            f.setReplaceShown(false)
            f.field.stringValue = "Manim"; await self.runFind(keep: false)
            self.showFindReplace(nil); f.replaceField.stringValue = "MANIM"
            shot("replace")
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

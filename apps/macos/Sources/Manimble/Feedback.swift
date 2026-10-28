import AppKit

/// One feedback note: red text pinned to a point of a slide, typed in Presenter View's Feedback Mode (or in the
/// editor). The audience display never shows it: notes live in `feedback.json` beside the deck, not in the Python,
/// so nothing renders and no slide is marked stale.
struct FeedbackNote: Codable, Equatable {
    var id: String
    var scene: String
    var build: Int                            // the build it was typed on (shown on every build of the slide)
    var x: Double, y: Double                  // top-left corner, as fractions of the slide (y from the top)
    var w: Double                             // wrap width, as a fraction of the slide's width
    var text: String
    var created: Date

    static let defaultWidth = 0.32
}

/// The deck's feedback notes, read from and written to `feedback.json` in the working copy (so Save carries them
/// to the original like any other edit, and closing without saving drops them).
@MainActor
final class FeedbackStore {
    let url: URL
    /// The original deck has a `feedback.json`: an empty list is written rather than the file removed, so Save
    /// clears the original's too.
    private let keepEmptyFile: Bool
    private(set) var notes: [FeedbackNote] = []
    /// Anything changed (a note added, edited or removed).
    var onChange: (() -> Void)?

    private struct File: Codable { var version: Int; var notes: [FeedbackNote] }

    init(url: URL, originalHasFile: Bool) {
        self.url = url
        keepEmptyFile = originalHasFile
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { notes = []; return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        notes = (try? dec.decode(File.self, from: data))?.notes ?? []
    }

    private func save() {
        if notes.isEmpty && !keepEmptyFile {
            try? FileManager.default.removeItem(at: url)
        } else {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(File(version: 1, notes: notes)) { try? data.write(to: url, options: .atomic) }
        }
        onChange?()
    }

    var isEmpty: Bool { notes.isEmpty }
    func notes(for scene: String) -> [FeedbackNote] { notes.filter { $0.scene == scene } }
    func note(_ id: String) -> FeedbackNote? { notes.first { $0.id == id } }
    /// The scenes with notes, in the order they were first written to.
    var scenes: [String] { var seen: [String] = []; for n in notes where !seen.contains(n.scene) { seen.append(n.scene) }; return seen }

    @discardableResult
    func add(scene: String, build: Int, x: Double, y: Double, text: String = "") -> FeedbackNote {
        let n = FeedbackNote(id: UUID().uuidString, scene: scene, build: build, x: x, y: y, w: FeedbackNote.defaultWidth,
                             text: text, created: Date())
        notes.append(n)
        save()
        return n
    }

    func setText(_ id: String, _ text: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return }
        notes[i].text = text
        save()
    }

    func move(_ id: String, x: Double, y: Double) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].x = x; notes[i].y = y
        save()
    }

    func remove(_ id: String) {
        guard notes.contains(where: { $0.id == id }) else { return }
        notes.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        guard !notes.isEmpty else { return }
        notes = []
        save()
    }
}

/// The text of one note: red, borderless, typing straight onto the slide. esc or ⌘↵ ends editing (the text is
/// kept: feedback is never reverted); backspace on an empty note removes it.
final class FeedbackTextView: NSTextView {
    var onEnd: (() -> Void)?
    var onDeleteEmpty: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        onFocusChange?(true)
        return true
    }
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        onFocusChange?(false)
        return true
    }
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if event.keyCode == 53 || ((event.keyCode == 36 || event.keyCode == 76) && mods == .command) { onEnd?(); return }
        super.keyDown(with: event)
    }
    override func deleteBackward(_ sender: Any?) {
        if string.isEmpty, let d = onDeleteEmpty { d() } else { super.deleteBackward(sender) }
    }
    override func deleteForward(_ sender: Any?) {
        if string.isEmpty, let d = onDeleteEmpty { d() } else { super.deleteForward(sender) }
    }
}

/// One note on the slide: its text with a thin red frame and a close button; dragging the frame moves it.
@MainActor
final class FeedbackBox: NSView {
    let id: String
    let text = FeedbackTextView(frame: .zero)
    private let close = NSButton()
    var onDelete: (() -> Void)?
    var onMoved: ((CGPoint) -> Void)?      // new top-left, in the superview's coordinates
    var onTextChange: (() -> Void)?
    private var dragOrigin: CGPoint?
    private var dragStart: CGPoint?
    /// What the last layout was for (width, font size, text) and the height it gave: the canvas relays out on
    /// every redraw, so text layout is redone only when one of them changed.
    private var laidOut: (width: CGFloat, fontSize: CGFloat, text: String, height: CGFloat)?
    static let red = NSColor(srgbRed: 1.0, green: 0.18, blue: 0.16, alpha: 1)
    static let inset: CGFloat = 6

    init(id: String) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = Self.red.withAlphaComponent(0.75).cgColor
        layer?.backgroundColor = Self.red.withAlphaComponent(0.07).cgColor
        text.isRichText = false; text.allowsUndo = true; text.drawsBackground = false; text.focusRingType = .none
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = false; text.textContainer?.heightTracksTextView = false
        text.isHorizontallyResizable = false; text.isVerticallyResizable = false
        text.textColor = Self.red; text.insertionPointColor = Self.red
        text.delegate = self
        addSubview(text)
        close.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Delete this feedback")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        close.isBordered = false; close.imagePosition = .imageOnly
        close.contentTintColor = Self.red
        close.alphaValue = 0.8
        close.toolTip = "Delete this feedback"
        close.target = self; close.action = #selector(deletePressed)
        addSubview(close)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func deletePressed() { onDelete?() }

    /// Lay the text out at `fontSize` across `width` points and size the box to it; returns the box's height.
    @discardableResult
    func layout(width: CGFloat, fontSize: CGFloat) -> CGFloat {
        if let l = laidOut, l.width == width, l.fontSize == fontSize, l.text == text.string { return l.height }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        text.font = font
        text.typingAttributes = [.font: font, .foregroundColor: Self.red]
        if let s = text.textStorage, s.length > 0 {
            s.addAttributes([.font: font, .foregroundColor: Self.red], range: NSRange(location: 0, length: s.length))
        }
        let inner = max(10, width - 2 * Self.inset)
        text.textContainer?.containerSize = NSSize(width: inner, height: 1e6)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let used = text.layoutManager?.usedRect(for: text.textContainer!).height ?? fontSize
        let lineH = NSLayoutManager().defaultLineHeight(for: font)
        let h = max(used, lineH) + 2 * Self.inset
        text.frame = NSRect(x: Self.inset, y: Self.inset, width: inner, height: h - 2 * Self.inset)
        let cs = max(12, min(18, fontSize * 0.8))
        close.frame = NSRect(x: width - cs - 1, y: h - cs - 1, width: cs, height: cs)
        laidOut = (width, fontSize, text.string, h)
        return h
    }

    /// A press on the frame (outside the text) starts a drag; a press in the text starts typing.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if text.frame.contains(p) {
            window?.makeFirstResponder(text)
            text.mouseDown(with: event)
            return
        }
        dragOrigin = frame.origin
        dragStart = superview?.convert(event.locationInWindow, from: nil)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let o = dragOrigin, let s = dragStart, let now = superview?.convert(event.locationInWindow, from: nil) else { return }
        frame.origin = CGPoint(x: o.x + now.x - s.x, y: o.y + now.y - s.y)
    }
    override func mouseUp(with event: NSEvent) {
        guard let o = dragOrigin else { return }
        dragOrigin = nil; dragStart = nil
        if frame.origin != o { onMoved?(CGPoint(x: frame.minX, y: frame.maxY)) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand); addCursorRect(text.frame, cursor: .iBeam) }
}

extension FeedbackBox: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { onTextChange?() }
}

/// The notes of one slide laid over its picture, in the editor (over the canvas) and in Presenter View (over the
/// current-slide panel). The host says where the slide is drawn (`slideRect`) and calls `relayout()` whenever
/// that moves. Clicks pass through to the view beneath unless they land on a note, or `placing` is on (Feedback
/// Mode): then a click adds a note there and starts typing into it.
@MainActor
final class FeedbackLayer: NSView {
    var store: FeedbackStore? { didSet { rebuild() } }
    var scene: String? { didSet { if scene != oldValue { rebuild() } } }
    /// The build on screen: what a new note remembers.
    var build = 0
    /// Where the slide is drawn, in this view's coordinates.
    var slideRect: () -> CGRect = { .zero }
    /// Feedback Mode: a click on the slide adds a note.
    var placing = false { didSet { window?.invalidateCursorRects(for: self) } }
    /// Who takes the keys back when a note's editing ends (the canvas in the editor; nil in Presenter View, whose
    /// window drives the show with no first responder).
    weak var fallbackResponder: NSResponder?
    /// A note was added here (so the host can, say, mark the slide in a list).
    var onAdd: (() -> Void)?
    private var boxes: [String: FeedbackBox] = [:]
    private var highlighted: String?

    override var isFlipped: Bool { false }

    /// Font size for the text, from the slide's height on screen (about 3.3% of it: 24 pt on a 720 pt slide).
    static func fontSize(for r: CGRect) -> CGFloat { max(8, (r.height * 0.033).rounded()) }

    /// Make the boxes match the store (new notes get a box, gone notes lose theirs) and lay them out.
    func rebuild() {
        let wanted = (scene.flatMap { store?.notes(for: $0) } ?? [])
        let ids = Set(wanted.map(\.id))
        for (id, b) in boxes where !ids.contains(id) {
            if window?.firstResponder === b.text { window?.makeFirstResponder(fallbackResponder) }
            b.removeFromSuperview(); boxes[id] = nil
        }
        for n in wanted {
            guard let b = boxes[n.id] else { boxes[n.id] = makeBox(n); continue }
            // typed in the other window (the editor's layer while Presenter View types, or the other way round)
            if window?.firstResponder !== b.text, b.text.string != n.text { b.text.string = n.text }
        }
        relayout()
    }

    private func makeBox(_ n: FeedbackNote) -> FeedbackBox {
        let b = FeedbackBox(id: n.id)
        b.text.string = n.text
        b.onDelete = { [weak self] in self?.remove(n.id) }
        b.onTextChange = { [weak self] in self?.relayout(only: n.id) }
        b.onMoved = { [weak self] topLeft in
            guard let self, let s = self.store else { return }
            let r = self.slideRect()
            guard r.width > 0, r.height > 0 else { return }
            let x = min(max(0, (topLeft.x - r.minX) / r.width), 0.98), y = min(max(0, (r.maxY - topLeft.y) / r.height), 0.98)
            s.move(n.id, x: Double(x), y: Double(y))
        }
        b.text.onEnd = { [weak self] in self?.endEditing() }
        b.text.onDeleteEmpty = { [weak self] in self?.remove(n.id) }
        b.text.onFocusChange = { [weak self, weak b] focused in
            guard let self, let b else { return }
            b.layer?.borderWidth = focused ? 2 : 1
            guard !focused else { return }
            // saved as the focus leaves; an empty note is dropped once the responder change is over (removing it
            // in the middle would change the first responder again)
            self.store?.setText(b.id, b.text.string)
            if b.text.string.isEmpty { let id = b.id; DispatchQueue.main.async { [weak self] in self?.remove(id) } }
        }
        addSubview(b)
        return b
    }

    private func remove(_ id: String) {
        if let b = boxes[id] {
            if window?.firstResponder === b.text { window?.makeFirstResponder(fallbackResponder) }
            b.removeFromSuperview(); boxes[id] = nil
        }
        store?.remove(id)              // onChange → host → rebuild()
    }

    /// Hand the keys back (a note's text is saved as it loses focus).
    func endEditing() {
        if let fr = window?.firstResponder as? FeedbackTextView, boxes.values.contains(where: { $0.text === fr }) {
            window?.makeFirstResponder(fallbackResponder)
        }
    }

    /// Whether one of this layer's notes is being typed into.
    var isEditing: Bool {
        guard let fr = window?.firstResponder as? FeedbackTextView else { return false }
        return boxes.values.contains { $0.text === fr }
    }

    /// Put the boxes where their notes say, sized to their text.
    func relayout(only: String? = nil) {
        let r = slideRect()
        guard r.width > 0, r.height > 0, let store else { return }
        let fs = Self.fontSize(for: r)
        for (id, b) in boxes {
            if let only, only != id { continue }
            guard let n = store.note(id) else { continue }
            let w = max(60, r.width * CGFloat(n.w))
            let h = b.layout(width: w, fontSize: fs)
            let x = r.minX + r.width * CGFloat(n.x), top = r.maxY - r.height * CGFloat(n.y)
            let f = NSRect(x: x, y: top - h, width: w, height: h).integral
            if b.frame != f { b.frame = f }
        }
    }

    /// Start typing into a note (after a jump to its slide from the feedback list): outline it and focus it.
    func focus(_ id: String) {
        guard let b = boxes[id] else { return }
        window?.makeFirstResponder(b.text)
        b.text.setSelectedRange(NSRange(location: (b.text.string as NSString).length, length: 0))
        flash(b)
    }

    private func flash(_ b: FeedbackBox) {
        let a = CABasicAnimation(keyPath: "borderWidth")
        a.fromValue = 4; a.toValue = 2; a.duration = 0.6
        b.layer?.add(a, forKey: "flash")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        for b in boxes.values.reversed() where b.frame.contains(p) {
            return b.hitTest(p) ?? b
        }
        return placing && slideRect().contains(p) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard placing, let scene, let store else { super.mouseDown(with: event); return }
        let p = convert(event.locationInWindow, from: nil)
        let r = slideRect()
        guard r.contains(p) else { return }
        endEditing()                                    // the note being typed is saved (or dropped when empty)
        let x = min(max(0, (p.x - r.minX) / r.width), 0.96), y = min(max(0, (r.maxY - p.y) / r.height), 0.96)
        let n = store.add(scene: scene, build: build, x: Double(x), y: Double(y))
        if boxes[n.id] == nil { boxes[n.id] = makeBox(n) }
        relayout(only: n.id)
        window?.makeFirstResponder(boxes[n.id]?.text)
        onAdd?()
    }

    override func resetCursorRects() {
        if placing { addCursorRect(slideRect(), cursor: .crosshair) }
    }
}

/// The feedback list (the "View Feedback" popover): every note grouped by slide, with Previous / Next to walk
/// through them and a delete button on each. `slideLabel` names a scene the way the editor numbers it.
@MainActor
final class FeedbackListView: NSView {
    let store: FeedbackStore
    var slideLabel: (String) -> String = { $0 }
    var onGo: ((FeedbackNote) -> Void)?
    /// "Done": the host puts the inspector back.
    var onClose: (() -> Void)?
    private let counter = NSTextField(labelWithString: "")
    private let column = NSStackView()
    private let scroll = NSScrollView()
    private var current: String?
    private var rows: [String: NSView] = [:]

    init(store: FeedbackStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        Theme.layerColors(self) { $0.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        // title row, like the inspector's header: symbol, "Feedback", Done
        let img = NSImageView(image: NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil) ?? NSImage())
        img.symbolConfiguration = .init(pointSize: 15, weight: .medium); img.contentTintColor = Theme.accent
        let title = NSTextField(labelWithString: "Feedback"); title.font = Theme.font(14, .semibold)
        let sub = NSTextField(labelWithString: "red notes from Presenter View"); sub.font = Theme.mono(10); sub.textColor = .tertiaryLabelColor
        let col = NSStackView(views: [title, sub]); col.orientation = .vertical; col.alignment = .leading; col.spacing = 0
        col.setContentHuggingPriority(.init(1), for: .horizontal)
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .texturedRounded; done.controlSize = .small; done.font = Theme.font(11)
        done.toolTip = "Back to the edit panel"
        let titleRow = NSStackView(views: [img, col, done])
        titleRow.orientation = .horizontal; titleRow.alignment = .centerY; titleRow.spacing = 9
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        // controls: previous / counter / next, Delete All
        let prev = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Previous")!, target: self, action: #selector(previous))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Next")!, target: self, action: #selector(nextOne))
        for b in [prev, next] { b.bezelStyle = .texturedRounded; b.translatesAutoresizingMaskIntoConstraints = false }
        prev.toolTip = "Previous feedback"; next.toolTip = "Next feedback"
        counter.font = Theme.font(12, .semibold); counter.alignment = .center
        counter.setContentHuggingPriority(.init(1), for: .horizontal)
        let clear = NSButton(title: "Delete All", target: self, action: #selector(deleteAll))
        clear.bezelStyle = .texturedRounded; clear.controlSize = .small; clear.font = Theme.font(11)
        let head = NSStackView(views: [prev, counter, next, clear])
        head.orientation = .horizontal; head.alignment = .centerY; head.spacing = 6
        head.translatesAutoresizingMaskIntoConstraints = false
        // an explicit height: a separator has no intrinsic one, and the layout otherwise sometimes gives the rule
        // the whole pane (a vertical line down the middle, the controls at the bottom, the list squeezed to nothing)
        let rule = NSBox(); rule.boxType = .separator; rule.translatesAutoresizingMaskIntoConstraints = false
        rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(column)
        scroll.documentView = doc; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleRow); addSubview(rule); addSubview(head); addSubview(scroll)
        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), titleRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            rule.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 10),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            head.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 10),
            head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), head.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            column.leadingAnchor.constraint(equalTo: doc.leadingAnchor), column.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            column.topAnchor.constraint(equalTo: doc.topAnchor), column.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        reload()
    }

    @objc private func close() { onClose?() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Notes in slide order, as listed.
    private var ordered: [FeedbackNote] {
        var out: [FeedbackNote] = []
        for s in store.scenes.sorted(by: { slideLabel($0).localizedStandardCompare(slideLabel($1)) == .orderedAscending }) {
            out += store.notes(for: s).sorted { $0.created < $1.created }
        }
        return out
    }

    func reload() {
        for v in column.arrangedSubviews { column.removeArrangedSubview(v); v.removeFromSuperview() }
        rows = [:]
        let all = ordered
        if all.isEmpty {
            let l = NSTextField(labelWithString: "No feedback"); l.textColor = .secondaryLabelColor; l.font = Theme.font(12)
            column.addArrangedSubview(l)
            column.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        } else { column.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0) }
        var lastScene: String?
        for n in all {
            if n.scene != lastScene {
                lastScene = n.scene
                let h = NSTextField(labelWithString: slideLabel(n.scene).uppercased())
                h.font = Theme.font(10, .semibold); h.textColor = .secondaryLabelColor
                h.translatesAutoresizingMaskIntoConstraints = false
                let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
                wrap.addSubview(h)
                NSLayoutConstraint.activate([
                    h.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 12), h.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -12),
                    h.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 8), h.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2),
                ])
                column.addArrangedSubview(wrap)
                wrap.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
            let row = makeRow(n)
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            rows[n.id] = row
        }
        if let c = current, !all.contains(where: { $0.id == c }) { current = nil }
        updateCounter()
    }

    private func makeRow(_ n: FeedbackNote) -> NSView {
        let row = FeedbackRow()
        row.onClick = { [weak self] in self?.go(to: n.id) }
        let text = NSTextField(wrappingLabelWithString: n.text.isEmpty ? "(empty)" : n.text)
        text.font = Theme.font(12); text.textColor = n.text.isEmpty ? .tertiaryLabelColor : .labelColor
        text.maximumNumberOfLines = 3; text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let sub = NSTextField(labelWithString: "build \(n.build + 1)")
        sub.font = Theme.font(10); sub.textColor = .tertiaryLabelColor
        sub.translatesAutoresizingMaskIntoConstraints = false
        let del = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete")!, target: self, action: #selector(deleteRow(_:)))
        del.isBordered = false; del.toolTip = "Delete this feedback"
        del.identifier = NSUserInterfaceItemIdentifier(n.id)
        del.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(text); row.addSubview(sub); row.addSubview(del)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12), text.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: del.leadingAnchor, constant: -8),
            sub.leadingAnchor.constraint(equalTo: text.leadingAnchor), sub.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 2),
            sub.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -6),
            del.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10), del.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            del.widthAnchor.constraint(equalToConstant: 22),
        ])
        return row
    }

    @objc private func deleteRow(_ b: NSButton) {
        guard let id = b.identifier?.rawValue else { return }
        let all = ordered
        let i = all.firstIndex { $0.id == id }
        store.remove(id)                 // the host's onChange reloads this list
        if current == id, let i { let rest = ordered; current = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].id }
        updateCounter()
    }

    @objc private func deleteAll() { store.removeAll() }

    @objc private func previous() { step(-1) }
    @objc private func nextOne() { step(1) }
    /// For the headless test: the Next button.
    func goNext() { step(1) }
    private func step(_ d: Int) {
        let all = ordered
        guard !all.isEmpty else { return }
        let i = current.flatMap { c in all.firstIndex { $0.id == c } }
        let k = i.map { ($0 + d + all.count) % all.count } ?? (d > 0 ? 0 : all.count - 1)
        go(to: all[k].id)
    }

    private func go(to id: String) {
        guard let n = store.note(id) else { return }
        current = id
        updateCounter()
        onGo?(n)
        if let r = rows[id] { r.scrollToVisible(r.bounds) }
    }

    private func updateCounter() {
        let all = ordered
        for (id, r) in rows { (r as? FeedbackRow)?.selected = id == current }
        if let c = current, let i = all.firstIndex(where: { $0.id == c }) { counter.stringValue = "\(i + 1) of \(all.count)" }
        else { counter.stringValue = all.isEmpty ? "No feedback" : "\(all.count) note" + (all.count == 1 ? "" : "s") }
    }
}

/// A row of the feedback list: a click goes to its note.
private final class FeedbackRow: NSView {
    var onClick: (() -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        if selected { Theme.accentSoft.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 5, yRadius: 5).fill() }
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

import AppKit

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Shows numbered, coloured source while idle and plain editable Python on focus.
final class SourceCodeView: NSTextView {
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?
    var onChange: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onBlur?() }
        return accepted
    }

    override func didChangeText() {
        super.didChangeText()
        onChange?()
    }

    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let before = text.substring(to: min(selectedRange().location, text.length))
        let line = before.components(separatedBy: "\n").last ?? ""
        let indentation = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let extra = line.trimmingCharacters(in: .whitespaces).hasSuffix(":") ? "    " : ""
        insertText("\n" + indentation + extra, replacementRange: selectedRange())
    }
}

/// Multi-line text box for a Text object: Return starts a new line, ⌘↵ (or leaving the box) applies,
/// Esc restores the current text. Grows with its content up to `maxLines`, then scrolls.
final class MultilineTextBox: NSScrollView, NSTextViewDelegate {
    private final class Editor: NSTextView {
        var onCommit: (() -> Void)?
        var onCancel: (() -> Void)?
        var onBlur: (() -> Void)?
        /// Typed characters become superscript (true) or subscript (false) ones.
        var scriptMode: Bool?
        override func insertText(_ string: Any, replacementRange: NSRange) {
            if let mode = scriptMode, let str = (string as? String) ?? (string as? NSAttributedString)?.string {
                super.insertText(TextTransform.raise(str, superscript: mode), replacementRange: replacementRange); return
            }
            super.insertText(string, replacementRange: replacementRange)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "\r" { onCommit?(); return true }
            return super.performKeyEquivalent(with: event)
        }
        override func cancelOperation(_ sender: Any?) { onCancel?() }
        /// Pictures pasted or dropped in (see `MultilineTextBox.imageBase`); true when it took them.
        var onImages: ((NSPasteboard) -> Bool)?
        override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
            onImages == nil ? super.readablePasteboardTypes : [.fileURL, .png, .tiff] + super.readablePasteboardTypes
        }
        override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
            if let f = onImages, f(pboard) { return true }
            return super.readSelection(from: pboard, type: type)
        }
        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { onBlur?() }
            return accepted
        }
    }

    private let editor = Editor()
    private var original: String
    private var heightConstraint: NSLayoutConstraint!
    /// Fill whatever height the container gives (a resizable pane) instead of growing with the text.
    var fillsContainer = false { didSet { heightConstraint.isActive = !fillsContainer; fit() } }
    private let maxLines: Int
    var onCommit: ((String) -> Void)?
    /// The deck folder: pictures in the text (Markdown images, see `NoteImages`) show inline, and pictures pasted,
    /// dropped or inserted are copied there. Nil keeps the box plain text.
    var imageBase: URL? {
        didSet { editor.onImages = imageBase == nil ? nil : { [weak self] pb in self?.pasteImages(pb) ?? false } }
    }

    var stringValue: String { imageBase == nil ? editor.string : NoteImages.markup(editor.attributedString()) }
    /// Current selection (UTF-16 range) of the box, kept while the box is not focused.
    var selectedRange: NSRange { editor.selectedRange() }
    /// Whether the box has the keyboard focus (unsaved typing is committed when it loses it).
    var isEditing: Bool { window?.firstResponder === editor }
    /// Characters typed become superscript (true) / subscript (false) ones; cleared when the box loses focus.
    var scriptMode: Bool? { get { editor.scriptMode } set { editor.scriptMode = newValue } }
    /// Convert the selected characters; false when nothing is selected or nothing converts.
    func scriptSelection(superscript: Bool) -> Bool {
        let r = editor.selectedRange()
        guard r.length > 0, let out = TextTransform.script((editor.string as NSString).substring(with: r), superscript: superscript) else { return false }
        editor.scriptMode = nil
        editor.insertText(out, replacementRange: r)
        editor.setSelectedRange(NSRange(location: r.location, length: (out as NSString).length))
        return true
    }
    var font: NSFont? { get { editor.font } set { editor.font = newValue; fit() } }
    var textColor: NSColor? { get { editor.textColor } set { editor.textColor = newValue } }
    var editorBackground: NSColor { get { editor.backgroundColor } set { editor.backgroundColor = newValue; backgroundColor = newValue } }

    /// Replace the text without triggering a commit (the caller applies the edit itself).
    func setText(_ s: String) { show(s); original = s; fit() }

    private func show(_ s: String) {
        guard imageBase != nil, NoteImages.has(s) else { editor.string = s; return }
        let attrs: [NSAttributedString.Key: Any] = [.font: editor.font ?? Theme.font(13), .foregroundColor: editor.textColor ?? NSColor.textColor]
        editor.textStorage?.setAttributedString(NoteImages.attributed(s, base: imageBase, attributes: attrs, maxWidth: imageWidth))
    }

    /// Highlight characters `from..<to` (Unicode scalars) of `value`, the text the box shows, as a search match and
    /// scroll them into view; nil `value` clears it. Pictures make the box's text differ from `value`, so the match
    /// is found again in it by its text and how many times that came before.
    func highlight(in value: String?, from: Int, to: Int) {
        guard let lm = editor.layoutManager else { return }
        let text = editor.string as NSString
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: text.length))
        let scalars = Array((value ?? "").unicodeScalars)
        guard value != nil, from >= 0, from < to, to <= scalars.count else { return }
        func str(_ s: ArraySlice<Unicode.Scalar>) -> String { var u = String.UnicodeScalarView(); u.append(contentsOf: s); return String(u) }
        let match = str(scalars[from..<to]), before = str(scalars[..<from]) as NSString
        var n = 0, at = NSRange(location: 0, length: before.length)
        while case let r = before.range(of: match, range: at), r.location != NSNotFound {
            n += 1; at = NSRange(location: r.location + 1, length: before.length - r.location - 1)
        }
        var found = NSRange(location: NSNotFound, length: 0), from16 = 0
        for _ in 0...n {
            found = text.range(of: match, range: NSRange(location: from16, length: text.length - from16))
            guard found.location != NSNotFound else { return }
            from16 = found.location + 1
        }
        lm.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.8), forCharacterRange: found)
        editor.scrollRangeToVisible(found)
    }

    /// Pictures at most this wide: the box's text width, up to 360 pt.
    private var imageWidth: CGFloat { min(360, max(80, (editor.textContainer?.size.width ?? 360) - 12)) }

    /// The pictures in the text, for the headless test.
    var imageCount: Int {
        var n = 0
        editor.attributedString().enumerateAttribute(.attachment, in: NSRange(location: 0, length: editor.attributedString().length)) { v, _, _ in
            if v is NoteImageAttachment { n += 1 }
        }
        return n
    }

    /// Put picture files (paths relative to `imageBase`) at the insertion point.
    func insertImages(_ paths: [String]) {
        guard let base = imageBase, !paths.isEmpty else { return }
        if window?.firstResponder !== editor { window?.makeFirstResponder(editor) }
        NoteImages.insert(paths, in: editor, base: base, maxWidth: imageWidth)
        fit()
    }

    /// Pictures on a pasteboard into the text at the insertion point; false when it has none.
    func pasteImages(_ pb: NSPasteboard) -> Bool {
        guard let base = imageBase, let paths = NoteImages.importImages(from: pb, into: base) else { return false }
        NoteImages.insert(paths, in: editor, base: base, maxWidth: imageWidth)
        fit()
        return true
    }

    init(string: String, maxLines: Int = 14) {
        original = string; self.maxLines = maxLines
        super.init(frame: .zero)
        editor.font = Theme.font(13)
        editor.isRichText = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.textContainerInset = NSSize(width: 2, height: 4)
        editor.minSize = .zero; editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.string = string; editor.delegate = self
        editor.onCommit = { [weak self] in self?.commit() }
        editor.onBlur = { [weak self] in self?.editor.scriptMode = nil; self?.commit() }
        editor.onCancel = { [weak self] in
            guard let self = self else { return }
            self.show(self.original); self.fit()
            self.window?.makeFirstResponder(nil)
        }
        documentView = editor
        hasVerticalScroller = true; autohidesScrollers = true; borderType = .bezelBorder
        heightConstraint = heightAnchor.constraint(equalToConstant: 24); heightConstraint.isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); fit() }

    func textDidChange(_ notification: Notification) { fit() }

    /// Focus the box and select all of its text.
    func beginEditing() { window?.makeFirstResponder(editor); editor.selectAll(nil) }

    private func commit() {
        let v = stringValue
        guard v != original else { return }
        original = v
        onCommit?(v)
    }

    private func fit() {
        guard !fillsContainer, let lm = editor.layoutManager, let tc = editor.textContainer else { return }
        lm.ensureLayout(for: tc)
        let line = lm.defaultLineHeight(for: editor.font ?? Theme.font(13))
        let used = max(lm.usedRect(for: tc).height, line)
        let h = min(used, line * CGFloat(maxLines)) + editor.textContainerInset.height * 2 + 4
        if abs(heightConstraint.constant - h) > 0.5 { heightConstraint.constant = h }
    }
}

extension NSColor {
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count != 6 { h = "FFFFFF" }
        let v = UInt32(h, radix: 16) ?? 0xFFFFFF
        self.init(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

/// The slide navigator: Delete removes the selected slide (or the build last clicked under it), right-click offers
/// the Slide menu for that row.
final class SlideTable: NSTableView {
    var onDelete: (() -> Void)?
    var onDeleteBuild: (() -> Void)?
    /// A build panel under the selected slide was clicked (or stepped to) since the last click on a slide row.
    var buildFocused = false
    var onMenu: ((Int) -> NSMenu?)?
    /// Called when the already-selected slide is clicked again (toggles its builds list).
    var onReclick: ((Int) -> Void)?
    /// ↑/↓ step through every build of every slide (±1) instead of jumping a whole row.
    var onArrow: ((Int) -> Void)?
    private var clickedSelected = false
    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        clickedSelected = row >= 0 && row == selectedRow
        buildFocused = false
        super.mouseDown(with: event)
    }
    /// The table's action fires after a click that was not a drag; a reclick of the selected row toggles.
    @objc func rowClicked(_ sender: Any?) {
        guard clickedSelected, clickedRow >= 0, clickedRow == selectedRow else { return }
        onReclick?(clickedRow)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, selectedRow >= 0 {
            if buildFocused, let d = onDeleteBuild { d() } else { onDelete?() }
            return
        }
        if event.keyCode == 125 || event.keyCode == 126, let arrow = onArrow,
           event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            arrow(event.keyCode == 125 ? 1 : -1); return
        }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, row != selectedRow { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return onMenu?(row)
    }
    /// Let clicks reach the nested build panels instead of being swallowed by row selection.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        responder is BuildPanel || super.validateProposedFirstResponder(responder, for: event)
    }
}

/// Row view without the system highlight: selection is shown by a ring around the thumbnail.
final class FlatRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }
}

/// One row of the slide navigator.
final class SlideCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("SlideCell")
    private let num = NSTextField(labelWithString: "")
    private let thumb = NSImageView()
    private let ring = NSView()
    private let name = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    /// Nested list of the slide's builds, shown under the selected slide only.
    private let builds = NSStackView()
    var onBuild: ((Int) -> Void)?

    /// Horizontal space around the thumbnail (number column + margins) and the extra indent of the builds list.
    static let thumbInset: CGFloat = 2 + 20 + 8 + 12
    static let buildIndent: CGFloat = 16
    static let buildSpacing: CGFloat = 6
    static let baseHeight: CGFloat = 108

    /// Row height for a slide at the given column width, with `builds` nested panels under it (0 = collapsed).
    static func rowHeight(columnWidth: CGFloat, builds n: Int) -> CGFloat {
        let thumbW = max(40, columnWidth - thumbInset)
        let thumbH = (thumbW * 9 / 16).rounded()
        // thumbnail (16:9, scales with the column) + name line; never shorter than the base row
        guard n > 0 else { return max(baseHeight, 6 + thumbH + 4 + 13 + 2) }
        let top = max(baseHeight, 6 + thumbH + 4 + 13 + buildSpacing)
        let bw = max(32, thumbW - buildIndent)
        let bh = (bw * 9 / 16).rounded()
        return top + CGFloat(n) * (bh + buildSpacing) + 2
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = SlideCell.id
        num.font = Theme.font(11, .medium); num.textColor = .tertiaryLabelColor; num.alignment = .right
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.backgroundColor = NSColor.black.cgColor
        thumb.layer?.cornerRadius = 5; thumb.layer?.masksToBounds = true
        ring.wantsLayer = true
        ring.layer?.cornerRadius = 7; ring.layer?.borderWidth = 0
        ring.layer?.shadowColor = NSColor.black.cgColor; ring.layer?.shadowOpacity = 0.28
        ring.layer?.shadowRadius = 4; ring.layer?.shadowOffset = CGSize(width: 0, height: -1.5)
        name.font = Theme.font(10); name.textColor = .secondaryLabelColor; name.lineBreakMode = .byTruncatingTail
        badge.font = Theme.font(10, .medium); badge.textColor = .tertiaryLabelColor; badge.alignment = .right
        // the badge keeps its full text ("3 builds ▾"); a long slide name truncates instead
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        builds.orientation = .vertical; builds.alignment = .leading; builds.spacing = SlideCell.buildSpacing
        builds.setHuggingPriority(.required, for: .vertical)
        for v in [num, ring, thumb, name, badge, builds] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            num.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), num.widthAnchor.constraint(equalToConstant: 20),
            num.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            thumb.leadingAnchor.constraint(equalTo: num.trailingAnchor, constant: 8),
            thumb.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            thumb.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            thumb.heightAnchor.constraint(equalTo: thumb.widthAnchor, multiplier: 9.0 / 16.0),
            ring.leadingAnchor.constraint(equalTo: thumb.leadingAnchor, constant: -2), ring.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 2),
            ring.topAnchor.constraint(equalTo: thumb.topAnchor, constant: -2), ring.bottomAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 2),
            name.leadingAnchor.constraint(equalTo: thumb.leadingAnchor, constant: 2), name.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 4),
            name.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -4),
            badge.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: -2), badge.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            builds.leadingAnchor.constraint(equalTo: thumb.leadingAnchor, constant: SlideCell.buildIndent),
            builds.trailingAnchor.constraint(equalTo: thumb.trailingAnchor),
            builds.topAnchor.constraint(equalTo: name.bottomAnchor, constant: SlideCell.buildSpacing),
        ])
        // keep the ring behind the thumbnail
        addSubview(ring, positioned: .below, relativeTo: thumb)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(number: Int, name n: String, image: NSImage?, status: String, stops: Int, active: Bool, unused: Bool = false, hidden: Bool = false, expanded: Bool? = nil) {
        if hidden, !unused {
            num.attributedStringValue = NSAttributedString(string: String(number), attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .font: Theme.font(11, .medium)])
        } else {
            num.stringValue = unused ? "–" : String(number)
        }
        name.stringValue = status == "error" ? "\(n) — error" : n
        name.textColor = status == "error" ? .systemRed : (active ? .labelColor : .secondaryLabelColor)
        thumb.image = image
        thumb.alphaValue = hidden ? 0.4 : 1
        let chevron = expanded.map { $0 ? " ▾" : " ▸" } ?? ""
        badge.stringValue = unused ? "unused" : hidden ? "hidden" : (stops > 1 ? "\(stops) builds" + chevron : (image == nil && status != "error" ? "…" : ""))
        setActive(active)
        setBuilds([], active: -1)
    }

    /// Show the slide's builds as small indented panels under the thumbnail (empty list collapses them).
    func setBuilds(_ images: [NSImage?], active: Int) {
        builds.arrangedSubviews.forEach { $0.removeFromSuperview() }
        builds.isHidden = images.isEmpty
        for (i, img) in images.enumerated() {
            let panel = BuildPanel(image: img, index: i, active: i == active) { [weak self] in self?.onBuild?(i) }
            builds.addArrangedSubview(panel)
            panel.widthAnchor.constraint(equalTo: builds.widthAnchor).isActive = true
        }
    }

    func setActive(_ on: Bool) {
        ring.layer?.borderWidth = on ? 2.5 : 0
        ring.layer?.borderColor = Theme.accent.cgColor
        num.textColor = on ? Theme.accent : .tertiaryLabelColor
        name.textColor = on ? .labelColor : .secondaryLabelColor
    }
}

/// One build of the selected slide, nested under it in the navigator: a smaller 16:9 panel with its number.
final class BuildPanel: NSView {
    private let handler: () -> Void
    init(image: NSImage?, index: Int, active: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5; layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.borderWidth = active ? 2 : 1
        layer?.borderColor = (active ? Theme.accent : NSColor.tertiaryLabelColor.withAlphaComponent(0.35)).cgColor
        let iv = NSImageView(image: image ?? NSImage())
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.alphaValue = active ? 1 : 0.72
        iv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iv)
        let l = NSTextField(labelWithString: String(index + 1)); l.font = Theme.font(9, .bold); l.textColor = .white; l.alignment = .center
        l.wantsLayer = true; l.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor; l.layer?.cornerRadius = 3
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalTo: widthAnchor, multiplier: 9.0 / 16.0),
            iv.leadingAnchor.constraint(equalTo: leadingAnchor), iv.trailingAnchor.constraint(equalTo: trailingAnchor),
            iv.topAnchor.constraint(equalTo: topAnchor), iv.bottomAnchor.constraint(equalTo: bottomAnchor),
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), l.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            l.widthAnchor.constraint(equalToConstant: 14), l.heightAnchor.constraint(equalToConstant: 12),
        ])
        toolTip = "Build \(index + 1)"
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Clicks still land here (see `SlideTable.validateProposedFirstResponder`), but key focus stays on the table:
    /// the panel is rebuilt on every build change, and a focused panel would take the keyboard with it.
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) { handler() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Small build thumbnail in the steps strip.
final class StepButton: NSView {
    private let handler: () -> Void
    init(path: String, index: Int, active: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: NSRect(x: 0, y: 0, width: 80, height: 45))
        wantsLayer = true
        layer?.borderWidth = active ? 2 : 1
        Theme.layerColors(self) { $0.layer?.borderColor = (active ? Theme.accent : Theme.ink(0.14)).cgColor }
        layer?.cornerRadius = 6; layer?.masksToBounds = true
        let iv = NSImageView(image: DarkMode.image(path: path) ?? NSImage())
        iv.imageScaling = .scaleAxesIndependently
        iv.frame = bounds; iv.autoresizingMask = [.width, .height]
        iv.alphaValue = active ? 1 : 0.78
        addSubview(iv)
        let l = NSTextField(labelWithString: String(index + 1)); l.font = Theme.font(10, .bold); l.textColor = .white
        l.wantsLayer = true; l.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor; l.layer?.cornerRadius = 4
        l.frame = NSRect(x: 4, y: 29, width: 14, height: 13); l.alignment = .center
        addSubview(l)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 80).isActive = true
        heightAnchor.constraint(equalToConstant: 45).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { handler() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Modal LaTeX editor with a live preview (compiled by the real TeX through the engine).
final class LatexSheet: NSObject, NSTextViewDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
    private let text = NSTextView()
    private let preview = NSImageView()
    private let errLabel = NSTextField(wrappingLabelWithString: "")
    private let sharedBox: NSButton?
    private let renderFn: (String) async -> (String?, String?)
    private let applyFn: (String, Bool) -> Void
    private var task: Task<Void, Never>?

    init(initial: String, shared: SharedInfo?, render: @escaping (String) async -> (String?, String?), apply: @escaping (String, Bool) -> Void) {
        renderFn = render; applyFn = apply
        if let s = shared {
            let b = NSButton(checkboxWithTitle: "Change everywhere (\(s.name) in \(s.rel), used \(s.uses)×). Untick for this slide only.", target: nil, action: nil)
            b.state = .on; sharedBox = b
        } else { sharedBox = nil }
        super.init()
        window.title = "Edit formula"
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = content
        text.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        text.isRichText = false; text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.string = initial; text.delegate = self
        let sv = NSScrollView(); sv.documentView = text; sv.hasVerticalScroller = true; sv.borderType = .bezelBorder
        text.minSize = NSSize(width: 0, height: 0); text.isVerticallyResizable = true
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        let pv = NSView(); pv.wantsLayer = true; pv.layer?.backgroundColor = NSColor.black.cgColor; pv.layer?.cornerRadius = 8
        preview.imageScaling = .scaleProportionallyDown; preview.translatesAutoresizingMaskIntoConstraints = false
        pv.addSubview(preview)
        errLabel.textColor = .systemRed; errLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        errLabel.translatesAutoresizingMaskIntoConstraints = false; pv.addSubview(errLabel)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: pv.leadingAnchor, constant: 12), preview.trailingAnchor.constraint(equalTo: pv.trailingAnchor, constant: -12),
            preview.topAnchor.constraint(equalTo: pv.topAnchor, constant: 12), preview.bottomAnchor.constraint(equalTo: pv.bottomAnchor, constant: -12),
            errLabel.leadingAnchor.constraint(equalTo: pv.leadingAnchor, constant: 12), errLabel.trailingAnchor.constraint(equalTo: pv.trailingAnchor, constant: -12),
            errLabel.bottomAnchor.constraint(equalTo: pv.bottomAnchor, constant: -10),
        ])
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed)); cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "Apply", target: self, action: #selector(applyPressed)); ok.keyEquivalent = "\r"; ok.keyEquivalentModifierMask = .command
        ok.bezelStyle = .rounded
        let hint = NSTextField(labelWithString: "LaTeX  ·  ⌘↵ to apply"); hint.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [cancel, ok]); buttons.spacing = 8
        var views: [NSView] = [hint, sv, pv]
        if let b = sharedBox { views.append(b) }
        views.append(buttons)
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            sv.widthAnchor.constraint(equalTo: stack.widthAnchor), pv.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sv.heightAnchor.constraint(equalToConstant: 110), pv.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        buttons.setContentHuggingPriority(.required, for: .vertical)
        refresh()
    }

    func textDidChange(_ n: Notification) { refresh() }

    private func refresh() {
        task?.cancel()
        let tex = text.string
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            guard let self = self else { return }
            let (path, err) = await self.renderFn(tex)
            if Task.isCancelled { return }
            if let p = path { self.preview.image = NSImage(contentsOfFile: p); self.errLabel.stringValue = "" }
            else { self.errLabel.stringValue = (err ?? "LaTeX error").components(separatedBy: "\n").suffix(4).joined(separator: "\n") }
        }
    }

    @objc private func cancelPressed() { task?.cancel(); window.sheetParent?.endSheet(window) }
    @objc private func applyPressed() {
        task?.cancel()
        let v = text.string, shared = sharedBox?.state != .off
        let fn = applyFn                       // the controller drops this sheet when it closes; keep the callback alive
        let parent = window.sheetParent
        parent?.endSheet(window)
        DispatchQueue.main.async { fn(v, shared) }
    }
}

extension String {
    func appendLine(to path: String) throws {
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(self.utf8)); h.closeFile() }
        else { try self.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}

/// Split view with a wider, easy-to-grab divider that still draws as a hairline.
final class GrabSplitView: NSSplitView, NSSplitViewDelegate {
    /// Let the first and last panes collapse when their divider is dragged past half their minimum
    /// width; dragging the divider back out from the window edge brings them back.
    var collapsesEdgePanes = false { didSet { delegate = collapsesEdgePanes || collapsesLastPane ? self : nil } }
    /// Only the last pane collapses (the drawer under the slide; the slide itself never does).
    var collapsesLastPane = false { didSet { delegate = collapsesEdgePanes || collapsesLastPane ? self : nil } }
    /// After the panes were resized, e.g. one collapsed or brought back by a drag.
    var onResize: (() -> Void)?
    override var dividerThickness: CGFloat { 9 }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        (collapsesEdgePanes && (subview === arrangedSubviews.first || subview === arrangedSubviews.last))
            || (collapsesLastPane && subview === arrangedSubviews.last)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) { onResize?() }
    override func drawDivider(in rect: NSRect) {
        NSColor.separatorColor.setFill()
        if isVertical { NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height).fill() }
        else { NSRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1).fill() }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
    }
}

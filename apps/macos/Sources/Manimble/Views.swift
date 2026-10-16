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
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "\r" { onCommit?(); return true }
            return super.performKeyEquivalent(with: event)
        }
        override func cancelOperation(_ sender: Any?) { onCancel?() }
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

    var stringValue: String { editor.string }
    /// Current selection (UTF-16 range) of the box, kept while the box is not focused.
    var selectedRange: NSRange { editor.selectedRange() }
    /// Whether the box has the keyboard focus (unsaved typing is committed when it loses it).
    var isEditing: Bool { window?.firstResponder === editor }
    var font: NSFont? { get { editor.font } set { editor.font = newValue; fit() } }
    var textColor: NSColor? { get { editor.textColor } set { editor.textColor = newValue } }
    var editorBackground: NSColor { get { editor.backgroundColor } set { editor.backgroundColor = newValue; backgroundColor = newValue } }

    /// Replace the text without triggering a commit (the caller applies the edit itself).
    func setText(_ s: String) { editor.string = s; original = s; fit() }

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
        editor.onBlur = { [weak self] in self?.commit() }
        editor.onCancel = { [weak self] in
            guard let self = self else { return }
            self.editor.string = self.original; self.fit()
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
        let v = editor.string
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

/// The slide navigator: Delete removes the selected slide, right-click offers the Slide menu for that row.
final class SlideTable: NSTableView {
    var onDelete: (() -> Void)?
    var onMenu: ((Int) -> NSMenu?)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, selectedRow >= 0 { onDelete?(); return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, row != selectedRow { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return onMenu?(row)
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
        for v in [num, ring, thumb, name, badge] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
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
        ])
        // keep the ring behind the thumbnail
        addSubview(ring, positioned: .below, relativeTo: thumb)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(number: Int, name n: String, image: NSImage?, status: String, stops: Int, active: Bool, unused: Bool = false, hidden: Bool = false) {
        if hidden, !unused {
            num.attributedStringValue = NSAttributedString(string: String(number), attributes: [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .font: Theme.font(11, .medium)])
        } else {
            num.stringValue = unused ? "–" : String(number)
        }
        name.stringValue = status == "error" ? "\(n) — error" : n
        name.textColor = status == "error" ? .systemRed : (active ? .labelColor : .secondaryLabelColor)
        thumb.image = image
        thumb.alphaValue = hidden ? 0.4 : 1
        badge.stringValue = unused ? "unused" : hidden ? "hidden" : (stops > 1 ? "\(stops) builds" : (image == nil && status != "error" ? "…" : ""))
        setActive(active)
    }

    func setActive(_ on: Bool) {
        ring.layer?.borderWidth = on ? 2.5 : 0
        ring.layer?.borderColor = Theme.accent.cgColor
        num.textColor = on ? Theme.accent : .tertiaryLabelColor
        name.textColor = on ? .labelColor : .secondaryLabelColor
    }
}

/// Small build thumbnail in the steps strip.
final class StepButton: NSView {
    private let handler: () -> Void
    init(path: String, index: Int, active: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: NSRect(x: 0, y: 0, width: 80, height: 45))
        wantsLayer = true
        layer?.borderWidth = active ? 2 : 1
        layer?.borderColor = (active ? Theme.accent : NSColor(white: 1, alpha: 0.14)).cgColor
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
final class GrabSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 9 }
    override func drawDivider(in rect: NSRect) {
        NSColor.separatorColor.setFill()
        if isVertical { NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height).fill() }
        else { NSRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1).fill() }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
    }
}

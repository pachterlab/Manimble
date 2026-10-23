import AppKit

/// PowerPoint-style Home bar above the slide: font, size, character styles, paragraph tools, view helpers and
/// drawing tools. The controller fills it from the selected object and wires every control to an edit.
final class FormatBar: NSView {
    // font
    let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let sizeField = NSTextField(string: "")
    let sizeStepper = NSStepper()
    let bigger = FormatBar.button("textformat.size.larger", "A↑", "Increase font size (⌥⌘=)")
    let smaller = FormatBar.button("textformat.size.smaller", "A↓", "Decrease font size (⌥⌘-)")
    let bold = FormatBar.button("bold", "B", "Bold (⌘B)", toggle: true)
    let italic = FormatBar.button("italic", "I", "Italic (⌘I)", toggle: true)
    let underline = FormatBar.button("underline", "U", "Underline (⌘U): a line attached to the text", toggle: true)
    let strike = FormatBar.button("strikethrough", "S", "Strikethrough: a line attached to the text", toggle: true)
    let superscript = FormatBar.button("textformat.superscript", "x²", "Superscript (⇧⌘+): the selected characters, or what you type next", toggle: true)
    let subscriptButton = FormatBar.button("textformat.subscript", "x₂", "Subscript (⇧⌘_): the selected characters, or what you type next", toggle: true)
    let highlight = FormatBar.button("highlighter", "H", "Text highlight colour (a background rectangle behind the text)")
    let colorButton = FormatBar.button("textformat", "A", "Text colour")
    let clearFormat = FormatBar.button("eraser", "Tx", "Clear all formatting: bold, italic, colour, highlight, underline, strikethrough, line spacing")
    // paragraph
    let bullets = FormatBar.button("list.bullet", "•", "Bulleted list (⇧⌘8)", toggle: true)
    let numbers = FormatBar.button("list.number", "1.", "Numbered list (⇧⌘7)", toggle: true)
    let outdent = FormatBar.button("decrease.indent", "⇤", "Decrease indent (⇧⌘[)")
    let indent = FormatBar.button("increase.indent", "⇥", "Increase indent (⇧⌘])")
    let alignLeft = FormatBar.button("text.alignleft", "L", "Align left (⌘L)", toggle: true)
    let alignCenter = FormatBar.button("text.aligncenter", "C", "Center (⌘E)", toggle: true)
    let alignRight = FormatBar.button("text.alignright", "R", "Align right (⌘R)", toggle: true)
    let alignJustify = FormatBar.button("text.justify", "J", "Justify (⌘J) — not available for Manim text with manual line breaks", toggle: true)
    let spacing = NSPopUpButton(frame: .zero, pullsDown: true)
    let columns = NSPopUpButton(frame: .zero, pullsDown: true)
    // view
    let grid = FormatBar.button("grid", "#", "Grid lines, one manim unit apart (⌥⌘G)", toggle: true)
    let snap = FormatBar.button("square.on.square.dashed", "⌗", "Snap to other objects, guides and the slide while dragging (⌥⌘S; hold ⌥ to drag freely)", toggle: true)
    let guideV = FormatBar.button("rectangle.split.2x1", "│", "Add a vertical guide (drag it into place, drag it off the slide to remove)")
    let guideH = FormatBar.button("rectangle.split.1x2", "─", "Add a horizontal guide (drag it into place, drag it off the slide to remove)")
    var alignButtons: [(String, NSButton)] {
        [("left", alignLeft), ("center", alignCenter), ("right", alignRight), ("justify", alignJustify)]
    }
    var textControls: [NSControl] { [bold, italic, underline, strike, superscript, subscriptButton, highlight, clearFormat,
                                      bullets, numbers, outdent, indent, alignLeft, alignCenter, alignRight, alignJustify, spacing, columns] }

    static func button(_ symbol: String, _ fallback: String, _ tip: String, toggle: Bool = false) -> NSButton {
        let b = NSButton(title: "", target: nil, action: nil)
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) {
            b.image = img; b.imagePosition = .imageOnly
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        } else {
            b.title = fallback; b.font = Theme.font(12, .semibold)
        }
        b.bezelStyle = .texturedRounded
        b.setButtonType(toggle ? .pushOnPushOff : .momentaryPushIn)
        b.toolTip = tip
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }

    private static func separator() -> NSView {
        let v = NSBox(); v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    private static func pulldown(_ pop: NSPopUpButton, _ symbol: String, _ fallback: String, _ tip: String, items: [(String, Any?)]) {
        pop.removeAllItems()
        let head = NSMenuItem(title: fallback, action: nil, keyEquivalent: "")
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) { head.image = img; head.title = "" }
        pop.menu?.addItem(head)
        for (title, obj) in items {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: ""); mi.representedObject = obj
            pop.menu?.addItem(mi)
        }
        pop.toolTip = tip
        pop.bezelStyle = .texturedRounded
        (pop.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        pop.imagePosition = head.image == nil ? .noImage : .imageOnly
        pop.translatesAutoresizingMaskIntoConstraints = false
        pop.widthAnchor.constraint(equalToConstant: 44).isActive = true
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        Theme.layerColors(self) { $0.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        fontPopup.translatesAutoresizingMaskIntoConstraints = false
        fontPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        fontPopup.toolTip = "Font family (usually a deck-wide constant, so it changes every slide)"
        fontPopup.bezelStyle = .texturedRounded
        sizeField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.widthAnchor.constraint(equalToConstant: 46).isActive = true
        sizeField.alignment = .right; sizeField.toolTip = "Font size (manim font_size)"
        sizeStepper.minValue = 4; sizeStepper.maxValue = 400; sizeStepper.increment = 1
        sizeStepper.toolTip = "Font size"
        setColor(.white)
        FormatBar.pulldown(spacing, "arrow.up.and.down.text.horizontal", "↕", "Line spacing",
                           items: [("1.0", 1.0), ("1.15", 1.15), ("1.5", 1.5), ("2.0", 2.0), ("2.5", 2.5), ("3.0", 3.0), ("Custom…", nil)])
        FormatBar.pulldown(columns, "rectangle.split.2x1", "⫴", "Columns: lay the lines out side by side",
                           items: [("One column", 1), ("Two columns", 2), ("Three columns", 3), ("Four columns", 4)])

        let fontGroup: [NSView] = [fontPopup, sizeField, sizeStepper, bigger, smaller, FormatBar.separator(),
                                   bold, italic, underline, strike, superscript, subscriptButton, FormatBar.separator(),
                                   highlight, colorButton, clearFormat]
        let paraGroup: [NSView] = [FormatBar.separator(), bullets, numbers, outdent, indent, FormatBar.separator(),
                                   alignLeft, alignCenter, alignRight, alignJustify, spacing, columns]
        let viewGroup: [NSView] = [FormatBar.separator(), grid, snap, guideV, guideH]
        let stack = NSStackView(views: fontGroup + paraGroup + viewGroup)
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 4
        stack.detachesHiddenViews = true
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        for v in paraGroup { stack.setVisibilityPriority(.detachOnlyIfNecessary, for: v) }
        for v in viewGroup { stack.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 700), for: v) }
        stack.setCustomSpacing(2, after: sizeField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let line = hairline(); line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 36),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The text colour control: an "A" over a bar in the current colour.
    func setColor(_ c: NSColor) {
        let img = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            let a = NSAttributedString(string: "A", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
            let sz = a.size()
            a.draw(at: NSPoint(x: (20 - sz.width) / 2, y: 3))
            c.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 0.5, width: 16, height: 3.5), xRadius: 1, yRadius: 1).fill()
            return true
        }
        img.isTemplate = false
        colorButton.image = img; colorButton.imagePosition = .imageOnly
    }
}

/// Bullets, numbering, indentation and Unicode super/subscripts for plain `Text` strings.
enum TextTransform {
    static let marker = try! NSRegularExpression(pattern: "^(\\s*)(?:[•\\-–▪◦]|\\d+[.)])\\s+")

    static func lines(_ s: String) -> [String] { s.components(separatedBy: "\n") }

    /// (indent, rest) with any list marker removed.
    static func strip(_ line: String) -> (String, String) {
        let ns = line as NSString
        if let m = marker.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            return (ns.substring(with: m.range(at: 1)), ns.substring(from: m.range.location + m.range.length))
        }
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        return (indent, String(line.dropFirst(indent.count)))
    }

    static func hasMarker(_ line: String) -> Bool {
        marker.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    static func isBulleted(_ s: String) -> Bool {
        let ls = lines(s).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return !ls.isEmpty && ls.allSatisfy { hasMarker($0) && !$0.trimmingCharacters(in: .whitespaces).first!.isNumber }
    }
    static func isNumbered(_ s: String) -> Bool {
        let ls = lines(s).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return !ls.isEmpty && ls.allSatisfy { hasMarker($0) && $0.trimmingCharacters(in: .whitespaces).first!.isNumber }
    }

    static func toggleBullets(_ s: String) -> String {
        let on = isBulleted(s)
        return lines(s).map { l in
            if l.trimmingCharacters(in: .whitespaces).isEmpty { return l }
            let (ind, rest) = strip(l)
            return on ? ind + rest : ind + "• " + rest
        }.joined(separator: "\n")
    }

    static func toggleNumbers(_ s: String) -> String {
        let on = isNumbered(s)
        var n = 0
        return lines(s).map { l in
            if l.trimmingCharacters(in: .whitespaces).isEmpty { return l }
            let (ind, rest) = strip(l)
            n += 1
            return on ? ind + rest : ind + "\(n). " + rest
        }.joined(separator: "\n")
    }

    /// Indent (+) or outdent (−) the given lines (all when nil) by four spaces.
    static func indent(_ s: String, lines which: ClosedRange<Int>?, by delta: Int) -> String {
        lines(s).enumerated().map { i, l in
            guard which == nil || which!.contains(i) else { return l }
            if delta > 0 { return "    " + l }
            var k = 0
            while k < 4 && k < l.count && l[l.index(l.startIndex, offsetBy: k)] == " " { k += 1 }
            return String(l.dropFirst(k))
        }.joined(separator: "\n")
    }

    /// Line indexes covered by a UTF-16 range of the string.
    static func lineRange(_ s: String, _ r: NSRange) -> ClosedRange<Int> {
        let ns = s as NSString
        let a = ns.substring(to: min(r.location, ns.length)).filter { $0 == "\n" }.count
        let endLoc = max(r.location, r.location + r.length - (r.length > 0 ? 1 : 0))
        let b = ns.substring(to: min(endLoc, ns.length)).filter { $0 == "\n" }.count
        return a...max(a, b)
    }

    static let sup: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(
        Array("0123456789+-=()abcdefghijklmnoprstuvwxyzABDEGHIJKLMNOPRTUVW"),
        Array("⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻᴬᴮᴰᴱᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾᴿᵀᵁⱽᵂ")))
    static let sub: [Character: Character] = Dictionary(uniqueKeysWithValues: zip(
        Array("0123456789+-=()aehijklmnoprstuvx"),
        Array("₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ")))

    /// Each character in its super/subscript form where one exists (typing in script mode).
    static func raise(_ s: String, superscript: Bool) -> String {
        let map = superscript ? sup : sub
        return String(s.map { map[$0] ?? $0 })
    }

    /// Convert to (or, when everything already is, back from) super/subscript. nil when nothing can be converted.
    static func script(_ s: String, superscript: Bool) -> String? {
        let map = superscript ? sup : sub
        let back = Dictionary(uniqueKeysWithValues: map.map { ($1, $0) })
        let chars = Array(s)
        let convertible = chars.filter { map[$0] != nil || back[$0] != nil }
        if convertible.isEmpty { return nil }
        let allScripted = convertible.allSatisfy { back[$0] != nil }
        let out = chars.map { c -> Character in
            if allScripted { return back[c] ?? c }
            return map[c] ?? c
        }
        return String(out)
    }
}

extension MainController {
    // MARK: building and syncing the bar

    func makeFormatBar() -> FormatBar {
        let bar = FormatBar()
        bar.fontPopup.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        bar.fontPopup.menu?.delegate = fontMenuStyler          // each family's name set in that family, like PowerPoint
        bar.fontPopup.target = self; bar.fontPopup.action = #selector(familyChanged(_:))
        bar.sizeField.target = self; bar.sizeField.action = #selector(sizeCommitted(_:))
        bar.sizeStepper.target = self; bar.sizeStepper.action = #selector(sizeStepped(_:))
        bar.bigger.target = self; bar.bigger.action = #selector(formatBigger)
        bar.smaller.target = self; bar.smaller.action = #selector(formatSmaller)
        bar.bold.target = self; bar.bold.action = #selector(boldToggled(_:))
        bar.italic.target = self; bar.italic.action = #selector(italicToggled(_:))
        bar.underline.target = self; bar.underline.action = #selector(underlineToggled(_:))
        bar.strike.target = self; bar.strike.action = #selector(strikeToggled(_:))
        bar.superscript.target = self; bar.superscript.action = #selector(formatSuperscript)
        bar.subscriptButton.target = self; bar.subscriptButton.action = #selector(formatSubscript)
        bar.highlight.target = self; bar.highlight.action = #selector(highlightPressed(_:))
        bar.colorButton.target = self; bar.colorButton.action = #selector(colorButtonPressed(_:))
        bar.clearFormat.target = self; bar.clearFormat.action = #selector(clearFormatting)
        bar.bullets.target = self; bar.bullets.action = #selector(toggleBullets)
        bar.numbers.target = self; bar.numbers.action = #selector(toggleNumbering)
        bar.outdent.target = self; bar.outdent.action = #selector(decreaseIndent)
        bar.indent.target = self; bar.indent.action = #selector(increaseIndent)
        bar.alignLeft.target = self; bar.alignLeft.action = #selector(alignLeft)
        bar.alignCenter.target = self; bar.alignCenter.action = #selector(alignCenter)
        bar.alignRight.target = self; bar.alignRight.action = #selector(alignRight)
        bar.alignJustify.target = self; bar.alignJustify.action = #selector(alignJustify)
        bar.spacing.target = self; bar.spacing.action = #selector(spacingChosen(_:))
        bar.columns.target = self; bar.columns.action = #selector(columnsChosen(_:))
        bar.grid.target = self; bar.grid.action = #selector(toggleGrid)
        bar.snap.target = self; bar.snap.action = #selector(toggleSnap)
        bar.guideV.target = self; bar.guideV.action = #selector(addVerticalGuide)
        bar.guideH.target = self; bar.guideH.action = #selector(addHorizontalGuide)
        return bar
    }

    /// Reflect the selected object (or nothing) in the bar.
    func syncFormatBar() {
        guard let bar = formatBar else { return }
        let o = objInfo
        let isText = o?.kind == "text", isTexty = o?.kind == "text" || o?.kind == "tex"
        bar.fontPopup.isEnabled = isText
        if let f = o?.font, isText {
            if bar.fontPopup.item(withTitle: f) == nil { bar.fontPopup.insertItem(withTitle: f, at: 0) }
            bar.fontPopup.selectItem(withTitle: f)
        } else { bar.fontPopup.selectItem(at: -1) }
        bar.sizeField.isEnabled = isTexty; bar.sizeStepper.isEnabled = isTexty
        bar.bigger.isEnabled = isTexty; bar.smaller.isEnabled = isTexty
        bar.sizeField.stringValue = isTexty ? String(format: "%g", (o?.fontSize ?? 0).rounded(toPlaces: 1)) : ""
        bar.sizeStepper.doubleValue = o?.fontSize ?? 30
        for c in bar.textControls { c.isEnabled = isTexty }
        for c in [bar.bold, bar.italic, bar.bullets, bar.numbers, bar.outdent, bar.indent, bar.alignLeft, bar.alignCenter,
                  bar.alignRight, bar.alignJustify, bar.spacing, bar.columns] as [NSControl] { c.isEnabled = isText }
        bar.superscript.isEnabled = isText && o?.textOk == true
        bar.subscriptButton.isEnabled = bar.superscript.isEnabled
        let mode = canvas.editingText != nil ? canvas.textScriptMode : (textField?.isEditing == true ? textField?.scriptMode : nil)
        bar.superscript.state = mode == true ? .on : .off
        bar.subscriptButton.state = mode == false ? .on : .off
        bar.bullets.isEnabled = isText && o?.textOk == true; bar.numbers.isEnabled = bar.bullets.isEnabled
        bar.outdent.isEnabled = bar.bullets.isEnabled; bar.indent.isEnabled = bar.bullets.isEnabled
        bar.colorButton.isEnabled = o != nil && o?.kind != "image"
        bar.setColor(NSColor(hex: o?.color ?? "#FFFFFF"))
        bar.bold.state = o?.weight?.uppercased() == "BOLD" ? .on : .off
        bar.italic.state = ["ITALIC", "OBLIQUE"].contains(o?.slant?.uppercased() ?? "") ? .on : .off
        let fmt = o?.format
        bar.underline.state = fmt?.underline == true ? .on : .off
        bar.strike.state = fmt?.strike == true ? .on : .off
        bar.highlight.contentTintColor = fmt?.highlight.map { $0.hasPrefix("#") ? NSColor(hex: $0) : NSColor.systemYellow }
        bar.bullets.state = isText && TextTransform.isBulleted(o?.value ?? "") ? .on : .off
        bar.numbers.state = isText && TextTransform.isNumbered(o?.value ?? "") ? .on : .off
        for (k, b) in bar.alignButtons { b.state = isText && (fmt?.align ?? "left") == k ? .on : .off }
        bar.grid.state = canvas.showGrid ? .on : .off
        bar.snap.state = canvas.snapEnabled ? .on : .off
        bar.guideV.isEnabled = sceneName != nil; bar.guideH.isEnabled = sceneName != nil
    }

    // MARK: text colour (the colour panel, driven from the bar's "A" control)

    /// The swatch grid under the "A" control: a row of greys and one of tints and shades per hue, plus the panel.
    @objc func colorButtonPressed(_ b: NSButton) {
        guard let o = objInfo, o.kind != "image" else { return }
        let m = NSMenu()
        let grid = ColorGridView(current: o.color) { [weak self] hex in
            guard let self = self else { return }
            self.formatBar.setColor(NSColor(hex: hex))
            self.commitColor(hex)
        }
        let holder = NSMenuItem(); holder.view = grid
        m.addItem(holder)
        m.addItem(.separator())
        let more = NSMenuItem(title: "More Colours…", action: #selector(openColorPanel), keyEquivalent: ""); more.target = self
        m.addItem(more)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    @objc func openColorPanel() {
        guard let o = objInfo, o.kind != "image" else { return }
        let panel = NSColorPanel.shared
        panel.setTarget(self); panel.setAction(#selector(colorPanelChanged(_:)))
        panel.color = NSColor(hex: o.color ?? "#FFFFFF")
        panel.isContinuous = true
        panel.orderFront(nil)
    }

    @objc func colorPanelChanged(_ panel: NSColorPanel) {
        guard objInfo != nil else { return }
        formatBar.setColor(panel.color)
        colorPanelWork?.cancel()
        let hex = panel.color.hexString
        let w = DispatchWorkItem { [weak self] in self?.commitColor(hex) }
        colorPanelWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)     // the panel streams while dragging
    }

    func commitColor(_ hex: String) {
        guard let s = selection, let o = objInfo, o.color?.uppercased() != hex.uppercased() else { return }
        submit { [weak self] in
            guard let self = self else { return }
            if o.kind == "text" || o.kind == "tex" { await self.previewSprite(s, kind: o.kind, value: o.value, size: o.fontSize ?? 30, color: hex, font: o.font, weight: o.weight, slant: o.slant) }
            await self.runEdit(["op": "color", "oid": s, "value": hex])
        }
    }

    // MARK: guides

    var guidesKey: String? { workspace.map { "guides:" + $0.original.path } }

    @objc func addVerticalGuide() { addGuide(vertical: true) }
    @objc func addHorizontalGuide() { addGuide(vertical: false) }
    func addGuide(vertical: Bool) {
        guard sceneName != nil else { return }
        let w = Double(canvas.frameSize.width), h = Double(canvas.frameSize.height)
        canvas.userGuides.append((vertical: vertical, pos: vertical ? w / 2 : h / 2))
        saveGuides()
        toast("Guide added at the centre: drag it into place, drag it off the slide to remove it")
    }
    @objc func clearGuides() { canvas.userGuides = []; saveGuides() }

    func saveGuides() {
        guard let key = guidesKey else { return }
        UserDefaults.standard.set(canvas.userGuides.map { [$0.vertical ? 1.0 : 0.0, $0.pos] }, forKey: key)
    }
    func loadGuides() {
        guard let key = guidesKey, let arr = UserDefaults.standard.array(forKey: key) as? [[Double]] else { canvas.userGuides = []; return }
        canvas.userGuides = arr.filter { $0.count == 2 }.map { (vertical: $0[0] > 0.5, pos: $0[1]) }
    }

    // MARK: character formatting

    @objc func underlineToggled(_ b: NSButton) { commitDecoration("underline", on: b.state == .on) }
    @objc func strikeToggled(_ b: NSButton) { commitDecoration("strike", on: b.state == .on) }
    @objc func formatUnderline() { commitDecoration("underline", on: objInfo?.format?.underline != true) }
    @objc func formatStrikethrough() { commitDecoration("strike", on: objInfo?.format?.strike != true) }

    func commitDecoration(_ kind: String, on: Bool) {
        guard let s = selection, let o = objInfo, o.kind == "text" || o.kind == "tex" else { return }
        submit { [weak self] in await self?.runEdit(["op": "decorate", "oid": s, "kind": kind, "on": on]) }
    }

    static let highlightSwatches: [(String, String?)] = [
        ("Yellow", "#FFD400"), ("Green", "#7CFC00"), ("Cyan", "#40E0FF"), ("Pink", "#FF6EC7"), ("Blue", "#4D7CFF"),
        ("Red", "#FF4040"), ("Orange", "#FF9A2E"), ("Gray", "#8A8A8A"), ("No Highlight", nil),
    ]

    func highlightMenu() -> NSMenu {
        let m = NSMenu()
        for (title, hex) in MainController.highlightSwatches {
            let mi = NSMenuItem(title: title, action: #selector(highlightChosen(_:)), keyEquivalent: "")
            mi.target = self; mi.representedObject = hex
            if let h = hex {
                let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
                    NSColor(hex: h).setFill(); NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill(); return true
                }
                mi.image = img
            }
            if (objInfo?.format?.highlight?.uppercased()) == hex?.uppercased() { mi.state = .on }
            m.addItem(mi)
        }
        return m
    }

    @objc func highlightPressed(_ b: NSButton) {
        guard objInfo != nil else { return }
        highlightMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    @objc func highlightChosen(_ m: NSMenuItem) {
        guard let s = selection, let o = objInfo, o.kind == "text" || o.kind == "tex" else { return }
        var req: [String: Any] = ["op": "highlight", "oid": s, "opacity": 0.6]
        if let hex = m.representedObject as? String { req["color"] = hex }
        submit { [weak self] in await self?.runEdit(req) }
    }

    @objc func clearFormatting() {
        guard let s = selection, let o = objInfo, o.kind == "text" || o.kind == "tex" else { return }
        submit { [weak self] in await self?.runEdit(["op": "clear_format", "oid": s]) }
    }

    @objc func formatSuperscript() { applyScript(superscript: true) }
    @objc func formatSubscript() { applyScript(superscript: false) }

    /// Unicode super/subscript (Manim's Text has no per-character rise, so the characters themselves are
    /// swapped). While typing: the selected characters are converted, or with nothing selected the characters
    /// typed next are, until pressed again. With the text object merely selected: its whole text.
    func applyScript(superscript: Bool) {
        let kind = superscript ? "superscript" : "subscript"
        guard let s = selection, let o = objInfo, o.kind == "text", o.textOk == true else {
            syncFormatBar(); toast("Select a text object first; \(kind) applies to its text", error: true); return
        }
        if canvas.editingText == s {
            if canvas.scriptSelection(superscript: superscript) { syncFormatBar(); return }
            let on = canvas.textScriptMode != superscript
            canvas.textScriptMode = on ? superscript : nil
            syncFormatBar()
            toast(on ? "Characters you type now are \(kind) · press again to stop" : "Back to normal characters")
            return
        }
        if let box = textField, box.isEditing {
            if box.scriptSelection(superscript: superscript) { syncFormatBar(); return }
            let on = box.scriptMode != superscript
            box.scriptMode = on ? superscript : nil
            syncFormatBar()
            toast(on ? "Characters you type now are \(kind) · press again to stop" : "Back to normal characters")
            return
        }
        let current = textField?.stringValue ?? o.value
        guard let converted = TextTransform.script(current, superscript: superscript) else {
            syncFormatBar(); toast("No \(kind) form exists for these characters", error: true); return
        }
        syncFormatBar()
        textField?.setText(converted)
        commitText(s, converted, shared: sharedChoice)
    }

    // MARK: paragraph formatting

    /// Apply a whole-string transform to the selected text (reads the text box so unsaved typing is kept).
    func transformText(_ f: (String, NSRange?) -> String) {
        guard let s = selection, let o = objInfo, o.kind == "text", o.textOk == true else {
            toast("Select a text object first", error: true); return
        }
        let current = textField?.stringValue ?? o.value
        let range = textField.flatMap { $0.selectedRange.length > 0 ? $0.selectedRange : nil }
        let new = f(current, range)
        guard new != current else { return }
        textField?.setText(new)
        commitText(s, new, shared: sharedChoice)
    }

    @objc func toggleBullets() { transformText { s, _ in TextTransform.toggleBullets(s) } }
    @objc func toggleNumbering() { transformText { s, _ in TextTransform.toggleNumbers(s) } }
    @objc func increaseIndent() { transformText { s, r in TextTransform.indent(s, lines: r.map { TextTransform.lineRange(s, $0) }, by: 4) } }
    @objc func decreaseIndent() { transformText { s, r in TextTransform.indent(s, lines: r.map { TextTransform.lineRange(s, $0) }, by: -4) } }

    @objc func alignLeft() { commitAlign("left") }
    @objc func alignCenter() { commitAlign("center") }
    @objc func alignRight() { commitAlign("right") }
    @objc func alignJustify() {
        syncFormatBar()
        toast("Manim cannot justify text with manual line breaks; use left, centre or right", error: true)
    }

    func commitAlign(_ value: String) {
        guard let s = selection, let o = objInfo, o.kind == "text" else { return }
        if !o.value.contains("\n") && o.frame == nil {
            syncFormatBar(); toast("Alignment shows on text with several lines (↵ in the text box adds one), or in a text box of a slide layout", error: true); return
        }
        submit { [weak self] in await self?.runEdit(["op": "align", "oid": s, "value": value]) }
    }

    @objc func spacingChosen(_ p: NSPopUpButton) {
        guard let s = selection, let o = objInfo, o.kind == "text" else { return }
        guard let item = p.selectedItem, p.indexOfSelectedItem > 0 else { return }
        var ppt: Double
        if let v = item.representedObject as? Double { ppt = v }
        else {
            let a = NSAlert(); a.messageText = "Line spacing"; a.informativeText = "Multiple of single spacing (1.0 = Manim's default):"
            let f = NSTextField(string: String(format: "%g", (o.format?.lineSpacing ?? 0.3) + 0.7)); f.frame = NSRect(x: 0, y: 0, width: 80, height: 24)
            a.accessoryView = f; a.addButton(withTitle: "Apply"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn, f.doubleValue > 0 else { return }
            ppt = f.doubleValue
        }
        // Manim's line_spacing is relative to the font size with 0.3 as "single"; PowerPoint's 1.0 is single.
        let manim = max(-0.6, ppt - 0.7)
        submit { [weak self] in await self?.runEdit(["op": "spacing", "oid": s, "value": manim]) }
    }

    @objc func spacingMenuChosen(_ m: NSMenuItem) {
        guard let s = selection, let o = objInfo, o.kind == "text" else { return }
        guard let v = m.representedObject as? Double else { spacingChosen(formatBar.spacing); return }
        submit { [weak self] in await self?.runEdit(["op": "spacing", "oid": s, "value": max(-0.6, v - 0.7)]) }
    }

    @objc func columnsChosen(_ p: NSPopUpButton) {
        guard let n = p.selectedItem?.representedObject as? Int, p.indexOfSelectedItem > 0 else { return }
        commitColumns(n)
    }
    @objc func columnsMenuChosen(_ m: NSMenuItem) { if let n = m.representedObject as? Int { commitColumns(n) } }

    func commitColumns(_ n: Int) {
        guard let s = selection, let o = objInfo, o.kind == "text" else { return }
        if n > 1 && !o.value.contains("\n") && (o.format?.columns ?? 1) == 1 {
            toast("Columns lay out the lines of a text; add lines with ↵ in the text box first", error: true); return
        }
        submit { [weak self] in await self?.runEdit(["op": "columns", "oid": s, "value": n]) }
    }

    // MARK: grid, snapping, drawing

    @objc func toggleGrid() {
        canvas.showGrid.toggle()
        UserDefaults.standard.set(canvas.showGrid, forKey: "showGrid")
        syncFormatBar()
    }
    @objc func toggleSnap() {
        canvas.snapEnabled.toggle()
        UserDefaults.standard.set(canvas.snapEnabled, forKey: "snapObjects")
        syncFormatBar()
        toast(canvas.snapEnabled ? "Snapping on: hold ⌥ to drag freely" : "Snapping off")
    }

    @objc func drawToolMenu(_ m: NSMenuItem) { setDrawTool(m.representedObject as? String) }

    func setDrawTool(_ kind: String?) {
        guard sceneName != nil else { return }
        canvas.drawTool = kind
        window.makeFirstResponder(canvas)
        if kind == "pen" {
            toast("Draw on the slide with the pen; every stroke is saved as a curve · esc when done")
        } else if let k = kind {
            let names = ["line": "line", "arrow": "arrow", "darrow": "double arrow", "rectangle": "rectangle", "ellipse": "ellipse"]
            toast("Drag on the slide to draw a \(names[k] ?? k) · esc to cancel")
        }
    }

    /// The canvas finished a rubber-band drag: insert the element with that geometry.
    func drawFinished(_ kind: String, _ sx: Double, _ sy: Double, _ ex: Double, _ ey: Double) {
        insert(kind: kind, extra: ["sx": sx, "sy": sy, "ex": ex, "ey": ey])
    }

    // MARK: headless check (MANIMBLE_TEST_FORMAT=deck)

    func formatTest() {
        let env = ProcessInfo.processInfo.environment
        let dir = (env["MANIMBLE_TEST_OUT"] ?? env["MANIMBLE_SELFTEST"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "format.log") }
        Task { @MainActor in
            await selectScene("Shapes")
            guard let (oid, _) = scene?.objects?.first(where: { $0.value.kind == "text" }).map({ (Int($0.key)!, $0.value) }) else { log("no text"); return }
            selection = oid
            log("bar: font=\(formatBar.fontPopup.titleOfSelectedItem ?? "-") size=\(formatBar.sizeField.stringValue) bold=\(formatBar.bold.state == .on) underline=\(formatBar.underline.state == .on)")
            commitDecoration("underline", on: true)
            await queueTail?.value
            try? await Task.sleep(nanoseconds: 300_000_000)
            selection = oid
            log("after underline: \(objInfo?.format.map { "u=\($0.underline ?? false) s=\($0.strike ?? false)" } ?? "-") toast=\(toastPill.label.stringValue)")
            highlightChosen({ let m = NSMenuItem(); m.representedObject = "#FFD400"; return m }())
            await queueTail?.value
            selection = oid
            log("after highlight: \(objInfo?.format?.highlight ?? "-") barTint=\(formatBar.highlight.contentTintColor?.hexString ?? "-")")
            commitDecoration("strike", on: true)
            await queueTail?.value
            selection = oid
            log("after strike: \(objInfo?.format.map { "u=\($0.underline ?? false) s=\($0.strike ?? false)" } ?? "-")")
            canvas.showGrid = true
            addVerticalGuide(); addHorizontalGuide()
            canvas.userGuides[0].pos = 300
            log("guides: \(canvas.userGuides.map { "\($0.vertical ? "v" : "h")@\(Int($0.pos))" })")
            drawFinished("arrow", 200, 600, 600, 680)
            await queueTail?.value
            try? await Task.sleep(nanoseconds: 500_000_000)
            log("objects after draw: \(scene?.objects?.values.map { $0.value }.sorted() ?? [])")
            if let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "format.png"))
            }
            if let img = canvas.snapshotView() {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "format-canvas.png"))
            }
            log("done")
        }
    }
}

extension Double {
    func rounded(toPlaces n: Int) -> Double { let k = pow(10.0, Double(n)); return (self * k).rounded() / k }
}

/// Each font family's menu item titled in that family (symbol fonts, which cannot spell their name, stay plain).
final class FontMenuStyler: NSObject, NSMenuDelegate {
    private var styled = false
    func menuWillOpen(_ menu: NSMenu) {
        guard !styled else { return }
        styled = true
        style(menu)
    }
    func style(_ menu: NSMenu) {
        for it in menu.items where it.attributedTitle == nil && !it.title.isEmpty {
            guard let f = NSFontManager.shared.font(withFamily: it.title, traits: [], weight: 5, size: 13) else { continue }
            let cs = f.coveredCharacterSet
            guard it.title.unicodeScalars.allSatisfy({ cs.contains($0) }) else { continue }
            it.attributedTitle = NSAttributedString(string: it.title, attributes: [.font: f])
        }
    }
}

/// A PowerPoint-style colour picker: a row of greys, then a row per hue running from its tints to its shades.
final class ColorGridView: NSView {
    static let rows: [[String]] = {
        func hsb(_ h: Double, _ s: Double, _ b: Double) -> String {
            NSColor(hue: CGFloat(h / 360), saturation: CGFloat(s), brightness: CGFloat(b), alpha: 1).hexString
        }
        func hueRow(_ h: Double) -> [String] {
            [0.12, 0.25, 0.4, 0.6, 0.8].map { hsb(h, $0, 1) } + [hsb(h, 1, 1)] + [0.85, 0.7, 0.55, 0.4].map { hsb(h, 1, $0) }
        }
        let greys = (0..<10).map { i -> String in let v = CGFloat(9 - i) / 9; return NSColor(white: v, alpha: 1).hexString }
        let browns = [(0.3, 0.95), (0.45, 0.86), (0.55, 0.77), (0.65, 0.68), (0.75, 0.6), (0.8, 0.5), (0.85, 0.42), (0.9, 0.34), (0.9, 0.27), (0.9, 0.2)]
            .map { hsb(28, $0.0, $0.1) }
        return [greys, hueRow(0), hueRow(30), hueRow(54), hueRow(120), hueRow(185), hueRow(220), hueRow(275), browns]
    }()
    private let cell: CGFloat = 20, gap: CGFloat = 3, inset: CGFloat = 8
    private let current: String?
    private let chosen: (String) -> Void
    private var hover: (Int, Int)?

    init(current: String?, chosen: @escaping (String) -> Void) {
        self.current = current?.uppercased(); self.chosen = chosen
        let cols = CGFloat(ColorGridView.rows[0].count), rows = CGFloat(ColorGridView.rows.count)
        super.init(frame: NSRect(x: 0, y: 0, width: inset * 2 + cols * cell + (cols - 1) * gap, height: inset * 2 + rows * cell + (rows - 1) * gap))
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rect(_ r: Int, _ c: Int) -> NSRect {
        NSRect(x: inset + CGFloat(c) * (cell + gap), y: bounds.height - inset - CGFloat(r + 1) * cell - CGFloat(r) * gap, width: cell, height: cell)
    }
    private func cellAt(_ p: NSPoint) -> (Int, Int)? {
        for (r, row) in ColorGridView.rows.enumerated() {
            for c in row.indices where rect(r, c).insetBy(dx: -gap / 2, dy: -gap / 2).contains(p) { return (r, c) }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        for (r, row) in ColorGridView.rows.enumerated() {
            for (c, hex) in row.enumerated() {
                let rc = rect(r, c)
                let path = NSBezierPath(roundedRect: rc, xRadius: 3, yRadius: 3)
                NSColor(hex: hex).setFill(); path.fill()
                NSColor.separatorColor.setStroke(); path.lineWidth = 0.5; path.stroke()
                if hover.map({ $0 == (r, c) }) == true || hex.uppercased() == current {
                    let ring = NSBezierPath(roundedRect: rc.insetBy(dx: -2, dy: -2), xRadius: 5, yRadius: 5)
                    (hex.uppercased() == current ? NSColor.labelColor : NSColor.controlAccentColor).setStroke()
                    ring.lineWidth = 2; ring.stroke()
                }
            }
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let h = cellAt(convert(event.locationInWindow, from: nil))
        if h?.0 != hover?.0 || h?.1 != hover?.1 { hover = h; needsDisplay = true }
        toolTip = h.map { ColorGridView.rows[$0.0][$0.1] }
    }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        guard let (r, c) = cellAt(convert(event.locationInWindow, from: nil)) else { return }
        let hex = ColorGridView.rows[r][c]
        enclosingMenuItem?.menu?.cancelTracking()
        chosen(hex)
    }
}

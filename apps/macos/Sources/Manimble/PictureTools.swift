import AppKit

/// A picture's border, aligning the selection to the slide, and the PowerPoint keys that go with them
/// (⌘D duplicate, Home / End, Tab between objects).
extension MainController {
    // MARK: picture border

    /// The inspector's Border row for a picture: a swatch of its border colour; a click opens the colour grid.
    func borderRow(_ o: ObjInfo) {
        let b = NSButton(title: o.border.map { $0.uppercased() } ?? "No Border", target: self, action: #selector(borderButtonPressed(_:)))
        b.bezelStyle = .rounded
        b.image = MainController.borderSwatch(o.border); b.imagePosition = .imageLeading
        b.toolTip = "A frame drawn around the picture, in this colour"
        inspector.addArrangedSubview(label("Border")); inspector.addArrangedSubview(b)
    }

    /// A small square of the border colour (a crossed-out square for no border).
    static func borderSwatch(_ hex: String?) -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 12), flipped: false) { r in
            let box = r.insetBy(dx: 1, dy: 1)
            if let h = hex { NSColor(hex: h).setFill(); NSBezierPath(rect: box).fill() }
            NSColor.separatorColor.setStroke()
            let p = NSBezierPath(rect: box); p.lineWidth = 1; p.stroke()
            if hex == nil {
                NSColor.systemRed.setStroke()
                let x = NSBezierPath(); x.move(to: NSPoint(x: box.minX, y: box.minY)); x.line(to: NSPoint(x: box.maxX, y: box.maxY))
                x.lineWidth = 1.2; x.stroke()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    @objc func borderButtonPressed(_ b: NSButton) {
        guard let o = objInfo, o.kind == "image" else { return }
        let m = NSMenu(); m.autoenablesItems = false
        let grid = ColorGridView(current: o.border) { [weak self] hex in self?.commitBorder(hex) }
        let holder = NSMenuItem(); holder.view = grid
        m.addItem(holder)
        m.addItem(.separator())
        let none = NSMenuItem(title: "No Border", action: #selector(removeBorder), keyEquivalent: ""); none.target = self
        none.isEnabled = o.border != nil
        m.addItem(none)
        let more = NSMenuItem(title: "More Colours…", action: #selector(openBorderColorPanel), keyEquivalent: ""); more.target = self
        m.addItem(more)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    @objc func removeBorder() { commitBorder(nil) }

    @objc func openBorderColorPanel() {
        guard let o = objInfo, o.kind == "image" else { return }
        let panel = NSColorPanel.shared
        panel.setTarget(self); panel.setAction(#selector(borderPanelChanged(_:)))
        panel.color = NSColor(hex: o.border ?? "#FFFFFF")
        panel.orderFront(nil)
    }

    @objc func borderPanelChanged(_ panel: NSColorPanel) {
        colorPanelWork?.cancel()                 // the panel sends a stream of colours while dragging: the last one is kept
        let hex = panel.color.hexString
        let w = DispatchWorkItem { [weak self] in self?.commitBorder(hex) }
        colorPanelWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    /// The selected pictures get a border in `hex` (nil removes it): `img.add(border(img, color=...))` in the slide.
    func commitBorder(_ hex: String?) {
        let ids = canvas.selectedIDs.filter { scene?.objects?[String($0)]?.kind == "image" }
        guard !ids.isEmpty else { return }
        let send = {
            for id in ids {
                var r: [String: Any] = ["op": "border", "oid": id]
                if let h = hex { r["color"] = h.uppercased() }
                let req = r
                self.submit { [weak self] in await self?.runEdit(req) }
            }
        }
        if ids.count > 1 { asOneUndoStep(hex == nil ? "remove border" : "border", send) } else { send() }
    }

    // MARK: align to the slide

    @objc func alignSlideLeft() { alignOnSlide("left") }
    @objc func alignSlideCenter() { alignOnSlide("hcenter") }
    @objc func alignSlideRight() { alignOnSlide("right") }
    @objc func alignSlideTop() { alignOnSlide("top") }
    @objc func alignSlideMiddle() { alignOnSlide("vcenter") }
    @objc func alignSlideBottom() { alignOnSlide("bottom") }
    @objc func alignOnSlidePressed(_ b: NSButton) { if let how = b.identifier?.rawValue { alignOnSlide(how) } }

    /// Arrange ▸ Align to Slide: the selection, as one block, to an edge or the middle of the slide (as PowerPoint's).
    func alignOnSlide(_ how: String) {
        let ids = canvas.selectedIDs
        let boxes = ids.compactMap { id in scene?.objects?[String(id)]?.frameBox ?? canvas.stop?.box(of: id) }
        guard let first = boxes.first else { return }
        let u = boxes.dropFirst().reduce(first) { Box(x0: min($0.x0, $1.x0), y0: min($0.y0, $1.y0), x1: max($0.x1, $1.x1), y1: max($0.y1, $1.y1)) }
        let fw = Double(canvas.frameSize.width), fh = Double(canvas.frameSize.height)
        var dx = 0.0, dy = 0.0
        switch how {
        case "left": dx = -u.x0
        case "hcenter": dx = fw / 2 - u.cx
        case "right": dx = fw - u.x1
        case "top": dy = -u.y0
        case "vcenter": dy = fh / 2 - u.cy
        case "bottom": dy = fh - u.y1
        default: return
        }
        if abs(dx) < 0.5 && abs(dy) < 0.5 { toast("Already there"); return }
        for id in ids { nudgeObject(id, dx, dy) }        // previewed at once; one undo step for the lot
    }

    static let alignSlideItems: [(title: String, action: Selector)] = [
        ("Align Left", #selector(alignSlideLeft)), ("Align Center", #selector(alignSlideCenter)),
        ("Align Right", #selector(alignSlideRight)), ("Align Top", #selector(alignSlideTop)),
        ("Align Middle", #selector(alignSlideMiddle)), ("Align Bottom", #selector(alignSlideBottom)),
    ]

    /// The Align to Slide submenu, for the menu bar and the object's right-click menu.
    static func alignSlideMenuItem(target: AnyObject?) -> NSMenuItem {
        let m = NSMenu(title: "Align to Slide")
        for (i, a) in alignSlideItems.enumerated() {
            if i == 3 { m.addItem(.separator()) }
            let it = NSMenuItem(title: a.title, action: a.action, keyEquivalent: ""); it.target = target
            m.addItem(it)
        }
        let item = NSMenuItem(title: "Align to Slide", action: nil, keyEquivalent: ""); item.submenu = m
        return item
    }

    /// The inspector's "On slide" buttons: left, centre, right; top, middle, bottom.
    func alignOnSlideRow() {
        func button(_ symbol: String, _ how: String, _ tip: String) -> NSButton {
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
            let b = NSButton(image: img, target: self, action: #selector(alignOnSlidePressed(_:)))
            b.bezelStyle = .texturedRounded; b.identifier = NSUserInterfaceItemIdentifier(how); b.toolTip = tip
            b.widthAnchor.constraint(equalToConstant: 30).isActive = true
            return b
        }
        let h = NSStackView(views: [button("align.horizontal.left", "left", "Align to the slide's left edge"),
                                    button("align.horizontal.center", "hcenter", "Center across the slide"),
                                    button("align.horizontal.right", "right", "Align to the slide's right edge")])
        let v = NSStackView(views: [button("align.vertical.top", "top", "Align to the slide's top edge"),
                                    button("align.vertical.center", "vcenter", "Center down the slide"),
                                    button("align.vertical.bottom", "bottom", "Align to the slide's bottom edge")])
        h.spacing = 2; v.spacing = 2
        let row = NSStackView(views: [h, v]); row.spacing = 12
        inspector.addArrangedSubview(label("On slide")); inspector.addArrangedSubview(row)
    }

    // MARK: PowerPoint keys

    /// Edit ▸ Duplicate (⌘D): a copy of the selected objects a little below and right of them, leaving the clipboard
    /// alone; with nothing selected, the slide (as PowerPoint does).
    @objc func duplicatePressed() {
        guard !canvas.selectedIDs.isEmpty, let ws = workspace else { duplicateSlide(); return }
        let pb = NSPasteboard(name: NSPasteboard.Name("org.manimble.duplicate"))
        copySelection(to: pb) { [weak self] in
            guard let self = self, let d = pb.data(forType: CopiedObjects.type),
                  let c = try? JSONDecoder().decode(CopiedObjects.self, from: d) else { return }
            self.pasteObjects(c, into: ws)
        }
    }

    /// Slide ▸ First Slide / Last Slide (Home / End on the slide or in the navigator).
    @objc func firstSlide() { jumpToSlide(first: true) }
    @objc func lastSlide() { jumpToSlide(first: false) }
    func jumpToSlide(first: Bool) {
        guard let st = state, let target = first ? st.scenes.first : st.scenes.last, target.name != sceneName else { return }
        Task { @MainActor in await selectScene(target.name) }
    }

    /// Tab / ⇧Tab on the slide: the next / previous object of the build on screen, with its group (as in PowerPoint).
    func selectNextObject(_ d: Int) {
        guard let stop = canvas.stop else { return }
        var order: [Int] = []
        for v in stop.visible where !order.contains(Int(v[0])) { order.append(Int(v[0])) }
        guard !order.isEmpty else { return }
        let at = canvas.selectedIDs.compactMap { order.firstIndex(of: $0) }
        let next = at.isEmpty ? (d > 0 ? 0 : order.count - 1)
                              : (((d > 0 ? at.max()! : at.min()!) + d) % order.count + order.count) % order.count
        canvas.selectWithGroup(order[next])
    }
}

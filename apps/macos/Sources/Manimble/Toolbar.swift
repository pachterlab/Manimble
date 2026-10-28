import AppKit
import PDFKit
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let newSlide = NSToolbarItem.Identifier("newSlide")
    static let newBuild = NSToolbarItem.Identifier("newBuild")
    static let expandAll = NSToolbarItem.Identifier("expandAll")
    static let insText = NSToolbarItem.Identifier("insText")
    static let insFormula = NSToolbarItem.Identifier("insFormula")
    static let insShape = NSToolbarItem.Identifier("insShape")
    static let insTable = NSToolbarItem.Identifier("insTable")
    static let insImage = NSToolbarItem.Identifier("insImage")
    static let theme = NSToolbarItem.Identifier("theme")
    static let insPlot = NSToolbarItem.Identifier("insPlot")
    static let insBioCartoon = NSToolbarItem.Identifier("insBioCartoon")
    static let zoom = NSToolbarItem.Identifier("zoom")
    static let share = NSToolbarItem.Identifier("share")
    static let terminal = NSToolbarItem.Identifier("terminal")
    static let dark = NSToolbarItem.Identifier("dark")
}

private let zoomLevels: [(String, CGFloat?)] = [
    ("Fit", nil), ("25%", 0.25), ("50%", 0.5), ("75%", 0.75), ("100%", 1.0), ("150%", 1.5), ("200%", 2.0), ("300%", 3.0),
]

extension MainController: NSToolbarDelegate {
    func makeToolbar() -> NSToolbar {
        let t = NSToolbar(identifier: "manimble.toolbar")
        t.delegate = self
        t.displayMode = .iconAndLabel
        t.allowsUserCustomization = false
        return t
    }

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.newSlide, .newBuild, .expandAll, .space, .insTable, .insText, .insFormula, .insShape, .insBioCartoon, .insImage, .theme, .insPlot, .flexibleSpace, .zoom, .dark, .space, .terminal, .share]
    }
    /// The Expand All button says what a click does: expand every slide's builds, or collapse them again.
    func styleExpandAllItem(_ i: NSToolbarItem) {
        let label = buildsExpandedAll ? "Collapse All" : "Expand All"
        i.label = label
        i.toolTip = buildsExpandedAll ? "Fold away the builds listed under every slide" : "List the builds under every slide in the navigator"
        i.image = NSImage(systemSymbolName: buildsExpandedAll ? "rectangle.compress.vertical" : "rectangle.expand.vertical", accessibilityDescription: label)
    }
    func updateExpandAllItem() {
        if let i = window.toolbar?.items.first(where: { $0.itemIdentifier == .expandAll }) { styleExpandAllItem(i) }
    }

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(t) }

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        func symbol(_ name: String, _ desc: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: desc) }
        func button(_ id: NSToolbarItem.Identifier, _ label: String, _ sym: String, _ sel: Selector) -> NSToolbarItem {
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = label; i.paletteLabel = label; i.toolTip = "Insert " + label.lowercased()
            i.image = symbol(sym, label); i.target = self; i.action = sel
            return i
        }
        switch id {
        case .terminal:
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Terminal"; i.paletteLabel = "Terminal"; i.toolTip = "Show or hide the terminal (⌥⌘T)"
            i.image = symbol("terminal", "Terminal"); i.target = self; i.action = #selector(toggleTerminal)
            return i
        case .dark:
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Dark Mode"; i.paletteLabel = "Dark Mode"
            i.toolTip = "Show slides with whites and blacks swapped (view only; Format ▸ Apply Dark Mode to Deck writes it)"
            i.image = symbol(DarkMode.mode == .dark ? "moon.fill" : "moon", "Dark Mode"); i.target = self; i.action = #selector(toggleDarkMode)
            return i
        case .newSlide:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.label = "New Slide"; i.paletteLabel = "New Slide"; i.toolTip = "Add a slide after this one (choose a layout)"
            i.image = symbol("plus.rectangle.on.rectangle", "New Slide"); i.showsIndicator = true
            i.target = self; i.action = #selector(newSlide)
            let m = NSMenu()
            for (title, layout, _) in MainController.slideLayouts {
                let mi = NSMenuItem(title: title, action: #selector(newSlideLayout(_:)), keyEquivalent: "")
                mi.representedObject = layout; mi.target = self
                mi.image = MainController.layoutIcon(layout)
                m.addItem(mi)
            }
            i.menu = m
            return i
        case .newBuild:
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "New Build"; i.paletteLabel = "New Build"; i.toolTip = "Add a build after this one, starting from what it shows"
            i.image = symbol("square.stack.3d.up.badge.automatic", "New Build") ?? symbol("square.stack.3d.up", "New Build")
            i.target = self; i.action = #selector(newBuild)
            return i
        case .expandAll:
            let i = NSToolbarItem(itemIdentifier: id)
            i.paletteLabel = "Expand All"; i.target = self; i.action = #selector(toggleExpandAllBuilds)
            styleExpandAllItem(i)
            return i
        case .insTable:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.label = "Table"; i.paletteLabel = "Table"; i.toolTip = "Insert a word table (click) or choose word / math"
            i.image = symbol("tablecells", "Table"); i.showsIndicator = true
            i.target = self; i.action = #selector(insertTablePressed(_:))
            let m = NSMenu()
            for (title, style, sym, tip) in [("Word Table", "word", "tablecells", "Plain text cells (Table)"),
                                             ("Math Table", "math", "function", "LaTeX cells (MathTable)")] {
                let mi = NSMenuItem(title: title, action: #selector(insertTablePressed(_:)), keyEquivalent: "")
                mi.representedObject = style; mi.target = self; mi.image = symbol(sym, title); mi.toolTip = tip
                m.addItem(mi)
            }
            i.menu = m
            return i
        case .insText: return button(id, "Text", "textformat", #selector(insertTextPressed))
        case .insFormula: return button(id, "Formula", "function", #selector(insertFormulaPressed))
        case .insImage: return button(id, "Image", "photo", #selector(insertImagePressed))
        case .theme:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.label = "Theme"; i.paletteLabel = "Theme"; i.toolTip = "Switch the deck to another theme (font, colours, background)"
            i.image = symbol("swatchpalette", "Theme") ?? symbol("paintbrush", "Theme"); i.showsIndicator = true
            i.menu = DeckTheme.menu(target: self)
            return i
        case .insPlot:
            let i = button(id, "Python Plot", "chart.xyaxis.line", #selector(insertPythonPlotPressed))
            i.toolTip = "Insert a picture drawn by Python code (or a .py file); hover it and press ▶ to run the code again"
            return i
        case .insBioCartoon:
            let i = button(id, "BioCartoon", "paintpalette", #selector(showBioCartoon))
            i.toolTip = "Search BioCartoon's science icons and drag them onto the slide"
            let logo = BioCartoonCLI.logo.copy() as! NSImage
            logo.size = NSSize(width: 22, height: 22)
            i.image = logo
            return i
        case .insShape:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.label = "Shape"; i.paletteLabel = "Shape"; i.toolTip = "Insert shape"
            i.image = symbol("square.on.circle", "Shape"); i.showsIndicator = true
            let m = NSMenu()
            for (title, kind, sym) in [("Rectangle", "rectangle", "rectangle"), ("Rounded Rectangle", "rounded", "rectangle.roundedtop"),
                                       ("Circle", "circle", "circle"), ("Ellipse", "ellipse", "oval"), ("Triangle", "triangle", "triangle"),
                                       ("Line", "line", "line.diagonal"), ("Arrow", "arrow", "arrow.right"),
                                       ("Double Arrow", "darrow", "arrow.left.and.right")] {
                let mi = NSMenuItem(title: title, action: #selector(insertShapePressed(_:)), keyEquivalent: "")
                mi.representedObject = kind; mi.target = self; mi.image = symbol(sym, title)
                m.addItem(mi)
            }
            m.addItem(.separator())
            for (title, kind, sym) in [("Draw Line", "line", "pencil.line"), ("Draw Arrow", "arrow", "arrow.up.right"),
                                       ("Draw Double Arrow", "darrow", "arrow.left.and.right"), ("Draw Rectangle", "rectangle", "rectangle.dashed"),
                                       ("Draw Ellipse", "ellipse", "oval")] {
                let mi = NSMenuItem(title: title, action: #selector(drawToolMenu(_:)), keyEquivalent: "")
                mi.representedObject = kind; mi.target = self; mi.image = symbol(sym, title)
                mi.toolTip = "Then drag on the slide (⇧ snaps the angle or keeps it square)"
                m.addItem(mi)
            }
            m.addItem(.separator())
            let pen = NSMenuItem(title: "Pen (freehand)", action: #selector(drawToolMenu(_:)), keyEquivalent: "")
            pen.representedObject = "pen"; pen.target = self; pen.image = symbol("pencil.tip", "Pen")
            pen.toolTip = "Draw freehand on the slide (⇧⌘P); each stroke becomes a smooth curve in the source. Esc ends the pen."
            m.addItem(pen)
            let colors = NSMenu()
            for (title, hex) in MainController.penSwatches {
                let mi = NSMenuItem(title: title, action: #selector(penColorChosen(_:)), keyEquivalent: "")
                mi.representedObject = hex; mi.target = self
                mi.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
                    NSColor(hex: hex).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 2, dy: 2)).fill(); return true
                }
                colors.addItem(mi)
            }
            let colorItem = NSMenuItem(title: "Pen Color", action: nil, keyEquivalent: ""); colorItem.submenu = colors
            m.addItem(colorItem)
            i.menu = m
            return i
        case .zoom:
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Zoom"; i.paletteLabel = "Zoom"
            let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 84, height: 26), pullsDown: false)
            pop.addItems(withTitles: zoomLevels.map { $0.0 })
            pop.target = self; pop.action = #selector(zoomChosen(_:))
            zoomPopup = pop
            i.view = pop
            return i
        case .share:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.label = "Share"; i.paletteLabel = "Share"; i.toolTip = "Share the presentation"
            i.image = symbol("square.and.arrow.up", "Share"); i.showsIndicator = false
            let m = NSMenu()
            func add(_ title: String, _ sel: Selector, _ tag: Int = 0) {
                let mi = NSMenuItem(title: title, action: sel, keyEquivalent: ""); mi.target = self; mi.tag = tag; m.addItem(mi)
            }
            add("Share PDF (one page per slide)…", #selector(shareChosen(_:)), 0)
            add("Share PDF (every build)…", #selector(shareChosen(_:)), 1)
            m.addItem(.separator())
            add("Export PowerPoint (.pptx)…", #selector(exportPowerPoint))
            add("Export Keynote (.key)…", #selector(exportKeynote))
            add("Export Beamer (.tex)…", #selector(exportBeamer))
            add("Export Movie (.mp4)…", #selector(exportMovie))
            m.addItem(.separator())
            add("Save PDF…", #selector(shareChosen(_:)), 3)
            i.menu = m
            return i
        default: return nil
        }
    }

    // MARK: zoom

    @objc func zoomChosen(_ p: NSPopUpButton) { canvas.zoom = zoomLevels[p.indexOfSelectedItem].1 }
    @objc func zoomIn() { canvas.zoomBy(1.25) }
    @objc func zoomOut() { canvas.zoomBy(0.8) }
    @objc func zoomFit() { canvas.zoom = nil }

    func syncZoomPopup() {
        guard let pop = zoomPopup else { return }
        if let z = canvas.zoom {
            let pct = Int((z * 100).rounded())
            let title = "\(pct)%"
            if pop.itemTitles.contains(title) { pop.selectItem(withTitle: title) }
            else { if pop.itemTitles.count > zoomLevels.count { pop.removeItem(at: zoomLevels.count) }; pop.addItem(withTitle: title); pop.selectItem(withTitle: title) }
        } else {
            if pop.itemTitles.count > zoomLevels.count { pop.removeItem(at: zoomLevels.count) }
            pop.selectItem(at: 0)
            pop.item(at: 0)?.title = "Fit (\(Int((canvas.fitScale * 100).rounded()))%)"
        }
    }

    // MARK: insert

    @objc func insertTextPressed() { insert(kind: "text") }
    @objc func insertFormulaPressed() {
        guard sceneName != nil else { return }
        // ask for the LaTeX first, so the formula is inserted once with its final content
        let sheet = LatexSheet(initial: "x^2 + y^2 = z^2", shared: nil,
                               render: { [weak self] tex in
                                   guard let self = self else { return (nil, "no engine") }
                                   do {
                                       let r = try await self.engine.call("sprite", ["kind": "tex", "value": tex, "font_size": 40.0, "color": "#FFFFFF"], as: SpriteResult.self)
                                       return (r.path, r.error)
                                   } catch { return (nil, "\(error)") }
                               },
                               apply: { [weak self] tex, _ in self?.insert(kind: "formula", extra: ["tex": tex]) })
        latexSheet = sheet
        window.beginSheet(sheet.window) { [weak self] _ in self?.latexSheet = nil }
    }
    @objc func insertShapePressed(_ m: NSMenuItem) { if let k = m.representedObject as? String { insert(kind: k) } }

    @objc func insertTablePressed(_ sender: Any?) {
        let style = ((sender as? NSMenuItem)?.representedObject as? String) ?? "word"
        let a = NSAlert(); a.messageText = style == "math" ? "Insert math table" : "Insert word table"; a.informativeText = "Rows and columns:"
        let rows = NSTextField(string: "3"), cols = NSTextField(string: "3")
        for f in [rows, cols] { f.widthAnchor.constraint(equalToConstant: 60).isActive = true }
        let stack = NSStackView(views: [NSTextField(labelWithString: "Rows"), rows, NSTextField(labelWithString: "Columns"), cols])
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        a.accessoryView = stack
        a.addButton(withTitle: "Insert"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        insert(kind: "table", extra: ["rows": max(1, rows.integerValue), "cols": max(1, cols.integerValue), "style": style])
    }

    @objc func insertImagePressed() {
        guard let ws = workspace else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .heic]
        p.message = "Choose an image to insert"
        guard p.runModal() == .OK, let u = p.url else { return }
        var name = u.lastPathComponent
        var dest = ws.work.appendingPathComponent(name)
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            name = u.deletingPathExtension().lastPathComponent + "_\(n)." + u.pathExtension
            dest = ws.work.appendingPathComponent(name); n += 1
        }
        do { try FileManager.default.copyItem(at: u, to: dest) } catch { alert("Could not copy the image", "\(error)"); return }
        insert(kind: "image", extra: ["file": name])
    }

    func insert(kind: String, extra: [String: Any] = [:]) {
        guard let scene = sceneName else { return }
        var req = extra; req["kind"] = kind; req["scene"] = scene
        // 1. show the element immediately (rasterised on its own, in parallel with the real insert)
        if kind != "pen" { Task { @MainActor in
            if let sp = try? await engine.call("insert_sprite", req, as: SpriteResult.self), let path = sp.path,
               let tex = canvas.texture(path: path), let w = sp.w, let h = sp.h, sceneName != nil, canvas.ghost == nil || true {
                canvas.ghost = (tex, Double(canvas.frameSize.width) / 2 + (sp.cx ?? 0), Double(canvas.frameSize.height) / 2 + (sp.cy ?? 0), w, h)
            }
        } }
        // 2. patch the source and re-render in the background
        submit { [weak self] in
            guard let self = self, let name = self.sceneName else { return }
            self.busy += 1
            var r2 = req; r2["scene"] = name; r2["stop"] = self.stopIndex
            let res = try? await self.engine.call("insert", r2, as: InsertResult.self)
            self.busy -= 1
            guard let r = res, r.ok == true else {
                self.canvas.ghost = nil
                if kind == "pen", !self.canvas.pendingStrokes.isEmpty { self.canvas.pendingStrokes.removeFirst() }
                self.toast(res?.error ?? "insert failed", error: true); return
            }
            self.lastChanged = ChangedLines(file: r.file, ranges: [[r.line ?? 1, r.line ?? 1]])
            await self.loadScene(name, keepStop: true)
            self.canvas.ghost = nil
            if kind == "pen", !self.canvas.pendingStrokes.isEmpty { self.canvas.pendingStrokes.removeFirst() }
            let target = "\(r.file ?? ""):\(r.line ?? 0)"
            if kind != "pen", let oid = self.scene?.objects?.first(where: { $0.value.loc == target })?.key, let id = Int(oid) {
                self.selection = id
                if kind == "text" { self.beginEdit(id) }
            }
            self.toast("Inserted \(kind)")
            await self.reloadState()
        }
    }

    func deleteSelected(_ oid: Int) {
        submit { [weak self] in
            guard let self = self else { return }
            await self.runEdit(["op": "delete", "oid": oid])
            self.selection = nil; self.canvas.selection = nil
        }
    }

    // MARK: tables

    func tableRows(_ json: String) -> [[String]] {
        guard let d = json.data(using: .utf8), let arr = try? JSONSerialization.jsonObject(with: d) as? [[Any]] else { return [] }
        return arr.map { $0.map { c in
            if let n = c as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { let v = n.doubleValue; return v == v.rounded() ? String(Int(v)) : String(v) }
            return "\(c)"
        } }
    }

    func tableEditor(_ o: ObjInfo, width: (NSView) -> Void) -> [NSView] {
        let sv = NSScrollView(); sv.hasHorizontalScroller = true; sv.hasVerticalScroller = true
        sv.autohidesScrollers = true; sv.borderType = .noBorder; sv.drawsBackground = false
        width(sv)
        tableGrid = sv
        layoutTableGrid(tableRows(o.value))
        func small(_ title: String, _ sel: Selector, _ tip: String) -> NSButton {
            let b = NSButton(title: title, target: self, action: sel); b.controlSize = .small; b.font = .systemFont(ofSize: 11); b.toolTip = tip
            return b
        }
        let edit = NSStackView(views: [small("+ Row", #selector(tableAddRow), "Add a row at the bottom"),
                                       small("− Row", #selector(tableRemoveRow), "Remove the bottom row"),
                                       small("+ Col", #selector(tableAddCol), "Add a column on the right"),
                                       small("− Col", #selector(tableRemoveCol), "Remove the right column")])
        edit.spacing = 4
        let apply = NSButton(title: "Apply Table", target: self, action: #selector(applyTable))
        let hint = NSTextField(labelWithString: "⇥ next cell  ·  ↵ apply")
        hint.font = Theme.font(10); hint.textColor = .tertiaryLabelColor
        return [label("Cells"), sv, edit, apply, hint]
    }

    /// The cells as currently typed (not yet applied).
    func tableDraft() -> [[String]] { tableCells.map { $0.map(\.stringValue) } }

    func layoutTableGrid(_ rows: [[String]]) {
        guard let sv = tableGrid else { return }
        let rows = rows.isEmpty ? [[""]] : rows
        let nc = max(1, rows.map(\.count).max() ?? 1)
        let gap: CGFloat = 4, h: CGFloat = 24, avail: CGFloat = 292
        let w = max(56, ((avail - gap * CGFloat(nc - 1)) / CGFloat(nc)).rounded(.down))
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: CGFloat(nc) * w + CGFloat(nc - 1) * gap,
                                            height: CGFloat(rows.count) * h + CGFloat(rows.count - 1) * gap))
        tableCells = rows.enumerated().map { i, row in
            (0..<nc).map { j in
                let f = NSTextField(string: j < row.count ? row[j] : "")
                f.frame = NSRect(x: CGFloat(j) * (w + gap), y: CGFloat(i) * (h + gap), width: w, height: h - 2)
                f.font = .systemFont(ofSize: 12); f.cell?.isScrollable = true; f.cell?.wraps = false
                f.target = self; f.action = #selector(applyTable); f.cell?.sendsActionOnEndEditing = false
                doc.addSubview(f)
                return f
            }
        }
        let flat = tableCells.flatMap { $0 }
        for (k, f) in flat.enumerated() { f.nextKeyView = flat[(k + 1) % flat.count] }
        sv.documentView = doc
        sv.constraints.filter { $0.firstAttribute == .height }.forEach { sv.removeConstraint($0) }
        let scrollbar: CGFloat = doc.frame.width > avail ? 14 : 0
        sv.heightAnchor.constraint(equalToConstant: min(doc.frame.height, 220) + scrollbar).isActive = true
    }

    func reshapeTable(_ change: (inout [[String]]) -> Void) {
        var rows = tableDraft()
        change(&rows)
        guard !rows.isEmpty, !(rows.first?.isEmpty ?? true) else { NSSound.beep(); return }
        layoutTableGrid(rows)
    }
    @objc func tableAddRow() { reshapeTable { $0.append(Array(repeating: "", count: $0.first?.count ?? 1)) } }
    @objc func tableRemoveRow() { reshapeTable { if $0.count > 1 { $0.removeLast() } } }
    @objc func tableAddCol() { reshapeTable { for i in $0.indices { $0[i].append("") } } }
    @objc func tableRemoveCol() { reshapeTable { for i in $0.indices where $0[i].count > 1 { $0[i].removeLast() } } }

    @objc func applyTable() {
        guard let s = selection, !tableCells.isEmpty else { return }
        let rows = tableDraft()
        submit { [weak self] in await self?.runEdit(["op": "table", "oid": s, "rows": rows]) }
    }

    /// Headless check of insert table -> type in cells -> add a row -> apply: MANIMBLE_TEST_TABLE=<deck>, MANIMBLE_TEST_OUT=<dir>
    func tableTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "table.log") }
        func shot(_ name: String) {
            guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
        }
        Task { @MainActor in
            insert(kind: "table", extra: ["rows": 2, "cols": 3, "style": ProcessInfo.processInfo.environment["MANIMBLE_TEST_TABLE_STYLE"] ?? "word"])
            await queueTail?.value
            try? await Task.sleep(nanoseconds: 500_000_000)
            log("selected: \(selection.map { scene?.objects?[String($0)]?.kind ?? "-" } ?? "none") cells=\(tableDraft())")
            // double-click the middle cell of the bottom row and type into it on the slide
            if let s = selection, let c = canvas.stop?.tableCells(s).first(where: { $0.row == 1 && $0.col == 1 }) {
                let r = canvas.slideRect, k = canvas.effectiveScale
                beginEdit(s, at: canvas.convert(CGPoint(x: r.minX + c.cell.cx * k, y: r.maxY - c.cell.cy * k), to: nil))
                log("editing cell: \(canvas.editingCell.map { "\($0.row),\($0.col)" } ?? "none")")
                if let tv = window.firstResponder as? NSTextView {
                    tv.insertText("Hello", replacementRange: tv.selectedRange())
                    log("inspector cell mirrors: \(tableDraft())")
                    if let img = canvas.snapshotView() { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "table-cell-typing.png")) }
                    shot("table-cell-typing-window.png")
                    tv.insertTab(nil)
                }
                await queueTail?.value
                try? await Task.sleep(nanoseconds: 500_000_000)
                log("after cell edit: \(scene?.objects?.values.filter { $0.kind == "table" }.map(\.value) ?? []) editing=\(canvas.editingText.map(String.init) ?? "none")")
                if let img = canvas.snapshotView() { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "table-cell-done.png")) }
            } else { log("no cell geometry") }
            if let s = selection { beginEdit(s, at: nil) }
            log("Return edits first cell: \(canvas.editingCell.map { "\($0.row),\($0.col)" } ?? "none")")
            canvas.finishTextEdit(commit: false)
            shot("table-1.png")
            tableAddRow()
            for (i, row) in tableCells.enumerated() { for (j, f) in row.enumerated() { f.stringValue = "r\(i)c\(j)" } }
            applyTable()
            await queueTail?.value
            try? await Task.sleep(nanoseconds: 500_000_000)
            log("after apply: \(scene?.objects?.values.filter { $0.kind == "table" }.map(\.value) ?? []) cells=\(tableDraft())")
            shot("table-2.png")
            NSApp.terminate(nil)
        }
    }

    // MARK: PowerPoint / Keynote import

    @objc func importPowerPoint() { runImport(label: "PowerPoint") }
    @objc func importKeynote() { runImport(label: "Keynote") }
    @objc func importBeamer() { runImport(label: "Beamer (LaTeX)") }

    func runImport(label: String) {
        let exts = label.hasPrefix("Beamer") ? ["tex", "ltx"] : ["ppt", "pptx", "key"]
        guard confirmClose(for: "importing a presentation") else { return }
        // Folders stay choosable so tagged folders show up under the sidebar's Tags; picking one
        // reopens the panel inside it instead of importing it.
        var src: URL?
        var start: URL?
        while src == nil {
            let open = NSOpenPanel()
            open.message = "Choose a \(label) presentation to import"
            open.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) } + [.folder]
            open.canChooseFiles = true; open.canChooseDirectories = true
            if let start { open.directoryURL = start }
            guard open.runModal() == .OK, let u = open.url else { return }
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir && !exts.contains(u.pathExtension.lowercased()) { start = u } else { src = u }
        }
        guard let src else { return }
        let save = NSSavePanel()
        save.message = "Where should the new Manim Slides deck be created? A folder with this name is made."
        save.nameFieldStringValue = src.deletingPathExtension().lastPathComponent
        save.prompt = "Create Deck"
        save.canCreateDirectories = true
        guard save.runModal() == .OK, let dest = save.url else { return }
        busyPill.show("Importing…", symbol: nil, tint: nil, spinning: true)
        Task { @MainActor in
            let r = try? await engine.call("import", ["src": src.path, "dest": dest.path], as: UndoResult.self)
            if r?.ok != true { busyPill.hide(); toast(r?.error ?? "could not start the import", error: true) }
        }
    }

    // MARK: PowerPoint / Keynote export

    @objc func exportPDFPressed() {
        Task { @MainActor in if let u = await makePDF(builds: false) { saveCopy(of: u) } }
    }
    @objc func exportPowerPoint() { runExport(kind: "pptx") }
    @objc func exportKeynote() { runExport(kind: "key") }
    @objc func exportBeamer() { runExport(kind: "beamer") }

    func runExport(kind: String) {
        guard let ws = workspace else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        let ext = ["pptx": "pptx", "beamer": "tex"][kind] ?? "key"
        panel.nameFieldStringValue = ws.original.deletingLastPathComponent().lastPathComponent == "slides"
            ? "presentation.\(ext)" : "\(ws.original.lastPathComponent).\(ext)"
        panel.message = ["pptx": "Export to PowerPoint", "beamer": "Export to Beamer (LaTeX; pictures go in a -figures folder beside it)"][kind]
            ?? "Export to Keynote (needs Keynote installed)"
        let builds = NSButton(checkboxWithTitle: "Every build as its own slide", target: nil, action: nil); builds.state = .on
        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.addItems(withTitles: [kind == "beamer" ? "Editable text and LaTeX formulas (recommended)" : "Editable text boxes (recommended)", "Pictures only (exact look)"])
        let box = NSStackView(views: [builds, mode]); box.orientation = .vertical; box.alignment = .leading; box.spacing = 8
        box.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = box
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != ext { url.appendPathExtension(ext) }
        busyPill.show("Exporting…", symbol: nil, tint: nil, spinning: true)
        let req: [String: Any] = ["kind": kind, "path": url.path, "builds": builds.state == .on, "editable": mode.indexOfSelectedItem == 0]
        Task { @MainActor in
            let r = try? await engine.call("export", req, as: UndoResult.self)
            if r?.ok != true { busyPill.hide(); toast(r?.error ?? "could not start the export", error: true) }
        }
    }

    // MARK: Movie (.mp4) export

    /// File ▸ Export To ▸ Movie: the animated show as one MP4 (every build plays, then holds its last frame), built and
    /// encoded by the engine (`export_movie`, progress by events). The Save panel asks which slides, the resolution,
    /// the hold and the frame rate.
    @objc func exportMovie() { runMovieExport(slide: nil) }

    /// The navigator's right-click "Export Slide as Movie…": the same Save panel, opened with that slide chosen.
    @objc func exportSlideMovie(_ m: NSMenuItem) {
        guard let name = m.representedObject as? String else { return }
        runMovieExport(slide: name)
    }

    /// The movie Save panel; `slide` names the slide the panel starts on (its "Current slide" choice), else the
    /// whole show is chosen.
    func runMovieExport(slide: String?) {
        guard let ws = workspace, let scenes = state?.scenes, !scenes.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        let deckName = ws.original.deletingLastPathComponent().lastPathComponent == "slides" ? "presentation" : ws.original.lastPathComponent
        panel.nameFieldStringValue = (slide.map { deckName + "_" + $0 } ?? deckName) + ".mp4"
        panel.message = slide.map { "Export slide \($0) as a movie" } ?? "Export the animated show as a movie"
        let options = MovieExportOptions(scenes: scenes, currentSlide: slide ?? sceneName, height: animationHeight)
        if slide != nil { options.chooseCurrentSlide() }
        panel.accessoryView = options.view
        panel.delegate = options
        guard panel.runModal() == .OK, var url = panel.url else { return }
        let names: [String]?                                 // nil: the whole show
        do { names = try options.selectedScenes() } catch { toast(error.localizedDescription, error: true); return }
        if url.pathExtension.lowercased() != "mp4" { url.appendPathExtension("mp4") }
        var req: [String: Any] = ["path": url.path, "height": options.height, "hold": options.holdSeconds, "fps": options.frameRate]
        if let names { req["scenes"] = names }
        busyPill.show("Exporting movie…", symbol: nil, tint: nil, spinning: true)
        Task { @MainActor in
            let r = try? await engine.call("export_movie", req, as: UndoResult.self)
            if r?.ok != true { busyPill.hide(); toast(r?.error ?? "could not start the movie export", error: true) }
        }
    }

    // MARK: share / export

    @objc func shareChosen(_ m: NSMenuItem) {
        Task { @MainActor in
            let url: URL?
            switch m.tag {
            case 0, 3: url = await makePDF(builds: false)
            case 1: url = await makePDF(builds: true)
            default: return
            }
            guard let u = url else { return }
            if m.tag == 3 { saveCopy(of: u) } else { showSharePicker(u) }
        }
    }

    func showSharePicker(_ u: URL) {
        let picker = NSSharingServicePicker(items: [u])
        guard let v = window.contentView else { return }
        picker.show(relativeTo: NSRect(x: v.bounds.maxX - 60, y: v.bounds.maxY - 2, width: 40, height: 2), of: v, preferredEdge: .minY)
    }

    func saveCopy(of u: URL) {
        let p = NSSavePanel(); p.nameFieldStringValue = u.lastPathComponent
        if p.runModal() == .OK, let dest = p.url {
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: u, to: dest); toast("Saved \(dest.lastPathComponent)") }
            catch { alert("Could not save", "\(error)") }
        }
    }

    func exportDir() -> URL {
        let u = Workspace.base.appendingPathComponent("export")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func makePDF(builds: Bool) async -> URL? {
        guard let ws = workspace else { return nil }
        busy += 1; busyText = "Exporting…"
        defer { busy -= 1; busyText = "Rendering…" }
        guard let r = try? await engine.call("pages", ["builds": builds], as: PagesResult.self), let pages = r.pages else {
            toast("Could not render all slides for export", error: true); return nil
        }
        let doc = PDFDocument()
        for (i, path) in pages.enumerated() {
            if let img = NSImage(contentsOfFile: path), let pg = PDFPage(image: img) { doc.insert(pg, at: i) }
        }
        let out = exportDir().appendingPathComponent(ws.original.deletingLastPathComponent().lastPathComponent == "slides" ? "presentation.pdf" : ws.original.lastPathComponent + ".pdf")
        doc.write(to: out)
        return out
    }

}

// MARK: - Movie export options

/// The Save panel's accessory view for File ▸ Export To ▸ Movie: which slides (all, the current one, or a list typed
/// as navigator numbers and slide names), the frame height the clips are built at, how long each build's last frame
/// is held, and the frame rate. As the panel's delegate it keeps the panel open while a typed slide list is wrong.
final class MovieExportOptions: NSObject, NSOpenSavePanelDelegate {
    static let heights = [720, 1080, 1440, 2160]
    static let rates = [24, 30, 60]

    let view: NSStackView
    private let scenes: [SceneSummary]
    private let currentSlide: String?
    private let which = NSPopUpButton(frame: .zero, pullsDown: false)
    private let list = NSTextField(string: "")
    private let resolution = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hold = NSTextField(string: "2")
    private let fps = NSPopUpButton(frame: .zero, pullsDown: false)

    init(scenes: [SceneSummary], currentSlide: String?, height: Int) {
        self.scenes = scenes
        self.currentSlide = currentSlide
        which.addItems(withTitles: ["All slides", "Current slide" + (currentSlide.map { " (\($0))" } ?? ""), "Some slides…"])
        which.autoenablesItems = false
        if currentSlide == nil { which.item(at: 1)?.isEnabled = false }
        list.placeholderString = "numbers or names, e.g. 1-3, 7, Summary"
        list.isEnabled = false
        list.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        resolution.addItems(withTitles: ["720p (1280 × 720)", "1080p (1920 × 1080)", "1440p (2560 × 1440)", "4K (3840 × 2160)"])
        resolution.selectItem(at: Self.heights.firstIndex(of: height) ?? 0)
        let f = NumberFormatter(); f.minimum = 0; f.maximum = 600; f.maximumFractionDigits = 2
        hold.formatter = f
        hold.alignment = .right
        hold.widthAnchor.constraint(equalToConstant: 56).isActive = true
        fps.addItems(withTitles: Self.rates.map { "\($0) fps" }); fps.selectItem(at: 1)
        let holdRow = NSStackView(views: [hold, NSTextField(labelWithString: "seconds on each build’s last frame")]); holdRow.spacing = 6
        func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }
        let grid = NSGridView(views: [[label("Slides:"), which], [NSView(), list], [label("Resolution:"), resolution],
                                      [label("Hold:"), holdRow], [label("Frame rate:"), fps]])
        grid.rowSpacing = 8; grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        let note = NSTextField(wrappingLabelWithString: "Every build plays once at its playback rate, hidden slides are left out, and there is no audio. Slides not yet built at this resolution are built first.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize); note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 380
        view = NSStackView(views: [grid, note]); view.orientation = .vertical; view.alignment = .leading; view.spacing = 10
        view.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        super.init()
        which.target = self; which.action = #selector(whichChanged)
    }

    @objc private func whichChanged() {
        list.isEnabled = which.indexOfSelectedItem == 2
        if list.isEnabled { list.window?.makeFirstResponder(list) }
    }

    /// Start the panel on the "Current slide" choice (a no-op when there is no current slide).
    func chooseCurrentSlide() {
        guard currentSlide != nil else { return }
        which.selectItem(at: 1); whichChanged()
    }

    var height: Int { Self.heights[max(0, resolution.indexOfSelectedItem)] }
    var frameRate: Int { Self.rates[max(0, fps.indexOfSelectedItem)] }
    /// Seconds each build's last frame is held; an emptied field means the default of two seconds.
    var holdSeconds: Double {
        let s = hold.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return s.isEmpty ? 2 : max(0, Double(s) ?? 2)
    }

    /// The slide names to export, or nil for the whole show (every slide that is not hidden). Throws, with a message
    /// the Save panel shows, when the typed list names slides the deck does not have or only hidden ones.
    func selectedScenes() throws -> [String]? {
        switch which.indexOfSelectedItem {
        case 1:
            guard let name = currentSlide else { throw Self.problem("There is no current slide.", "Choose another option.") }
            return [name]
        case 2:
            var picked = Set<Int>(), unknown: [String] = []
            for raw in list.stringValue.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }) {
                let tok = String(raw).trimmingCharacters(in: .whitespaces)
                if tok.isEmpty { continue }
                let ends = tok.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map { Int($0) }
                if ends.count == 2, let a = ends[0], let b = ends[1] {
                    let lo = max(1, min(a, b)), hi = min(scenes.count, max(a, b))
                    if lo > hi { unknown.append(tok) } else { picked.formUnion((lo - 1)...(hi - 1)) }
                } else if let n = Int(tok) {
                    if 1...max(1, scenes.count) ~= n, n <= scenes.count { picked.insert(n - 1) } else { unknown.append(tok) }
                } else if let i = scenes.firstIndex(where: { $0.name == tok })
                            ?? scenes.firstIndex(where: { $0.name.caseInsensitiveCompare(tok) == .orderedSame }) {
                    picked.insert(i)
                } else {
                    unknown.append(tok)
                }
            }
            if !unknown.isEmpty {
                throw Self.problem("No such slides: " + unknown.joined(separator: ", "),
                                   "Type the navigator’s numbers (1–\(scenes.count)), ranges like 2-5, or slide names, separated by commas.")
            }
            let names = picked.sorted().map { scenes[$0] }.filter { $0.hidden != true }.map(\.name)
            if names.isEmpty {
                throw Self.problem(picked.isEmpty ? "Type which slides to export." : "Only hidden slides were chosen.",
                                   picked.isEmpty ? "For example 1-3, 7 or Summary." : "Hidden slides are left out of exports; unhide them or choose others.")
            }
            return names
        default:
            return nil
        }
    }

    func panel(_ sender: Any, validate url: URL) throws {
        _ = try selectedScenes()
    }

    private static func problem(_ message: String, _ suggestion: String) -> NSError {
        NSError(domain: "Manimble", code: 1, userInfo: [NSLocalizedDescriptionKey: message, NSLocalizedRecoverySuggestionErrorKey: suggestion])
    }
}

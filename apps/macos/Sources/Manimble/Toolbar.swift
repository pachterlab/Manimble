import AppKit
import PDFKit
import UniformTypeIdentifiers

private extension NSToolbarItem.Identifier {
    static let insText = NSToolbarItem.Identifier("insText")
    static let insFormula = NSToolbarItem.Identifier("insFormula")
    static let insShape = NSToolbarItem.Identifier("insShape")
    static let insTable = NSToolbarItem.Identifier("insTable")
    static let insImage = NSToolbarItem.Identifier("insImage")
    static let zoom = NSToolbarItem.Identifier("zoom")
    static let share = NSToolbarItem.Identifier("share")
    static let terminal = NSToolbarItem.Identifier("terminal")
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
        [.insTable, .insText, .insFormula, .insShape, .insImage, .flexibleSpace, .zoom, .space, .terminal, .share]
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
        case .insTable: return button(id, "Table", "tablecells", #selector(insertTablePressed))
        case .insText: return button(id, "Text", "textformat", #selector(insertTextPressed))
        case .insFormula: return button(id, "Formula", "function", #selector(insertFormulaPressed))
        case .insImage: return button(id, "Image", "photo", #selector(insertImagePressed))
        case .insShape:
            let i = NSMenuToolbarItem(itemIdentifier: id)
            i.label = "Shape"; i.paletteLabel = "Shape"; i.toolTip = "Insert shape"
            i.image = symbol("square.on.circle", "Shape"); i.showsIndicator = true
            let m = NSMenu()
            for (title, kind, sym) in [("Rectangle", "rectangle", "rectangle"), ("Rounded Rectangle", "rounded", "rectangle.roundedtop"),
                                       ("Circle", "circle", "circle"), ("Triangle", "triangle", "triangle"),
                                       ("Line", "line", "line.diagonal"), ("Arrow", "arrow", "arrow.right")] {
                let mi = NSMenuItem(title: title, action: #selector(insertShapePressed(_:)), keyEquivalent: "")
                mi.representedObject = kind; mi.target = self; mi.image = symbol(sym, title)
                m.addItem(mi)
            }
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

    @objc func insertTablePressed() {
        let a = NSAlert(); a.messageText = "Insert table"; a.informativeText = "Rows and columns:"
        let rows = NSTextField(string: "3"), cols = NSTextField(string: "3")
        for f in [rows, cols] { f.widthAnchor.constraint(equalToConstant: 60).isActive = true }
        let stack = NSStackView(views: [NSTextField(labelWithString: "Rows"), rows, NSTextField(labelWithString: "Columns"), cols])
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        a.accessoryView = stack
        a.addButton(withTitle: "Insert"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        insert(kind: "table", extra: ["rows": max(1, rows.integerValue), "cols": max(1, cols.integerValue)])
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
        guard sceneName != nil else { return }
        var req = extra; req["kind"] = kind
        // 1. show the element immediately (rasterised on its own, in parallel with the real insert)
        Task { @MainActor in
            if let sp = try? await engine.call("insert_sprite", req, as: SpriteResult.self), let path = sp.path,
               let tex = canvas.texture(path: path), let w = sp.w, let h = sp.h, sceneName != nil, canvas.ghost == nil || true {
                canvas.ghost = (tex, Double(canvas.frameSize.width) / 2 + (sp.cx ?? 0), Double(canvas.frameSize.height) / 2 + (sp.cy ?? 0), w, h)
            }
        }
        // 2. patch the source and re-render in the background
        submit { [weak self] in
            guard let self = self, let name = self.sceneName else { return }
            self.busy += 1
            var r2 = req; r2["scene"] = name; r2["stop"] = self.stopIndex
            let res = try? await self.engine.call("insert", r2, as: InsertResult.self)
            self.busy -= 1
            guard let r = res, r.ok == true else {
                self.canvas.ghost = nil
                self.toast(res?.error ?? "insert failed", error: true); return
            }
            self.lastChanged = ChangedLines(file: r.file, ranges: [[r.line ?? 1, r.line ?? 1]])
            await self.loadScene(name, keepStop: true)
            self.canvas.ghost = nil
            let target = "\(r.file ?? ""):\(r.line ?? 0)"
            if let oid = self.scene?.objects?.first(where: { $0.value.loc == target })?.key, let id = Int(oid) {
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
        let tv = NSTextView()
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.string = tableRows(o.value).map { $0.joined(separator: ", ") }.joined(separator: "\n")
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false; tv.isAutomaticDashSubstitutionEnabled = false
        let sv = NSScrollView(); sv.documentView = tv; sv.hasVerticalScroller = true; sv.borderType = .bezelBorder
        width(sv); sv.heightAnchor.constraint(equalToConstant: 110).isActive = true
        tableText = tv
        let apply = NSButton(title: "Apply Table", target: self, action: #selector(applyTable))
        return [label("Cells (one row per line, comma-separated)"), sv, apply]
    }

    @objc func applyTable() {
        guard let s = selection, let tv = tableText else { return }
        let rows = tv.string.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) } }
        guard !rows.isEmpty else { return }
        submit { [weak self] in await self?.runEdit(["op": "table", "oid": s, "rows": rows]) }
    }

    // MARK: PowerPoint / Keynote import

    @objc func importPowerPoint() { runImport(exts: ["pptx"], label: "PowerPoint") }
    @objc func importKeynote() { runImport(exts: ["key"], label: "Keynote") }

    func runImport(exts: [String], label: String) {
        guard confirmClose(for: "importing a presentation") else { return }
        let open = NSOpenPanel()
        open.message = "Choose a \(label) presentation to import"
        open.allowedContentTypes = exts.compactMap { UTType(filenameExtension: $0) }
        open.canChooseFiles = true; open.canChooseDirectories = false
        guard open.runModal() == .OK, let src = open.url else { return }
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

    func runExport(kind: String) {
        guard let ws = workspace else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        let ext = kind == "pptx" ? "pptx" : "key"
        panel.nameFieldStringValue = ws.original.deletingLastPathComponent().lastPathComponent == "slides"
            ? "presentation.\(ext)" : "\(ws.original.lastPathComponent).\(ext)"
        panel.message = kind == "pptx" ? "Export to PowerPoint" : "Export to Keynote (needs Keynote installed)"
        let builds = NSButton(checkboxWithTitle: "Every build as its own slide", target: nil, action: nil); builds.state = .on
        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.addItems(withTitles: ["Editable text boxes (recommended)", "Pictures only (exact look)"])
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

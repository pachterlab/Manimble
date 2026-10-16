import AppKit

/// Slide-level tools: new-slide layouts, slide numbers, the speaker-notes pane, the pen, image element extraction
/// and the presenter view. Each one is an engine command (see docs/protocol.md) or a window of its own.
extension MainController {
    // MARK: new slide layouts

    /// (menu title, engine layout name, ⇧⌘ key)
    static let slideLayouts: [(String, String, String)] = [
        ("Title Slide", "title", ""), ("Title and Content", "title_content", "n"), ("Section Header", "section", ""),
        ("Two Content", "two_content", ""), ("Title Only", "title_only", ""), ("Blank", "blank", ""),
    ]
    static let layoutSymbols: [String: String] = [
        "title": "rectangle.center.inset.filled", "title_content": "rectangle.topthird.inset.filled",
        "section": "rectangle.lefthalf.inset.filled", "two_content": "rectangle.split.2x1",
        "title_only": "rectangle.tophalf.inset.filled", "blank": "rectangle",
    ]

    @objc func newSlideLayout(_ m: NSMenuItem) { slideOp("new", layout: m.representedObject as? String ?? "title_content") }

    // MARK: pen

    static let penSwatches: [(String, String)] = [
        ("Red", "#FF3B30"), ("Orange", "#FF9A2E"), ("Yellow", "#FFD400"), ("Green", "#34C759"), ("Blue", "#4D7CFF"),
        ("Purple", "#7C5CFF"), ("White", "#FFFFFF"), ("Black", "#000000"),
    ]

    @objc func penColorChosen(_ m: NSMenuItem) { if let hex = m.representedObject as? String { setPenColor(NSColor(hex: hex)) } }

    @objc func penColorPanel() {
        let panel = NSColorPanel.shared
        panel.setTarget(self); panel.setAction(#selector(penPanelChanged(_:)))
        panel.color = canvas.penColor
        panel.isContinuous = false
        panel.orderFront(nil)
    }
    @objc func penPanelChanged(_ panel: NSColorPanel) { setPenColor(panel.color) }

    func setPenColor(_ c: NSColor) {
        canvas.penColor = c
        UserDefaults.standard.set(c.hexString, forKey: "penColor")
        if canvas.drawTool != "pen" { setDrawTool("pen") } else { toast("Pen colour \(c.hexString)") }
    }

    /// A stroke was drawn with the pen: write it into the slide as a smooth curve.
    func penFinished(_ pts: [CGPoint]) {
        insert(kind: "pen", extra: ["points": pts.map { [Double($0.x), Double($0.y)] },
                                    "color": canvas.penColor.hexString, "width": canvas.penWidth])
    }

    // MARK: slide numbers

    @objc func slideNumbersPressed() {
        guard sceneName != nil else { return }
        Task { @MainActor in
            let info = try? await engine.call("page_numbers", ["op": "get"], as: PageNumberInfo.self)
            let a = NSAlert()
            a.messageText = "Slide numbers"
            a.informativeText = "Every slide of the show gets a number: a Text at the top of its construct(). The numbers follow along when slides are added, deleted or reordered."
            let positions = [("Bottom right", "DR"), ("Bottom centre", "DOWN"), ("Bottom left", "DL")]
            let pos = NSPopUpButton(frame: .zero, pullsDown: false)
            pos.addItems(withTitles: positions.map { $0.0 })
            pos.selectItem(at: positions.firstIndex(where: { $0.1 == (info?.pos ?? "DR") }) ?? 0)
            let start = NSTextField(string: String(info?.start ?? 1))
            let size = NSTextField(string: String(info?.size ?? 24))
            for f in [start, size] { f.widthAnchor.constraint(equalToConstant: 64).isActive = true }
            let skip = NSButton(checkboxWithTitle: "Don't show on the title slide", target: nil, action: nil)
            skip.state = (info?.skip ?? true) ? .on : .off
            let total = NSButton(checkboxWithTitle: "Show the total  (3 / 10)", target: nil, action: nil)
            total.state = (info?.total ?? true) ? .on : .off
            let grid = NSGridView(views: [[fieldLabel("Position"), pos], [fieldLabel("Start at"), start],
                                          [fieldLabel("Font size"), size], [NSView(), skip], [NSView(), total]])
            grid.rowSpacing = 7; grid.columnSpacing = 10
            grid.column(at: 0).xPlacement = .trailing
            grid.frame = NSRect(origin: .zero, size: NSSize(width: max(300, grid.fittingSize.width), height: grid.fittingSize.height))
            a.accessoryView = grid
            a.addButton(withTitle: info?.on == true ? "Update Numbers" : "Add Numbers")
            if info?.on == true { a.addButton(withTitle: "Remove Numbers") }
            a.addButton(withTitle: "Cancel")
            let r = a.runModal()
            if r == .alertFirstButtonReturn {
                runPageNumbers(["op": "set", "pos": positions[pos.indexOfSelectedItem].1, "start": start.integerValue,
                                "size": max(6, size.integerValue), "skip": skip.state == .on, "total": total.state == .on])
            } else if info?.on == true, r == .alertSecondButtonReturn {
                runPageNumbers(["op": "remove"])
            }
        }
    }

    func runPageNumbers(_ args: [String: Any]) {
        guard let name = sceneName else { return }
        submit { [weak self] in
            guard let self = self else { return }
            self.busy += 1
            var req = args; req["scene"] = name
            let r = try? await self.engine.call("page_numbers", req, as: EditResult.self)
            self.busy -= 1
            guard let res = r, res.ok == true else { self.toast(r?.error ?? "could not write the slide numbers", error: true); return }
            self.lastChanged = res.changed
            self.toast(res.message == "no change" ? "No change" : "Saved · \(res.message ?? "slide numbers")")
            await self.loadScene(name, keepStop: true)
            await self.reloadState()
        }
    }

    // MARK: speaker notes pane

    func buildNotesPane() {
        notesPane.wantsLayer = true
        notesPane.layer?.backgroundColor = Theme.canvasBottom.cgColor
        let head = NSTextField(labelWithString: "SPEAKER NOTES")
        head.font = Theme.font(10, .semibold); head.textColor = NSColor(white: 1, alpha: 0.45)
        let hint = NSTextField(labelWithString: "shown in Presenter View and by Manim Slides  ·  ⌘↵ or click away to save")
        hint.font = Theme.font(10); hint.textColor = NSColor(white: 1, alpha: 0.3)
        let minimize = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Hide speaker notes") ?? NSImage(),
                                target: self, action: #selector(hideNotesPane))
        minimize.isBordered = false; minimize.toolTip = "Hide speaker notes (⌥⌘K)"
        minimize.contentTintColor = NSColor(white: 1, alpha: 0.5)
        minimize.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let headRow = NSStackView(views: [head, hint, spacer, minimize]); headRow.spacing = 10
        notesBox.font = Theme.font(13)
        notesBox.textColor = NSColor(white: 0.92, alpha: 1)
        notesBox.editorBackground = NSColor(white: 1, alpha: 0.07)
        notesBox.borderType = .noBorder
        notesBox.wantsLayer = true; notesBox.layer?.cornerRadius = 6; notesBox.layer?.masksToBounds = true
        notesBox.onCommit = { [weak self] text in self?.commitNotes(text) }
        notesBox.fillsContainer = true                 // the pane's height comes from the divider above it
        let stack = NSStackView(views: [headRow, notesBox])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 8, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        notesPane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: notesPane.leadingAnchor), stack.trailingAnchor.constraint(equalTo: notesPane.trailingAnchor),
            stack.topAnchor.constraint(equalTo: notesPane.topAnchor), stack.bottomAnchor.constraint(equalTo: notesPane.bottomAnchor),
            notesBox.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            headRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        notesMinHeight = notesPane.heightAnchor.constraint(greaterThanOrEqualToConstant: 64)
        let on = UserDefaults.standard.object(forKey: "showNotes") as? Bool ?? true
        notesPane.isHidden = !on
        notesMinHeight?.isActive = on
        if on, UserDefaults.standard.object(forKey: "NSSplitView Subview Frames manimble.notes") == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let sp = self.notesSplit else { return }
                sp.setPosition(max(160, sp.bounds.height - 110), ofDividerAt: 0)
            }
        }
    }

    func setNotesVisible(_ on: Bool) {
        guard let sp = notesSplit else { return }
        let wasHidden = notesPane.isHidden
        notesPane.isHidden = !on
        notesMinHeight?.isActive = on
        sp.adjustSubviews()
        if on, wasHidden, notesPane.frame.height < 64 { sp.setPosition(max(160, sp.bounds.height - 110), ofDividerAt: 0) }
        UserDefaults.standard.set(on, forKey: "showNotes")
    }

    @objc func hideNotesPane() {
        if notesBox.isEditing { window.makeFirstResponder(canvas) }     // commits the notes first
        setNotesVisible(false)
    }

    @objc func toggleNotesPane() {
        setNotesVisible(notesPane.isHidden)
        if !notesPane.isHidden { notesBox.beginEditing() }
    }

    func commitNotes(_ text: String) {
        guard let name = sceneName else { return }
        submit { [weak self] in
            guard let self = self else { return }
            self.busy += 1
            let r = try? await self.engine.call("notes", ["op": "set", "scene": name, "text": text], as: NotesResult.self)
            self.busy -= 1
            guard let res = r, res.ok == true else { self.toast(r?.error ?? "could not save the notes", error: true); return }
            self.lastChanged = res.changed
            self.toast(res.message == "no change" ? "No change" : "Speaker notes saved")
            if self.sceneName == name { await self.loadScene(name, keepStop: true) }
            await self.reloadState()
        }
    }

    // MARK: extract elements from a picture

    @objc func extractElementsPressed() { Task { @MainActor in await extractElements(interactive: true) } }

    /// Split the selected picture into elements and insert them: interactively, in the Extract Elements sheet (boxes,
    /// Keep / Remove brushes, filled-in background); otherwise every element the model finds, background filled in.
    /// With the fill, the picture is pointed at a copy where what was behind the elements is painted in, so moving
    /// an element away leaves no duplicate behind.
    func extractElements(interactive: Bool) async {
        guard let sel = selection, let o = objInfo, o.kind == "image", let path = o.imagePath,
              let box = canvas.stop?.box(of: sel), let ws = workspace, let name = sceneName else {
            toast("Select a picture on the slide first", error: true); return
        }
        guard #available(macOS 14.0, *) else {
            alert("Extracting elements needs macOS 14 or later", "This feature uses the system's subject-lifting models, which arrived with macOS Sonoma.")
            return
        }
        busyText = "Finding the elements of \(o.image ?? "the picture")…"
        busy += 1
        let found = await Task.detached(priority: .userInitiated) { () -> Result<(CGImage, [[UInt8]]), Error> in
            do {
                let cg = try ImageExtractor.load(path: path)
                return .success((cg, try ImageExtractor.subjects(in: cg)))
            } catch { return .failure(error) }
        }.value
        busy -= 1; busyText = "Rendering…"
        let cg: CGImage, auto: [[UInt8]]
        switch found {
        case .failure(let e): alert("Could not analyse the picture", e.localizedDescription); return
        case .success(let v): (cg, auto) = v
        }
        var choice: ExtractEditor.Result
        if interactive {
            let editor = ExtractEditor(image: cg, masks: auto, source: o.image ?? "the picture")
            guard let r = await withCheckedContinuation({ (k: CheckedContinuation<ExtractEditor.Result?, Never>) in
                editor.run(on: window) { k.resume(returning: $0) }
            }) else { return }
            choice = r
        } else {
            guard !auto.isEmpty else { toast("No separate elements were found in this picture", error: true); return }
            choice = ExtractEditor.Result(masks: auto, fill: true, filled: nil)
        }
        guard sceneName == name else { return }
        busyText = choice.fill ? "Cutting out the elements and filling in the background…" : "Cutting out the elements…"
        busy += 1
        let masks = choice.masks, fill = choice.fill, preview = choice.filled
        let made = await Task.detached(priority: .userInitiated) { () -> ([ImageExtractor.Part], CGImage?) in
            let parts = masks.compactMap { ImageExtractor.cutOut(cg, mask: $0) }
            let bg = fill ? (preview ?? ImageFill.inpaint(cg, hole: ImageExtractor.hole(for: masks, w: cg.width, h: cg.height))) : nil
            return (parts, bg)
        }.value
        busy -= 1; busyText = "Rendering…"
        let (parts, filled) = made
        guard !parts.isEmpty else { toast("Nothing to extract", error: true); return }
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        func freeName(_ stem: String, _ k: inout Int) -> String {
            var file = "\(stem)\(k).png"
            while FileManager.default.fileExists(atPath: ws.work.appendingPathComponent(file).path) { k += 1; file = "\(stem)\(k).png" }
            k += 1
            return file
        }
        // with the fill, the picture shows its filled-in copy from its first build on, so the parts must arrive then too
        let firstShown = scene?.stops?.firstIndex { st in st.visible.contains { Int($0[0]) == sel } } ?? stopIndex
        var req: [String: Any] = ["scene": name, "stop": fill ? min(firstShown, stopIndex) : stopIndex]
        if fill {
            guard let bg = filled, let data = ImageExtractor.png(bg) else { alert("Could not fill in the background", "The picture has no area left to copy from."); return }
            var k = 1
            let file = freeName("\(base)_background", &k)
            do { try data.write(to: ws.work.appendingPathComponent(file)) } catch { alert("Could not save \(file)", "\(error)"); return }
            req["replace_image"] = ["oid": sel, "file": file]
        }
        var items: [[String: Any]] = []
        var k = 1
        for part in parts {
            let file = freeName("\(base)_part", &k)
            guard let data = ImageExtractor.png(part.image) else { continue }
            do { try data.write(to: ws.work.appendingPathComponent(file)) } catch { alert("Could not save \(file)", "\(error)"); return }
            // where the part sits in the picture -> where it sits on the slide (frame pixels)
            let kx = box.w / Double(cg.width), ky = box.h / Double(cg.height)
            items.append(["kind": "image", "file": file,
                          "sx": box.x0 + Double(part.box.minX) * kx, "sy": box.y0 + Double(part.box.minY) * ky,
                          "ex": box.x0 + Double(part.box.maxX) * kx, "ey": box.y0 + Double(part.box.maxY) * ky])
        }
        guard !items.isEmpty else { return }
        req["items"] = items
        submit { [weak self] in
            guard let self = self else { return }
            self.busy += 1
            let r = try? await self.engine.call("insert_many", req, as: EditResult.self)
            self.busy -= 1
            guard let res = r, res.ok == true else { self.toast(r?.error ?? "could not insert the elements", error: true); return }
            self.lastChanged = res.changed
            await self.loadScene(name, keepStop: true)
            await self.reloadState()
            let what = "\(items.count) element\(items.count == 1 ? "" : "s")"
            self.toast(fill ? "Inserted \(what) and filled in the picture behind them · ⌘Z undoes it all"
                            : "Inserted \(what) from the picture · ⌘Z undoes them all")
        }
    }

    // MARK: headless check (MANIMBLE_TEST_TOOLS=deck, MANIMBLE_TEST_OUT=dir)

    func toolsTest() {
        let env = ProcessInfo.processInfo.environment
        let dir = (env["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "tools.log") }
        func shot(_ w: NSWindow, _ name: String) {
            guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
        }
        func values() -> [String] { (scene?.objects?.values.map { $0.kind == "image" ? "image:" + ($0.image ?? "") : $0.value } ?? []).sorted() }
        Task { @MainActor in
            await selectScene("Formula")
            setNotesVisible(true)
            commitNotes("Explain Euler's identity.\nThen ask for questions.")
            await queueTail?.value
            log("notes: \(scene?.notes ?? "-") box=\(notesBox.stringValue.replacingOccurrences(of: "\n", with: "|"))")
            runPageNumbers(["op": "set", "pos": "DR", "start": 1, "size": 24, "skip": true, "total": true])
            await queueTail?.value
            log("numbers: \(values().filter { $0.contains("/") }) stops=\(scene?.stops?.count ?? -1)")
            slideOp("new", layout: "two_content")
            await queueTail?.value
            log("new slide: \(sceneName ?? "-") objects=\(values())")
            setDrawTool("pen")
            penFinished([CGPoint(x: 200, y: 500), CGPoint(x: 320, y: 430), CGPoint(x: 450, y: 520), CGPoint(x: 600, y: 440)])
            await queueTail?.value
            log("pen: \(values().filter { $0 == "Pen" }.count) pending=\(canvas.pendingStrokes.count) tool=\(canvas.drawTool ?? "-")")
            canvas.drawTool = nil
            if let ws = workspace, let pic = env["MANIMBLE_TEST_PICTURE"] {
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: pic), to: ws.work.appendingPathComponent("people.png"))
                insert(kind: "image", extra: ["file": "people.png"])
                await queueTail?.value
                if let img = scene?.objects?.first(where: { $0.value.image == "people.png" }), let id = Int(img.key) {
                    selection = id
                    await extractElements(interactive: false)
                    await queueTail?.value
                }
                log("extracted: \(values().filter { $0.hasPrefix("image:") })")
            }
            // hidden slides, resizable notes, terminal folder, one-file export
            await selectScene("Shapes")
            toggleHideSlide()
            await queueTail?.value
            log("hidden: \(state?.scenes.map { "\($0.name):\($0.hidden == true)" } ?? []) menu=\(navigatorMenu(row: 1)?.items.map { $0.title } ?? [])")
            let deck = try? await engine.call("deck_pages", as: DeckPages.self)
            log("deck_pages: \(deck?.slides.map { $0.scene } ?? [])")
            if let sp = notesSplit {
                let before = notesPane.frame.height
                sp.setPosition(sp.bounds.height - 200, ofDividerAt: 0); sp.layoutSubtreeIfNeeded()
                let dragged = notesPane.frame.height
                setNotesVisible(false); sp.layoutSubtreeIfNeeded()
                let hiddenH = notesPane.isHidden ? 0 : notesPane.frame.height
                setNotesVisible(true); sp.layoutSubtreeIfNeeded()
                log("notes pane: before=\(Int(before)) dragged=\(Int(dragged)) hidden=\(Int(hiddenH)) shown=\(Int(notesPane.frame.height)) stage=\(Int(stageArea.frame.height))")
            }
            if let ws = workspace { log("terminal dir: \(terminalDirectory(ws))") }
            let out = dir + "whole.py"
            let ex = try? await engine.call("export_python", ["path": out], as: EditResult.self)
            log("export: \(ex?.message ?? ex?.error ?? "-") exists=\(FileManager.default.fileExists(atPath: out))")
            await selectScene("NewSlide1")
            try? await Task.sleep(nanoseconds: 600_000_000)
            shot(window, "tools.png")
            presenterView()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let p = presenter {
                log("presenter: pages=\(p.source.pageCount) index=\(p.source.pageIndex) visibleAudience=\(p.source.window.isVisible)")
                p.source.next()
                try? await Task.sleep(nanoseconds: 500_000_000)
                shot(p.window, "presenter.png")
                p.source.exit()
            } else { log("presenter: none") }
            try? await Task.sleep(nanoseconds: 300_000_000)
            log("after exit: presenter=\(presenter == nil ? "nil" : "alive")")
            log("done")
        }
    }

    // MARK: navigator menu, hidden slides

    /// Right-click menu of the slide navigator (the row is already selected).
    func navigatorMenu(row: Int) -> NSMenu? {
        guard navigatorScenes.indices.contains(row), player == nil else { return nil }
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector, _ obj: Any? = nil) {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: ""); mi.target = self; mi.representedObject = obj; m.addItem(mi)
        }
        let layouts = NSMenu()
        for (title, layout, _) in MainController.slideLayouts {
            let mi = NSMenuItem(title: title, action: #selector(newSlideLayout(_:)), keyEquivalent: ""); mi.target = self; mi.representedObject = layout
            layouts.addItem(mi)
        }
        let newItem = NSMenuItem(title: "New Slide After This", action: nil, keyEquivalent: ""); newItem.submenu = layouts
        m.addItem(newItem)
        add("Duplicate Slide", #selector(duplicateSlide))
        m.addItem(.separator())
        if selectedSlideIsUnused { add("Restore Slide to Show", #selector(restoreSlide)) }
        else { add(selectedSlideIsHidden ? "Unhide Slide" : "Hide Slide", #selector(toggleHideSlide)) }
        m.addItem(.separator())
        add("Delete Slide", #selector(deleteSlide))
        return m
    }

    // MARK: terminal folder

    @objc func toggleTerminalInWorkCopy() {
        let now = !UserDefaults.standard.bool(forKey: "terminalInWorkCopy")
        UserDefaults.standard.set(now, forKey: "terminalInWorkCopy")
        if terminal.hasStarted, let ws = workspace { terminal.start(in: terminalDirectory(ws), original: ws.original.path) }
        toast(now ? "New terminals open in the working copy (what the slides show)" : "New terminals open in the project repository")
    }

    /// Where a terminal starts: the project repository of the original deck (its git root, else the deck's parent
    /// folder), or the working copy when View ▸ Terminal Starts in Working Copy is on.
    func terminalDirectory(_ ws: Workspace) -> String {
        if UserDefaults.standard.bool(forKey: "terminalInWorkCopy") { return ws.work.path }
        var dir = ws.original
        while true {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir.path }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || parent.path == "/" { break }
            dir = parent
        }
        return ws.original.deletingLastPathComponent().path
    }

    // MARK: export the deck as one Python file

    @objc func exportPythonPressed() {
        guard let ws = workspace else { return }
        let panel = NSSavePanel()
        panel.message = "Write the whole deck as one Python file (helper modules inlined, slides in show order). The deck's own .py files are already the editable source; this is a single-file copy."
        panel.nameFieldStringValue = ws.original.deletingLastPathComponent().lastPathComponent + "_deck.py"
        panel.directoryURL = ws.original
        panel.canCreateDirectories = true
        let hidden = NSButton(checkboxWithTitle: "Include hidden slides", target: nil, action: nil)
        hidden.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        panel.accessoryView = hidden
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != "py" { url.appendPathExtension("py") }
        Task { @MainActor in
            busy += 1
            let r = try? await engine.call("export_python", ["path": url.path, "hidden": hidden.state == .on], as: EditResult.self)
            busy -= 1
            guard let res = r, res.ok == true else { toast(r?.error ?? "could not write the Python file", error: true); return }
            toast("Exported \(res.message ?? url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: headless check (MANIMBLE_TEST_EXTRACT=deck, MANIMBLE_TEST_EXTRACT_SCENE, MANIMBLE_TEST_EXTRACT_BOXES="x,y,w,h;…",
    // MANIMBLE_TEST_OUT=dir)

    func extractTest() {
        let env = ProcessInfo.processInfo.environment
        let dir = (env["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "extract.log") }
        func shot(_ w: NSWindow, _ name: String) {
            guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
        }
        func images() -> [(Int, String)] {
            (scene?.objects ?? [:]).compactMap { k, o in o.kind == "image" ? (Int(k) ?? -1, o.image ?? "") : nil }.sorted { $0.0 < $1.0 }
        }
        Task { @MainActor in
            if let sc = env["MANIMBLE_TEST_EXTRACT_SCENE"] { await selectScene(sc) }
            if let n = scene?.stops?.count { stopIndex = n - 1; applyStop() }
            log("images before: \(images())")
            guard let (oid, _) = images().first, let o = scene?.objects?[String(oid)], let path = o.imagePath,
                  let cg = try? ImageExtractor.load(path: path) else { log("no picture"); log("done"); return }
            selection = oid
            // the sheet, with the model's elements plus the boxes asked for
            let auto = (try? ImageExtractor.subjects(in: cg)) ?? []
            let editor = ExtractEditor(image: cg, masks: env["MANIMBLE_TEST_EXTRACT_BOXES"] == nil ? auto : [], source: o.image ?? "")
            var result: ExtractEditor.Result?
            editor.run(on: window) { result = $0 }
            for b in (env["MANIMBLE_TEST_EXTRACT_BOXES"] ?? "").split(separator: ";") {
                let v = b.split(separator: ",").compactMap { Double($0) }
                if v.count == 4 { editor.addRegion(CGRect(x: v[0], y: v[1], width: v[2], height: v[3]), wholeBox: false) }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            log("sheet elements: \(editor.elements.count) bounds=\(editor.elements.map { $0.bounds.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))" } ?? "-" })")
            editor.window.contentView?.layoutSubtreeIfNeeded()
            shot(editor.window, "extract_sheet.png")
            editor.window.sheetParent?.endSheet(editor.window)
            _ = result
            // insert them with the background filled in, as Insert does
            let masks = editor.elements.map { $0.mask }
            let parts = masks.compactMap { ImageExtractor.cutOut(cg, mask: $0) }
            guard let bg = ImageFill.inpaint(cg, hole: ImageExtractor.hole(for: masks, w: cg.width, h: cg.height)),
                  let ws = workspace, let name = sceneName, let box = canvas.stop?.box(of: oid) else { log("fill failed"); log("done"); return }
            try? ImageExtractor.png(bg)?.write(to: ws.work.appendingPathComponent("test_background1.png"))
            var items: [[String: Any]] = []
            for (i, part) in parts.enumerated() {
                let file = "test_part\(i + 1).png"
                try? ImageExtractor.png(part.image)?.write(to: ws.work.appendingPathComponent(file))
                let kx = box.w / Double(cg.width), ky = box.h / Double(cg.height)
                items.append(["kind": "image", "file": file,
                              "sx": box.x0 + Double(part.box.minX) * kx, "sy": box.y0 + Double(part.box.minY) * ky,
                              "ex": box.x0 + Double(part.box.maxX) * kx, "ey": box.y0 + Double(part.box.maxY) * ky])
            }
            let firstShown = scene?.stops?.firstIndex { st in st.visible.contains { Int($0[0]) == oid } } ?? stopIndex
            let r = try? await engine.call("insert_many", ["scene": name, "stop": firstShown, "items": items,
                                                           "replace_image": ["oid": oid, "file": "test_background1.png"]], as: EditResult.self)
            log("insert: ok=\(r?.ok ?? false) \(r?.message ?? r?.error ?? "-")")
            await loadScene(name, keepStop: true)
            log("images after: \(images())")
            for i in 0..<(scene?.stops?.count ?? 0) {
                log("build \(i + 1) shows: \(scene?.stops?[i].visible.compactMap { scene?.objects?[String(Int($0[0]))]?.image } ?? [])")
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            shot(window, "extract_inserted.png")
            // move the first part away: the picture behind it is filled in
            if let (pid, _) = images().first(where: { $0.1 == "test_part1.png" }) {
                let m = try? await engine.call("edit", ["scene": name, "stop": stopIndex, "oid": pid, "op": "move", "dx": 120, "dy": 0], as: EditResult.self)
                log("move: ok=\(m?.ok ?? false) \(m?.message ?? m?.error ?? "-")")
                await loadScene(name, keepStop: true)
                selection = nil
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                shot(window, "extract_moved.png")
            }
            log("done")
        }
    }

    // MARK: presenter view

    @objc func presenterView() {
        guard player == nil, presenter == nil, animatedPlayer == nil else { return }
        closeAnimationPreview()
        Task { @MainActor in
            busyText = "Preparing presenter view…"
            busy += 1
            let deck = try? await engine.call("deck_pages", as: DeckPages.self)
            busy -= 1; busyText = "Rendering…"
            guard let d = deck else { toast("Could not prepare the slideshow", error: true); return }
            let broken = d.slides.filter { $0.error != nil }.map { $0.scene }
            let playable = d.slides.filter { $0.error == nil && !$0.pages.isEmpty }
            if !broken.isEmpty { toast("Skipping slides that fail to render: " + broken.joined(separator: ", "), error: true) }
            guard !playable.isEmpty else { return }
            var start = 0
            if let n = sceneName, let i = playable.firstIndex(where: { $0.scene == n }) { start = i }
            let here = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
            let other = NSScreen.screens.first { $0 != here }
            let p = PresenterController(slides: playable.map { $0.pages }, notes: playable.map { $0.notes ?? "" },
                                        startSlide: start, presenterScreen: here, audienceScreen: other)
            p.onExit = { [weak self] in self?.presenter = nil; self?.window.makeKeyAndOrderFront(nil) }
            presenter = p
            if other == nil { toast("One display: this is a rehearsal view. With a second display the audience sees the slides there.") }
        }
    }
}

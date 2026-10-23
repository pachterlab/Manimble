import AppKit

/// Slide-level tools: new-slide layouts, slide numbers, the speaker-notes pane, the pen, image element extraction
/// and the presenter view. Each one is an engine command (see docs/protocol.md) or a window of its own.
extension MainController {
    // MARK: new slide layouts

    /// (menu title, engine layout name, ⇧⌘ key)
    static let slideLayouts: [(String, String, String)] = [
        ("Title Slide", "title", ""), ("Title and Content", "title_content", "n"),
        ("Two Content", "two_content", ""), ("Title Only", "title_only", ""), ("Blank", "blank", ""),
    ]
    /// Each layout's text boxes on a 13.333 x 7.5 in slide (left, top, width, height in inches), as the engine writes them.
    static let layoutBoxes: [String: [(Double, Double, Double, Double)]] = [
        "title": [(1.667, 1.227, 10.0, 2.61), (1.667, 3.938, 10.0, 1.81)],
        "title_content": [(0.917, 0.399, 11.5, 1.45), (0.917, 1.996, 11.5, 4.76)],
        "two_content": [(0.917, 0.399, 11.5, 1.45), (0.917, 1.996, 5.667, 4.76), (6.75, 1.996, 5.667, 4.76)],
        "title_only": [(0.917, 0.399, 11.5, 1.45)],
        "blank": [],
    ]

    private static var iconCache: [String: NSImage] = [:]

    /// A miniature of the layout, as PowerPoint's layout gallery shows it: the slide's background with its dashed boxes.
    static func layoutIcon(_ layout: String, width: CGFloat = 44, background: NSColor = .white) -> NSImage {
        let bg = background.usingColorSpace(.sRGB) ?? .white
        let key = "\(layout)@\(Int(width)) \(bg.hexString)"
        if let img = iconCache[key] { return img }
        let light = 0.2126 * bg.redComponent + 0.7152 * bg.greenComponent + 0.0722 * bg.blueComponent > 0.5
        let size = NSSize(width: width, height: (width * 7.5 / 13.333).rounded())
        let img = NSImage(size: size, flipped: true) { r in
            let slide = r.insetBy(dx: 0.5, dy: 0.5)
            bg.setFill(); slide.fill()
            NSColor(white: light ? 0.55 : 0.45, alpha: 1).setStroke()
            let frame = NSBezierPath(rect: slide); frame.lineWidth = 1; frame.stroke()
            let k = slide.width / 13.333
            for (l, t, w, h) in layoutBoxes[layout] ?? [] {
                let box = NSRect(x: slide.minX + l * k, y: slide.minY + t * k, width: w * k, height: h * k)
                let p = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
                p.lineWidth = 0.8; p.setLineDash([1.6, 1.0], count: 2, phase: 0)
                NSColor(white: 0.6, alpha: 1).setStroke(); p.stroke()
            }
            return true
        }
        if iconCache.count > 40 { iconCache.removeAll() }
        iconCache[key] = img
        return img
    }

    @objc func newSlideLayout(_ m: NSMenuItem) { slideOp("new", layout: m.representedObject as? String ?? "title_content") }

    /// Headless check of new-slide layouts and typing into their placeholders: MANIMBLE_TEST_LAYOUTS=deck,
    /// output (layouts.log, layout-*.png, the menu icons) in MANIMBLE_TEST_OUT.
    /// Headless check of text frames, ⌘A, super/subscript and the editor's spacing: MANIMBLE_TEST_FRAME=deck,
    /// frame.log and shots in MANIMBLE_TEST_OUT.
    func frameTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "frame.log") }
        func shot(_ name: String) {
            guard let img = canvas.snapshotView() else { return }
            let out = NSImage(size: canvas.bounds.size)
            out.lockFocus()
            NSImage(cgImage: img, size: canvas.bounds.size).draw(in: canvas.bounds)
            for v in canvas.subviews where v is NSTextView {
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    NSImage(cgImage: rep.cgImage!, size: v.bounds.size).draw(in: v.frame)
                }
            }
            out.unlockFocus()
            if let t = out.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir + name + ".png"))
            }
        }
        func box(_ b: Box?) -> String { b.map { "\(Int($0.x0)),\(Int($0.y0)) \(Int($0.w))x\(Int($0.h))" } ?? "-" }
        func settle() async { await queueTail?.value; try? await Task.sleep(nanoseconds: 800_000_000) }
        Task { @MainActor in
            slideOp("new", layout: "title_content")
            await settle()
            guard let ph = canvas.placeholders.first(where: { $0.role == "body" }) else { log("no body placeholder"); return }
            canvas.onPlaceholder?(ph)
            guard let tv = window.firstResponder as? NSTextView else { log("placeholder editor not focused"); return }
            tv.insertText("Hello world", replacementRange: tv.selectedRange())
            window.makeFirstResponder(canvas)
            await settle()
            guard let (oid, o) = scene?.objects?.first(where: { $0.value.kind == "text" }).map({ (Int($0.key)!, $0.value) }) else { log("no text"); return }
            log("text \(oid) '\(o.value)' frame=\(box(o.frameBox)) align=\(o.format?.align ?? "-") valign=\(o.format?.valign ?? "-") ink=\(box(canvas.stop?.box(of: oid)))")
            selection = oid
            log("selected box=\(box(canvas.selectedBox))")
            shot("frame-selected")
            alignCenter()
            await settle()
            selection = oid
            log("after center: align=\(objInfo?.format?.align ?? "-") frame=\(box(objInfo?.frameBox)) ink=\(box(canvas.stop?.box(of: oid)))")
            submit { [weak self] in await self?.runEdit(["op": "spacing", "oid": oid, "value": 1.0]) }
            await settle()
            selection = oid
            log("after spacing: lineSpacing=\(objInfo?.format?.lineSpacing ?? -1)")
            beginEdit(oid, at: nil)
            guard let ed = window.firstResponder as? NSTextView else { log("inline editor not focused"); return }
            let ps = ed.defaultParagraphStyle
            log("editor: frame=\(ed.frame) font=\(ed.font?.pointSize ?? 0) align=\(ps?.alignment.rawValue ?? -1) lineSpacing=\(ps?.lineSpacing ?? -1) editingText=\(canvas.editingText ?? -1)")
            ed.setSelectedRange(NSRange(location: 0, length: 0))
            // ⌘A through the menu, the way the key reaches it
            if let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) {
                let handled = NSApp.mainMenu?.performKeyEquivalent(with: ev) ?? false
                log("cmd-A handled=\(handled) selection=\(ed.selectedRange())")
            }
            ed.setSelectedRange(NSRange(location: 6, length: 5))          // "world"
            formatSuperscript()
            log("superscript selection: '\(ed.string)' selection=\(ed.selectedRange()) toast=\(toastPill.label.stringValue)")
            ed.setSelectedRange(NSRange(location: (ed.string as NSString).length, length: 0))
            formatSubscript()
            log("subscript mode: \(canvas.textScriptMode.map(String.init) ?? "nil") button=\(formatBar.subscriptButton.state == .on) toast=\(toastPill.label.stringValue)")
            ed.insertText("2", replacementRange: ed.selectedRange())
            formatSubscript()
            ed.insertText("x", replacementRange: ed.selectedRange())
            log("typed in modes: '\(ed.string)' mode=\(canvas.textScriptMode.map(String.init) ?? "nil")")
            ed.insertNewline(nil); ed.insertText("Second line", replacementRange: ed.selectedRange())
            log("editor two lines: frame=\(ed.frame)")
            shot("frame-editing")
            window.makeFirstResponder(canvas)
            await settle()
            selection = oid
            log("after commit: '\(objInfo?.value ?? "-")' frame=\(box(objInfo?.frameBox)) ink=\(box(canvas.stop?.box(of: oid)))")
            shot("frame-after")
            log("done")
        }
    }

    func layoutsTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "layouts.log") }
        func save(_ img: NSImage, _ name: String) {
            if let t = img.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir + name + ".png"))
            }
        }
        func shot(_ name: String) {
            guard let img = canvas.snapshotView() else { return }
            let out = NSImage(size: canvas.bounds.size)
            out.lockFocus()
            NSImage(cgImage: img, size: canvas.bounds.size).draw(in: canvas.bounds)
            for v in canvas.subviews where v is NSTextView {
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    NSImage(cgImage: rep.cgImage!, size: v.bounds.size).draw(in: v.frame)
                }
            }
            out.unlockFocus()
            save(out, name)
        }
        for (_, layout, _) in MainController.slideLayouts { save(MainController.layoutIcon(layout, width: 132), "icon-" + layout) }
        Task { @MainActor in
            var made: [String: String] = [:]
            for (_, layout, _) in MainController.slideLayouts {
                slideOp("new", layout: layout)
                await queueTail?.value
                try? await Task.sleep(nanoseconds: 600_000_000)
                made[layout] = sceneName
                log("\(layout): \(sceneName ?? "-") placeholders=\(canvas.placeholders.map { "\($0.role)@\($0.line)" }) objects=\(scene?.objects?.count ?? -1)")
                shot("layout-" + layout)
            }
            await selectScene(made["title_content"] ?? "")
            try? await Task.sleep(nanoseconds: 400_000_000)
            for (_, layout, _) in MainController.slideLayouts {
                save(MainController.layoutIcon(layout, width: 132, background: canvas.shownBackground ?? .white), "icon-shown-" + layout)
            }
            for (i, text) in ["Results", "First finding\nSecond finding"].enumerated() {
                guard let ph = canvas.placeholders.first else { log("no placeholder left"); return }
                let r = canvas.slideRect, sc = canvas.effectiveScale
                let wp = canvas.convert(CGPoint(x: r.minX + ph.rect.cx * sc, y: r.maxY - ph.rect.cy * sc), to: nil)
                canvas.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: wp, modifierFlags: [], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                          clickCount: 1, pressure: 1)!)
                guard let tv = window.firstResponder as? NSTextView else { log("editor not focused"); return }
                log("editing \(ph.role): editor frame=\(tv.frame) font=\(tv.font?.pointSize ?? 0)")
                for (j, part) in text.components(separatedBy: "\n").enumerated() {
                    if j > 0 { tv.insertNewline(nil) }
                    tv.insertText(part, replacementRange: tv.selectedRange())
                }
                log("typed: '\(tv.string)'")
                shot("typing-\(i)")
                window.makeFirstResponder(canvas)
                await queueTail?.value
                try? await Task.sleep(nanoseconds: 800_000_000)
                log("after: placeholders=\(canvas.placeholders.map { $0.role }) texts=\(scene?.objects?.values.map { $0.value } ?? [])")
                shot("typed-\(i)")
            }
            log("source:\n\(scene?.source?.text ?? "-")")
            // an empty box: click it, press backspace -> it is removed
            await selectScene(made["two_content"] ?? "")
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let ph = canvas.placeholders.last {
                let r = canvas.slideRect, sc = canvas.effectiveScale
                let wp = canvas.convert(CGPoint(x: r.minX + ph.rect.cx * sc, y: r.maxY - ph.rect.cy * sc), to: nil)
                canvas.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: wp, modifierFlags: [], timestamp: 0,
                                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                          clickCount: 1, pressure: 1)!)
                (window.firstResponder as? NSTextView)?.deleteBackward(nil)
                await queueTail?.value
                try? await Task.sleep(nanoseconds: 600_000_000)
                log("after backspace: placeholders=\(canvas.placeholders.map { "\($0.role)@\($0.line)" }) editing=\(window.firstResponder is NSTextView)")
                shot("backspaced")
            }
            log("done")
        }
    }

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
            let positions = [("Bottom right", "DR"), ("Bottom center", "DOWN"), ("Bottom left", "DL")]
            let pos = NSPopUpButton(frame: .zero, pullsDown: false)
            pos.addItems(withTitles: positions.map { $0.0 })
            pos.selectItem(at: positions.firstIndex(where: { $0.1 == (info?.pos ?? "DR") }) ?? 0)
            let start = NSTextField(string: String(info?.start ?? 1))
            let size = NSTextField(string: String(info?.size ?? 24))
            for f in [start, size] { f.widthAnchor.constraint(equalToConstant: 64).isActive = true }
            let skip = NSButton(checkboxWithTitle: "Skip title slide", target: nil, action: nil)
            skip.state = (info?.skip ?? true) ? .on : .off
            let total = NSButton(checkboxWithTitle: "Show total slides", target: nil, action: nil)
            total.state = (info?.total ?? true) ? .on : .off
            let sub = NSButton(checkboxWithTitle: "Show sub-slide numbers", target: nil, action: nil)
            sub.state = (info?.sub ?? false) ? .on : .off
            sub.toolTip = "Slides with several builds also count them: 29 / 47 · 1/3 rather than 29 / 47"
            // saved as soon as it is picked: Update Numbers would also reset numbers that were moved or restyled
            let spread = NSPopUpButton(frame: .zero, pullsDown: false)
            spread.addItems(withTitles: Self.pageSpreadChoices.map { $0.0 })
            let saved = UserDefaults.standard.string(forKey: Self.pageSpreadKey)
            spread.selectItem(at: Self.pageSpreadChoices.firstIndex(where: { $0.1 == saved }) ?? 0)
            spread.target = self; spread.action = #selector(pageSpreadPicked(_:))
            let grid = NSGridView(views: [[fieldLabel("Position"), pos], [fieldLabel("Start at"), start],
                                          [fieldLabel("Font size"), size], [NSView(), skip], [NSView(), total], [NSView(), sub],
                                          [fieldLabel("When one is changed"), spread]])
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
                                "size": max(6, size.integerValue), "skip": skip.state == .on, "total": total.state == .on,
                                "sub": sub.state == .on])
            } else if info?.on == true, r == .alertSecondButtonReturn {
                runPageNumbers(["op": "remove"])
            }
        }
    }

    /// What to do when one slide's number is moved or restyled; nil (Ask) is the default.
    static let pageSpreadKey = "pageNumberSpread"
    static let pageSpreadChoices: [(String, String?)] = [("Ask", nil), ("Apply to all slides", "all"), ("Only that slide", "one")]

    @objc func pageSpreadPicked(_ p: NSPopUpButton) {
        UserDefaults.standard.set(Self.pageSpreadChoices[p.indexOfSelectedItem].1, forKey: Self.pageSpreadKey)
    }

    /// The slide number on `scene` was moved or restyled: ask whether every slide's number should match it, unless
    /// "Don't ask again" was ticked (Insert ▸ Slide Numbers… turns the question back on).
    func offerPageNumberSpread(_ scene: String) {
        switch UserDefaults.standard.string(forKey: Self.pageSpreadKey) {
        case "all": runPageNumbers(["op": "spread"], scene: scene); return
        case "one": return
        default: break
        }
        let a = NSAlert()
        a.messageText = "Apply to all slides?"
        a.informativeText = "You changed this slide's number. Give every slide's number the same position and style?"
        a.addButton(withTitle: "Apply to All Slides")
        a.addButton(withTitle: "Only This Slide")
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Don't ask again"
        let all = a.runModal() == .alertFirstButtonReturn
        if a.suppressionButton?.state == .on {
            UserDefaults.standard.set(all ? "all" : "one", forKey: Self.pageSpreadKey)
            toast("Won't ask again · change this in Insert ▸ Slide Numbers…")
        }
        if all { runPageNumbers(["op": "spread"], scene: scene) }
    }

    func runPageNumbers(_ args: [String: Any], scene: String? = nil) {
        guard let name = scene ?? sceneName else { return }
        submit { [weak self] in
            guard let self = self else { return }
            self.busy += 1
            var req = args; req["scene"] = name
            let r = try? await self.engine.call("page_numbers", req, as: EditResult.self)
            self.busy -= 1
            guard let res = r, res.ok == true else { self.toast(r?.error ?? "could not write the slide numbers", error: true); return }
            self.lastChanged = res.changed
            self.toast(res.message == "no change" ? "No change" : "Saved · \(res.message ?? "slide numbers")")
            if let shown = self.sceneName { await self.loadScene(shown, keepStop: true) }
            await self.reloadState()
        }
    }

    // MARK: speaker notes pane

    /// The Slide Notes and Build Notes tabs of the drawer.
    func buildNotesPane() {
        for (pane, box) in [(notesPane, notesBox), (buildNotesView, buildNotesBox)] {
            pane.wantsLayer = true
            Theme.layerColors(pane) { $0.layer?.backgroundColor = Theme.canvasBottom.cgColor }
            box.font = Theme.font(13)
            box.textColor = Theme.ink(0.92)
            box.editorBackground = Theme.dynamic(light: .white, dark: NSColor(white: 1, alpha: 0.07))
            box.borderType = .noBorder
            box.wantsLayer = true; box.layer?.cornerRadius = 6; box.layer?.masksToBounds = true
            box.fillsContainer = true                 // the pane's height comes from the drawer's divider
            box.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(box)
            NSLayoutConstraint.activate([
                box.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
                box.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12),
                box.topAnchor.constraint(equalTo: pane.topAnchor, constant: 8),
                box.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -8),
            ])
        }
        notesBox.onCommit = { [weak self] text in self?.commitNotes(text) }
        buildNotesBox.onCommit = { [weak self] text in self?.commitBuildNotes(text) }
    }

    @objc func hideNotesPane() { setDrawerOpen(false) }

    /// ⌥⌘K: the drawer on the notes tab, or closed if that is already showing.
    @objc func toggleNotesPane() {
        if drawerShowsNotes { setDrawerOpen(false); return }
        drawer.show(.notes)
        setDrawerOpen(true)
        notesBox.beginEditing()
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

    /// Save the Build Notes tab's text for the build it was showing (on that build's next_slide()).
    func commitBuildNotes(_ text: String) {
        guard let target = buildNotesFor else { return }
        submit { [weak self] in
            guard let self = self else { return }
            self.busy += 1
            let r = try? await self.engine.call("notes", ["op": "set", "scene": target.scene, "stop": target.stop, "text": text],
                                                as: NotesResult.self)
            self.busy -= 1
            guard let res = r, res.ok == true else {
                self.toast(r?.error ?? "could not save the build notes", error: true)
                if self.sceneName == target.scene { await self.loadScene(target.scene, keepStop: true) }     // back to what is saved
                return
            }
            self.lastChanged = res.changed
            self.toast(res.message == "no change" ? "No change" : "Notes saved for build \(target.stop + 1)")
            if self.sceneName == target.scene { await self.loadScene(target.scene, keepStop: true) }
            await self.reloadState()
        }
    }

    /// Save notes typed in Presenter View: the slide's (`build` nil) or one build's.
    func savePresenterNotes(scene: String, build: Int?, text: String, done: @escaping (Bool) -> Void) {
        submit { [weak self] in
            guard let self = self else { return }
            var args: [String: Any] = ["op": "set", "scene": scene, "text": text]
            if let b = build { args["stop"] = b }
            let r = try? await self.engine.call("notes", args, as: NotesResult.self)
            guard let res = r, res.ok == true else {
                self.toast(r?.error ?? "could not save the notes", error: true)
                done(false)
                return
            }
            self.lastChanged = res.changed
            done(true)
            if self.sceneName == scene { await self.loadScene(scene, keepStop: true) }
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
            drawer.show(.notes); setDrawerOpen(true)
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
            if let sp = centerSplit {
                drawer.show(.notes); setDrawerOpen(true); sp.layoutSubtreeIfNeeded()
                let before = notesPane.frame.height
                sp.setPosition(sp.bounds.height - 200, ofDividerAt: 0); sp.layoutSubtreeIfNeeded()
                let dragged = notesPane.frame.height
                setDrawerOpen(false); sp.layoutSubtreeIfNeeded()
                let hiddenH = drawer.isHidden ? 0 : notesPane.frame.height
                setDrawerOpen(true); sp.layoutSubtreeIfNeeded()
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
            mi.image = MainController.layoutIcon(layout)
            layouts.addItem(mi)
        }
        let newItem = NSMenuItem(title: "New Slide", action: nil, keyEquivalent: ""); newItem.submenu = layouts
        m.addItem(newItem)
        add("New Build", #selector(newBuild))
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
            let p = PresenterController(slides: playable.map { $0.pages }, scenes: playable.map { $0.scene },
                                        notes: playable.map { $0.notes ?? "" },
                                        buildNotes: playable.map { $0.buildNotes ?? [] },
                                        startSlide: start, presenterScreen: here, audienceScreen: other)
            p.onExit = { [weak self] in self?.presenter = nil; self?.window.makeKeyAndOrderFront(nil) }
            p.onSaveNotes = { [weak self] scene, build, text, done in self?.savePresenterNotes(scene: scene, build: build, text: text, done: done) }
            p.feedback = feedback
            // "Use Slide Show": the presenter window closes and the show carries on as the plain slideshow
            p.onDetach = { [weak self] src in
                self?.presenter = nil
                guard let s = src as? SlidePlayer else { return }
                s.onExit = { [weak self] in self?.player = nil; self?.window.makeKeyAndOrderFront(nil) }
                self?.player = s
            }
            presenter = p
            if other == nil { toast("One display: the show is full screen behind the presenter window. With a second display it goes there.") }
        }
    }
}

// MARK: - feedback notes (Presenter View's Feedback Mode)

extension MainController {
    /// Open the deck's feedback notes alongside its working copy and lay them over the canvas.
    func openFeedback(_ ws: Workspace) {
        let original = ws.original.appendingPathComponent("feedback.json")
        let store = FeedbackStore(url: ws.work.appendingPathComponent("feedback.json"),
                                  originalHasFile: FileManager.default.fileExists(atPath: original.path))
        store.onChange = { [weak self] in self?.feedbackChanged() }
        feedback = store
        let layer = canvas.attachFeedbackLayer()
        layer.store = store
        layer.scene = sceneName
        syncFeedbackButton()
    }

    /// A note was added, edited or removed (in the editor or in Presenter View).
    func feedbackChanged() {
        updateDocumentState()
        syncFeedbackButton()
        canvas.feedbackLayer?.rebuild()
        presenter?.feedbackChanged()
        (feedbackPopover?.contentViewController?.view as? FeedbackListView)?.reload()
    }

    func syncFeedbackButton() {
        let n = feedback?.notes.count ?? 0
        formatBar?.feedback.isEnabled = n > 0
        formatBar?.feedback.title = n > 0 ? "View Feedback (\(n))" : "View Feedback"
    }

    /// How the feedback list names a slide: its number in the navigator (and name), or "missing" for a slide that
    /// was renamed or deleted since.
    func feedbackSlideLabel(_ scene: String) -> String {
        if let i = state?.scenes.firstIndex(where: { $0.name == scene }) {
            return "Slide \(i + 1) · \(scene)" + (state?.scenes[i].hidden == true ? " (hidden)" : "")
        }
        if state?.unusedScenes.contains(where: { $0.name == scene }) == true { return "Unused slide · \(scene)" }
        return "Missing slide · \(scene)"
    }

    /// "View Feedback": the notes grouped by slide in a popover; a click (or Previous / Next) shows that slide
    /// with the note outlined, ready to edit.
    @objc func viewFeedback(_ sender: NSButton) {
        if let p = feedbackPopover, p.isShown { p.close(); return }
        guard let store = feedback, !store.isEmpty else { return }
        let list = FeedbackListView(store: store)
        list.slideLabel = { [weak self] in self?.feedbackSlideLabel($0) ?? $0 }
        list.onGo = { [weak self] n in
            guard let self else { return }
            Task { @MainActor in
                if self.sceneName != n.scene {
                    guard self.state?.scenes.contains(where: { $0.name == n.scene }) == true
                            || self.state?.unusedScenes.contains(where: { $0.name == n.scene }) == true
                    else { self.toast("That slide no longer exists", error: true); return }
                    await self.selectScene(n.scene)
                }
                if let stops = self.scene?.stops, stops.indices.contains(n.build), self.stopIndex != n.build {
                    self.stopIndex = n.build
                    self.applyStop()
                }
                self.canvas.feedbackLayer?.focus(n.id)
            }
        }
        let vc = NSViewController(); vc.view = list
        let p = NSPopover(); p.contentViewController = vc; p.behavior = .transient
        feedbackPopover = p
        p.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
}

extension MainController {
    /// MANIMBLE_TEST_FEEDBACK=<deck>: Presenter View (stills) in Feedback Mode, notes typed through real window
    /// events, then the editor's overlay and the View Feedback list; feedback.log and feedback-*.png in
    /// MANIMBLE_TEST_OUT.
    func feedbackTest() {
        let env = ProcessInfo.processInfo.environment
        let dir = (env["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "feedback.log") }
        func shot(_ w: NSWindow, _ name: String) {
            guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
        }
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        func click(_ w: NSWindow, _ p: CGPoint, right: Bool = false) {
            for (t, n) in [(right ? NSEvent.EventType.rightMouseDown : .leftMouseDown, 1), (right ? .rightMouseUp : .leftMouseUp, 1)] {
                if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: n, clickCount: 1, pressure: 1) { w.sendEvent(e) }
            }
        }
        func key(_ w: NSWindow, code: UInt16, chars: String, mods: NSEvent.ModifierFlags = []) {
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                        isARepeat: false, keyCode: code) { w.sendEvent(e) }
        }
        Task { @MainActor in
            try? "".write(toFile: dir + "feedback.log", atomically: true, encoding: .utf8)
            await selectScene("Welcome")
            await queueTail?.value
            log("store=\(feedback != nil) notes=\(feedback?.notes.count ?? -1) button=\(formatBar.feedback.isEnabled)")
            presenterView()
            for _ in 0..<600 { await wait(0.5); if presenter != nil { break } }
            guard let pc = presenter else { log("no presenter"); return }
            await wait(1.5)
            let w = pc.window
            log("presenter page=\(pc.source.pageIndex)/\(pc.source.pageCount) mode=\(pc.feedbackMode)")
            // a click on the slide with Feedback Mode off advances the show
            var r = pc.feedbackSlideRectInWindow
            click(w, CGPoint(x: r.midX, y: r.midY)); await wait(0.4)
            log("click off-mode: page=\(pc.source.pageIndex) (expected 1)")
            pc.source.go(0); await wait(0.4)
            // Feedback Mode: a click adds a note and typing goes into it
            pc.setFeedbackMode(true)
            r = pc.feedbackSlideRectInWindow
            click(w, CGPoint(x: r.minX + r.width * 0.2, y: r.minY + r.height * 0.7)); await wait(0.3)
            log("after click: first responder=\(type(of: w.firstResponder as Any)) notes=\(feedback?.notes.count ?? -1)")
            (w.firstResponder as? NSTextView)?.insertText("Fix this title", replacementRange: NSRange(location: 0, length: 0))
            await wait(0.2)
            shot(w, "feedback-1-typing.png")
            key(w, code: 53, chars: "\u{1B}")                   // esc ends typing and saves
            await wait(0.3)
            let n1 = feedback?.notes.first
            log("note 1: scene=\(n1?.scene ?? "-") build=\(n1?.build ?? -1) x=\(n1?.x ?? -1) y=\(n1?.y ?? -1) text='\(n1?.text ?? "")' fr=\(type(of: w.firstResponder as Any))")
            log("file exists=\(FileManager.default.fileExists(atPath: feedback?.url.path ?? "")) modified=\(workspace?.isModified ?? false)")
            // the arrow keys still drive the show after esc
            key(w, code: 124, chars: "\u{F703}"); await wait(0.4)
            log("after → : page=\(pc.source.pageIndex) (expected 1)")
            // a note on the last slide, ended by moving on (the show's keys) rather than esc
            pc.source.go(pc.source.pageCount - 1); await wait(0.5)
            r = pc.feedbackSlideRectInWindow
            click(w, CGPoint(x: r.minX + r.width * 0.6, y: r.minY + r.height * 0.3)); await wait(0.3)
            (w.firstResponder as? NSTextView)?.insertText("Too much maths here", replacementRange: NSRange(location: 0, length: 0))
            await wait(0.2)
            key(w, code: 36, chars: "\r", mods: .command)      // ⌘↵
            await wait(0.3)
            shot(w, "feedback-2-last-slide.png")
            log("notes=\(feedback?.notes.map { "\($0.scene):\($0.text)" } ?? [])")
            // an empty note is dropped
            click(w, CGPoint(x: r.minX + r.width * 0.5, y: r.minY + r.height * 0.5)); await wait(0.2)
            key(w, code: 53, chars: "\u{1B}"); await wait(0.4)
            log("after empty note: notes=\(feedback?.notes.count ?? -1) (expected 2)")
            pc.setFeedbackMode(false)
            w.close(); await wait(0.6)
            log("closed presenter=\(presenter == nil) player=\(player == nil)")
            // the editor shows the notes of the slide on screen; the audience never did (nothing is rendered)
            await selectScene("Welcome"); await queueTail?.value; await wait(0.8)
            let boxes = canvas.feedbackLayer?.subviews.compactMap { $0 as? FeedbackBox } ?? []
            log("editor Welcome: boxes=\(boxes.count) frames=\(boxes.map { "\($0.frame.integral)" }) slide=\(canvas.slideRect.integral)")
            log("editor Welcome: box text=\(boxes.map { "'\($0.text.string)' storage=\($0.text.textStorage?.string ?? "nil") tf=\($0.text.frame)" }) store=\(feedback?.notes.map(\.text) ?? [])")
            shot(window, "feedback-3-editor.png")
            log("button=\(formatBar.feedback.isEnabled) title='\(formatBar.feedback.title)'")
            // View Feedback: Next goes to the first note, then the second (another slide), focused for editing
            viewFeedback(formatBar.feedback); await wait(0.5)
            guard let list = feedbackPopover?.contentViewController?.view as? FeedbackListView else { log("no popover"); return }
            log("popover shown=\(feedbackPopover?.isShown ?? false)")
            list.goNext(); await wait(1.2)
            log("after next 1: scene=\(sceneName ?? "-") fr=\(type(of: window.firstResponder as Any))")
            list.goNext(); await wait(1.5)
            log("after next 2: scene=\(sceneName ?? "-") fr=\(type(of: window.firstResponder as Any)) boxes=\(canvas.feedbackLayer?.subviews.compactMap { $0 as? FeedbackBox }.count ?? -1)")
            shot(window, "feedback-4-editor-formula.png")
            feedbackPopover?.close()
            // deleting: one, then all
            if let id = feedback?.notes.first?.id { feedback?.remove(id) }
            await wait(0.2)
            log("after remove one: notes=\(feedback?.notes.count ?? -1) button=\(formatBar.feedback.isEnabled)")
            feedback?.removeAll(); await wait(0.2)
            log("after remove all: notes=\(feedback?.notes.count ?? -1) button=\(formatBar.feedback.isEnabled) file=\(FileManager.default.fileExists(atPath: feedback?.url.path ?? "")) boxes=\(canvas.feedbackLayer?.subviews.compactMap { $0 as? FeedbackBox }.count ?? -1)")
            log("done")
        }
    }
}

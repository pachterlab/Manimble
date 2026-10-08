import AppKit
import UniformTypeIdentifiers

@MainActor
final class MainController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    let engine = Engine()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 920),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    let canvas = CanvasView()
    let table = NSTableView()
    let stepsBar = NSStackView()
    let inspector = NSStackView()
    let sourceView = NSTextView()
    let srcHeader = NSTextField(labelWithString: "PYTHON")
    let toastPill = Pill()
    let busyPill = Pill()
    var busyText = "Rendering…" { didSet { if busy > 0 { busyPill.show(busyText, symbol: nil, tint: nil, spinning: true) } } }

    var workspace: Workspace?
    // Opening a deck can happen while startup is still searching for Python.
    // Keep the selection and open it as soon as launch() has started the engine.
    private var pendingDeck: String?
    var state: StateInfo?
    var scene: SceneData?
    var sceneName: String?
    var stopIndex = 0
    var selection: Int? { didSet { canvas.selection = selection; rebuildInspector(); highlightSource() } }
    var busy = 0 { didSet {
        if busy > 0 { busyPill.show(busyText, symbol: nil, tint: nil, spinning: true) } else { busyPill.hide() }
    } }
    var queueTail: Task<Void, Never>?
    var lastChanged: ChangedLines?
    var thumbCache = NSCache<NSString, NSImage>()
    var refreshTimer: Timer?
    var pendingStateRefresh = false
    var nudge = (dx: 0.0, dy: 0.0)
    var nudgeWork: DispatchWorkItem?
    var sharedChoice = true
    var suppressTable = false
    var testRan = false
    var shownDir: String?
    var mainSplit: NSSplitView?
    var sideScroll: NSScrollView?
    var player: SlidePlayer?
    let terminal = TerminalPanel()
    var centerSplit: NSSplitView?

    // inspector controls kept for reading
    var zoomPopup: NSPopUpButton?
    var tableText: NSTextView?
    var textField: NSTextField?
    var sizeField: NSTextField?
    var colorWell: NSColorWell?

    // MARK: setup

    func showWindow() {
        window.title = "Manimble"
        window.titlebarSeparatorStyle = .line
        window.delegate = self
        window.minSize = NSSize(width: 1000, height: 600)
        window.setFrameAutosaveName("manimble.main")
        window.contentView = buildUI()
        window.toolbar = makeToolbar()
        window.toolbarStyle = .unified
        canvas.onZoomChange = { [weak self] in self?.syncZoomPopup() }
        canvas.onDelete = { [weak self] oid in self?.deleteSelected(oid) }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func buildUI() -> NSView {
        // sidebar
        let col = NSTableColumn(identifier: .init("slide")); col.width = 220; col.minWidth = 120; col.maxWidth = 600
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.headerView = nil
        table.rowHeight = 108
        table.dataSource = self; table.delegate = self
        table.style = .plain
        table.backgroundColor = .clear
        let side = NSScrollView(); side.documentView = table; side.hasVerticalScroller = true
        side.drawsBackground = false
        side.automaticallyAdjustsContentInsets = false
        side.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 12, right: 0)
        let sideBox = NSVisualEffectView(); sideBox.material = .sidebar; sideBox.blendingMode = .behindWindow
        sideBox.addSubview(side)
        side.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: sideBox.leadingAnchor), side.trailingAnchor.constraint(equalTo: sideBox.trailingAnchor),
            side.topAnchor.constraint(equalTo: sideBox.topAnchor), side.bottomAnchor.constraint(equalTo: sideBox.bottomAnchor),
        ])
        sideBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        side.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: side, queue: .main) { [weak self, weak side] _ in
            guard let side = side, let self = self else { return }
            self.table.tableColumns.first?.width = side.contentSize.width
        }

        // centre: canvas + builds
        canvas.onSelect = { [weak self] oid in self?.selection = oid }
        canvas.onMove = { [weak self] oid, dx, dy in self?.commitMove(oid, dx, dy) }
        canvas.onResize = { [weak self] oid, r in self?.commitResize(oid, r) }
        canvas.onEndpoints = { [weak self] oid, e in self?.commitEndpoints(oid, e) }
        canvas.onEdit = { [weak self] oid in self?.beginEdit(oid) }
        canvas.onNudge = { [weak self] oid, dx, dy in self?.nudgeObject(oid, dx, dy) }
        stepsBar.orientation = .horizontal; stepsBar.spacing = 8
        stepsBar.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 8, right: 12)
        let stepsScroll = NSScrollView(); stepsScroll.documentView = stepsBar
        stepsScroll.hasHorizontalScroller = false
        stepsScroll.drawsBackground = true; stepsScroll.backgroundColor = Theme.canvasBottom
        stepsScroll.heightAnchor.constraint(equalToConstant: 68).isActive = true
        let center = NSView()
        let vs = NSStackView(views: [canvas, stepsScroll]); vs.orientation = .vertical; vs.spacing = 0
        // slides on top, optional terminal below
        let cs = GrabSplitView(); cs.isVertical = false; cs.dividerStyle = .thin
        cs.addArrangedSubview(vs); cs.addArrangedSubview(terminal)
        terminal.isHidden = true
        terminal.onHide = { [weak self] in self?.toggleTerminal() }
        centerSplit = cs
        cs.translatesAutoresizingMaskIntoConstraints = false
        for pill in [toastPill, busyPill] { pill.translatesAutoresizingMaskIntoConstraints = false }
        // the slide area sits in an inset rounded card with a slim light edge, matching the code card on the right
        let stageCard = NSView(); stageCard.wantsLayer = true
        stageCard.layer?.cornerRadius = 12; stageCard.layer?.masksToBounds = true
        stageCard.layer?.borderWidth = 1; stageCard.layer?.borderColor = NSColor(white: 1, alpha: 0.22).cgColor
        stageCard.layer?.backgroundColor = Theme.canvasBottom.cgColor
        stageCard.translatesAutoresizingMaskIntoConstraints = false
        center.wantsLayer = true
        center.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        center.addSubview(stageCard)
        stageCard.addSubview(cs)
        center.addSubview(toastPill); center.addSubview(busyPill)
        NSLayoutConstraint.activate([
            stageCard.leadingAnchor.constraint(equalTo: center.leadingAnchor, constant: 10), stageCard.trailingAnchor.constraint(equalTo: center.trailingAnchor, constant: -10),
            stageCard.topAnchor.constraint(equalTo: center.topAnchor, constant: 10), stageCard.bottomAnchor.constraint(equalTo: center.bottomAnchor, constant: -10),
            cs.leadingAnchor.constraint(equalTo: stageCard.leadingAnchor), cs.trailingAnchor.constraint(equalTo: stageCard.trailingAnchor),
            cs.topAnchor.constraint(equalTo: stageCard.topAnchor), cs.bottomAnchor.constraint(equalTo: stageCard.bottomAnchor),
            toastPill.centerXAnchor.constraint(equalTo: center.centerXAnchor),
            toastPill.bottomAnchor.constraint(equalTo: center.bottomAnchor, constant: -90),
            toastPill.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            busyPill.topAnchor.constraint(equalTo: center.topAnchor, constant: 22),
            busyPill.trailingAnchor.constraint(equalTo: center.trailingAnchor, constant: -24),
        ])
        center.widthAnchor.constraint(greaterThanOrEqualToConstant: 500).isActive = true

        // right: inspector + source
        inspector.orientation = .vertical; inspector.alignment = .leading; inspector.spacing = 9
        inspector.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        inspector.translatesAutoresizingMaskIntoConstraints = false
        let inspScroll = NSScrollView(); inspScroll.hasVerticalScroller = true
        inspScroll.drawsBackground = true; inspScroll.backgroundColor = .windowBackgroundColor
        let flip = FlippedView(); flip.translatesAutoresizingMaskIntoConstraints = false
        flip.addSubview(inspector)
        NSLayoutConstraint.activate([
            inspector.leadingAnchor.constraint(equalTo: flip.leadingAnchor), inspector.trailingAnchor.constraint(equalTo: flip.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: flip.topAnchor), inspector.bottomAnchor.constraint(equalTo: flip.bottomAnchor),
        ])
        inspScroll.documentView = flip
        flip.widthAnchor.constraint(equalTo: inspScroll.contentView.widthAnchor).isActive = true
        sourceView.isEditable = false
        sourceView.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        sourceView.backgroundColor = NSColor(srgbRed: 0.098, green: 0.102, blue: 0.125, alpha: 1)
        sourceView.textColor = .init(white: 0.88, alpha: 1)
        // no wrapping: long lines scroll sideways
        sourceView.isHorizontallyResizable = true; sourceView.isVerticallyResizable = true
        sourceView.minSize = NSSize(width: 0, height: 0)
        sourceView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        sourceView.autoresizingMask = []
        sourceView.textContainer?.widthTracksTextView = false
        sourceView.textContainer?.heightTracksTextView = false
        sourceView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        sourceView.textContainerInset = NSSize(width: 0, height: 6)
        let srcScroll = NSScrollView(); srcScroll.documentView = sourceView
        srcScroll.hasVerticalScroller = true; srcScroll.hasHorizontalScroller = true
        srcScroll.scrollerStyle = .legacy; srcScroll.autohidesScrollers = false      // always-visible bars
        srcScroll.appearance = NSAppearance(named: .darkAqua)        // dark track, light knob on the dark card
        srcScroll.scrollerKnobStyle = .light
        srcScroll.drawsBackground = true; srcScroll.backgroundColor = sourceView.backgroundColor
        srcScroll.borderType = .noBorder
        srcHeader.font = Theme.font(10, .semibold); srcHeader.textColor = NSColor(white: 1, alpha: 0.5)
        let headBar = NSView(); headBar.wantsLayer = true
        headBar.layer?.backgroundColor = NSColor(srgbRed: 0.125, green: 0.13, blue: 0.158, alpha: 1).cgColor
        srcHeader.translatesAutoresizingMaskIntoConstraints = false; headBar.addSubview(srcHeader)
        headBar.heightAnchor.constraint(equalToConstant: 26).isActive = true
        NSLayoutConstraint.activate([srcHeader.leadingAnchor.constraint(equalTo: headBar.leadingAnchor, constant: 14),
                                     srcHeader.centerYAnchor.constraint(equalTo: headBar.centerYAnchor)])
        let srcBox = NSStackView(views: [headBar, srcScroll]); srcBox.orientation = .vertical; srcBox.spacing = 0
        headBar.widthAnchor.constraint(equalTo: srcBox.widthAnchor).isActive = true
        let right = GrabSplitView(); right.isVertical = false; right.dividerStyle = .thin
        // the code sits in an inset card with its own edge
        let card = NSView(); card.wantsLayer = true
        card.layer?.cornerRadius = 10; card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1; card.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        card.layer?.backgroundColor = sourceView.backgroundColor.cgColor
        srcBox.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(srcBox)
        NSLayoutConstraint.activate([
            srcBox.leadingAnchor.constraint(equalTo: card.leadingAnchor), srcBox.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            srcBox.topAnchor.constraint(equalTo: card.topAnchor), srcBox.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        let cardHolder = NSView(); cardHolder.wantsLayer = true
        cardHolder.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        cardHolder.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: cardHolder.leadingAnchor, constant: 10), card.trailingAnchor.constraint(equalTo: cardHolder.trailingAnchor, constant: -10),
            card.topAnchor.constraint(equalTo: cardHolder.topAnchor, constant: 8), card.bottomAnchor.constraint(equalTo: cardHolder.bottomAnchor, constant: -10),
        ])
        right.addArrangedSubview(inspScroll); right.addArrangedSubview(cardHolder)
        right.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        right.setHoldingPriority(.defaultLow, forSubviewAt: 0)

        let split = GrabSplitView(); split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(sideBox); split.addArrangedSubview(center); split.addArrangedSubview(right)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(250), forSubviewAt: 2)
        split.autosaveName = "manimble.split"            // remembers where you dragged the dividers
        mainSplit = split
        sideScroll = side
        NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main) { [weak self] _ in
            self?.fitSidebarColumn()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.fitSidebarColumn() }
        let saved = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames manimble.split") != nil
        if !saved {
            DispatchQueue.main.async { split.setPosition(232, ofDividerAt: 0); split.setPosition(split.bounds.width - 360, ofDividerAt: 1) }
        }
        DispatchQueue.main.async { right.setPosition(400, ofDividerAt: 0) }
        rebuildInspector()
        return split
    }

    // MARK: engine lifecycle

    func start() {
        // find a Python that has manim, without blocking the UI
        busyPill.show("Looking for a Python with manim…", symbol: nil, tint: nil, spinning: true)
        Task.detached {
            let py = Engine.findPython()
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.busyPill.hide()
                if let py = py { self.launch(python: py) }
                else {
                    self.alert("Manimble needs a Python environment with manim",
                               "Could not find a Python that can import manim and Pillow. Install them (pip install manim manim-slides pillow python-pptx), then choose that environment's python in the next dialog.")
                    self.choosePython()
                }
            }
        }
    }

    func launch(python: String) {
        do { try engine.start(python: python) }
        catch {
            pendingDeck = nil
            busyPill.hide()
            alert("Could not start the engine", "\(error)")
            return
        }
        busyPill.hide()
        engine.onEvent = { [weak self] ev in self?.handleEvent(ev) }
        if let pending = pendingDeck {
            pendingDeck = nil
            open(deck: pending)
        } else {
            let last = UserDefaults.standard.string(forKey: "lastDeck")
            if let d = last, FileManager.default.fileExists(atPath: d) { open(deck: d) } else { openDeck() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.busy == 0 { await self?.reloadState() } }
        }
    }

    @objc func choosePython() {
        let p = NSOpenPanel()
        p.message = "Choose the Python executable of the environment where manim is installed (e.g. …/venv/bin/python)"
        p.canChooseFiles = true; p.canChooseDirectories = false; p.showsHiddenFiles = true
        if p.runModal() == .OK, let u = p.url {
            UserDefaults.standard.set(u.path, forKey: "python")
            if engine.isRunning { engine.stop() }
            launch(python: u.path)
        }
    }

    @objc func openDeck() {
        let p = NSOpenPanel()
        p.message = "Choose a deck folder, a Manimble project folder, or a .manimble package"
        p.canChooseDirectories = true; p.canChooseFiles = true
        if let last = UserDefaults.standard.string(forKey: "lastDeck") { p.directoryURL = URL(fileURLWithPath: last).deletingLastPathComponent() }
        guard p.runModal() == .OK, let u = p.url else { return }
        do {
            if u.pathExtension.lowercased() == "manimble" {
                open(deck: try PortableProject.unpackArchive(u).path)
            } else if let deck = try PortableProject.deckURL(in: u) {
                open(deck: deck.path)
            } else if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                open(deck: u.path)
            } else {
                alert("Could not open project", "Choose a deck folder or a .manimble package.")
            }
        } catch { alert("Could not open project", "\(error.localizedDescription)") }
    }

    @objc func saveProjectFolderPressed() {
        guard let ws = workspace else { return }
        let panel = NSOpenPanel()
        panel.title = "Save a Portable Project Folder"
        panel.message = "Choose where Manimble should create the project folder."
        panel.prompt = "Save Project Here"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        var name = ws.projectName
        var destination = parent.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            name = "\(ws.projectName) (\(suffix))"
            destination = parent.appendingPathComponent(name)
            suffix += 1
        }
        savePortableProject(workspace: ws, destination: destination, archive: false)
    }

    @objc func packageProjectPressed() {
        guard let ws = workspace else { return }
        let panel = NSSavePanel()
        panel.title = "Package Project for Sharing"
        panel.message = "Create one portable .manimble file that includes the deck and its checked dependencies."
        panel.nameFieldStringValue = ws.projectName + ".manimble"
        if let projectType = UTType(filenameExtension: "manimble") { panel.allowedContentTypes = [projectType] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var destination = panel.url else { return }
        if destination.pathExtension.lowercased() != "manimble" { destination.appendPathExtension("manimble") }
        savePortableProject(workspace: ws, destination: destination, archive: true)
    }

    private func savePortableProject(workspace ws: Workspace, destination: URL, archive: Bool) {
        Task { @MainActor in
            busyText = "Checking slide dependencies…"
            busy += 1
            defer { busy -= 1; busyText = "Rendering…" }
            do {
                let report = try await engine.call("dependency_report", as: DependencyReportResult.self)
                guard report.scannedScenes == report.totalScenes else {
                    alert("Dependency scan incomplete", "Manimble checked \(report.scannedScenes) of \(report.totalScenes) slides. Please try again.")
                    return
                }
                if !report.failures.isEmpty {
                    let details = report.failures.prefix(5).map { "\($0.scene): \($0.error)" }.joined(separator: "\n")
                    let a = NSAlert()
                    a.alertStyle = .warning
                    a.messageText = "Some slides did not render during the dependency check"
                    a.informativeText = "Manimble found dependencies in \(report.scannedScenes) slides, but the package may be incomplete.\n\n\(details)\n\nContinue with the project copy?"
                    a.addButton(withTitle: "Continue Anyway"); a.addButton(withTitle: "Cancel")
                    guard a.runModal() == .alertFirstButtonReturn else { return }
                }
                if archive {
                    try PortableProject.createArchive(workspace: ws, dependencies: report.dependencies, at: destination)
                } else {
                    try PortableProject.createFolder(workspace: ws, dependencies: report.dependencies, at: destination)
                }
                toast(archive ? "Packaged \(destination.lastPathComponent)" : "Saved project folder \(destination.lastPathComponent)")
            } catch { alert("Could not save portable project", "\(error.localizedDescription)") }
        }
    }

    func open(deck: String) {
        guard engine.isRunning else {
            pendingDeck = deck
            busyPill.show("Waiting for Manimble engine…", symbol: nil, tint: nil, spinning: true)
            return
        }
        guard confirmClose(for: "opening another deck") else { return }
        Task { @MainActor in
            busy += 1
            defer { busy -= 1 }
            do {
                let ws = try Workspace(deck: deck)
                workspace?.discard()
                workspace = ws
                if terminal.hasStarted { terminal.start(in: ws.work.path, original: ws.original.path) }
                _ = try await engine.raw("open", ["deck": ws.work.path, "cache": Workspace.cacheDir(for: ws.original)])
                UserDefaults.standard.set(deck, forKey: "lastDeck")
                sceneName = nil; scene = nil; selection = nil
                canvas.stop = nil
                await reloadState()
                if let first = state?.scenes.first { await selectScene(first.name) }
                updateDocumentState()
            } catch { alert("Could not open deck", "\(error)") }
        }
    }

    // MARK: working copy

    func updateDocumentState() {
        guard let ws = workspace else { return }
        let m = ws.isModified
        window.isDocumentEdited = m
        window.title = ws.original.deletingLastPathComponent().lastPathComponent + " / " + ws.original.lastPathComponent
        window.subtitle = m ? "Edited — not saved to the original" : "Manimble"
    }

    @objc func saveToOriginal() {
        guard let ws = workspace else { return }
        if !ws.isModified { toast("Nothing to save"); return }
        if !ws.conflictFiles.isEmpty {
            let a = NSAlert(); a.alertStyle = .warning
            a.messageText = "The original changed on disk"
            a.informativeText = "\(ws.conflictFiles.joined(separator: ", ")) was modified outside Manimble since this copy was made. Overwrite it with your edits?"
            a.addButton(withTitle: "Overwrite"); a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        do { try ws.save(); toast("Saved to \(ws.original.path)"); updateDocumentState() }
        catch { alert("Could not save", "\(error)") }
    }

    @objc func revertToOriginal() {
        guard let ws = workspace, ws.isModified else { toast("No changes to revert"); return }
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = "Discard all unsaved edits?"
        a.informativeText = "The working copy goes back to the last saved version of the deck."
        a.addButton(withTitle: "Revert"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        submit { [weak self] in
            guard let self = self, let ws = self.workspace else { return }
            try? ws.revert()
            self.lastChanged = nil
            if let n = self.sceneName { await self.loadScene(n, keepStop: true) }
            await self.reloadState()
            self.updateDocumentState()
            self.toast("Reverted")
        }
    }

    /// Ask what to do with unsaved edits. Returns false if the user cancelled.
    func confirmClose(for what: String) -> Bool {
        guard let ws = workspace, ws.isModified else { return true }
        let a = NSAlert()
        a.messageText = "Save your edits to \(ws.original.lastPathComponent)?"
        a.informativeText = "You are editing a working copy. Before \(what), save it to the original or discard the changes."
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Discard Changes"); a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            if !ws.conflictFiles.isEmpty {
                let c = NSAlert(); c.alertStyle = .warning
                c.messageText = "The original changed on disk"
                c.informativeText = "\(ws.conflictFiles.joined(separator: ", ")) was modified outside Manimble. Overwrite it?"
                c.addButton(withTitle: "Overwrite"); c.addButton(withTitle: "Cancel")
                if c.runModal() != .alertFirstButtonReturn { return false }
            }
            do { try ws.save(); return true } catch { alert("Could not save", "\(error)"); return false }
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func finish() { engine.stop(); workspace?.discard(); workspace = nil }

    func handleEvent(_ ev: [String: Any]) {
        if ev["event"] as? String == "import" {
            switch ev["phase"] as? String {
            case "building":
                busyPill.show("Importing slide \((ev["done"] as? Int ?? 0) + 1)/\(ev["total"] as? Int ?? 0)…", symbol: nil, tint: nil, spinning: true)
            case "done":
                busyPill.hide()
                let n = ev["slides"] as? Int ?? 0
                let warn = (ev["warnings"] as? [String]) ?? []
                toast("Imported \(n) slides" + (warn.isEmpty ? "" : " — " + warn.prefix(2).joined(separator: "; ")), error: !warn.isEmpty)
                if let d = ev["deck"] as? String { open(deck: d) }
            default:
                busyPill.hide(); toast(ev["error"] as? String ?? "import failed", error: true)
            }
            return
        }
        if ev["event"] as? String == "export" {
            switch ev["phase"] as? String {
            case "building":
                let done = (ev["done"] as? Int ?? 0) + 1, total = ev["total"] as? Int ?? 0
                busyPill.show("Exporting slide \(done)/\(total)…", symbol: nil, tint: nil, spinning: true)
            case "keynote":
                busyPill.show("Opening in Keynote…", symbol: nil, tint: nil, spinning: true)
            case "done":
                busyPill.hide()
                if let p = ev["path"] as? String {
                    toast("Exported \((p as NSString).lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                }
            default:
                busyPill.hide(); toast(ev["error"] as? String ?? "export failed", error: true)
            }
            return
        }
        if ev["event"] as? String == "present" {
            switch ev["phase"] as? String {
            case "building":
                let done = (ev["done"] as? Int ?? 0) + 1, total = ev["total"] as? Int ?? 0
                busyPill.show("Building slides for Manim Slides \(done)/\(total): \(ev["scene"] as? String ?? "")", symbol: nil, tint: nil, spinning: true)
            case "playing":
                busyPill.hide(); toast("Manim Slides presenter launched")
            default:
                busyPill.hide(); toast(ev["error"] as? String ?? "presenter failed", error: true)
            }
            return
        }
        guard ev["event"] as? String == "rendered" else { return }
        if !pendingStateRefresh {
            pendingStateRefresh = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.pendingStateRefresh = false
                Task { @MainActor in await self.reloadState() }
            }
        }
    }

    // MARK: state / scenes

    func reloadState() async {
        guard let st = try? await engine.call("state", ["current": sceneName ?? ""], as: StateInfo.self) else { return }
        let old = state
        state = st
        // reload only the rows that changed
        if let old = old, old.scenes.count == st.scenes.count {
            var changed = IndexSet()
            for (i, (a, b)) in zip(old.scenes, st.scenes).enumerated() where a.thumb != b.thumb || a.status != b.status || a.stops != b.stops { changed.insert(i) }
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
        } else {
            suppressTable = true; table.reloadData(); suppressTable = false
            if let n = sceneName, let i = st.scenes.firstIndex(where: { $0.name == n }) { selectRow(i) }
        }
        updateDocumentState()
        // the slide on screen was re-rendered (an edit from outside, e.g. Claude in the terminal): show it
        if let n = sceneName, busy == 0, let cur = st.scenes.first(where: { $0.name == n }), cur.status == "ready",
           let t = cur.thumb, let shown = shownDir, URL(fileURLWithPath: t).deletingLastPathComponent().path != shown {
            await loadScene(n, keepStop: true)
        }
    }

    func selectRow(_ i: Int) {
        suppressTable = true
        table.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
        table.scrollRowToVisible(i)
        suppressTable = false
        refreshRings()
    }

    func selectScene(_ name: String) async {
        sceneName = name; stopIndex = 0; selection = nil
        refreshRings()
        canvas.overrides = [:]; canvas.lineOverrides = [:]; canvas.selection = nil
        if let i = state?.scenes.firstIndex(where: { $0.name == name }) { selectRow(i) }
        await loadScene(name, keepStop: false)
    }

    func loadScene(_ name: String, keepStop: Bool) async {
        busy += 1
        defer { busy -= 1 }
        guard let sc = try? await engine.call("scene", ["name": name], as: SceneData.self), name == sceneName else { return }
        if let old = scene, old.name == name, old.stops?.first?.png != sc.stops?.first?.png { canvas.dropTextures() }
        if sc.status != "ready" || sc.stops == nil {
            // keep showing the last good frame instead of a blank canvas
            if scene?.name != name || scene?.stops == nil { canvas.stop = nil; scene = sc }
            canvas.overrides = [:]
            toast("Slide failed to render: " + (sc.error ?? "unknown error").split(separator: "\n").suffix(3).joined(separator: " "), error: true)
            showSourceError(sc.error ?? "scene not ready")
            return
        }
        scene = sc
        shownDir = URL(fileURLWithPath: sc.stops![0].png).deletingLastPathComponent().path
        stopIndex = keepStop ? min(stopIndex, sc.stops!.count - 1) : 0
        if let sel = selection, sc.objects?[String(sel)] == nil { selection = nil }
        applyStop()
        canvas.overrides = [:]; canvas.lineOverrides = [:]
        if ProcessInfo.processInfo.environment["MANIMBLE_SELFTEST"] != nil { selfTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_PLAY"] != nil, !testRan { testRan = true; playTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_TERM"] != nil, !testRan { testRan = true; termTest() }
        if let tcase = ProcessInfo.processInfo.environment["MANIMBLE_TEST_FORMULA"], !testRan { testRan = true; formulaTest(tcase) }
        rebuildSteps()
        renderSource()
        rebuildInspector()
    }

    func applyStop() {
        guard let sc = scene, let stops = sc.stops else { return }
        canvas.frameSize = CGSize(width: sc.size?[0] ?? 1280, height: sc.size?[1] ?? 720)
        canvas.sceneObjects = sc.objects ?? [:]
        canvas.stop = stops[stopIndex]
        canvas.selection = selection
    }

    /// Headless reproduction of "edit formula -> Apply": MANIMBLE_TEST_FORMULA=scene:stop:newtex
    func formulaTest(_ spec: String) {
        let parts = spec.components(separatedBy: ":")
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_SELFTEST"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "test.log") }
        Task { @MainActor in
            await selectScene(parts[0])
            stopIndex = Int(parts[1]) ?? 0; applyStop()
            guard let id = (scene?.objects ?? [:]).filter({ $0.value.kind == "tex" && $0.value.textOk == true }).keys.compactMap({ Int($0) }).sorted().first else { log("no formula"); return }
            log("before: visible=\(canvas.stop?.visible.count ?? -1)")
            commitText(id, parts[2], shared: false)
            for i in 0..<30 {
                try? await Task.sleep(nanoseconds: 300_000_000)
                log("t=\(i): busy=\(busy) overrides=\(canvas.overrides.count) toast=\(toastPill.isHidden ? "-" : toastPill.label.stringValue)")
                if i == 3, let img = canvas.snapshot() {
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "during.png"))
                }
            }
            if let img = canvas.snapshot() {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "after.png"))
            }
            log("done")
        }
    }

    func termTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_SELFTEST"] ?? "/tmp") + "/"
        Task { @MainActor in
            toggleTerminal()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            terminal.type("echo TERM_OK $MANIMBLE_DECK; ls | head -3; which claude\r")
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            try? terminal.contents().write(toFile: dir + "term.txt", atomically: true, encoding: .utf8)
            if let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "term.png"))
            }
            try? "hidden=\(terminal.isHidden)".write(toFile: dir + "term.log", atomically: true, encoding: .utf8)
            toggleTerminal()
            try? "hidden-after=\(terminal.isHidden)".appendLine(to: dir + "term.log")
        }
    }

    func playTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_SELFTEST"] ?? "/tmp") + "/"
        Task { @MainActor in
            playFromCurrent()
            for _ in 0..<80 { try? await Task.sleep(nanoseconds: 500_000_000); if player != nil { break } }
            guard let p = player else { try? "no player".write(toFile: dir + "play.log", atomically: true, encoding: .utf8); return }
            func dump(_ name: String) {
                guard let v = p.window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
            }
            try? await Task.sleep(nanoseconds: 800_000_000); dump("play1.png")
            p.next(); try? await Task.sleep(nanoseconds: 900_000_000); dump("play2.png")
            p.exit()
            try? "ok player=\(player == nil)".write(toFile: dir + "play.log", atomically: true, encoding: .utf8)
        }
    }

    func selfTest() {
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_SPLIT"] != nil, let sp = mainSplit {
            let dir = (ProcessInfo.processInfo.environment["MANIMBLE_SELFTEST"] ?? "/tmp") + "/"
            func w() -> String { sp.subviews.map { String(Int($0.frame.width)) }.joined(separator: "/") }
            var out = "start \(w())\n"
            sp.setPosition(320, ofDividerAt: 0); sp.layoutSubtreeIfNeeded(); out += "drag to 320 -> \(w())\n"
            sp.setPosition(200, ofDividerAt: 0); sp.layoutSubtreeIfNeeded(); out += "drag to 200 -> \(w())\n"
            try? out.write(toFile: dir + "split.log", atomically: true, encoding: .utf8)
        }
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_SELFTEST"] ?? "/tmp") + "/"
        func save(_ name: String) {
            guard let img = canvas.snapshot() else { return }
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
        }
        canvas.showObjects = false
        if let side = sideScroll {
            let info = "side.frame=\(side.frame.width) content=\(side.contentSize.width) col=\(table.tableColumns.first?.width ?? -1) table.frame=\(table.frame.width) box=\(side.superview?.frame.width ?? -1) split=\(mainSplit?.subviews.map { Int($0.frame.width) } ?? [])\n"
            try? info.write(toFile: dir + "side.log", atomically: true, encoding: .utf8)
        }
        save("exact.png")
        func saveView(_ name: String) {
            guard let img = canvas.snapshotView() else { return }
            try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
        }
        if let v = canvas.stop?.visible.first { canvas.overrides[Int(v[0])] = Override(dx: 120, dy: 60, scale: 1.3) }
        canvas.selection = canvas.stop?.visible.first.map { Int($0[0]) }
        save("composite.png")
        canvas.overrides = [:]; canvas.selection = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            if let o = canvas.stop?.visible.dropFirst(2).first { selection = Int(o[0]); canvas.selection = selection }
            saveView("view.png")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            if let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                if let o = canvas.stop?.visible.first { selection = Int(o[0]); canvas.selection = selection }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "window.png"))
            }
        }
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { state?.scenes.count ?? 0 }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard let s = state?.scenes[row] else { return nil }
        let cell = (tv.makeView(withIdentifier: SlideCell.id, owner: nil) as? SlideCell) ?? SlideCell()
        var img: NSImage?
        if let t = s.thumb {
            img = thumbCache.object(forKey: t as NSString)
            if img == nil, let i = NSImage(contentsOfFile: t) { thumbCache.setObject(i, forKey: t as NSString); img = i }
        }
        cell.configure(number: row + 1, name: s.name, image: img, status: s.status, stops: s.stops ?? 0, active: s.name == sceneName)
        _ = tv
        return cell
    }

    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FlatRowView() }

    /// Keep the single column exactly as wide as the sidebar so thumbnails never run off the edge.
    func fitSidebarColumn() {
        guard let side = sideScroll, let col = table.tableColumns.first else { return }
        let w = max(120, side.contentSize.width)
        if abs(col.width - w) > 0.5 { col.width = w }
    }

    func refreshRings() {
        for r in 0..<(state?.scenes.count ?? 0) {
            (table.view(atColumn: 0, row: r, makeIfNecessary: false) as? SlideCell)?.setActive(state?.scenes[r].name == sceneName)
        }
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        if suppressTable { return }
        let r = table.selectedRow
        guard r >= 0, let s = state?.scenes[r], s.name != sceneName else { return }
        Task { @MainActor in await selectScene(s.name) }
    }

    // MARK: steps strip

    func rebuildSteps() {
        stepsBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let stops = scene?.stops, stops.count > 1 else { return }
        let l = NSTextField(labelWithString: "BUILDS"); l.textColor = NSColor(white: 1, alpha: 0.45); l.font = Theme.font(10, .semibold)
        stepsBar.addArrangedSubview(l)
        for (i, st) in stops.enumerated() {
            let b = StepButton(path: st.png, index: i, active: i == stopIndex) { [weak self] in
                guard let self = self else { return }
                self.stopIndex = i; self.canvas.overrides = [:]; self.canvas.lineOverrides = [:]; self.applyStop(); self.rebuildSteps(); self.rebuildInspector()
            }
            stepsBar.addArrangedSubview(b)
        }
    }

    // MARK: inspector

    func label(_ s: String) -> NSTextField { fieldLabel(s) }

    func inspectorHeader(symbol: String, title: String, detail: String?) -> NSView {
        let img = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        img.symbolConfiguration = .init(pointSize: 15, weight: .medium); img.contentTintColor = Theme.accent
        let t = NSTextField(labelWithString: title); t.font = Theme.font(14, .semibold)
        let d = NSTextField(labelWithString: detail ?? ""); d.font = Theme.mono(10); d.textColor = .tertiaryLabelColor
        let col = NSStackView(views: [t, d]); col.orientation = .vertical; col.alignment = .leading; col.spacing = 0
        let row = NSStackView(views: [img, col]); row.spacing = 9; row.alignment = .centerY
        return row
    }

    func rebuildInspector() {
        inspector.arrangedSubviews.forEach { $0.removeFromSuperview() }
        textField = nil; sizeField = nil; colorWell = nil
        func width(_ v: NSView) { v.widthAnchor.constraint(equalToConstant: 292).isActive = true }
        guard let sel = selection, let sc = scene, let o = sc.objects?[String(sel)] else {
            inspector.addArrangedSubview(inspectorHeader(symbol: "rectangle.on.rectangle", title: "Slide", detail: sceneName))
            inspector.addArrangedSubview(hairline())
            let tips = ["Click an element to edit it", "Double-click text to retype, a formula for LaTeX", "Drag to move · drag a handle to resize",
                        "Arrow keys nudge · ⇧ for bigger steps", "⌘Z undo · ⌘↑ ⌘↓ slides · ⌘[ ⌘] builds"]
            for tip in tips {
                let t = NSTextField(wrappingLabelWithString: tip); t.font = Theme.font(12); t.textColor = .secondaryLabelColor; width(t)
                inspector.addArrangedSubview(t)
            }
            return
        }
        let kind = ["text": "TEXT", "tex": "FORMULA", "image": "IMAGE", "line": (o.shape ?? "LINE").uppercased(), "shape": (o.shape ?? "SHAPE").uppercased(), "table": "TABLE"][o.kind] ?? o.kind.uppercased()
        let symbols = ["text": "textformat", "tex": "function", "image": "photo", "line": "line.diagonal", "shape": "square.on.circle", "table": "tablecells"]
        inspector.addArrangedSubview(inspectorHeader(symbol: symbols[o.kind] ?? "square", title: kind.capitalized, detail: o.loc))
        inspector.addArrangedSubview(hairline())
        if o.kind == "text" {
            if o.textOk == true {
                inspector.addArrangedSubview(label("Text"))
                let f = NSTextField(string: o.value); f.delegate = self; f.target = self; f.action = #selector(textCommitted(_:))
                f.usesSingleLineMode = false; f.cell?.wraps = true; f.cell?.isScrollable = false
                f.lineBreakMode = .byWordWrapping; width(f); f.maximumNumberOfLines = 4
                textField = f; inspector.addArrangedSubview(f)
                sharedRow(o)
            } else {
                let t = NSTextField(wrappingLabelWithString: "Text is generated by code (\(o.textNote ?? "computed")); edit it in the source.")
                t.textColor = .systemOrange; width(t); inspector.addArrangedSubview(t)
            }
            styleFields(o, width)
        } else if o.kind == "tex" {
            let b = NSButton(title: "Edit LaTeX…", target: self, action: #selector(editLatexPressed)); inspector.addArrangedSubview(b)
            let t = NSTextField(wrappingLabelWithString: o.value)
            t.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular); t.isSelectable = true; width(t)
            inspector.addArrangedSubview(t)
            if o.textOk != true {
                let n = NSTextField(wrappingLabelWithString: "Formula is generated by code (\(o.textNote ?? "computed")).")
                n.textColor = .systemOrange; width(n); inspector.addArrangedSubview(n)
            }
            styleFields(o, width)
        } else if o.kind == "table" {
            for v in tableEditor(o, width: width) { inspector.addArrangedSubview(v) }
        } else if o.kind == "image" {
            inspector.addArrangedSubview(label("File")); inspector.addArrangedSubview(NSTextField(labelWithString: o.image ?? ""))
        } else {
            let w = NSColorWell(); w.color = NSColor(hex: o.color ?? "#FFFFFF")
            w.target = self; w.action = #selector(colorCommitted(_:))
            w.widthAnchor.constraint(equalToConstant: 60).isActive = true; w.heightAnchor.constraint(equalToConstant: 26).isActive = true
            inspector.addArrangedSubview(label("Color")); inspector.addArrangedSubview(w)
            if o.kind == "line" {
                let n = NSTextField(wrappingLabelWithString: "Drag an end handle to change the line. Hold ⇧ to snap the angle.")
                n.textColor = .secondaryLabelColor; width(n); inspector.addArrangedSubview(n)
            }
        }
        if let b = canvas.stop?.box(of: sel) { geometryRows(b) }
        if o.siblings > 1 {
            let n = NSTextField(wrappingLabelWithString: "Created in a loop/helper: \(o.siblings) objects share this source line.")
            n.textColor = .systemOrange; width(n); inspector.addArrangedSubview(n)
        }
    }

    func sharedRow(_ o: ObjInfo) {
        guard let sh = o.shared else { return }
        let c = NSButton(checkboxWithTitle: "Change everywhere (\(sh.name) in \(sh.rel), used \(sh.uses)×)", target: self, action: #selector(sharedToggled(_:)))
        c.state = sharedChoice ? .on : .off
        c.font = .systemFont(ofSize: 11)
        inspector.addArrangedSubview(c)
    }
    @objc func sharedToggled(_ b: NSButton) { sharedChoice = b.state == .on }

    func styleFields(_ o: ObjInfo, _ width: (NSView) -> Void) {
        inspector.addArrangedSubview(sectionLabel("Appearance"))
        if o.kind == "text" {
            // family
            let pop = NSPopUpButton(frame: .zero, pullsDown: false)
            let fams = NSFontManager.shared.availableFontFamilies
            pop.addItems(withTitles: fams)
            if let f = o.font { if !fams.contains(f) { pop.insertItem(withTitle: f, at: 0) }; pop.selectItem(withTitle: f) }
            pop.target = self; pop.action = #selector(familyChanged(_:)); width(pop)
            pop.toolTip = "The font is usually a deck-wide constant, so this changes it for every slide."
            inspector.addArrangedSubview(label("Font")); inspector.addArrangedSubview(pop)
            // bold / italic
            func toggle(_ title: String, _ on: Bool, _ sel: Selector, _ font: NSFont) -> NSButton {
                let b = NSButton(title: title, target: self, action: sel)
                b.setButtonType(.pushOnPushOff); b.bezelStyle = .texturedRounded; b.state = on ? .on : .off
                b.font = font; b.widthAnchor.constraint(equalToConstant: 34).isActive = true
                return b
            }
            let bold = toggle("B", o.weight?.uppercased() == "BOLD", #selector(boldToggled(_:)), .boldSystemFont(ofSize: 13))
            let italic = toggle("I", ["ITALIC", "OBLIQUE"].contains(o.slant?.uppercased() ?? ""), #selector(italicToggled(_:)),
                                NSFontManager.shared.convert(.systemFont(ofSize: 13), toHaveTrait: .italicFontMask))
            let row = NSStackView(views: [bold, italic]); row.spacing = 6
            inspector.addArrangedSubview(label("Style")); inspector.addArrangedSubview(row)
        }
        let size = NSTextField(string: String(format: "%.1f", o.fontSize ?? 0))
        size.target = self; size.action = #selector(sizeCommitted(_:)); sizeField = size
        let stepper = NSStepper(); stepper.minValue = 4; stepper.maxValue = 300; stepper.increment = 1
        stepper.doubleValue = o.fontSize ?? 30; stepper.target = self; stepper.action = #selector(sizeStepped(_:))
        size.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let sizeRow = NSStackView(views: [size, stepper]); sizeRow.spacing = 6
        inspector.addArrangedSubview(label("Size")); inspector.addArrangedSubview(sizeRow)
        let w = NSColorWell(); w.color = NSColor(hex: o.color ?? "#FFFFFF")
        w.target = self; w.action = #selector(colorCommitted(_:))
        w.widthAnchor.constraint(equalToConstant: 60).isActive = true; w.heightAnchor.constraint(equalToConstant: 26).isActive = true
        colorWell = w
        inspector.addArrangedSubview(label("Color")); inspector.addArrangedSubview(w)
    }

    func geometryRows(_ b: Box) {
        inspector.addArrangedSubview(hairline())
        inspector.addArrangedSubview(sectionLabel("Arrange"))
        func row(_ a: (String, Double, Selector), _ c: (String, Double, Selector)) {
            let fa = NSTextField(string: String(Int(a.1.rounded()))), fc = NSTextField(string: String(Int(c.1.rounded())))
            fa.target = self; fa.action = a.2; fc.target = self; fc.action = c.2
            fa.widthAnchor.constraint(equalToConstant: 80).isActive = true; fc.widthAnchor.constraint(equalToConstant: 80).isActive = true
            let sa = NSStackView(views: [label(a.0), fa]); sa.orientation = .vertical; sa.alignment = .leading; sa.spacing = 2
            let sc = NSStackView(views: [label(c.0), fc]); sc.orientation = .vertical; sc.alignment = .leading; sc.spacing = 2
            let r = NSStackView(views: [sa, sc]); r.spacing = 16; inspector.addArrangedSubview(r)
        }
        row(("X (px)", b.cx, #selector(xCommitted(_:))), ("Y (px)", b.cy, #selector(yCommitted(_:))))
        row(("Width", b.w, #selector(wCommitted(_:))), ("Height", b.h, #selector(hCommitted(_:))))
    }

    @objc func xCommitted(_ f: NSTextField) { if let s = selection, let b = canvas.stop?.box(of: s) { commitMove(s, f.doubleValue - b.cx, 0) } }
    @objc func yCommitted(_ f: NSTextField) { if let s = selection, let b = canvas.stop?.box(of: s) { commitMove(s, 0, f.doubleValue - b.cy) } }
    @objc func wCommitted(_ f: NSTextField) { if let s = selection, let b = canvas.stop?.box(of: s), b.w > 0 { commitResize(s, f.doubleValue / b.w) } }
    @objc func hCommitted(_ f: NSTextField) { if let s = selection, let b = canvas.stop?.box(of: s), b.h > 0 { commitResize(s, f.doubleValue / b.h) } }

    // MARK: edits

    var objInfo: ObjInfo? { selection.flatMap { scene?.objects?[String($0)] } }

    /// Run edit operations strictly one after another.
    func submit(_ work: @escaping @MainActor () async -> Void) {
        let prev = queueTail
        queueTail = Task { @MainActor in await prev?.value; await work() }
    }

    func runEdit(_ req: [String: Any]) async {
        guard let name = sceneName else { return }
        busy += 1
        var r = req; r["scene"] = name; r["stop"] = stopIndex
        var result: EditResult?
        var failure: String?
        do { result = try await engine.call("edit", r, as: EditResult.self) } catch { failure = "\(error)" }
        busy -= 1
        if let res = result, res.ok == true {
            lastChanged = res.changed
            var msg = res.message == "no change" ? "No change" : "Saved · \(res.message ?? "")"
            if let n = res.siblings { msg += " (\(n) similar objects share this line; all moved)" }
            toast(msg)
        } else {
            toast(failure ?? result?.error ?? "edit failed", error: true)
            lastChanged = nil
        }
        await loadScene(name, keepStop: true)
        await reloadState()
    }

    func commitMove(_ oid: Int, _ dx: Double, _ dy: Double) {
        submit { [weak self] in await self?.runEdit(["op": "move", "oid": oid, "dx": dx, "dy": dy]) }
    }
    func commitEndpoints(_ oid: Int, _ e: [Double]) {
        submit { [weak self] in await self?.runEdit(["op": "endpoints", "oid": oid, "sx": e[0], "sy": e[1], "ex": e[2], "ey": e[3]]) }
    }
    func commitResize(_ oid: Int, _ ratio: Double) {
        if canvas.overrides[oid] == nil { canvas.overrides[oid] = Override(scale: ratio) }
        submit { [weak self] in await self?.runEdit(["op": "resize", "oid": oid, "ratio": ratio]) }
    }

    func nudgeObject(_ oid: Int, _ dx: Double, _ dy: Double) {
        nudge.dx += dx; nudge.dy += dy
        var o = canvas.overrides[oid] ?? Override()
        o.dx = nudge.dx; o.dy = nudge.dy
        canvas.overrides[oid] = o
        nudgeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let (a, b) = (self.nudge.dx, self.nudge.dy); self.nudge = (0, 0)
            self.commitMove(oid, a, b)
        }
        nudgeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }

    /// Show a freshly rasterised text/formula at once, then patch the source.
    func previewSprite(_ oid: Int, kind: String, value: String, size: Double, color: String?, font: String?,
                       weight: String? = nil, slant: String? = nil) async {
        var args: [String: Any] = ["kind": kind, "value": value, "font_size": size]
        if let c = color { args["color"] = c }
        if let f = font { args["font"] = f }
        if let w = weight { args["weight"] = w }
        if let sl = slant { args["slant"] = sl }
        guard let sp = try? await engine.call("sprite", args, as: SpriteResult.self), let path = sp.path,
              let tex = canvas.texture(path: path), let w = sp.w, let h = sp.h else { return }
        var o = canvas.overrides[oid] ?? Override()
        o.replacement = (tex, w, h)
        canvas.overrides[oid] = o
    }

    func commitText(_ oid: Int, _ value: String, shared: Bool) {
        guard let o = scene?.objects?[String(oid)], value != o.value else { return }
        submit { [weak self] in
            guard let self = self else { return }
            await self.previewSprite(oid, kind: o.kind, value: value, size: o.fontSize ?? 30, color: o.color, font: o.font, weight: o.weight, slant: o.slant)
            await self.runEdit(["op": "text", "oid": oid, "value": value, "shared": shared])
        }
    }

    @objc func textCommitted(_ f: NSTextField) { if let s = selection { commitText(s, f.stringValue, shared: sharedChoice) } }

    @objc func sizeCommitted(_ f: NSTextField) {
        guard let s = selection, let o = objInfo, f.doubleValue >= 4 else { return }
        let v = f.doubleValue
        submit { [weak self] in
            guard let self = self else { return }
            await self.previewSprite(s, kind: o.kind, value: o.value, size: v, color: o.color, font: o.font, weight: o.weight, slant: o.slant)
            await self.runEdit(["op": "font", "oid": s, "value": v])
        }
    }

    @objc func sizeStepped(_ st: NSStepper) {
        sizeField?.doubleValue = st.doubleValue
        if let f = sizeField { sizeCommitted(f) }
    }

    func commitStyle(font: String? = nil, weight: String? = nil, slant: String? = nil) {
        guard let s = selection, let o = objInfo else { return }
        submit { [weak self] in
            guard let self = self else { return }
            await self.previewSprite(s, kind: o.kind, value: o.value, size: o.fontSize ?? 30, color: o.color,
                                     font: font ?? o.font, weight: weight ?? o.weight, slant: slant ?? o.slant)
            var req: [String: Any] = ["op": "style", "oid": s, "shared": true]
            if let f = font { req["font"] = f }
            if let w = weight { req["weight"] = w }
            if let sl = slant { req["slant"] = sl }
            await self.runEdit(req)
        }
    }
    @objc func familyChanged(_ p: NSPopUpButton) { if let t = p.titleOfSelectedItem { commitStyle(font: t) } }
    @objc func boldToggled(_ b: NSButton) { commitStyle(weight: b.state == .on ? "BOLD" : "NORMAL") }
    @objc func italicToggled(_ b: NSButton) { commitStyle(slant: b.state == .on ? "ITALIC" : "NORMAL") }

    @objc func colorCommitted(_ w: NSColorWell) {
        guard let s = selection, let o = objInfo else { return }
        let hex = w.color.hexString
        submit { [weak self] in
            guard let self = self else { return }
            if o.kind == "text" || o.kind == "tex" { await self.previewSprite(s, kind: o.kind, value: o.value, size: o.fontSize ?? 30, color: hex, font: o.font, weight: o.weight, slant: o.slant) }
            await self.runEdit(["op": "color", "oid": s, "value": hex])
        }
    }

    func beginEdit(_ oid: Int) {
        guard let o = scene?.objects?[String(oid)] else { return }
        if o.kind == "tex" { openLatex(oid) }
        else if o.kind == "text", o.textOk == true, let f = textField { window.makeFirstResponder(f); f.selectText(nil) }
    }
    @objc func editLatexPressed() { if let s = selection { openLatex(s) } }

    // MARK: LaTeX sheet

    var latexSheet: LatexSheet?
    func openLatex(_ oid: Int) {
        guard let o = scene?.objects?[String(oid)], o.kind == "tex" else { return }
        if o.textOk != true { toast("This formula is generated by code: \(o.textNote ?? "")", error: true); return }
        let sheet = LatexSheet(initial: o.value, shared: o.shared,
                               render: { [weak self] tex in
                                   guard let self = self else { return (nil, "no engine") }
                                   do {
                                       let r = try await self.engine.call("sprite", ["kind": "tex", "value": tex, "font_size": 40.0, "color": "#FFFFFF"], as: SpriteResult.self)
                                       if let e = r.error { return (nil, e) }
                                       return (r.path, nil)
                                   } catch { return (nil, "\(error)") }
                               },
                               apply: { [weak self] tex, shared in self?.commitText(oid, tex, shared: shared) })
        latexSheet = sheet
        window.beginSheet(sheet.window) { [weak self] _ in self?.latexSheet = nil }
    }

    // MARK: source pane

    func renderSource() {
        guard let src = scene?.source else { sourceView.string = ""; return }
        srcHeader.stringValue = "PYTHON  ·  \(src.file):\(src.start)"
        let chg = lastChanged ?? src.changed
        var changed = Set<Int>()
        if let c = chg, c.file == src.file { for r in c.ranges ?? [] where r.count == 2 { for n in r[0]...max(r[0], r[1]) { changed.insert(n) } } }
        let lines = src.text.components(separatedBy: "\n")
        let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        var curLine: Int?
        if let sel = selection, let o = scene?.objects?[String(sel)] {
            let parts = o.loc.split(separator: ":"); if parts.count == 2, String(parts[0]) == src.file { curLine = Int(parts[1]) }
        }
        var firstChanged: Int?
        for i in 0..<lines.count where changed.contains(src.start + i) { firstChanged = src.start + i; break }
        // line numbers via ruler-less prefix: prepend to each line
        let numbered = NSMutableAttributedString()
        for (i, t) in lines.enumerated() {
            let n = src.start + i
            var bg: NSColor = .clear
            if changed.contains(n) { bg = NSColor.systemGreen.withAlphaComponent(0.28) } else if n == curLine { bg = NSColor.systemBlue.withAlphaComponent(0.25) }
            let numAttr: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor(white: 0.5, alpha: 1), .backgroundColor: bg]
            let txtAttr: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor(white: 0.9, alpha: 1), .backgroundColor: bg]
            numbered.append(NSAttributedString(string: String(format: "%5d  ", n), attributes: numAttr))
            numbered.append(highlight(t + "\n", bg: bg)); _ = txtAttr
        }
        sourceView.textStorage?.setAttributedString(numbered)
        if let target = firstChanged ?? curLine {
            let idx = target - src.start
            var loc = 0
            for k in 0..<min(idx, lines.count) { loc += 7 + lines[k].utf16.count + 1 }
            sourceView.scrollRangeToVisible(NSRange(location: min(loc, numbered.length), length: 0))
        }
    }
    // Python syntax colouring (dark palette)
    static let pyKeywords = try! NSRegularExpression(pattern: "\\b(def|class|self|for|in|if|elif|else|return|import|from|as|with|while|and|or|not|None|True|False|lambda|pass|yield|try|except|raise|is|assert|break|continue)\\b")
    static let pyNumbers = try! NSRegularExpression(pattern: "(?<![\\w.])\\d+(\\.\\d+)?")
    static let pyStrings = try! NSRegularExpression(pattern: "[rbf]?(\"[^\"\\n]*\"|'[^'\\n]*')")
    static let pyCalls = try! NSRegularExpression(pattern: "\\b([A-Za-z_][A-Za-z_0-9]*)(?=\\()")
    static let pyConsts = try! NSRegularExpression(pattern: "\\b[A-Z][A-Z0-9_]{2,}\\b")

    func highlight(_ line: String, bg: NSColor) -> NSAttributedString {
        let mono = Theme.mono(11.5)
        let out = NSMutableAttributedString(string: line, attributes: [.font: mono, .foregroundColor: NSColor(white: 0.88, alpha: 1), .backgroundColor: bg])
        let ns = line as NSString
        func paint(_ re: NSRegularExpression, _ color: NSColor) {
            re.enumerateMatches(in: line, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let r = m?.range { out.addAttribute(.foregroundColor, value: color, range: r) }
            }
        }
        paint(MainController.pyConsts, NSColor(srgbRed: 0.55, green: 0.80, blue: 0.95, alpha: 1))
        paint(MainController.pyCalls, NSColor(srgbRed: 0.45, green: 0.85, blue: 0.75, alpha: 1))
        paint(MainController.pyKeywords, NSColor(srgbRed: 1.0, green: 0.48, blue: 0.70, alpha: 1))
        paint(MainController.pyNumbers, NSColor(srgbRed: 0.85, green: 0.80, blue: 0.50, alpha: 1))
        paint(MainController.pyStrings, NSColor(srgbRed: 1.0, green: 0.58, blue: 0.45, alpha: 1))
        if let h = line.firstIndex(of: "#") {
            let loc = line.distance(from: line.startIndex, to: h)
            let before = String(line[..<h])
            if before.filter({ $0 == "\"" }).count % 2 == 0 && before.filter({ $0 == "'" }).count % 2 == 0 {
                out.addAttribute(.foregroundColor, value: NSColor(white: 0.5, alpha: 1), range: NSRange(location: loc, length: (line as NSString).length - loc))
            }
        }
        return out
    }

    func highlightSource() { if scene?.source != nil { renderSource() } }
    func showSourceError(_ s: String) { sourceView.string = s }

    // MARK: undo / navigation / misc

    @objc func undo() { doUndo(redo: false) }
    @objc func redo() { doUndo(redo: true) }
    func doUndo(redo: Bool) {
        if window.firstResponder is NSTextView && window.firstResponder !== sourceView && window.firstResponder !== canvas { return }
        submit { [weak self] in
            guard let self = self else { return }
            self.busy += 1
            let r = try? await self.engine.call(redo ? "redo" : "undo", as: UndoResult.self)
            self.busy -= 1
            if r?.ok == true {
                self.lastChanged = nil
                self.toast((redo ? "Redid " : "Undid ") + (r?.label ?? ""))
                if let n = self.sceneName { await self.loadScene(n, keepStop: true) }
                await self.reloadState()
            } else { self.toast(r?.error ?? "nothing to undo", error: true) }
        }
    }
    @objc func present() {
        Task { @MainActor in
            busyPill.show("Preparing presentation…", symbol: nil, tint: nil, spinning: true)
            let r = try? await engine.call("present", as: UndoResult.self)
            if r?.ok != true { busyPill.hide(); toast(r?.error ?? "Could not start the presenter", error: true) }
        }
    }

    // MARK: Play (built-in slideshow)

    @objc func playFromBeginning() { play(fromCurrent: false) }
    @objc func playFromCurrent() { play(fromCurrent: true) }

    func play(fromCurrent: Bool) {
        guard player == nil else { return }
        Task { @MainActor in
            busyText = "Preparing slideshow…"
            busy += 1
            let deck = try? await engine.call("deck_pages", as: DeckPages.self)
            busy -= 1; busyText = "Rendering…"
            guard let d = deck else { toast("Could not prepare the slideshow", error: true); return }
            let broken = d.slides.filter { $0.error != nil }.map { $0.scene }
            let playable = d.slides.filter { $0.error == nil && !$0.pages.isEmpty }
            if !broken.isEmpty { toast("Skipping slides that fail to render: " + broken.joined(separator: ", "), error: true) }
            guard !playable.isEmpty else { return }
            var start = 0
            if fromCurrent, let n = sceneName, let i = playable.firstIndex(where: { $0.scene == n }) { start = i }
            let p = SlidePlayer(screen: window.screen ?? NSScreen.main ?? NSScreen.screens[0])
            p.onExit = { [weak self] in self?.player = nil; self?.window.makeKeyAndOrderFront(nil) }
            player = p
            p.play(slides: playable.map { $0.pages }, startSlide: start)
        }
    }

    // MARK: Slide menu

    @objc func newSlide() { slideOp("new") }
    @objc func duplicateSlide() { slideOp("duplicate") }
    @objc func deleteSlide() { slideOp("delete") }
    @objc func moveSlideUp() { slideOp("up") }
    @objc func moveSlideDown() { slideOp("down") }

    func slideOp(_ op: String) {
        guard let name = sceneName else { return }
        submit { [weak self] in
            guard let self = self else { return }
            self.busy += 1
            let r = try? await self.engine.call("slide", ["op": op, "scene": name], as: SlideResult.self)
            self.busy -= 1
            guard let res = r, res.ok == true else { self.toast(r?.error ?? "slide operation failed", error: true); return }
            self.lastChanged = nil
            await self.reloadState()
            if let sel = res.select { await self.selectScene(sel) }
            self.toast((res.message ?? op).capitalized + (op == "delete" ? " — ⌘Z to undo" : ""))
            self.updateDocumentState()
        }
    }

    // MARK: Format menu (acts on the selected text)

    @objc func formatBold() {
        guard let o = objInfo, o.kind == "text" else { return }
        commitStyle(weight: o.weight?.uppercased() == "BOLD" ? "NORMAL" : "BOLD")
    }
    @objc func formatItalic() {
        guard let o = objInfo, o.kind == "text" else { return }
        commitStyle(slant: ["ITALIC", "OBLIQUE"].contains(o.slant?.uppercased() ?? "") ? "NORMAL" : "ITALIC")
    }
    @objc func formatBigger() { scaleFont(1.1) }
    @objc func formatSmaller() { scaleFont(1 / 1.1) }
    func scaleFont(_ k: Double) {
        guard let s = selection, let o = objInfo, o.kind == "text" || o.kind == "tex", let fs = o.fontSize else { return }
        let v = max(4, (fs * k).rounded())
        submit { [weak self] in
            guard let self = self else { return }
            await self.previewSprite(s, kind: o.kind, value: o.value, size: v, color: o.color, font: o.font, weight: o.weight, slant: o.slant)
            await self.runEdit(["op": "font", "oid": s, "value": v])
        }
    }

    // MARK: terminal

    @objc func toggleTerminal() {
        guard let cs = centerSplit else { return }
        let show = terminal.isHidden
        terminal.isHidden = !show
        cs.adjustSubviews()
        if show {
            if !terminal.hasStarted, let ws = workspace { terminal.start(in: ws.work.path, original: ws.original.path) }
            DispatchQueue.main.async { [self] in
                if cs.bounds.height > 300 { cs.setPosition(cs.bounds.height * 0.58, ofDividerAt: 0) }
                terminal.focus()
            }
        } else { window.makeFirstResponder(canvas) }
    }

    // MARK: View menu: panels

    @objc func toggleNavigator() { mainSplit?.subviews.first?.isHidden.toggle(); mainSplit?.adjustSubviews() }
    @objc func toggleInspector() { mainSplit?.subviews.last?.isHidden.toggle(); mainSplit?.adjustSubviews() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(formatBold), #selector(formatItalic): return objInfo?.kind == "text"
        case #selector(formatBigger), #selector(formatSmaller): return objInfo?.kind == "text" || objInfo?.kind == "tex"
        case #selector(newSlide), #selector(duplicateSlide), #selector(moveSlideUp), #selector(moveSlideDown),
             #selector(playFromCurrent), #selector(insertTextPressed), #selector(insertFormulaPressed), #selector(insertTablePressed),
             #selector(insertImagePressed), #selector(insertShapePressed(_:)):
            return sceneName != nil && player == nil
        case #selector(toggleTerminal):
            item.title = terminal.isHidden ? "Show Terminal" : "Hide Terminal"; return workspace != nil
        case #selector(playFromBeginning): return state?.scenes.isEmpty == false && player == nil
        case #selector(deleteSlide): return sceneName != nil && (state?.scenes.count ?? 0) > 1 && player == nil
        case #selector(undo): return state?.canUndo ?? true
        case #selector(redo): return state?.canRedo ?? true
        default: return true
        }
    }
    @objc func toggleObjects() { canvas.showObjects.toggle() }
    @objc func prevSlide() { moveSlide(-1) }
    @objc func nextSlide() { moveSlide(1) }
    func moveSlide(_ d: Int) {
        guard let st = state, let n = sceneName, let i = st.scenes.firstIndex(where: { $0.name == n }), st.scenes.indices.contains(i + d) else { return }
        Task { @MainActor in await selectScene(st.scenes[i + d].name) }
    }
    @objc func prevStop() { moveStop(-1) }
    @objc func nextStop() { moveStop(1) }
    func moveStop(_ d: Int) {
        guard let n = scene?.stops?.count, (0..<n).contains(stopIndex + d) else { return }
        stopIndex += d; canvas.overrides = [:]; canvas.lineOverrides = [:]; applyStop(); rebuildSteps(); rebuildInspector()
    }

    var toastWork: DispatchWorkItem?
    func toast(_ s: String, error: Bool = false) {
        toastPill.show(s, symbol: error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                       tint: error ? .systemOrange : Theme.accent)
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toastPill.hide() }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (error ? 8 : 2.6), execute: w)
    }

    func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClose(for: "closing") }
    func windowWillClose(_ n: Notification) { finish() }
}

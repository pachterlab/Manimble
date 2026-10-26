import AppKit
import UniformTypeIdentifiers

@MainActor
final class MainController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate, NSMenuItemValidation {
    let engine = Engine()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 920),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    let canvas = CanvasView()
    let table = SlideTable()
    private let slideDragType = NSPasteboard.PasteboardType("org.manimble.slide-reorder")
    let stepsBar = NSStackView()
    let inspector = NSStackView()
    let inspectorHost = NSView()            // the inspector, or the BioCartoon search in its place
    var inspectorScroll: NSScrollView?
    let sourceView = SourceCodeView()
    let srcHeader = NSTextField(labelWithString: "PYTHON")
    let sourceError = NSTextField(wrappingLabelWithString: "")
    let sourceErrorButton = NSButton(title: "Error Details…", target: nil, action: nil)
    var sourceErrorMessage: String?
    var sourceEditBase: SourceInfo?
    /// The inset card around the Python pane; outlined in the accent colour while the code has focus.
    weak var sourceCard: NSView?
    var sourceEditSceneName: String?
    var sourceDraft: String?
    var sourceFocused = false
    let toastPill = Pill()
    let busyPill = Pill()
    var busyText = "Rendering…" {
        didSet { if busyText != oldValue { busyProgress = nil; renderETA = nil }; if busy > 0 { updateBusyPill() } }
    }
    /// The busy pill's bar: a known fraction, else the current slide's render estimate (`render_progress` events).
    var busyProgress: Double? { didSet { if busyProgress != oldValue, busy > 0 || verifying { updateBusyPill() } } }
    var renderETA: (start: Date, total: Double)?

    var workspace: Workspace? {
        didSet { for b in [notesBox, buildNotesBox] { b.imageBase = workspace?.work } }     // pictures in the notes
    }
    // Opening a deck can happen while startup is still searching for Python.
    // Keep the selection and open it as soon as launch() has started the engine.
    private var pendingDeck: String?
    var state: StateInfo?
    var showUnusedSlides = false
    var navigatorScenes: [SceneSummary] {
        guard let state else { return [] }
        return state.scenes + (showUnusedSlides ? state.unusedScenes : [])
    }
    var selectedSlideIsUnused: Bool {
        guard let name = sceneName else { return false }
        return state?.unusedScenes.contains(where: { $0.name == name }) == true
    }
    var scene: SceneData?
    var sceneName: String?
    var stopIndex = 0
    var selection: Int? { didSet { canvas.selection = selection; rebuildInspector(); highlightSource() } }
    var busy = 0 { didSet { updateBusyPill() } }
    /// The slide on screen shows an optimistic move/resize whose verifying render has not landed yet: objects laid
    /// out from the moved one (arrows, labels) catch up only then, so the pill stays until the real frame is shown.
    var verifying = false { didSet { if verifying != oldValue { updateBusyPill() } } }
    func updateBusyPill() {
        if busy > 0 || verifying {
            let remaining = renderETA.map { $0.total + $0.start.timeIntervalSinceNow }
            busyPill.show(busyText, symbol: nil, tint: nil, spinning: true, progress: busyProgress, remaining: remaining)
        } else { busyPill.hide(); busyProgress = nil; renderETA = nil }
    }
    var queueTail: Task<Void, Never>?
    var lastChanged: ChangedLines?
    /// The object just moved in one build only, so Select All (Cmd-A) can extend that move to every build.
    var lastBuildMove: (scene: String, oid: Int, stop: Int)?
    var thumbCache = NSCache<NSString, NSImage>()
    var refreshTimer: Timer?
    var pendingStateRefresh = false
    /// A stills show is on with slides still rendering in the background; `rendered` events refill its pages.
    var showPending = false
    var pendingShowRefresh = false
    var nudge: [Int: (dx: Double, dy: Double)] = [:]      // arrow-key moves not yet sent, by object
    var nudgeWork: DispatchWorkItem?
    var sharedChoice = true
    var suppressTable = false
    var testRan = false
    var shownDir: String?
    var mainSplit: NSSplitView?
    var sideScroll: NSScrollView?
    var player: SlidePlayer?
    var presenter: PresenterController?
    var animatedPlayer: AnimatedPlayer?
    /// The deck's feedback notes (Presenter View's Feedback Mode), in `feedback.json` of the working copy.
    var feedback: FeedbackStore?
    var feedbackPane: FeedbackListView?       // the feedback list, in the inspector's place while it is up
    private var presentFrom = 0              // scene (order.txt index) the animated show starts at
    private var presentWithPresenter = false // the animated show opens in Presenter View
    var animationPreview: AnimationPreviewView?
    /// Speaker notes of the slide on screen, a tab of the drawer below the canvas (View ▸ Speaker Notes).
    let notesBox = MultilineTextBox(string: "", maxLines: 4)
    let notesPane = NSView()
    /// Speaker notes of the build on screen only, the drawer's Build Notes tab; `buildNotesFor` is the build its
    /// text belongs to (a commit after the build changed still goes to the right one).
    let buildNotesBox = MultilineTextBox(string: "", maxLines: 4)
    let buildNotesView = NSView()
    var buildNotesFor: (scene: String, stop: Int)?
    var previewScene: String?
    let stageArea = NSView()
    /// PowerPoint-style rulers above and left of the slide (View ▸ Ruler).
    let hRuler = RulerView(.horizontal), vRuler = RulerView(.vertical), rulerCorner = NSView()
    var rulerThickness: [NSLayoutConstraint] = []
    let terminal = TerminalPanel()
    /// Below the slide: the notes and the terminals as tabs, with one divider above them.
    lazy var drawer = BottomDrawer(notes: notesPane, buildNotes: buildNotesView, terminal: terminal)
    var sourceBox: NSView?                 // the PYTHON card's contents (PaneOverlay.swift swaps them out)
    var paneOverlay: AuxPaneView?
    var paneOverlayMonitor: Any?
    var centerSplit: NSSplitView?
    var formatBar: FormatBar!
    let fontMenuStyler = FontMenuStyler()
    /// Width and height fields change an object proportionally (true) or stretch it (false).
    var aspectLocked = true
    var colorPanelWork: DispatchWorkItem?

    // inspector controls kept for reading
    var zoomPopup: NSPopUpButton?
    var tableCells: [[NSTextField]] = []
    var tableGrid: NSScrollView?
    var textField: MultilineTextBox?
    var sizeField: NSTextField?
    var colorWell: NSColorWell?

    // MARK: setup

    func showWindow() {
        window.title = "Manimble"
        window.titlebarSeparatorStyle = .line
        window.delegate = self
        window.isReleasedWhenClosed = false     // closing it closes the deck; the window comes back for the next one
        window.minSize = NSSize(width: 1000, height: 600)
        window.setFrameAutosaveName("manimble.main")
        window.contentView = buildUI()
        window.toolbar = makeToolbar()
        window.toolbarStyle = .unified
        canvas.onZoomChange = { [weak self] in self?.syncZoomPopup() }
        canvas.onDelete = { [weak self] oid in self?.deleteSelected(oid) }
        canvas.onContextMenu = { [weak self] in self?.canvasMenu() }
        canvas.colorView = DarkMode.mode; canvas.darkImages = DarkMode.images
        canvas.onDraw = { [weak self] kind, sx, sy, ex, ey, anchors in self?.drawFinished(kind, sx, sy, ex, ey, anchors: anchors) }
        canvas.onPen = { [weak self] pts in self?.penFinished(pts) }
        canvas.registerForDraggedTypes([BioCartoonPane.dragType])
        canvas.onIconDrop = { [weak self] data, p in self?.biocartoonDropped(data, at: p) ?? false }
        canvas.penColor = NSColor(hex: UserDefaults.standard.string(forKey: "penColor") ?? "#FF3B30")
        canvas.onDrawToolChange = { [weak self] in self?.syncFormatBar() }
        canvas.onGuidesChange = { [weak self] in self?.saveGuides() }
        canvas.showGrid = UserDefaults.standard.bool(forKey: "showGrid")
        canvas.snapEnabled = UserDefaults.standard.object(forKey: "snapObjects") as? Bool ?? true
        syncFormatBar()
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    func buildUI() -> NSView {
        // sidebar
        let col = NSTableColumn(identifier: .init("slide")); col.width = 220; col.minWidth = 120; col.maxWidth = 600
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.headerView = nil
        table.rowHeight = SlideCell.baseHeight
        table.dataSource = self; table.delegate = self
        table.onDelete = { [weak self] in self?.deleteSlide() }
        table.onDeleteBuild = { [weak self] in self?.deleteBuild() }
        table.onMenu = { [weak self] row in self?.navigatorMenu(row: row) }
        table.target = table; table.action = #selector(SlideTable.rowClicked(_:))
        table.onReclick = { [weak self] _ in self?.toggleBuildsList() }
        table.onArrow = { [weak self] d in self?.stepNavigator(d) }
        table.registerForDraggedTypes([slideDragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
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
            self.noteSlideRowHeights()
        }

        // centre: canvas + builds
        canvas.onSelect = { [weak self] oid in self?.selection = oid }
        canvas.onMove = { [weak self] oid, dx, dy in self?.commitMove(oid, dx, dy) }
        canvas.onManyEdits = { [weak self] label, body in
            if let self = self { self.asOneUndoStep(label, body) } else { body() }
        }
        canvas.onResize = { [weak self] oid, r in self?.commitResize(oid, r) }
        canvas.onWrap = { [weak self] oid, w, side in self?.commitWrap(oid, w, side) }
        canvas.onEndpoints = { [weak self] oid, e, anchors in self?.commitEndpoints(oid, e, anchors: anchors) }
        canvas.onEdit = { [weak self] oid, at in self?.beginEdit(oid, at: at) }
        canvas.onPlaceholder = { [weak self] ph in self?.beginPlaceholder(ph) }
        canvas.onPlaceholderDelete = { [weak self] line in self?.removePlaceholder(line) }
        canvas.onNudge = { [weak self] oid, dx, dy in self?.nudgeObject(oid, dx, dy) }
        stepsBar.orientation = .horizontal; stepsBar.spacing = 8
        stepsBar.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 8, right: 12)
        let stepsScroll = NSScrollView(); stepsScroll.documentView = stepsBar
        stepsScroll.hasHorizontalScroller = false
        stepsScroll.drawsBackground = true; stepsScroll.backgroundColor = Theme.canvasBottom
        stepsScroll.heightAnchor.constraint(equalToConstant: 68).isActive = true
        let center = NSView()
        let stageColumn = NSView()
        buildNotesPane()
        // the slide with its build steps under it
        stageColumn.addSubview(stageArea)
        stageColumn.addSubview(stepsScroll)
        stageArea.translatesAutoresizingMaskIntoConstraints = false
        stepsScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stageArea.leadingAnchor.constraint(equalTo: stageColumn.leadingAnchor),
            stageArea.trailingAnchor.constraint(equalTo: stageColumn.trailingAnchor),
            stageArea.topAnchor.constraint(equalTo: stageColumn.topAnchor),
            stageArea.bottomAnchor.constraint(equalTo: stepsScroll.topAnchor),
            stageArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            stepsScroll.leadingAnchor.constraint(equalTo: stageColumn.leadingAnchor),
            stepsScroll.trailingAnchor.constraint(equalTo: stageColumn.trailingAnchor),
            stepsScroll.bottomAnchor.constraint(equalTo: stageColumn.bottomAnchor),
        ])
        stageArea.addSubview(canvas)
        for v in [hRuler, vRuler, rulerCorner] { stageArea.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false }
        rulerCorner.wantsLayer = true
        Theme.layerColors(rulerCorner) { $0.layer?.backgroundColor = Theme.canvasBottom.cgColor }
        hRuler.canvas = canvas; vRuler.canvas = canvas
        canvas.translatesAutoresizingMaskIntoConstraints = false
        rulerThickness = [hRuler.heightAnchor.constraint(equalToConstant: RulerView.thickness),
                          vRuler.widthAnchor.constraint(equalToConstant: RulerView.thickness)]
        NSLayoutConstraint.activate(rulerThickness + [
            rulerCorner.leadingAnchor.constraint(equalTo: stageArea.leadingAnchor), rulerCorner.topAnchor.constraint(equalTo: stageArea.topAnchor),
            rulerCorner.widthAnchor.constraint(equalTo: vRuler.widthAnchor), rulerCorner.heightAnchor.constraint(equalTo: hRuler.heightAnchor),
            hRuler.leadingAnchor.constraint(equalTo: vRuler.trailingAnchor), hRuler.trailingAnchor.constraint(equalTo: stageArea.trailingAnchor),
            hRuler.topAnchor.constraint(equalTo: stageArea.topAnchor),
            vRuler.leadingAnchor.constraint(equalTo: stageArea.leadingAnchor), vRuler.topAnchor.constraint(equalTo: hRuler.bottomAnchor),
            vRuler.bottomAnchor.constraint(equalTo: stageArea.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: vRuler.trailingAnchor),
            canvas.trailingAnchor.constraint(equalTo: stageArea.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: hRuler.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: stageArea.bottomAnchor),
        ])
        applyRulerVisibility()
        canvas.onGeometryChange = { [weak self] in self?.redrawRulers() }
        canvas.onCursorMove = { [weak self] p in self?.hRuler.cursor = p; self?.vRuler.cursor = p }
        // slides on top, the notes/terminal drawer below
        let cs = GrabSplitView(); cs.isVertical = false; cs.dividerStyle = .thin
        cs.addArrangedSubview(stageColumn); cs.addArrangedSubview(drawer)
        cs.setHoldingPriority(.init(240), forSubviewAt: 0)
        cs.setHoldingPriority(.init(260), forSubviewAt: 1)
        cs.autosaveName = "manimble.drawer"
        cs.collapsesLastPane = true                        // drag the drawer all the way down to hide it, back up to show it
        centerSplit = cs
        installDrawer()
        cs.translatesAutoresizingMaskIntoConstraints = false
        for pill in [toastPill, busyPill] { pill.translatesAutoresizingMaskIntoConstraints = false }
        // the slide area sits in an inset rounded card with a slim light edge, matching the code card on the right
        let stageCard = NSView(); stageCard.wantsLayer = true
        stageCard.layer?.cornerRadius = 12; stageCard.layer?.masksToBounds = true
        stageCard.layer?.borderWidth = 1
        Theme.layerColors(stageCard) { v in
            v.layer?.borderColor = Theme.ink(0.22).cgColor; v.layer?.backgroundColor = Theme.canvasBottom.cgColor
        }
        stageCard.translatesAutoresizingMaskIntoConstraints = false
        center.wantsLayer = true
        Theme.layerColors(center) { $0.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
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
        sourceView.isRichText = false
        sourceView.allowsUndo = true
        sourceView.isAutomaticQuoteSubstitutionEnabled = false
        sourceView.isAutomaticDashSubstitutionEnabled = false
        sourceView.isAutomaticSpellingCorrectionEnabled = false
        sourceView.onFocus = { [weak self] in self?.beginSourceEditing() }
        sourceView.onBlur = { [weak self] in self?.endSourceEditing() }
        sourceView.onChange = { [weak self] in self?.sourceTextChanged() }
        sourceView.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        sourceView.backgroundColor = Theme.codeBackground
        sourceView.textColor = MainController.pyText
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
        srcScroll.drawsBackground = true; srcScroll.backgroundColor = sourceView.backgroundColor
        srcScroll.borderType = .noBorder
        srcHeader.font = Theme.font(10, .semibold); srcHeader.textColor = Theme.ink(0.5)
        let headBar = NSView(); headBar.wantsLayer = true
        Theme.layerColors(headBar) { $0.layer?.backgroundColor = Theme.barBackground.cgColor }
        srcHeader.translatesAutoresizingMaskIntoConstraints = false; headBar.addSubview(srcHeader)
        sourceErrorButton.target = self
        sourceErrorButton.action = #selector(showSourceErrorDetails)
        sourceErrorButton.isBordered = false
        sourceErrorButton.font = Theme.font(10, .medium)
        sourceErrorButton.contentTintColor = .systemRed
        sourceErrorButton.isHidden = true
        sourceErrorButton.translatesAutoresizingMaskIntoConstraints = false
        headBar.addSubview(sourceErrorButton)
        headBar.heightAnchor.constraint(equalToConstant: 26).isActive = true
        NSLayoutConstraint.activate([srcHeader.leadingAnchor.constraint(equalTo: headBar.leadingAnchor, constant: 14),
                                     srcHeader.centerYAnchor.constraint(equalTo: headBar.centerYAnchor),
                                     srcHeader.trailingAnchor.constraint(lessThanOrEqualTo: sourceErrorButton.leadingAnchor, constant: -4),
                                     sourceErrorButton.trailingAnchor.constraint(equalTo: headBar.trailingAnchor, constant: -10),
                                     sourceErrorButton.centerYAnchor.constraint(equalTo: headBar.centerYAnchor)])
        sourceError.font = Theme.mono(10)
        sourceError.textColor = .systemRed
        sourceError.backgroundColor = NSColor.systemRed.withAlphaComponent(0.1)
        sourceError.drawsBackground = true
        sourceError.isSelectable = true
        sourceError.maximumNumberOfLines = 5
        sourceError.isHidden = true
        let srcBox = NSStackView(views: [headBar, sourceError, srcScroll]); srcBox.orientation = .vertical; srcBox.spacing = 0
        headBar.widthAnchor.constraint(equalTo: srcBox.widthAnchor).isActive = true
        let right = GrabSplitView(); right.isVertical = false; right.dividerStyle = .thin
        // the code sits in an inset card with its own edge
        let card = NSView(); card.wantsLayer = true
        card.layer?.cornerRadius = 10; card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        sourceCard = card
        Theme.layerColors(card) { [weak self] v in
            v.layer?.backgroundColor = Theme.codeBackground.cgColor
            self?.updateSourceCardBorder()
        }
        srcBox.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(srcBox)
        sourceBox = srcBox
        installPaneShortcut()
        NSLayoutConstraint.activate([
            srcBox.leadingAnchor.constraint(equalTo: card.leadingAnchor), srcBox.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            srcBox.topAnchor.constraint(equalTo: card.topAnchor), srcBox.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        let cardHolder = NSView(); cardHolder.wantsLayer = true
        Theme.layerColors(cardHolder) { $0.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        card.translatesAutoresizingMaskIntoConstraints = false
        cardHolder.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: cardHolder.leadingAnchor, constant: 10), card.trailingAnchor.constraint(equalTo: cardHolder.trailingAnchor, constant: -10),
            card.topAnchor.constraint(equalTo: cardHolder.topAnchor, constant: 8), card.bottomAnchor.constraint(equalTo: cardHolder.bottomAnchor, constant: -10),
        ])
        inspScroll.translatesAutoresizingMaskIntoConstraints = false
        inspectorHost.addSubview(inspScroll)
        NSLayoutConstraint.activate([
            inspScroll.leadingAnchor.constraint(equalTo: inspectorHost.leadingAnchor), inspScroll.trailingAnchor.constraint(equalTo: inspectorHost.trailingAnchor),
            inspScroll.topAnchor.constraint(equalTo: inspectorHost.topAnchor), inspScroll.bottomAnchor.constraint(equalTo: inspectorHost.bottomAnchor),
        ])
        inspectorScroll = inspScroll
        right.addArrangedSubview(inspectorHost); right.addArrangedSubview(cardHolder)
        right.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        right.setHoldingPriority(.defaultLow, forSubviewAt: 0)

        let split = GrabSplitView(); split.isVertical = true; split.dividerStyle = .thin
        split.addArrangedSubview(sideBox); split.addArrangedSubview(center); split.addArrangedSubview(right)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(250), forSubviewAt: 2)
        split.collapsesEdgePanes = true                    // push a side panel all the way off; drag the edge to bring it back
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
        // the Home bar sits above everything
        formatBar = makeFormatBar()
        let root = NSView()
        formatBar.translatesAutoresizingMaskIntoConstraints = false
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(formatBar); root.addSubview(split)
        NSLayoutConstraint.activate([
            formatBar.leadingAnchor.constraint(equalTo: root.leadingAnchor), formatBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            formatBar.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor), split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: formatBar.bottomAnchor), split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
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
        } else if let d = ["BG", "DARK", "FORMAT", "TOOLS", "EXTRACT", "TABLE", "BIOCARTOON", "INLINE", "OFFSLIDE", "MOVE", "SHOW", "NOTES", "FRAME", "FEEDBACK", "CONNECT", "EXPAND"].lazy
                    .compactMap({ ProcessInfo.processInfo.environment["MANIMBLE_TEST_" + $0] }).first
                    ?? ProcessInfo.processInfo.environment["MANIMBLE_TEST_TERM"].flatMap({ $0.hasPrefix("/") ? $0 : nil }) {
            open(deck: d)
        } else {
            let last = UserDefaults.standard.string(forKey: "lastDeck")
            if let d = last, FileManager.default.fileExists(atPath: d) { open(deck: d) } else { chooseDeck() }
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
        // Only .manimble packages and plain folders are enabled; other files are grayed out.
        p.allowedContentTypes = [UTType(filenameExtension: "manimble"), .folder].compactMap { $0 }
        if let last = UserDefaults.standard.string(forKey: "lastDeck") { p.directoryURL = URL(fileURLWithPath: last).deletingLastPathComponent() }
        guard p.runModal() == .OK, let u = p.url else { return }
        openProject(at: u)
    }

    /// Open what File ▸ Open, a launch argument or the Dock/Finder hands over: a deck folder, a Manimble project
    /// folder, a .manimble package, or a file inside a deck folder (its deck is opened).
    func openProject(at u: URL) {
        do {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if u.pathExtension.lowercased() == "manimble" && !isDir {
                open(deck: try PortableProject.unpackArchive(u).path)
            } else if isDir, let deck = try PortableProject.deckURL(in: u) {
                open(deck: deck.path)
            } else if isDir {
                open(deck: u.path)
            } else if FileManager.default.fileExists(atPath: u.deletingLastPathComponent().appendingPathComponent("order.txt").path) {
                open(deck: u.deletingLastPathComponent().path)
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
        panel.nameFieldStringValue = ws.projectName
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

    /// `confirmed`: the caller already asked about unsaved edits to the open deck.
    func open(deck: String, confirmed: Bool = false) {
        guard engine.isRunning else {
            pendingDeck = deck
            busyPill.show("Waiting for Manimble engine…", symbol: nil, tint: nil, spinning: true)
            return
        }
        guard confirmed || confirmClose(for: "opening another deck") else { return }
        if !window.isVisible { window.makeKeyAndOrderFront(nil) }
        closeAnimationPreview()
        window.makeFirstResponder(canvas)
        Task { @MainActor in
            busy += 1
            defer { busy -= 1 }
            do {
                let ws = try Workspace(deck: deck)
                workspace?.discard()
                workspace = ws
                openFeedback(ws)
                if terminal.hasStarted { terminal.start(in: terminalDirectory(ws), original: ws.original.path) }
                _ = try await engine.raw("open", ["deck": ws.work.path, "cache": Workspace.cacheDir(for: ws.original)])
                UserDefaults.standard.set(deck, forKey: "lastDeck")
                loadGuides()
                sceneName = nil; scene = nil; selection = nil
                sourceDraft = nil; sourceEditBase = nil; sourceEditSceneName = nil
                sourceFocused = false
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
        let m = ws.isModified || sourceDraft != nil
        window.isDocumentEdited = m
        window.title = ws.original.deletingLastPathComponent().lastPathComponent + " / " + ws.original.lastPathComponent
        window.subtitle = m ? "Edited — not saved to the original" : "Manimble"
    }

    @objc func saveToOriginal() {
        guard let ws = workspace else { return }
        if sourceDraft != nil {
            window.makeFirstResponder(canvas)
            submit { [weak self] in self?.saveToOriginalAfterSourceEdit() }
            return
        }
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

    func saveToOriginalAfterSourceEdit() {
        guard sourceDraft == nil else {
            toast("Fix the Python code before saving", error: true)
            window.makeFirstResponder(sourceView)
            return
        }
        saveToOriginal()
    }

    @objc func revertToOriginal() {
        guard let ws = workspace, ws.isModified || sourceDraft != nil else { toast("No changes to revert"); return }
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = "Discard all unsaved edits?"
        a.informativeText = "The working copy goes back to the last saved version of the deck."
        a.addButton(withTitle: "Revert"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        sourceDraft = nil; sourceEditBase = nil; sourceEditSceneName = nil
        window.makeFirstResponder(canvas)
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
        if sourceDraft != nil {
            let draftAlert = NSAlert(); draftAlert.alertStyle = .warning
            draftAlert.messageText = "Python code has not been applied"
            draftAlert.informativeText = "Fix the code error and click outside the editor, or discard this draft before \(what)."
            draftAlert.addButton(withTitle: "Keep Editing"); draftAlert.addButton(withTitle: "Discard Draft")
            if draftAlert.runModal() != .alertSecondButtonReturn { window.makeFirstResponder(sourceView); return false }
            sourceDraft = nil; sourceEditBase = nil; sourceEditSceneName = nil
        }
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

    func finish() {
        closeAnimationPreview(); engine.stop(); workspace?.discard(); workspace = nil
        hideFeedbackPane(); feedbackPane?.removeFromSuperview(); feedbackPane = nil
        feedback = nil; canvas.feedbackLayer?.store = nil
    }

    func closeAnimationPreview() {
        previewScene = nil
        // only hand focus back when a preview actually had it; otherwise keep it (e.g. on the slide navigator)
        let wasOpen = animationPreview != nil
        animationPreview?.stop()
        animationPreview?.removeFromSuperview()
        animationPreview = nil
        if wasOpen, window.isVisible { window.makeFirstResponder(canvas) }
    }

    func showAnimationPreview(scene: String, clips: [AnimationClip]) {
        closeAnimationPreview()
        let preview = AnimationPreviewView(scene: scene, clips: clips)
        preview.onClose = { [weak self] in self?.closeAnimationPreview() }
        preview.onError = { [weak self] message in self?.toast(message, error: true) }
        preview.translatesAutoresizingMaskIntoConstraints = false
        stageArea.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: stageArea.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: stageArea.trailingAnchor),
            preview.topAnchor.constraint(equalTo: stageArea.topAnchor),
            preview.bottomAnchor.constraint(equalTo: stageArea.bottomAnchor),
        ])
        animationPreview = preview
        window.makeFirstResponder(preview)
    }

    func handleEvent(_ ev: [String: Any]) {
        if ev["event"] as? String == "render_progress" {        // the slide on screen is being rendered: run the bar
            guard ev["name"] as? String == sceneName, let step = ev["step"] as? Int else { return }
            if step == 0 {
                renderETA = (Date(), ev["estimate"] as? Double ?? 3)
                busyProgress = nil
                busyPill.bar.reset()
            } else if var eta = renderETA, let f = ev["fraction"] as? Double, f >= 0.05 {
                // the previous render was this far along at this step: re-estimate the total from the time spent
                let elapsed = -eta.start.timeIntervalSinceNow
                eta.total = 0.5 * eta.total + 0.5 * elapsed / f
                renderETA = eta
            } else { return }
            if busy > 0 || verifying { updateBusyPill() }
            return
        }
        if ev["event"] as? String == "animation_preview" {
            switch ev["phase"] as? String {
            case "building":
                let done = (ev["done"] as? Int ?? 0) + 1, total = ev["total"] as? Int ?? 0
                busyPill.show("Building animations \(done)/\(total)…", symbol: nil, tint: nil, spinning: true, progress: stepFraction(done, total))
            case "ready":
                busyPill.hide()
                guard let name = ev["scene"] as? String, name == sceneName, name == previewScene,
                      let records = ev["clips"] as? [[String: Any]] else { return }
                let clips = records.compactMap { item -> AnimationClip? in
                    guard let path = item["path"] as? String, let kind = item["kind"] as? String else { return nil }
                    return AnimationClip(url: URL(fileURLWithPath: path), kind: kind,
                                         playbackRate: (item["playbackRate"] as? NSNumber)?.floatValue ?? 1)
                }
                if clips.isEmpty { toast("No playable animation clips", error: true); return }
                showAnimationPreview(scene: name, clips: clips)
            default:
                busyPill.hide(); previewScene = nil
                toast(ev["error"] as? String ?? "Animation preview failed", error: true)
            }
            return
        }
        if ev["event"] as? String == "import" {
            switch ev["phase"] as? String {
            case "building":
                let done = (ev["done"] as? Int ?? 0) + 1, total = ev["total"] as? Int ?? 0
                busyPill.show("Importing slide \(done)/\(total)…", symbol: nil, tint: nil, spinning: true, progress: stepFraction(done, total))
            case "done":
                busyPill.hide()
                let n = ev["slides"] as? Int ?? 0
                let warn = (ev["warnings"] as? [String]) ?? []
                toast("Imported \(n) slides" + (warn.isEmpty ? "" : " — " + warn.prefix(2).joined(separator: "; ")), error: !warn.isEmpty)
                if let d = ev["deck"] as? String { open(deck: d, confirmed: true) }
            default:
                busyPill.hide(); toast(ev["error"] as? String ?? "import failed", error: true)
            }
            return
        }
        if ev["event"] as? String == "darkmode", ev["phase"] as? String == "building" {
            let done = (ev["done"] as? Int ?? 0) + 1, total = ev["total"] as? Int ?? 0
            let what = ev["mode"] as? String == "invert" ? "Inverting colours" : "Applying dark mode"
            busyPill.show("\(what) \(done)/\(total)…", symbol: nil, tint: nil, spinning: true, progress: stepFraction(done, total))
            return
        }
        if ev["event"] as? String == "export" {
            switch ev["phase"] as? String {
            case "building":
                let done = (ev["done"] as? Int ?? 0) + 1, total = ev["total"] as? Int ?? 0
                busyPill.show("Exporting slide \(done)/\(total)…", symbol: nil, tint: nil, spinning: true, progress: stepFraction(done, total))
            case "keynote":
                busyPill.show("Opening in Keynote…", symbol: nil, tint: nil, spinning: true)
            case "done":
                busyPill.hide()
                if let p = ev["path"] as? String {
                    toast("Exported \((p as NSString).lastPathComponent)")
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                    // Beamer: the .tex was written but LaTeX could not typeset it into a PDF
                    if let err = ev["pdfError"] as? String {
                        let log = ((p as NSString).deletingPathExtension as NSString).appendingPathExtension("log") ?? ""
                        alert("The PDF could not be compiled",
                              "\((p as NSString).lastPathComponent) was saved, but LaTeX stopped with:\n\n\(err)\n\n"
                              + "The full log is in \((log as NSString).lastPathComponent) next to it.")
                    }
                }
            default:
                busyPill.hide(); toast(ev["error"] as? String ?? "export failed", error: true)
            }
            return
        }
        if ev["event"] as? String == "export_movie" {
            let done = (ev["done"] as? Int ?? 0) + 1, total = ev["total"] as? Int ?? 0
            switch ev["phase"] as? String {
            case "building":
                busyPill.show("Building animations \(done)/\(total): \(ev["scene"] as? String ?? "")", symbol: nil, tint: nil, spinning: true, progress: stepFraction(done, total))
            case "encoding":
                busyPill.show("Encoding movie \(done)/\(total): \(ev["scene"] as? String ?? "")", symbol: nil, tint: nil, spinning: true, progress: stepFraction(done, total))
            case "done":
                busyPill.hide()
                if let p = ev["path"] as? String {
                    let n = ev["slides"] as? Int ?? 0
                    toast("Exported \((p as NSString).lastPathComponent)" + (n > 0 ? " (\(n) slide\(n == 1 ? "" : "s"))" : ""))
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                }
            default:
                busyPill.hide(); toast(ev["error"] as? String ?? "movie export failed", error: true)
            }
            return
        }
        if ev["event"] as? String == "present" {
            switch ev["phase"] as? String {
            case "building":
                let done = (ev["done"] as? Int ?? 0) + 1, total = ev["total"] as? Int ?? 0
                let title: String
                if let onlyScene = ev["onlyScene"] as? String {
                    title = "Building \(onlyScene)’s animations \(done)/\(total)"
                } else {
                    title = "Building animations \(done)/\(total): \(ev["scene"] as? String ?? "")"
                }
                busyPill.show(title, symbol: nil, tint: nil, spinning: true, progress: stepFraction(done, total))
            case "ready":
                busyPill.hide()
                guard let data = try? JSONSerialization.data(withJSONObject: ev),
                      let d = try? JSONDecoder().decode(PresentDeck.self, from: data), !d.slides.isEmpty else {
                    toast("No built slides to play", error: true); return
                }
                startAnimated(d)
            default:
                busyPill.hide(); toast(ev["error"] as? String ?? "presentation failed", error: true)
            }
            return
        }
        if ev["event"] as? String == "edit_failed" {          // an optimistic move/resize did not survive its render
            toast((ev["error"] as? String ?? "edit failed") + " (undone)", error: true)
            lastBuildMove = nil
            if let n = ev["name"] as? String, n == sceneName {
                Task { @MainActor in await self.loadScene(n, keepStop: true, keepOverrides: true); await self.reloadState() }
            }
            return
        }
        guard ev["event"] as? String == "rendered" else { return }
        if ev["name"] as? String == sceneName, renderETA != nil { renderETA = nil; busyProgress = 1 }
        if showPending, !pendingShowRefresh {
            pendingShowRefresh = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.pendingShowRefresh = false
                self.refreshShowPages()
            }
        }
        if !pendingStateRefresh {
            pendingStateRefresh = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.pendingStateRefresh = false
                Task { @MainActor in await self.reloadState(); await self.fetchAllBuildPages() }
            }
        }
    }

    /// Bar fill while working on step `done` (1-based) of `total`: the finished steps' share.
    func stepFraction(_ done: Int, _ total: Int) -> Double? { total > 0 ? Double(max(0, done - 1)) / Double(total) : nil }

    // MARK: state / scenes

    func reloadState() async {
        guard workspace != nil else { return }
        guard let st = try? await engine.call("state", ["current": sceneName ?? ""], as: StateInfo.self) else { return }
        let old = state
        state = st
        // reload only the rows that changed
        let oldRows = old.map { $0.scenes + (showUnusedSlides ? $0.unusedScenes : []) } ?? []
        let newRows = navigatorScenes
        if oldRows.map(\.name) == newRows.map(\.name) {
            var changed = IndexSet()
            for (i, (a, b)) in zip(oldRows, newRows).enumerated() where a.thumb != b.thumb || a.status != b.status || a.stops != b.stops || a.hidden != b.hidden { changed.insert(i) }
            if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
        } else {
            suppressTable = true; table.reloadData(); suppressTable = false
            if let n = sceneName, let i = newRows.firstIndex(where: { $0.name == n }) { selectRow(i) }
            else { table.deselectAll(nil) }
        }
        updateDocumentState()
        // the slide on screen was re-rendered (an edit from outside, e.g. Claude in the terminal): show it
        if let n = sceneName, busy == 0, let cur = newRows.first(where: { $0.name == n }), cur.status == "ready",
           let t = cur.thumb, let shown = shownDir, URL(fileURLWithPath: t).deletingLastPathComponent().path != shown {
            await loadScene(n, keepStop: true, keepOverrides: true)
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
        if name != sceneName && sourceFocused { window.makeFirstResponder(canvas) }
        if name != sceneName && (notesBox.isEditing || buildNotesBox.isEditing) { window.makeFirstResponder(canvas) }     // commits the notes first
        if name != sceneName && sourceDraft != nil {
            await queueTail?.value
            if sourceDraft != nil {
                toast("Fix the Python code before changing slides", error: true)
                if let current = sceneName, let row = navigatorScenes.firstIndex(where: { $0.name == current }) { selectRow(row) }
                window.makeFirstResponder(sourceView)
                return
            }
        }
        if name != sceneName { closeAnimationPreview(); table.buildFocused = false; canvas.feedbackLayer?.endEditing() }
        sceneName = name; stopIndex = 0; selection = nil
        canvas.feedbackLayer?.scene = name
        refreshRings()
        refreshBuildRows()
        canvas.overrides = [:]; canvas.lineOverrides = [:]; canvas.selection = nil
        if let i = navigatorScenes.firstIndex(where: { $0.name == name }) { selectRow(i) }
        await loadScene(name, keepStop: false)
    }

    /// `keepOverrides`: an edit's own render landing; previews of other objects (a drag in progress, moves still
    /// queued) stay, and the caller settles the edited object's.
    func loadScene(_ name: String, keepStop: Bool, keepOverrides: Bool = false) async {
        busy += 1
        defer { busy -= 1 }
        guard let sc = try? await engine.call("scene", ["name": name], as: SceneData.self), name == sceneName else { return }
        if let old = scene, old.name == name, old.stops?.first?.png != sc.stops?.first?.png { canvas.dropTextures() }
        if sc.status != "ready" || sc.stops == nil {
            // keep showing the last good frame instead of a blank canvas
            if scene?.name != name || scene?.stops == nil { canvas.stop = nil }
            scene = sc; selection = nil; verifying = false
            canvas.overrides = [:]
            toast("Slide failed to render: " + (sc.error ?? "unknown error").split(separator: "\n").suffix(3).joined(separator: " "), error: true)
            renderSource()
            showSourceError(sc.error ?? "scene not ready")
            rebuildSteps()
            rebuildInspector()
            return
        }
        scene = sc
        verifying = sc.optimistic == true
        if !notesBox.isEditing { notesBox.setText(sc.notes ?? "") }
        shownDir = URL(fileURLWithPath: sc.stops![0].png).deletingLastPathComponent().path
        stopIndex = keepStop ? min(stopIndex, sc.stops!.count - 1) : 0
        if let sel = selection, sc.objects?[String(sel)] == nil { selection = nil }
        applyStop()
        if !keepOverrides { canvas.overrides = [:]; canvas.lineOverrides = [:] }
        if ProcessInfo.processInfo.environment["MANIMBLE_SELFTEST"] != nil { selfTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_PLAY"] != nil, !testRan { testRan = true; playTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_PRESENT"] != nil, !testRan { testRan = true; presentTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_TERM"] != nil, !testRan { testRan = true; termTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_NOTES"] != nil, !testRan { testRan = true; notesTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_EXPAND"] != nil, !testRan { testRan = true; expandAllTest() }
        if let tcase = ProcessInfo.processInfo.environment["MANIMBLE_TEST_FORMULA"], !testRan { testRan = true; formulaTest(tcase) }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_BG"] != nil, !testRan { testRan = true; backgroundTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_DARK"] != nil, !testRan { testRan = true; darkModeTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_FORMAT"] != nil, !testRan { testRan = true; formatTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_LINK"] != nil, !testRan { testRan = true; linkTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_TOOLS"] != nil, !testRan { testRan = true; toolsTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_EXTRACT"] != nil, !testRan { testRan = true; extractTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_TABLE"] != nil, !testRan { testRan = true; tableTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_BIOCARTOON"] != nil, !testRan { testRan = true; biocartoonTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_INLINE"] != nil, !testRan { testRan = true; inlineTextTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_LAYOUTS"] != nil, !testRan { testRan = true; layoutsTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_FRAME"] != nil, !testRan { testRan = true; frameTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_FEEDBACK"] != nil, !testRan { testRan = true; feedbackTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_OFFSLIDE"] != nil, !testRan { testRan = true; offSlideTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_CONNECT"] != nil, !testRan { testRan = true; connectTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_MOVE"] != nil, !testRan { testRan = true; moveTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_SHOW"] != nil, !testRan { testRan = true; showTest() }
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_FIND"] != nil, !testRan { testRan = true; findTest() }
        rebuildSteps()
        renderSource()
        rebuildInspector()
    }

    func applyStop() {
        guard let sc = scene, let stops = sc.stops else { return }
        canvas.frameSize = CGSize(width: sc.size?[0] ?? 1280, height: sc.size?[1] ?? 720)
        canvas.unitPx = (sc.size?[0] ?? 1280) / (sc.frame?[0] ?? 14.2222)
        canvas.sceneObjects = sc.objects ?? [:]
        canvas.placeholders = sc.placeholders ?? []
        canvas.optimistic = sc.optimistic ?? false
        canvas.feedbackLayer?.build = stopIndex
        canvas.feedbackLayer?.scene = sc.name
        canvas.stop = stops[stopIndex]
        canvas.selection = selection
        if !buildNotesBox.isEditing {
            buildNotesBox.setText(sc.buildNotes.flatMap { $0.indices.contains(stopIndex) ? $0[stopIndex] : nil } ?? "")
            buildNotesFor = (sc.name, stopIndex)
        }
        drawer.buildLabel = stops.count > 1 ? "build \(stopIndex + 1) of \(stops.count)" : ""
    }

    /// Headless timing of a stills show that opens before every slide is rendered: MANIMBLE_TEST_SHOW=deck (best
    /// opened with an empty render cache), MANIMBLE_TEST_PRESENTER=1 for Presenter View instead of the plain show;
    /// show.log and shots in MANIMBLE_TEST_OUT.
    func showTest() {
        let env = ProcessInfo.processInfo.environment
        let dir = (env["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        let t0 = Date()
        func log(_ s: String) { try? (String(format: "%6.0f ms  ", Date().timeIntervalSince(t0) * 1000) + s + "\n").appendLine(to: dir + "show.log") }
        func shot(_ w: NSWindow?, _ name: String) {
            guard let w, let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming]),
                  let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: dir + name + ".png"))
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            let ready = state?.scenes.filter { $0.status == "ready" }.count ?? 0
            log("starting: \(ready) of \(state?.scenes.count ?? 0) slides rendered")
            if env["MANIMBLE_TEST_PRESENTER"] != nil { presenterView() } else { play(fromCurrent: true) }
            var source: SlidePlayer?
            for _ in 0..<1200 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                source = player ?? (presenter?.source as? SlidePlayer)
                if source != nil { break }
            }
            guard let p = source else { log("no show opened"); exit(0) }
            func pending() -> Int { p.pages.filter { $0.path.isEmpty }.count }
            log("show open: \(p.pageCount) pages, \(pending()) still rendering, on page \(p.pageIndex) (\(p.pages[p.pageIndex].path.isEmpty ? "placeholder" : "picture"))")
            shot(p.window, "show-open"); shot(presenter?.window, "presenter-open")
            var last = pending(), moved = false
            for _ in 0..<2400 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let n = pending()
                if n != last { log("\(n) pages still rendering; pageCount \(p.pageCount)"); last = n }
                if !moved, Date().timeIntervalSince(t0) > 4 {       // walk ahead into slides that are still rendering
                    moved = true
                    for _ in 0..<6 { p.next() }
                    log("after 6 nexts: page \(p.pageIndex) \(p.pages[p.pageIndex].path.isEmpty ? "placeholder" : "picture") showPending=\(showPending)")
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    shot(p.window, "show-ahead"); shot(presenter?.window, "presenter-ahead")
                }
                if n == 0 {
                    log("all pages in; page \(p.pageIndex) \(p.pages[p.pageIndex].path.isEmpty ? "placeholder" : "picture") showPending=\(showPending)")
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    shot(p.window, "show-done"); shot(presenter?.window, "presenter-done")
                    break
                }
            }
            if pending() > 0 { log("timed out with \(pending()) pages still rendering") }
            log("done")
            exit(0)
        }
    }

    /// Headless timing of one move: MANIMBLE_TEST_MOVE=deck, MANIMBLE_TEST_SCENE (default the first slide),
    /// MANIMBLE_TEST_KIND (kind of the object to move, default image); move.log and shots in MANIMBLE_TEST_OUT.
    func moveTest() {
        let env = ProcessInfo.processInfo.environment
        let dir = (env["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "move.log") }
        func shot(_ name: String) {
            guard let img = canvas.snapshotView(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: dir + name + ".png"))
        }
        func at(_ b: Box?) -> String { b.map { "\(Int($0.cx)),\(Int($0.cy))" } ?? "?" }
        Task { @MainActor in
            if let name = env["MANIMBLE_TEST_SCENE"] { await selectScene(name) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let kind = env["MANIMBLE_TEST_KIND"] ?? "image"
            guard let stop = canvas.stop, let sc = scene,
                  let oid = env["MANIMBLE_TEST_OID"].flatMap({ Int($0) })
                      ?? stop.visible.map({ Int($0[0]) }).first(where: { sc.objects?[String($0)]?.kind == kind }),
                  let b0 = stop.box(of: oid) else { log("no \(kind) on \(sceneName ?? "?")"); exit(0) }
            for (k, l) in stop.lines ?? [:] { log("line \(k) at \(l.prefix(4).map { Int($0) })") }
            selection = oid; canvas.selection = oid
            log("\(sceneName ?? "?") object \(oid) (\(kind)) at \(at(b0)), sync=\(env["MANIMBLE_SYNC_EDITS"] != nil)")
            shot("move-before")
            let dir0 = shownDir
            let t0 = Date()
            canvas.overrides[oid] = Override(dx: 60, dy: 40)        // what a drag leaves behind on mouse-up
            commitMove(oid, 60, 40)
            var settled = false
            for _ in 0..<750 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                if !settled, busy == 0, canvas.overrides[oid] == nil {
                    settled = true
                    log("edit returned, preview settled at \(ms) ms; object at \(at(canvas.stop?.box(of: oid))) optimistic=\(scene?.optimistic ?? false) pill=\(busyPill.isHidden ? "hidden" : "shown")")
                    for (k, l) in canvas.stop?.lines ?? [:] { log("line \(k) preview at \(l.prefix(4).map { Int($0) }) xform=\(canvas.stop?.xforms?[k]?.map { (($0 * 1000).rounded() / 1000) } ?? [])") }
                    shot("move-settled")
                }
                if settled, shownDir != dir0, scene?.optimistic != true {
                    log("verified render on screen at \(ms) ms; object at \(at(canvas.stop?.box(of: oid))) pill=\(busyPill.isHidden ? "hidden" : "shown")")
                    for (k, l) in canvas.stop?.lines ?? [:] { log("line \(k) verified at \(l.prefix(4).map { Int($0) })") }
                    shot("move-final")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    log("1 s later: busy=\(busy) verifying=\(verifying) pill=\(busyPill.isHidden ? "hidden" : "shown")")
                    break
                }
            }
            if !settled { log("timed out") }
            log("done")
            exit(0)
        }
    }

    /// Headless check of objects past the slide's edges showing on the pasteboard: MANIMBLE_TEST_OFFSLIDE=deck
    /// (scene in MANIMBLE_TEST_SCENE, default the first), shots in MANIMBLE_TEST_OUT.
    func offSlideTest() {
        let env = ProcessInfo.processInfo.environment
        let dir = (env["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "offslide.log") }
        func shot(_ name: String) {
            guard let img = canvas.snapshotView(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: dir + name + ".png"))
        }
        Task { @MainActor in
            if let name = env["MANIMBLE_TEST_SCENE"] { await selectScene(name) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let stop = canvas.stop else { log("no stop"); return }
            for sp in stop.sprites { log("sprite \(sp.oid) at \(Int(sp.x)),\(Int(sp.y)) \(Int(sp.w))x\(Int(sp.h))") }
            canvas.zoom = canvas.fitScale * 0.6
            shot("offslide-idle")
            if let v = stop.visible.first {
                let oid = Int(v[0])
                selection = oid
                canvas.overrides[oid] = Override(dx: -Double(canvas.frameSize.width) * 0.3, dy: 0)
                shot("offslide-dragged")
                canvas.overrides = [:]
            }
            log("done")
        }
    }

    /// Headless check of attaching arrows (MANIMBLE_TEST_CONNECT=deck, the hello deck's Shapes slide): an arrow drawn
    /// from near the rectangle's right edge to near the circle's left one snaps onto both and reads them in the source,
    /// then follows the circle when it moves. connect.log and connect-*.png in MANIMBLE_TEST_OUT.
    func connectTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "connect.log") }
        func shot(_ name: String) {
            guard let img = canvas.snapshotView(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: dir + name + ".png"))
        }
        func mouse(_ type: NSEvent.EventType, _ fx: Double, _ fy: Double) -> NSEvent {
            let r = canvas.slideRect
            let v = CGPoint(x: r.minX + fx * r.width / canvas.frameSize.width, y: r.maxY - fy * r.height / canvas.frameSize.height)
            return NSEvent.mouseEvent(with: type, location: canvas.convert(v, to: nil), modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func arrowLines() -> [String] {
            guard let s = scene?.source?.text else { return [] }
            return s.split(separator: "\n").map(String.init).filter { $0.contains("Arrow(") }
        }
        Task { @MainActor in
            await selectScene("Shapes")
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let objs = scene?.objects, let stop = canvas.stop,
                  let rect = objs.first(where: { $0.value.value == "Rectangle" }).flatMap({ Int($0.key) }),
                  let circ = objs.first(where: { $0.value.value == "Circle" }).flatMap({ Int($0.key) }),
                  let rb = stop.box(of: rect), let cb = stop.box(of: circ) else { log("no shapes"); return }
            setDrawTool("arrow")
            canvas.mouseMoved(with: mouse(.mouseMoved, rb.x1 + 4, rb.cy + 30))
            shot("connect-hover")
            canvas.mouseDown(with: mouse(.leftMouseDown, rb.x1 + 4, rb.cy + 3))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, cb.x0 - 5, cb.cy - 2))
            shot("connect-drag")
            canvas.mouseUp(with: mouse(.leftMouseUp, cb.x0 - 5, cb.cy - 2))
            await queueTail?.value
            try? await Task.sleep(nanoseconds: 500_000_000)
            log("after draw: \(arrowLines())")
            await runEdit(["op": "move", "oid": circ, "dx": 0, "dy": 120])
            await queueTail?.value
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            log("lines after moving the circle: \(canvas.stop?.lines ?? [:])")
            shot("connect-moved")
            log("done")
        }
    }

    /// Headless check of typing on the slide: MANIMBLE_TEST_INLINE=deck, output in MANIMBLE_TEST_OUT.
    func inlineTextTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "inline.log") }
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
        Task { @MainActor in
            await selectScene("Welcome")
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let stop = canvas.stop, let (oid, b) = stop.visible.compactMap({ v -> (Int, Box)? in
                let id = Int(v[0]); guard scene?.objects?[String(id)]?.kind == "text", let b = stop.box(of: id) else { return nil }
                return (id, b) }).max(by: { $0.1.area < $1.1.area }), let o = scene?.objects?[String(oid)] else { log("no text"); return }
            log("object \(oid) '\(o.value)' font=\(o.font ?? "-") size=\(o.fontSize ?? 0) box=\(Int(b.x0)),\(Int(b.y0)) \(Int(b.w))x\(Int(b.h))")
            selection = oid
            shot("inline-before")
            let r = canvas.slideRect, s = canvas.effectiveScale
            let clickX = b.x0 + b.w * 0.5
            let wp = canvas.convert(CGPoint(x: r.minX + clickX * s, y: r.maxY - b.cy * s), to: nil)
            beginEdit(oid, at: wp)
            guard let tv = window.firstResponder as? NSTextView, canvas.editingText == oid else { log("editor not focused"); return }
            log("editor font=\(tv.font?.fontName ?? "-") \(tv.font?.pointSize ?? 0)pt caret=\(tv.selectedRange().location) of \((tv.string as NSString).length)")
            log("editor box=\(canvas.selectedBox.map { "\(Int($0.x0)),\(Int($0.y0)) \(Int($0.w))x\(Int($0.h))" } ?? "-")")
            shot("inline-editing")
            tv.insertText(" XYZ", replacementRange: tv.selectedRange())
            log("after typing: editor='\(tv.string)' inspector='\(textField?.stringValue ?? "-")' box=\(canvas.selectedBox.map { "\(Int($0.w))x\(Int($0.h))" } ?? "-")")
            shot("inline-typed")
            window.makeFirstResponder(canvas)
            await queueTail?.value
            try? await Task.sleep(nanoseconds: 800_000_000)
            log("after commit: editing=\(canvas.editingText.map(String.init) ?? "nil") value='\(scene?.objects?[String(oid)]?.value ?? "-")'")
            shot("inline-after")
            log("done")
        }
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
        let env = ProcessInfo.processInfo.environment
        let dir = (env["MANIMBLE_TEST_OUT"] ?? env["MANIMBLE_SELFTEST"] ?? "/tmp") + "/"
        func shot(_ name: String) {
            guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
        }
        Task { @MainActor in
            toggleTerminal()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            terminal.type("echo TERM_OK $MANIMBLE_DECK; ls | head -3; which claude\r")
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            try? terminal.contents().write(toFile: dir + "term.txt", atomically: true, encoding: .utf8)
            newTerminal()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            terminal.type("echo TERM2_OK $MANIMBLE_DECK\r")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            try? terminal.contents().write(toFile: dir + "term2.txt", atomically: true, encoding: .utf8)
            splitTerminal()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            terminal.type("echo TERM3_OK\r")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            try? terminal.contents().write(toFile: dir + "term3.txt", atomically: true, encoding: .utf8)
            shot("term.png")
            try? "hidden=\(!drawerShowsTerminal) terminals=\(terminal.count) tabs=\(terminal.tabCount) drawer=\(Int(drawer.frame.height))\n".write(toFile: dir + "term.log", atomically: true, encoding: .utf8)
            toggleNotesPane()     // the same drawer, on its Notes tab
            try? await Task.sleep(nanoseconds: 500_000_000)
            shot("notes.png")
            try? "notes=\(drawerShowsNotes) terminal=\(drawerShowsTerminal) drawer=\(Int(drawer.frame.height))".appendLine(to: dir + "term.log")
            toggleTerminal()      // back to the terminals, then hidden
            toggleTerminal()
            try? "hidden-after=\(!drawerShowsTerminal) drawer-hidden=\(drawer.isHidden)".appendLine(to: dir + "term.log")
            NSApp.terminate(nil)
        }
    }

    /// MANIMBLE_TEST_NOTES=deck: the drawer's Slide Notes / Build Notes tabs on MANIMBLE_TEST_SCENE (default the
    /// first slide), saving notes for its second build; notes.log and shots in MANIMBLE_TEST_OUT.
    /// Headless check of Expand All / Collapse All (MANIMBLE_TEST_EXPAND=deck): row heights, the navigator menu,
    /// a click on another slide's build. expand.log and expand-*.png in MANIMBLE_TEST_OUT.
    func expandAllTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? s.appendLine(to: dir + "expand.log") }
        func shot(_ name: String) {
            guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
        }
        func heights() -> String { (0..<table.numberOfRows).map { String(Int(table.rect(ofRow: $0).height)) }.joined(separator: " ") }
        Task { @MainActor in
            for _ in 0..<120 { try? await Task.sleep(nanoseconds: 250_000_000); if state?.scenes.allSatisfy({ $0.status == "ready" }) == true { break } }
            log("start heights=\(heights()) stops=\(navigatorScenes.map { $0.stops ?? 0 })")
            shot("expand-0.png")
            log("menu: \(navigatorMenu(row: 0)?.items.map(\.title) ?? [])")
            toggleExpandAllBuilds()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            log("expanded heights=\(heights()) label=\(window.toolbar?.items.first { $0.action == #selector(toggleExpandAllBuilds) }?.label ?? "-")")
            log("menu: \(navigatorMenu(row: 0)?.items.map(\.title) ?? [])")
            shot("expand-1.png")
            if let r = navigatorScenes.indices.last, let cell = table.view(atColumn: 0, row: r, makeIfNecessary: true) as? SlideCell {
                cell.onBuild?(1)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                log("after build click: scene=\(sceneName ?? "-") stop=\(stopIndex) heights=\(heights())")
                shot("expand-2.png")
            }
            toggleExpandAllBuilds()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            log("collapsed heights=\(heights()) label=\(window.toolbar?.items.first { $0.action == #selector(toggleExpandAllBuilds) }?.label ?? "-")")
            shot("expand-3.png")
            log("done")
        }
    }

    func notesTest() {
        let env = ProcessInfo.processInfo.environment
        let dir = (env["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? s.appendLine(to: dir + "notes.log") }
        func shot(_ name: String) {
            guard let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
        }
        Task { @MainActor in
            if let name = env["MANIMBLE_TEST_SCENE"] { await selectScene(name) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            drawer.show(.notes); setDrawerOpen(true)
            try? await Task.sleep(nanoseconds: 500_000_000); shot("drawer-slide.png")
            // a picture pasted into the slide notes: saved as Markdown, its file in the deck, shown inline again
            let img = NSImage(size: NSSize(width: 200, height: 120), flipped: false) { r in
                NSColor.systemOrange.setFill(); r.fill(); NSColor.white.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 60, dy: 20)).fill(); return true
            }
            let pb = NSPasteboard(name: .init("manimble-notes-test"))
            pb.clearContents(); pb.setData(img.tiffRepresentation, forType: .tiff)
            notesBox.setText("before"); notesBox.beginEditing()
            notesBox.window?.firstResponder.flatMap { $0 as? NSTextView }?.setSelectedRange(NSRange(location: 6, length: 0))
            let pasted = notesBox.pasteImages(pb)
            log("pasted=\(pasted) box=\(notesBox.stringValue) images=\(notesBox.imageCount)")
            window.makeFirstResponder(canvas)
            for _ in 0..<40 { try? await Task.sleep(nanoseconds: 250_000_000); if busy == 0, scene?.notes?.contains("![](note_") == true { break } }
            let file = scene?.notes.flatMap { n in n.range(of: #"note_[0-9a-f]+\.png"#, options: .regularExpression).map { String(n[$0]) } }
            log("notes=\(scene?.notes ?? "nil") file=\(file ?? "nil") exists=\(file.map { FileManager.default.fileExists(atPath: workspace!.work.appendingPathComponent($0).path) } ?? false) reloaded images=\(notesBox.imageCount) box=\(notesBox.stringValue)")
            shot("drawer-image.png")
            if env["MANIMBLE_TEST_PRESENTER_IMAGES"] != nil {     // the same notes in Presenter View, then stop
                presenterView()
                for _ in 0..<120 { try? await Task.sleep(nanoseconds: 500_000_000); if presenter != nil { break } }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let w = presenter?.window, let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "presenter-image.png"))
                }
                log("presenter=\(presenter != nil) notes images=\(presenter?.notesImageCount ?? -1)")
                presenter?.source.exit(); try? await Task.sleep(nanoseconds: 500_000_000)
                NSApp.terminate(nil); return
            }
            goToStop(1); drawer.show(.buildNotes)
            try? await Task.sleep(nanoseconds: 300_000_000)
            commitBuildNotes("second build only")
            for _ in 0..<40 { try? await Task.sleep(nanoseconds: 250_000_000); if busy == 0, scene?.buildNotes?[1] == "second build only" { break } }
            log("buildNotes=\(scene?.buildNotes ?? []) stop=\(stopIndex) box=\(buildNotesBox.stringValue) target=\(String(describing: buildNotesFor))")
            goToStop(0); try? await Task.sleep(nanoseconds: 300_000_000)
            log("at stop 0 box=\(buildNotesBox.stringValue)")
            goToStop(1); try? await Task.sleep(nanoseconds: 300_000_000); shot("drawer-build.png")
            showTerminalPage(); try? await Task.sleep(nanoseconds: 1_500_000_000); shot("drawer-term.png")
            log("terminals=\(terminal.tabCount)")
            let before = scene?.stops?.count ?? 0
            newBuild()
            for _ in 0..<60 { try? await Task.sleep(nanoseconds: 250_000_000); if busy == 0, (scene?.stops?.count ?? 0) != before { break } }
            log("builds \(before) -> \(scene?.stops?.count ?? 0) at stop \(stopIndex)")
            if let cs = centerSplit { cs.setPosition(cs.bounds.height, ofDividerAt: 0) }
            try? await Task.sleep(nanoseconds: 500_000_000); shot("collapsed.png")
            log("collapsed hidden=\(drawer.isHidden) showNotes=\(UserDefaults.standard.bool(forKey: "showNotes"))")
            if let cs = centerSplit { cs.setPosition(cs.bounds.height - 200, ofDividerAt: 0) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            log("reopened hidden=\(drawer.isHidden) showNotes=\(UserDefaults.standard.bool(forKey: "showNotes"))")
            NSApp.terminate(nil)
        }
    }

    /// Headless check of the animated player: builds, plays, steps, and logs what it is showing over time.
    func presentTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_SELFTEST"] ?? "/tmp") + "/"
        let log = dir + "present.log"
        try? "".write(toFile: log, atomically: true, encoding: .utf8)
        Task { @MainActor in
            if ProcessInfo.processInfo.environment["MANIMBLE_TEST_PRESENT"] == "presenter" {
                await presenterAnimatedTest(dir: dir, log: log); return
            }
            presentFromBeginning()
            for _ in 0..<600 { try? await Task.sleep(nanoseconds: 500_000_000); if animatedPlayer != nil { break } }
            guard let p = animatedPlayer else { try? "no player\n".appendLine(to: log); return }
            func note(_ what: String) { try? "\(what): \(p.debugState)\n".appendLine(to: log) }
            for k in 0..<6 { try? await Task.sleep(nanoseconds: 300_000_000); note("t\(k)") }
            p.next(); note("after next")
            for k in 0..<6 { try? await Task.sleep(nanoseconds: 300_000_000); note("t\(k)") }
            p.previous(); try? await Task.sleep(nanoseconds: 600_000_000); note("after previous")
            p.jump(section: 1); try? await Task.sleep(nanoseconds: 600_000_000); note("after section 2")
            for _ in 0..<12 { p.next(); try? await Task.sleep(nanoseconds: 120_000_000) }
            try? await Task.sleep(nanoseconds: 1_000_000_000); note("after 12 rapid nexts")
            p.exit()
            try? "exited player=\(animatedPlayer == nil)\n".appendLine(to: log)
        }
    }

    /// MANIMBLE_TEST_PRESENT=presenter: Presenter View over the animated show (both windows on one display).
    private func presenterAnimatedTest(dir: String, log: String) async {
        presenterViewAnimated()
        for _ in 0..<600 { try? await Task.sleep(nanoseconds: 500_000_000); if presenter != nil { break } }
        guard let pc = presenter, let p = pc.source as? AnimatedPlayer else { try? "no presenter\n".appendLine(to: log); return }
        func note(_ what: String) {
            try? "\(what): \(p.debugState) live=\(p.livePlayer != nil) state=\(p.playbackState ?? "-") audience=\(p.window.isVisible) panel=\(pc.liveFrameReady)\n".appendLine(to: log)
        }
        func shot(_ name: String) {
            guard let v = pc.window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
        }
        try? await Task.sleep(nanoseconds: 400_000_000); note("start"); shot("presenter1.png")
        try? await Task.sleep(nanoseconds: 1_500_000_000); note("settled")
        p.next(); try? await Task.sleep(nanoseconds: 300_000_000); note("after next"); shot("presenter2.png")
        try? await Task.sleep(nanoseconds: 1_500_000_000); note("settled"); shot("presenter3.png")
        pc.window.close()
        try? await Task.sleep(nanoseconds: 300_000_000)
        try? "closed presenter=\(presenter == nil)\n".appendLine(to: log)
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

    func numberOfRows(in tableView: NSTableView) -> Int { navigatorScenes.count }

    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard navigatorScenes.indices.contains(row) else { return nil }
        let s = navigatorScenes[row]
        let cell = (tv.makeView(withIdentifier: SlideCell.id, owner: nil) as? SlideCell) ?? SlideCell()
        var img: NSImage?
        if let t = s.thumb {
            let key = (DarkMode.mode.rawValue + ":" + t) as NSString
            img = thumbCache.object(forKey: key)
            if img == nil, let i = DarkMode.image(path: t) { thumbCache.setObject(i, forKey: key); img = i }
        }
        let unused = row >= (state?.scenes.count ?? 0)
        let listable = s.name == sceneName && scene?.name == sceneName ? hasBuildsList : buildsExpandedAll && (allBuildPages[s.name]?.count ?? 0) > 1
        let expanded: Bool? = listable ? !collapsedBuilds.contains(s.name) : nil
        cell.configure(number: unused ? 0 : row + 1, name: s.name, image: img, status: s.status, stops: s.stops ?? 0, active: s.name == sceneName, unused: unused, hidden: s.hidden == true, expanded: expanded)
        cell.onBuild = { [weak self] i in
            guard let self = self else { return }
            self.window.makeFirstResponder(self.table)     // so ↑/↓ keep stepping from the clicked build
            self.table.buildFocused = true                  // and Delete removes this build, not the slide
            if s.name == self.sceneName { self.goToStop(i); return }
            Task { @MainActor in                            // a build of another slide (Expand All): open that slide there
                await self.selectScene(s.name)
                guard self.sceneName == s.name else { return }
                self.table.buildFocused = true
                self.goToStop(i)
            }
        }
        let paths = buildPaths(row: row)
        if !paths.isEmpty { cell.setBuilds(buildImages(paths), active: s.name == sceneName ? stopIndex : -1) }
        return cell
    }

    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FlatRowView() }

    /// Keep the single column exactly as wide as the sidebar so thumbnails never run off the edge.
    func fitSidebarColumn() {
        guard let side = sideScroll, let col = table.tableColumns.first else { return }
        let w = max(120, side.contentSize.width)
        if abs(col.width - w) > 0.5 { col.width = w; noteSlideRowHeights() }
    }

    // MARK: builds nested under the selected slide

    /// Slides whose builds list the user folded away by clicking the selected slide again.
    private var collapsedBuilds = Set<String>()

    /// Whether the selected slide has a builds list at all (more than one build, scene loaded).
    private var hasBuildsList: Bool {
        guard let n = sceneName, let sc = scene, sc.name == n else { return false }
        return (sc.stops?.count ?? 0) > 1
    }

    /// Row of the selected slide when its builds are listed under it.
    var buildsRow: Int? {
        guard let n = sceneName, let r = navigatorScenes.firstIndex(where: { $0.name == n }), !buildPaths(row: r).isEmpty else { return nil }
        return r
    }

    /// Expand All: every slide lists its builds, not just the selected one (until Collapse All).
    private(set) var buildsExpandedAll = false
    /// Each slide's build pictures from `deck_pages`, for the slides other than the selected one under Expand All.
    private var allBuildPages: [String: [String]] = [:]

    /// Pictures of the builds listed under row `row` (empty when none are): the selected slide's from its loaded
    /// scene, the others' (under Expand All) from `deck_pages`.
    private func buildPaths(row: Int) -> [String] {
        guard navigatorScenes.indices.contains(row) else { return [] }
        let n = navigatorScenes[row].name
        guard !collapsedBuilds.contains(n) else { return [] }
        if n == sceneName, let sc = scene, sc.name == n {
            let p = sc.stops?.map(\.png) ?? []
            return p.count > 1 ? p : []
        }
        guard buildsExpandedAll, let p = allBuildPages[n], p.count > 1 else { return [] }
        return p
    }

    /// Expand or collapse the builds list under every slide (toolbar and navigator menu).
    @objc func toggleExpandAllBuilds() {
        buildsExpandedAll.toggle()
        if buildsExpandedAll {
            collapsedBuilds.removeAll()
            Task { @MainActor in await fetchAllBuildPages() }
        } else {
            collapsedBuilds = Set(navigatorScenes.map(\.name))
        }
        updateExpandAllItem()
        reloadAllSlideRows()
        if let r = buildsRow ?? sceneName.flatMap({ n in navigatorScenes.firstIndex(where: { $0.name == n }) }) { table.scrollRowToVisible(r) }
    }

    /// Fetch the build pictures of every slide under Expand All (renders nothing: slides still rendering come in
    /// with their `rendered` events) and redraw the rows whose builds changed.
    func fetchAllBuildPages() async {
        guard buildsExpandedAll, let d = try? await engine.call("deck_pages", ["ahead": 0], as: DeckPages.self), buildsExpandedAll else { return }
        let old = allBuildPages
        allBuildPages = Dictionary(d.slides.filter { !$0.pages.isEmpty }.map { ($0.scene, $0.pages) }, uniquingKeysWith: { a, _ in a })
        let rows = IndexSet(navigatorScenes.indices.filter { old[navigatorScenes[$0].name] != allBuildPages[navigatorScenes[$0].name] })
        guard !rows.isEmpty else { return }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.18; table.noteHeightOfRows(withIndexesChanged: rows) }, completionHandler: nil)
    }

    private func reloadAllSlideRows() {
        guard table.numberOfRows > 0 else { return }
        let all = IndexSet(integersIn: 0..<table.numberOfRows)
        table.reloadData(forRowIndexes: all, columnIndexes: IndexSet(integer: 0))
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; table.noteHeightOfRows(withIndexesChanged: all) }
        shownBuildsRow = buildsRow
    }
    private var shownBuildsRow: Int?

    /// Fold or unfold the builds list under the selected slide (a click on the selected slide).
    func toggleBuildsList() {
        guard hasBuildsList, let n = sceneName else { return }
        if collapsedBuilds.contains(n) { collapsedBuilds.remove(n) } else { collapsedBuilds.insert(n) }
        if let r = navigatorScenes.firstIndex(where: { $0.name == n }) { shownBuildsRow = shownBuildsRow ?? r }
        refreshBuildRows()
    }

    /// ↑/↓ in the navigator: walk the builds of the current slide, then cross into the neighbouring slide with its
    /// builds unfolded, entering at its first build going down and at its last build going up.
    func stepNavigator(_ d: Int) {
        guard let n = sceneName, let row = navigatorScenes.firstIndex(where: { $0.name == n }) else { return }
        let count = scene?.name == n ? (scene?.stops?.count ?? 0) : 0
        if count > 1, (0..<count).contains(stopIndex + d) {
            collapsedBuilds.remove(n)
            table.buildFocused = true
            goToStop(stopIndex + d)
            return
        }
        table.buildFocused = false
        guard navigatorScenes.indices.contains(row + d) else { return }
        let next = navigatorScenes[row + d].name
        collapsedBuilds.remove(next)
        Task { @MainActor in
            await selectScene(next)
            if window.firstResponder !== table { window.makeFirstResponder(table) }
            if d < 0, sceneName == next, scene?.name == next, let last = scene?.stops?.indices.last, last > 0 { goToStop(last) }
        }
    }

    func tableView(_ tv: NSTableView, heightOfRow row: Int) -> CGFloat {
        let n = buildPaths(row: row).count
        return SlideCell.rowHeight(columnWidth: tv.tableColumns.first?.width ?? 220, builds: n)
    }

    /// Images for the builds listed under a slide (nil while a thumbnail is still rendering).
    func buildImages(_ paths: [String]) -> [NSImage?] {
        paths.map { png in
            let key = (DarkMode.mode.rawValue + ":" + png) as NSString
            if let i = thumbCache.object(forKey: key) { return i }
            guard let i = DarkMode.image(path: png) else { return nil }
            thumbCache.setObject(i, forKey: key); return i
        }
    }

    /// Expand the builds list under the selected slide, collapse it under the previous one, and mark the current build.
    func refreshBuildRows() {
        var rows = IndexSet()
        if let o = shownBuildsRow { rows.insert(o) }
        if let n = buildsRow { rows.insert(n) }
        shownBuildsRow = buildsRow
        rows = IndexSet(rows.filter { navigatorScenes.indices.contains($0) })
        guard !rows.isEmpty else { return }
        table.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            table.noteHeightOfRows(withIndexesChanged: rows)
        }
        if let n = buildsRow { table.scrollRowToVisible(n) }
    }

    /// The sidebar changed width: thumbnails (and the nested panels) scale with it, so re-measure every row.
    func noteSlideRowHeights() {
        guard table.numberOfRows > 0 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
        }
    }

    /// Show build `i` of the current slide.
    func goToStop(_ i: Int) {
        guard let n = scene?.stops?.count, (0..<n).contains(i) else { return }
        if i != stopIndex && buildNotesBox.isEditing { window.makeFirstResponder(canvas) }     // commits its notes first
        stopIndex = i; canvas.overrides = [:]; canvas.lineOverrides = [:]; applyStop(); rebuildSteps(); rebuildInspector()
    }

    func refreshRings() {
        for r in navigatorScenes.indices {
            (table.view(atColumn: 0, row: r, makeIfNecessary: false) as? SlideCell)?.setActive(navigatorScenes[r].name == sceneName)
        }
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        if suppressTable { return }
        let r = table.selectedRow
        guard navigatorScenes.indices.contains(r) else { return }
        let s = navigatorScenes[r]
        guard s.name != sceneName else { return }
        Task { @MainActor in await selectScene(s.name) }
    }

    func tableView(_ tv: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tv === table, player == nil, let scenes = state?.scenes, scenes.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(scenes[row].name, forType: slideDragType)
        return item
    }

    func tableView(_ tv: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard tv === table, info.draggingSource as? NSTableView === table, player == nil,
              let scenes = state?.scenes, (0...scenes.count).contains(row),
              let name = info.draggingPasteboard.string(forType: slideDragType),
              let source = scenes.firstIndex(where: { $0.name == name }),
              row != source && row != source + 1 else { return [] }
        tv.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tv: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard tableView(tv, validateDrop: info, proposedRow: row, proposedDropOperation: operation) == .move,
              let name = info.draggingPasteboard.string(forType: slideDragType) else { return false }
        slideOp("reorder", index: row, sceneOverride: name)
        return true
    }

    // MARK: steps strip

    func rebuildSteps() {
        stepsBar.arrangedSubviews.forEach { $0.removeFromSuperview() }
        refreshBuildRows()
        guard let stops = scene?.stops, stops.count > 1 else { return }
        let l = NSTextField(labelWithString: "BUILDS"); l.textColor = Theme.ink(0.45); l.font = Theme.font(10, .semibold)
        stepsBar.addArrangedSubview(l)
        for (i, st) in stops.enumerated() {
            let b = StepButton(path: st.png, index: i, active: i == stopIndex) { [weak self] in self?.goToStop(i) }
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
        defer { syncFormatBar() }
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
                let f = MultilineTextBox(string: o.value)
                f.onCommit = { [weak self] v in self?.commitText(sel, v, shared: self?.sharedChoice ?? true) }
                width(f)
                textField = f; inspector.addArrangedSubview(f)
                let hint = NSTextField(labelWithString: "↵ new line  ·  ⌘↵ apply  ·  esc revert")
                hint.font = Theme.font(10); hint.textColor = .tertiaryLabelColor
                inspector.addArrangedSubview(hint)
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
        if let b = canvas.stop?.box(of: sel) { geometryRows(b, o) }
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

    func geometryRows(_ b: Box, _ o: ObjInfo) {
        inspector.addArrangedSubview(hairline())
        inspector.addArrangedSubview(sectionLabel("Arrange"))
        func field(_ title: String, _ value: Double, _ sel: Selector, decimals: Int = 0) -> NSView {
            let f = NSTextField(string: decimals == 0 ? String(Int(value.rounded())) : String(format: "%.\(decimals)f", value))
            f.target = self; f.action = sel
            f.widthAnchor.constraint(equalToConstant: 80).isActive = true
            let s = NSStackView(views: [label(title), f]); s.orientation = .vertical; s.alignment = .leading; s.spacing = 2
            return s
        }
        func row(_ views: [NSView]) { let r = NSStackView(views: views); r.spacing = 16; r.alignment = .bottom; inspector.addArrangedSubview(r) }
        let dims = o.dims ?? [b.w, b.h]
        row([field("X (px)", b.cx, #selector(xCommitted(_:))), field("Y (px)", b.cy, #selector(yCommitted(_:)))])
        row([field("Width", dims[0], #selector(wCommitted(_:))), field("Height", dims[1], #selector(hCommitted(_:)))])
        if o.kind != "line" {
            var views: [NSView] = [field("Rotation (°)", o.rotation ?? 0, #selector(rotationCommitted(_:)), decimals: 1)]
            if o.kind == "image" || o.kind == "shape" {
                let lock = NSButton(checkboxWithTitle: "Keep aspect ratio", target: self, action: #selector(aspectToggled(_:)))
                lock.state = aspectLocked ? .on : .off; lock.font = Theme.font(11)
                lock.toolTip = "Off: width and height stretch the picture or shape independently"
                views.append(lock)
            }
            row(views)
        }
    }

    @objc func aspectToggled(_ b: NSButton) { aspectLocked = b.state == .on }

    /// Width and height from manim (what stretching sets), falling back to the on-screen box.
    func currentDims(_ s: Int) -> (Double, Double)? {
        if let d = objInfo?.dims, d.count == 2, d[0] > 0, d[1] > 0 { return (d[0], d[1]) }
        if let b = canvas.stop?.box(of: s), b.w > 0, b.h > 0 { return (b.w, b.h) }
        return nil
    }

    @objc func xCommitted(_ f: NSTextField) { if let s = selection, let b = canvas.stop?.box(of: s) { commitMove(s, f.doubleValue - b.cx, 0) } }
    @objc func yCommitted(_ f: NSTextField) { if let s = selection, let b = canvas.stop?.box(of: s) { commitMove(s, 0, f.doubleValue - b.cy) } }
    @objc func wCommitted(_ f: NSTextField) { commitDimension(width: f.doubleValue) }
    @objc func hCommitted(_ f: NSTextField) { commitDimension(height: f.doubleValue) }

    /// One dimension typed in the inspector: proportional resize when the aspect ratio is kept (or for text),
    /// otherwise a stretch of that dimension alone.
    func commitDimension(width: Double? = nil, height: Double? = nil) {
        guard let s = selection, let o = objInfo, let (w, h) = currentDims(s) else { return }
        let stretch = !aspectLocked && (o.kind == "image" || o.kind == "shape")
        if !stretch {
            if let v = width, v > 0 { commitResize(s, v / w) } else if let v = height, v > 0 { commitResize(s, v / h) }
            return
        }
        var req: [String: Any] = ["op": "size", "oid": s]
        if let v = width, v > 0 { req["width"] = v }
        if let v = height, v > 0 { req["height"] = v }
        guard req.count > 2 else { return }
        submit { [weak self] in await self?.runEdit(req) }
    }

    @objc func rotationCommitted(_ f: NSTextField) {
        guard let s = selection else { return }
        let deg = f.doubleValue
        submit { [weak self] in await self?.runEdit(["op": "rotate", "oid": s, "degrees": deg]) }
    }

    // MARK: edits

    var objInfo: ObjInfo? { selection.flatMap { scene?.objects?[String($0)] } }

    /// Run edit operations strictly one after another.
    func submit(_ work: @escaping @MainActor () async -> Void) {
        let prev = queueTail
        queueTail = Task { @MainActor in await prev?.value; await work() }
    }

    /// The edits `body` submits (one per object of a multi-object selection) become one undo step, `label`.
    func asOneUndoStep(_ label: String, _ body: () -> Void) {
        var mark: Int?
        submit { [weak self] in mark = (try? await self?.engine.call("undo_mark", as: UndoMark.self))?.mark }
        body()
        submit { [weak self] in
            guard let self = self, let m = mark,
                  let r = try? await self.engine.call("undo_merge", ["mark": m, "label": label], as: UndoResult.self),
                  r.ok == true else { return }
            await self.reloadState()
        }
    }

    func runEdit(_ req: [String: Any]) async {
        guard let name = (req["scene"] as? String) ?? sceneName else { return }
        let oid = req["oid"] as? Int
        let before = sceneName == name ? canvas.stop : nil
        busy += 1
        var r = req; r["scene"] = name; r["stop"] = stopIndex
        if ProcessInfo.processInfo.environment["MANIMBLE_SYNC_EDITS"] != nil { r["optimistic"] = false }
        var result: EditResult?
        var failure: String?
        do { result = try await engine.call("edit", r, as: EditResult.self) } catch { failure = "\(error)" }
        busy -= 1
        var ok = false
        lastBuildMove = nil
        if let res = result, res.ok == true {
            ok = true
            lastChanged = res.changed
            if res.oneBuild == true, let oid = oid { lastBuildMove = (name, oid, r["stop"] as? Int ?? 0) }
            var msg = res.message == "no change" ? "No change" : "Saved · \(res.message ?? "")"
            if res.oneBuild == true { msg += " · ⌘A applies it to every build" }
            if let n = res.siblings { msg += " (\(n) similar objects share this line; all moved)" }
            toast(msg)
        } else {
            toast(failure ?? result?.error ?? "edit failed", error: true)
            lastChanged = nil
        }
        // the render lands under whatever the user is doing now: only the edited object's preview is settled
        await loadScene(name, keepStop: true, keepOverrides: true)
        if let oid = oid, sceneName == name { settlePreview(name, oid, ok: ok, before: before) }
        await reloadState()
        // a restyled or moved slide number: offer it to the other slides once the series of edits is done
        if ok, result?.pageNumber == true, let oid = oid, pendingMoves["\(name):\(oid)"] == nil, !canvas.isDragging(oid) {
            offerPageNumberSpread(name)
        }
    }

    /// Moves committed while an earlier render was still running, by "scene:oid": one edit sends their total.
    var pendingMoves: [String: (dx: Double, dy: Double)] = [:]

    func commitMove(_ oid: Int, _ dx: Double, _ dy: Double) {
        guard let scene = sceneName else { return }
        let key = "\(scene):\(oid)"
        if let p = pendingMoves[key] { pendingMoves[key] = (p.dx + dx, p.dy + dy); return }   // one render for the series
        pendingMoves[key] = (dx, dy)
        submit { [weak self] in
            guard let self = self, let p = self.pendingMoves.removeValue(forKey: key) else { return }
            await self.runEdit(["op": "move", "oid": oid, "dx": p.dx, "dy": p.dy, "scene": scene, "build": true])
        }
    }

    /// Cmd-A: selects all the text in a focused text box, else, right after a move in one build, applies that
    /// move to every build of the slide instead. (Every menu item the controller answers to is targeted at it,
    /// so the text box never sees the key on its own.)
    @objc func selectAll(_ sender: Any?) {
        if let t = otherWindowText { t.selectAll(sender); return }
        if let t = window.firstResponder as? NSText { t.selectAll(sender); return }
        submit { [weak self] in                 // after the move itself, when it is still queued
            guard let self = self, let m = self.lastBuildMove, m.scene == self.sceneName, m.stop == self.stopIndex else { return }
            await self.runEdit(["op": "spread", "oid": m.oid, "scene": m.scene])
        }
    }

    /// After an edit the fresh render is the truth for that object, so its preview goes away. While more of its
    /// moves are queued or it is being dragged, it keeps previewing only what the slide does not show yet.
    func settlePreview(_ scene: String, _ oid: Int, ok: Bool, before: StopInfo?) {
        canvas.lineOverrides[oid] = nil
        let live = pendingMoves["\(scene):\(oid)"] != nil || canvas.isDragging(oid)
        guard ok, live, let a = before?.box(of: oid), let b = canvas.stop?.box(of: oid) else {
            canvas.overrides[oid] = nil
            if !ok { pendingMoves["\(scene):\(oid)"] = nil }
            return
        }
        canvas.settle(oid, shownDx: b.cx - a.cx, shownDy: b.cy - a.cy)
    }
    func commitEndpoints(_ oid: Int, _ e: [Double], anchors: [String: Any] = [:]) {
        let req = anchors.merging(["op": "endpoints", "oid": oid, "sx": e[0], "sy": e[1], "ex": e[2], "ey": e[3]]) { $1 }
        submit { [weak self] in await self?.runEdit(req) }
    }
    func commitResize(_ oid: Int, _ ratio: Double) {
        if canvas.overrides[oid] == nil { canvas.overrides[oid] = Override(scale: ratio) }
        submit { [weak self] in await self?.runEdit(["op": "resize", "oid": oid, "ratio": ratio]) }
    }

    func commitWrap(_ oid: Int, _ width: Double, _ side: String) {
        submit { [weak self] in await self?.runEdit(["op": "wrap", "oid": oid, "width": width, "side": side]) }
    }

    func nudgeObject(_ oid: Int, _ dx: Double, _ dy: Double) {
        let p = nudge[oid] ?? (0, 0); nudge[oid] = (p.dx + dx, p.dy + dy)
        var o = canvas.overrides[oid] ?? Override()
        o.dx += dx; o.dy += dy                 // on top of whatever is still previewed (moves not yet rendered)
        canvas.overrides[oid] = o
        nudgeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let all = self.nudge; self.nudge = [:]
            let send = { for (id, d) in all.sorted(by: { $0.key < $1.key }) { self.commitMove(id, d.dx, d.dy) } }
            if all.count > 1 { self.asOneUndoStep("move \(all.count) objects", send) } else { send() }
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

    /// `previewed` runs once the new text shows on the canvas (or at once when there is nothing to apply).
    func commitText(_ oid: Int, _ value: String, shared: Bool, previewed: (() -> Void)? = nil) {
        guard let o = scene?.objects?[String(oid)], value != o.value else { previewed?(); return }
        submit { [weak self] in
            guard let self = self else { previewed?(); return }
            await self.previewSprite(oid, kind: o.kind, value: value, size: o.fontSize ?? 30, color: o.color, font: o.font, weight: o.weight, slant: o.slant)
            previewed?()
            await self.runEdit(["op": "text", "oid": oid, "value": value, "shared": shared])
        }
    }

    @objc func sizeCommitted(_ f: NSTextField) { commitFontSize(f.doubleValue) }

    @objc func sizeStepped(_ st: NSStepper) {
        sizeField?.doubleValue = st.doubleValue
        formatBar?.sizeField.doubleValue = st.doubleValue
        commitFontSize(st.doubleValue)
    }

    func commitFontSize(_ v: Double) {
        guard let s = selection, let o = objInfo, v >= 4, o.kind == "text" || o.kind == "tex" else { return }
        submit { [weak self] in
            guard let self = self else { return }
            await self.previewSprite(s, kind: o.kind, value: o.value, size: v, color: o.color, font: o.font, weight: o.weight, slant: o.slant)
            await self.runEdit(["op": "font", "oid": s, "value": v])
        }
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

    /// `at`: where a double-click landed (window coordinates), for the text caret.
    func beginEdit(_ oid: Int, at: CGPoint? = nil) {
        guard let o = scene?.objects?[String(oid)] else { return }
        if o.kind == "tex" { openLatex(oid) }
        else if o.kind == "text", o.textOk == true {
            if !beginInlineText(oid, o, at: at) { textField?.beginEditing() }
        }
        else if o.kind == "table", !beginCellEdit(oid, o, at: at), let f = tableCells.first?.first { window.makeFirstResponder(f); f.selectText(nil) }
    }
    /// Type into the table cell under `at` (the first cell without one) right on the slide; its inspector cell follows along.
    func beginCellEdit(_ oid: Int, _ o: ObjInfo, at: CGPoint?) -> Bool {
        guard let stop = canvas.stop, canvas.overrides[oid] == nil,
              let c = at.map({ stop.tableCell(oid, at: canvas.framePoint(window: $0)) }) ?? stop.tableCells(oid).first else { return false }
        let rows = tableCells.isEmpty ? tableRows(o.value) : tableDraft()
        guard c.row < rows.count, c.col < rows[c.row].count else { return false }
        let current = rows[c.row][c.col]
        func mirror(_ v: String) {
            if c.row < tableCells.count, c.col < tableCells[c.row].count { tableCells[c.row][c.col].stringValue = v }
        }
        return canvas.beginTextEdit(oid, text: current, family: o.font, bold: false, italic: false, color: o.color, at: at,
                                    cell: c, sizing: current.isEmpty ? "Cell" : nil,      // a blank cell's ink is a hidden "Cell"
                                    changed: { mirror($0) },
                                    done: { [weak self] v, release in
                                        guard let self = self, let v = v else { mirror(current); release(); return }
                                        var rows = rows
                                        rows[c.row][c.col] = v
                                        self.submit { [weak self] in
                                            await self?.runEdit(["op": "table", "oid": oid, "rows": rows])
                                            release()
                                        }
                                    })
    }
    /// Type into a Text object right on the slide; the inspector's box follows along.
    func beginInlineText(_ oid: Int, _ o: ObjInfo, at: CGPoint?) -> Bool {
        let current = textField?.stringValue ?? o.value          // includes an applied edit still rendering
        return canvas.beginTextEdit(oid, text: current, family: o.font, bold: o.weight == "BOLD", italic: o.slant == "ITALIC",
                                    color: o.color, at: at, align: o.format?.align ?? "left", valign: o.format?.valign ?? "top",
                                    lineSpacing: o.format?.lineSpacing, frame: o.frameBox,
                                    changed: { [weak self] v in self?.textField?.setText(v) },
                                    done: { [weak self] v, release in
                                        guard let self = self, let v = v else { self?.textField?.setText(current); release(); return }
                                        self.commitText(oid, v, shared: self.sharedChoice, previewed: release)
                                    })
    }
    /// Type into an empty layout box; the text lands left-aligned at the box's left edge, as in PowerPoint.
    func beginPlaceholder(_ ph: Placeholder) {
        guard let name = sceneName else { return }
        selection = nil; canvas.selection = nil
        let light = canvas.backdropIsLight(ph.rect)       // a white slide needs dark text (Text defaults to white)
        _ = canvas.beginTextEdit(-1, text: ph.role == "body" ? CanvasView.bullet : "", family: scene?.font, bold: false, italic: false, color: light ? "#000000" : "#FFFFFF",
                                 at: nil, placeholder: ph, changed: { _ in },
                                 done: { [weak self] v, release in
                                     // bullets left on empty lines are dropped
                                     let v = v?.components(separatedBy: "\n")
                                         .filter { !$0.trimmingCharacters(in: CharacterSet(charactersIn: "\u{2022}").union(.whitespaces)).isEmpty }
                                         .joined(separator: "\n")
                                     guard let self = self, let v = v, !v.isEmpty else { release(); return }
                                     self.submit { [weak self] in
                                         guard let self = self else { release(); return }
                                         self.busy += 1
                                         var req: [String: Any] = ["scene": name, "line": ph.line, "text": v]
                                         if light { req["color"] = "#000000" }
                                         let res = try? await self.engine.call("placeholder", req, as: EditResult.self)
                                         self.busy -= 1
                                         if res?.ok == true { self.lastChanged = res?.changed; self.toast("Saved · \(res?.message ?? "")") }
                                         else { self.toast(res?.error ?? "could not add the text", error: true) }
                                         await self.loadScene(name, keepStop: true, keepOverrides: true)
                                         release()
                                         await self.reloadState()
                                     }
                                 })
    }
    /// Remove an empty layout box (Backspace with nothing typed in it).
    func removePlaceholder(_ line: Int) {
        guard let name = sceneName else { return }
        submit { [weak self] in
            guard let self = self else { return }
            self.busy += 1
            let res = try? await self.engine.call("placeholder", ["scene": name, "line": line, "op": "remove"], as: EditResult.self)
            self.busy -= 1
            if res?.ok == true { self.lastChanged = res?.changed; self.toast("Saved · \(res?.message ?? "")") }
            else { self.toast(res?.error ?? "could not remove the box", error: true) }
            await self.loadScene(name, keepStop: true, keepOverrides: true)
            await self.reloadState()
        }
    }
    @objc func editLatexPressed() { if let s = selection { openLatex(s) } }

    // MARK: LaTeX sheet

    var latexSheet: LatexSheet?
    var biocartoonPane: BioCartoonPane?
    var backgroundSheet: BackgroundSheet?
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

    func beginSourceEditing() {
        if sourceFocused { return }
        guard let name = sceneName, let src = scene?.source else { return }
        sourceFocused = true
        if sourceEditSceneName != name || sourceEditBase == nil {
            sourceEditBase = src
            sourceEditSceneName = name
            sourceDraft = nil
        }
        let wasDraft = sourceDraft != nil
        let position = sourceView.selectedRange().location
        let old = sourceView.string as NSString
        let prefix = old.substring(to: min(position, old.length))
        let line = prefix.filter { $0 == "\n" }.count
        sourceView.string = sourceDraft ?? src.text
        recolorSource()
        updateSourceCardBorder()
        let caret = min(max(0, position - (wasDraft ? 0 : 7 * (line + 1))), (sourceView.string as NSString).length)
        sourceView.setSelectedRange(NSRange(location: caret, length: 0))
        srcHeader.stringValue = "PYTHON  ·  \(src.file):\(src.start)  ·  EDITING"
    }

    func sourceTextChanged() {
        if animationPreview != nil { closeAnimationPreview() }
        guard sourceFocused, let base = sourceEditBase else { return }
        recolorSource()
        sourceDraft = sourceView.string == base.text ? nil : sourceView.string
        srcHeader.stringValue = "PYTHON  ·  \(base.file):\(base.start)" + (sourceDraft == nil ? "  ·  EDITING" : "  ·  UNSAVED CODE")
        if sourceDraft != nil { clearSourceError() }
        updateDocumentState()
    }

    func endSourceEditing() {
        sourceFocused = false
        updateSourceCardBorder()
        guard sourceDraft != nil else { sourceEditBase = nil; renderSource(); return }
        submit { [weak self] in await self?.commitSourceDraft() }
    }

    func commitSourceDraft() async {
        guard let name = sourceEditSceneName, let base = sourceEditBase, let draft = sourceDraft else { return }
        busy += 1
        let result: SourceEditResult?
        var failure: String?
        do {
            result = try await engine.call("edit_source", ["scene": name, "file": base.file,
                                                           "expected": base.text, "text": draft], as: SourceEditResult.self)
        } catch {
            result = nil
            failure = "\(error)"
        }
        busy -= 1
        guard result?.ok == true else {
            let message = result?.error ?? failure ?? "Could not update Python source"
            showSourceError(message)
            toast(message, error: true)
            updateDocumentState()
            return
        }
        lastChanged = result?.changed
        let hasNewerDraft = sourceDraft != draft
        if !hasNewerDraft {
            sourceDraft = nil
        }
        if sceneName == name { await loadScene(name, keepStop: true) }
        sourceEditBase = scene?.source
        await reloadState()
        if result?.error == nil { toast("Python source updated") }
        updateDocumentState()
        if hasNewerDraft && !sourceFocused { submit { [weak self] in await self?.commitSourceDraft() } }
    }

    func clearSourceError() {
        sourceErrorMessage = nil
        sourceError.stringValue = ""
        sourceError.toolTip = nil
        sourceError.isHidden = true
        sourceErrorButton.isHidden = true
    }

    func showSourceError(_ message: String) {
        sourceErrorMessage = message
        let lines = message.split(separator: "\n", omittingEmptySubsequences: true)
        sourceError.stringValue = lines.suffix(5).joined(separator: "\n")
        sourceError.toolTip = message
        sourceError.isHidden = false
        sourceErrorButton.isHidden = false
        srcHeader.stringValue = "PYTHON  ·  ERROR"
    }

    @objc func showSourceErrorDetails() {
        guard let message = sourceErrorMessage else { return }
        let alert = NSAlert(); alert.alertStyle = .critical
        alert.messageText = "Python error"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func renderSource() {
        if sourceFocused || sourceDraft != nil { return }
        guard let src = scene?.source else { sourceView.isEditable = false; sourceView.string = ""; return }
        sourceView.isEditable = true
        clearSourceError()
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
            let numAttr: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: MainController.pyComment, .backgroundColor: bg]
            let txtAttr: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: MainController.pyText, .backgroundColor: bg]
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
        if scene?.status == "error", let message = scene?.error { showSourceError(message) }
    }
    // Python syntax colouring (a dark and a light palette)
    private static func py(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        Theme.dynamic(light: NSColor(srgbRed: light.0, green: light.1, blue: light.2, alpha: 1),
                      dark: NSColor(srgbRed: dark.0, green: dark.1, blue: dark.2, alpha: 1))
    }
    static let pyText = py((0.13, 0.13, 0.15), (0.88, 0.88, 0.88))
    static let pyComment = py((0.48, 0.48, 0.52), (0.5, 0.5, 0.5))
    static let pyConstColor = py((0.0, 0.38, 0.62), (0.55, 0.80, 0.95))
    static let pyCallColor = py((0.0, 0.48, 0.42), (0.45, 0.85, 0.75))
    static let pyKeywordColor = py((0.72, 0.08, 0.42), (1.0, 0.48, 0.70))
    static let pyNumberColor = py((0.55, 0.42, 0.0), (0.85, 0.80, 0.50))
    static let pyStringColor = py((0.70, 0.25, 0.08), (1.0, 0.58, 0.45))
    static let pyKeywords = try! NSRegularExpression(pattern: "\\b(def|class|self|for|in|if|elif|else|return|import|from|as|with|while|and|or|not|None|True|False|lambda|pass|yield|try|except|raise|is|assert|break|continue)\\b")
    static let pyNumbers = try! NSRegularExpression(pattern: "(?<![\\w.])\\d+(\\.\\d+)?")
    static let pyStrings = try! NSRegularExpression(pattern: "[rbf]?(\"[^\"\\n]*\"|'[^'\\n]*')")
    static let pyCalls = try! NSRegularExpression(pattern: "\\b([A-Za-z_][A-Za-z_0-9]*)(?=\\()")
    static let pyConsts = try! NSRegularExpression(pattern: "\\b[A-Z][A-Z0-9_]{2,}\\b")

    func highlight(_ line: String, bg: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString(string: line, attributes: [.font: Theme.mono(11.5), .foregroundColor: MainController.pyText, .backgroundColor: bg])
        MainController.paintPython(out, line: line, at: 0)
        return out
    }

    /// Colours one line of Python (starting at `offset` in `out`) by recolouring foreground runs only.
    static func paintPython(_ out: NSMutableAttributedString, line: String, at offset: Int) {
        let ns = line as NSString
        func paint(_ re: NSRegularExpression, _ color: NSColor) {
            re.enumerateMatches(in: line, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                if let r = m?.range { out.addAttribute(.foregroundColor, value: color, range: NSRange(location: r.location + offset, length: r.length)) }
            }
        }
        paint(MainController.pyConsts, MainController.pyConstColor)
        paint(MainController.pyCalls, MainController.pyCallColor)
        paint(MainController.pyKeywords, MainController.pyKeywordColor)
        paint(MainController.pyNumbers, MainController.pyNumberColor)
        paint(MainController.pyStrings, MainController.pyStringColor)
        if let h = line.firstIndex(of: "#") {
            let before = String(line[..<h])
            if before.filter({ $0 == "\"" }).count % 2 == 0 && before.filter({ $0 == "'" }).count % 2 == 0 {
                let u = (before as NSString).length
                out.addAttribute(.foregroundColor, value: MainController.pyComment, range: NSRange(location: u + offset, length: ns.length - u))
            }
        }
    }

    /// Re-applies syntax colours to the editable source in place (attributes only, so the caret, scroll and
    /// undo stack are untouched); runs on focus and after every keystroke.
    func recolorSource() {
        guard let storage = sourceView.textStorage else { return }
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        storage.setAttributes([.font: Theme.mono(11.5), .foregroundColor: MainController.pyText], range: full)
        var pos = 0
        while pos < text.length {
            let lineRange = text.lineRange(for: NSRange(location: pos, length: 0))
            MainController.paintPython(storage, line: text.substring(with: lineRange), at: lineRange.location)
            pos = NSMaxRange(lineRange)
        }
        storage.endEditing()
        sourceView.typingAttributes = [.font: Theme.mono(11.5), .foregroundColor: MainController.pyText]
    }

    func updateSourceCardBorder() {
        guard let layer = sourceCard?.layer else { return }
        sourceCard?.effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = (self.sourceFocused ? Theme.accent : Theme.ink(0.12)).cgColor
        }
        layer.borderWidth = sourceFocused ? 2 : 1
    }

    func highlightSource() { if scene?.source != nil { renderSource() } }

    // MARK: undo / navigation / misc

    @objc func undo() { doUndo(redo: false) }
    @objc func redo() { doUndo(redo: true) }
    /// Text being typed in another window (Presenter View's notes): the Edit menu, targeted at this controller,
    /// must act on that text rather than on the deck.
    private var otherWindowText: NSText? {
        guard let w = NSApp.keyWindow, w !== window else { return nil }
        return w.firstResponder as? NSText
    }

    func doUndo(redo: Bool) {
        if let t = otherWindowText {
            if redo { t.undoManager?.redo() } else { t.undoManager?.undo() }
            return
        }
        if window.firstResponder === sourceView || sourceDraft != nil {
            window.makeFirstResponder(sourceView)
            if redo { sourceView.undoManager?.redo() } else { sourceView.undoManager?.undo() }
            return
        }
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
    // MARK: Play with animations (native Manim Slides player)

    /// Frame height the animations are built at (Play ▸ Animation Resolution); 720p unless chosen otherwise.
    var animationHeight: Int {
        let h = UserDefaults.standard.integer(forKey: "animationHeight")
        return [720, 1080, 1440, 2160].contains(h) ? h : 720
    }

    @objc func animationResolutionChosen(_ m: NSMenuItem) {
        guard let h = m.representedObject as? Int else { return }
        UserDefaults.standard.set(h, forKey: "animationHeight")
        toast(h == 720 ? "Animations build at 720p" : "Animations build at \(h == 2160 ? "4K" : "\(h)p") from the next show (slides rebuild once)")
    }

    /// Play menu: whether Play and Presenter View run the animated show (manim clips) or the stills slideshow.
    var showAnimations: Bool { UserDefaults.standard.bool(forKey: "playShowAnimations") }
    @objc func toggleShowAnimations() {
        UserDefaults.standard.set(!showAnimations, forKey: "playShowAnimations")
        toast(showAnimations ? "Play shows animations" : "Play shows still slides")
    }
    @objc func playMenuFromBeginning() { showAnimations ? presentFromBeginning() : playFromBeginning() }
    @objc func playMenuFromCurrent() { showAnimations ? presentFromCurrent() : playFromCurrent() }
    @objc func playMenuPresenter() { showAnimations ? presenterViewAnimated() : presenterView() }

    @objc func presentFromCurrent() { present(fromCurrent: true) }
    @objc func presentFromBeginning() { present(fromCurrent: false) }
    /// Presenter View (notes, next build, timer) over the animated show, from the current slide.
    @objc func presenterViewAnimated() { present(fromCurrent: true, withPresenter: true) }

    /// Builds any out-of-date slides with manim, then plays their clips in AnimatedPlayer (see the "ready" event).
    func present(fromCurrent: Bool, withPresenter: Bool = false) {
        guard player == nil, presenter == nil, animatedPlayer == nil else { return }
        closeAnimationPreview()
        presentWithPresenter = withPresenter
        presentFrom = fromCurrent ? (state?.scenes.firstIndex { $0.name == sceneName } ?? 0) : 0
        Task { @MainActor in
            busyPill.show("Preparing presentation…", symbol: nil, tint: nil, spinning: true)
            let r = try? await engine.call("present", ["height": animationHeight], as: UndoResult.self)
            if r?.ok != true { busyPill.hide(); toast(r?.error ?? "Could not start the presentation", error: true) }
        }
    }

    private func startAnimated(_ d: PresentDeck) {
        guard player == nil, presenter == nil, animatedPlayer == nil else { return }
        if presentWithPresenter {
            let here = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
            let other = NSScreen.screens.first { $0 != here }
            let p = PresenterController(deck: d, startScene: presentFrom, presenterScreen: here, audienceScreen: other)
            p.onExit = { [weak self] in self?.presenter = nil; self?.window.makeKeyAndOrderFront(nil) }
            p.onSaveNotes = { [weak self] scene, build, text, done in self?.savePresenterNotes(scene: scene, build: build, text: text, done: done) }
            p.noteImageBase = workspace?.work
            p.feedback = feedback
            // "Use Slide Show": the presenter window closes and the show carries on as the plain animated show
            p.onDetach = { [weak self] src in
                self?.presenter = nil
                guard let a = src as? AnimatedPlayer else { return }
                a.onExit = { [weak self] in self?.animatedPlayer = nil; self?.window.makeKeyAndOrderFront(nil) }
                self?.animatedPlayer = a
            }
            presenter = p
            if other == nil { toast("One display: the show is full screen behind the presenter window. With a second display it goes there.") }
            return
        }
        let p = AnimatedPlayer(screen: window.screen ?? NSScreen.main ?? NSScreen.screens[0])
        p.onExit = { [weak self] in self?.animatedPlayer = nil; self?.window.makeKeyAndOrderFront(nil) }
        animatedPlayer = p
        p.play(d, startScene: presentFrom)
    }

    @objc func playCurrentSlideAnimations() {
        guard let name = sceneName, sourceDraft == nil else { return }
        closeAnimationPreview()
        previewScene = name
        Task { @MainActor in
            busyPill.show("Preparing \(name)’s animations…", symbol: nil, tint: nil, spinning: true)
            let r = try? await engine.call("animation_preview", ["scene": name, "height": animationHeight], as: UndoResult.self)
            if r?.ok != true { busyPill.hide(); previewScene = nil; toast(r?.error ?? "Could not play this slide", error: true) }
        }
    }

    // MARK: Play (built-in slideshow)

    @objc func playFromBeginning() { play(fromCurrent: false) }
    @objc func playFromCurrent() { play(fromCurrent: true) }

    /// The still pages of a `deck_pages` reply, ready for `SlidePlayer`: slides that failed are left out, slides
    /// still rendering get one empty page per build (drawn as "Rendering…" until their pictures arrive).
    struct StillPages {
        var slides: [[String]], links: [[[PresentDeck.LinkRegion]]], scenes: [String], notes: [String], buildNotes: [[String]]
        var pending: Bool
    }

    func stillPages(_ d: DeckPages) -> StillPages {
        let playable = d.slides.filter { $0.error == nil && (!$0.pages.isEmpty || $0.pending == true) }
        return StillPages(slides: playable.map { $0.pages.isEmpty ? Array(repeating: "", count: max(1, $0.builds ?? 1)) : $0.pages },
                          links: playable.map { $0.links ?? [] }, scenes: playable.map { $0.scene },
                          notes: playable.map { $0.notes ?? "" }, buildNotes: playable.map { $0.buildNotes ?? [] },
                          pending: playable.contains { $0.pending == true })
    }

    /// How many slides a stills show waits for before it opens, counting from the current one; the rest render in
    /// the background while it plays.
    static let showAhead = 3

    /// `deck_pages` for a stills show starting at the current slide: the first few slides are rendered before the
    /// reply, the rest come through `rendered` events (see `refreshShowPages`).
    func fetchStillPages(fromCurrent: Bool) async -> DeckPages? {
        let args: [String: Any] = ["current": (fromCurrent ? sceneName : nil) ?? state?.scenes.first?.name ?? "", "ahead": Self.showAhead]
        return try? await engine.call("deck_pages", args, as: DeckPages.self)
    }

    /// A slide of the running stills show finished rendering: fetch the pages again (waiting for nothing) and
    /// hand them to the show.
    func refreshShowPages() {
        guard showPending, player != nil || presenter != nil else { showPending = false; return }
        Task { @MainActor in
            guard let d = try? await engine.call("deck_pages", ["ahead": 0], as: DeckPages.self) else { return }
            let s = stillPages(d)
            showPending = s.pending
            player?.update(slides: s.slides, links: s.links, scenes: s.scenes, notes: s.notes, buildNotes: s.buildNotes)
            presenter?.updateStills(slides: s.slides, links: s.links, scenes: s.scenes, notes: s.notes, buildNotes: s.buildNotes)
        }
    }

    func play(fromCurrent: Bool) {
        guard player == nil, presenter == nil, animatedPlayer == nil else { return }
        closeAnimationPreview()
        Task { @MainActor in
            busyText = "Preparing slideshow…"
            busy += 1
            let deck = await fetchStillPages(fromCurrent: fromCurrent)
            busy -= 1; busyText = "Rendering…"
            guard let d = deck else { toast("Could not prepare the slideshow", error: true); return }
            let broken = d.slides.filter { $0.error != nil }.map { $0.scene }
            let s = stillPages(d)
            if !broken.isEmpty { toast("Skipping slides that fail to render: " + broken.joined(separator: ", "), error: true) }
            guard !s.slides.isEmpty else { return }
            var start = 0
            if fromCurrent, let n = sceneName, let i = s.scenes.firstIndex(of: n) { start = i }
            let p = SlidePlayer(screen: window.screen ?? NSScreen.main ?? NSScreen.screens[0])
            p.scenes = s.scenes; p.notes = s.notes; p.buildNotes = s.buildNotes
            p.onExit = { [weak self] in self?.player = nil; self?.showPending = false; self?.window.makeKeyAndOrderFront(nil) }
            player = p
            showPending = s.pending
            p.play(slides: s.slides, links: s.links, startSlide: start)
        }
    }

    // MARK: Slide menu

    @objc func newSlide() { slideOp("new", layout: "title_content") }
    @objc func duplicateSlide() { slideOp("duplicate") }

    /// Add an empty build after the build on screen (it starts out showing the same picture) and go to it.
    @objc func newBuild() {
        guard let name = sceneName, scene?.name == name, scene?.stops != nil, player == nil else { return }
        if buildNotesBox.isEditing || notesBox.isEditing { window.makeFirstResponder(canvas) }     // commits the notes first
        let stop = stopIndex
        submit { [weak self] in
            guard let self = self else { return }
            self.busy += 1
            let r = try? await self.engine.call("new_build", ["scene": name, "stop": stop], as: SlideResult.self)
            self.busy -= 1
            guard let res = r, res.ok == true else { self.toast(r?.error ?? "could not add a build", error: true); return }
            self.lastChanged = res.changed
            if let s = res.stop { self.stopIndex = s }
            await self.loadScene(name, keepStop: true)
            await self.reloadState()
            self.refreshBuildRows()
            self.toast((res.message ?? "added a build").capitalized + " — ⌘Z to undo")
        }
    }
    @objc func deleteSlide() { slideOp("delete") }

    /// Delete the current build of the slide: its next_slide() goes, so what it showed runs on into the next build.
    func deleteBuild() {
        guard let name = sceneName, scene?.name == name, (scene?.stops?.count ?? 0) > 1, player == nil else { return }
        let stop = stopIndex
        submit { [weak self] in
            guard let self = self else { return }
            self.busy += 1
            let r = try? await self.engine.call("delete_build", ["scene": name, "stop": stop], as: SlideResult.self)
            self.busy -= 1
            guard let res = r, res.ok == true else { self.toast(r?.error ?? "could not delete the build", error: true); return }
            self.lastChanged = res.changed
            if let s = res.stop { self.stopIndex = s }
            await self.loadScene(name, keepStop: true)
            await self.reloadState()
            self.refreshBuildRows()
            self.toast((res.message ?? "deleted build").capitalized + " — ⌘Z to undo")
        }
    }
    @objc func restoreSlide() { slideOp("restore") }
    var selectedSlideIsHidden: Bool { state?.scenes.first(where: { $0.name == sceneName })?.hidden == true }
    @objc func toggleHideSlide() { slideOp(selectedSlideIsHidden ? "unhide" : "hide") }
    @objc func toggleUnusedSlides() {
        showUnusedSlides.toggle()
        suppressTable = true; table.reloadData(); suppressTable = false
        if let name = sceneName, let row = navigatorScenes.firstIndex(where: { $0.name == name }) { selectRow(row) }
        else if let first = navigatorScenes.first { Task { @MainActor in await selectScene(first.name) } }
        else { table.deselectAll(nil) }
    }
    @objc func moveSlideUp() { slideOp("up") }
    @objc func moveSlideDown() { slideOp("down") }

    func slideOp(_ op: String, index: Int? = nil, sceneOverride: String? = nil, layout: String? = nil) {
        guard let name = sceneOverride ?? sceneName else { return }
        submit { [weak self] in
            guard let self = self else { return }
            self.busy += 1
            var args: [String: Any] = ["op": op, "scene": name]
            if let index { args["index"] = index }
            if let layout { args["layout"] = layout }
            let r = try? await self.engine.call("slide", args, as: SlideResult.self)
            self.busy -= 1
            guard let res = r, res.ok == true else { self.toast(r?.error ?? "slide operation failed", error: true); return }
            self.lastChanged = nil
            await self.reloadState()
            if let sel = res.select { await self.selectScene(sel) }
            else if let first = self.navigatorScenes.first { await self.selectScene(first.name) }
            else {
                self.sceneName = nil; self.scene = nil; self.selection = nil
                self.canvas.stop = nil; self.sourceView.string = ""
                self.rebuildSteps(); self.rebuildInspector()
            }
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

    // MARK: the drawer below the slide (notes and terminals)

    func installDrawer() {
        drawer.willChangePage = { [weak self] _ in
            guard let self = self else { return }
            if self.notesBox.isEditing || self.buildNotesBox.isEditing { self.window.makeFirstResponder(self.canvas) }     // commits the notes first
        }
        drawer.onShowTerminal = { [weak self] in self?.showTerminalPage() }
        drawer.onNewTerminal = { [weak self] in     // + beside Terminal 1 adds another, starting Terminal 1 too if need be
            guard let self = self, self.workspace != nil else { return }
            if !self.terminal.hasStarted { self.showTerminalPage() }
            self.newTerminal()
        }
        drawer.onHide = { [weak self] in self?.setDrawerOpen(false) }
        drawer.onInsertImage = { [weak self] in self?.insertNotesImage() }
        terminal.onHide = { [weak self] in self?.drawer.show(.notes) }    // the last shell was killed
        let open = UserDefaults.standard.object(forKey: "showNotes") as? Bool ?? true
        drawer.isHidden = !open
        if open, UserDefaults.standard.object(forKey: "NSSplitView Subview Frames manimble.drawer") == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let cs = self.centerSplit else { return }
                cs.setPosition(max(160, cs.bounds.height - 140), ofDividerAt: 0)
            }
        }
        // collapsed or brought back by dragging the divider: remember it like the hide button does
        (centerSplit as? GrabSplitView)?.onResize = { [weak self] in
            guard let self = self, UserDefaults.standard.bool(forKey: "showNotes") == self.drawer.isHidden else { return }
            if self.drawer.isHidden, self.notesBox.isEditing || self.buildNotesBox.isEditing { self.window.makeFirstResponder(self.canvas) }
            UserDefaults.standard.set(!self.drawer.isHidden, forKey: "showNotes")
        }
    }

    var drawerShowsNotes: Bool { !drawer.isHidden && (drawer.page == .notes || drawer.page == .buildNotes) }
    var drawerShowsTerminal: Bool { !drawer.isHidden && drawer.page == .terminal }

    /// Open or close the drawer, keeping the slide at least 160pt tall.
    func setDrawerOpen(_ on: Bool, minHeight: CGFloat = 110) {
        guard let cs = centerSplit else { return }
        if !on, notesBox.isEditing || buildNotesBox.isEditing { window.makeFirstResponder(canvas) }
        let wasHidden = drawer.isHidden
        drawer.isHidden = !on
        cs.adjustSubviews()
        if on, wasHidden || drawer.frame.height < minHeight {
            cs.setPosition(max(160, cs.bounds.height - minHeight), ofDividerAt: 0)
        }
        if !on, window.firstResponder.map({ ($0 as? NSView)?.isDescendant(of: drawer) == true }) ?? false { window.makeFirstResponder(canvas) }
        UserDefaults.standard.set(on, forKey: "showNotes")
    }

    /// The drawer on the terminal page, starting the first shell; a little taller than notes need.
    private func showTerminalPage() {
        if !terminal.hasStarted, let ws = workspace { terminal.start(in: terminalDirectory(ws), original: ws.original.path) }
        drawer.show(.terminal)
        setDrawerOpen(true, minHeight: max(110, (centerSplit?.bounds.height ?? 0) * 0.42))
        DispatchQueue.main.async { [self] in terminal.focus() }
    }

    @objc func toggleTerminal() {
        if drawerShowsTerminal { setDrawerOpen(false) } else { showTerminalPage() }
    }

    /// Open a new terminal tab (showing the terminal first if it is hidden).
    @objc func newTerminal() {
        guard workspace != nil else { return }
        let wasStarted = terminal.hasStarted
        showTerminalPage()
        if wasStarted { terminal.addTab() }
    }

    /// Split the active terminal tab: another shell beside the active one.
    @objc func splitTerminal() {
        guard workspace != nil else { return }
        let wasStarted = terminal.hasStarted
        showTerminalPage()
        if wasStarted { terminal.splitActive() }
    }

    // MARK: View menu: panels

    @objc func toggleNavigator() { mainSplit?.subviews.first?.isHidden.toggle(); mainSplit?.adjustSubviews() }
    @objc func toggleInspector() { mainSplit?.subviews.last?.isHidden.toggle(); mainSplit?.adjustSubviews() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let v = validateArrangeItem(item) { return v }
        switch item.action {
        case #selector(formatBold), #selector(formatItalic): return objInfo?.kind == "text"
        case #selector(formatBigger), #selector(formatSmaller), #selector(formatUnderline), #selector(formatStrikethrough),
             #selector(highlightChosen(_:)), #selector(clearFormatting), #selector(hyperlinkPressed):
            if item.action == #selector(formatUnderline) { item.state = objInfo?.format?.underline == true ? .on : .off }
            if item.action == #selector(formatStrikethrough) { item.state = objInfo?.format?.strike == true ? .on : .off }
            if item.action == #selector(highlightChosen(_:)) {
                item.state = (objInfo?.format?.highlight?.uppercased()) == (item.representedObject as? String)?.uppercased() ? .on : .off
            }
            return objInfo?.kind == "text" || objInfo?.kind == "tex"
        case #selector(formatSuperscript), #selector(formatSubscript), #selector(toggleBullets), #selector(toggleNumbering),
             #selector(increaseIndent), #selector(decreaseIndent):
            return objInfo?.kind == "text" && objInfo?.textOk == true
        case #selector(alignLeft), #selector(alignCenter), #selector(alignRight), #selector(alignJustify),
             #selector(spacingMenuChosen(_:)), #selector(columnsMenuChosen(_:)):
            let align = ["left": #selector(alignLeft), "center": #selector(alignCenter), "right": #selector(alignRight)]
            if let a = objInfo?.format?.align, align[a] == item.action { item.state = .on } else if align.values.contains(item.action!) { item.state = .off }
            if item.action == #selector(columnsMenuChosen(_:)) { item.state = (objInfo?.format?.columns ?? 1) == (item.representedObject as? Int) ? .on : .off }
            return objInfo?.kind == "text"
        case #selector(toggleGrid): item.state = canvas.showGrid ? .on : .off; return true
        case #selector(toggleRuler): item.state = showRuler ? .on : .off; return true
        case #selector(toggleSnap): item.state = canvas.snapEnabled ? .on : .off; return true
        case #selector(toggleTips): item.state = showTips ? .on : .off; return true
        case #selector(addVerticalGuide), #selector(addHorizontalGuide): return sceneName != nil
        case #selector(clearGuides): return !canvas.userGuides.isEmpty
        case #selector(drawToolMenu(_:)):
            item.state = canvas.drawTool == (item.representedObject as? String) ? .on : .off
            return sceneName != nil && player == nil
        case #selector(penColorChosen(_:)):
            item.state = (item.representedObject as? String)?.uppercased() == canvas.penColor.hexString.uppercased() ? .on : .off
            return true
        case #selector(newSlideLayout(_:)):
            if let layout = item.representedObject as? String {     // drawn on the current slide's background
                item.image = MainController.layoutIcon(layout, background: canvas.shownBackground ?? .white)
            }
            return sceneName != nil && !selectedSlideIsUnused && player == nil
        case #selector(newSlide), #selector(duplicateSlide), #selector(moveSlideUp), #selector(moveSlideDown):
            return sceneName != nil && !selectedSlideIsUnused && player == nil
        case #selector(toggleExpandAllBuilds):
            item.title = buildsExpandedAll ? "Collapse All Builds" : "Expand All Builds"
            return navigatorScenes.isEmpty == false && player == nil
        case #selector(newBuild):
            return sceneName != nil && scene?.name == sceneName && scene?.stops != nil && player == nil
        case #selector(extractElementsPressed):
            return objInfo?.kind == "image" && objInfo?.imagePath != nil && player == nil
        case #selector(slideNumbersPressed):
            return state?.scenes.isEmpty == false && player == nil
        case #selector(toggleNotesPane):
            item.state = drawerShowsNotes ? .on : .off
            return workspace != nil
        case #selector(presenterView):
            return state?.scenes.isEmpty == false && player == nil && presenter == nil
        case #selector(restoreSlide):
            return selectedSlideIsUnused && player == nil
        case #selector(toggleHideSlide):
            item.title = selectedSlideIsHidden ? "Unhide Slide" : "Hide Slide"
            return sceneName != nil && !selectedSlideIsUnused && player == nil
        case #selector(toggleTerminalInWorkCopy):
            item.state = UserDefaults.standard.bool(forKey: "terminalInWorkCopy") ? .on : .off
            return true
        case #selector(exportPythonPressed):
            return workspace != nil
        case #selector(exportMovie):
            return state?.scenes.isEmpty == false && player == nil && animatedPlayer == nil
        case #selector(toggleUnusedSlides):
            item.state = showUnusedSlides ? .on : .off
            return workspace != nil
        case #selector(playFromCurrent), #selector(insertTextPressed), #selector(insertFormulaPressed), #selector(insertTablePressed),
             #selector(insertImagePressed), #selector(insertShapePressed(_:)), #selector(formatBackground), #selector(showBioCartoon):
            return sceneName != nil && player == nil
        case #selector(playCurrentSlideAnimations): return sceneName != nil && sourceDraft == nil && player == nil && previewScene == nil
        case #selector(toggleTerminal):
            item.title = drawerShowsTerminal ? "Hide Terminal" : "Show Terminal"; return workspace != nil
        case #selector(newTerminal), #selector(splitTerminal): return workspace != nil
        case #selector(toggleDarkMode): item.state = DarkMode.mode == .dark ? .on : .off; return true
        case #selector(toggleInvertColors): item.state = DarkMode.mode == .invert ? .on : .off; return true
        case #selector(toggleDarkImages): item.state = DarkMode.images ? .on : .off; return DarkMode.isOn
        case #selector(applyDarkMode), #selector(applyInvertColors): return state?.scenes.isEmpty == false && player == nil
        case #selector(playFromBeginning): return state?.scenes.isEmpty == false && player == nil && presenter == nil
        case #selector(toggleShowAnimations):
            item.title = showAnimations ? "Hide Animations" : "Show Animations"; return true
        case #selector(playMenuFromBeginning):
            return validateMenuItem(NSMenuItem(title: "", action: showAnimations ? #selector(presentFromBeginning) : #selector(playFromBeginning), keyEquivalent: ""))
        case #selector(playMenuFromCurrent):
            return validateMenuItem(NSMenuItem(title: "", action: showAnimations ? #selector(presentFromCurrent) : #selector(playFromCurrent), keyEquivalent: ""))
        case #selector(playMenuPresenter):
            return validateMenuItem(NSMenuItem(title: "", action: showAnimations ? #selector(presenterViewAnimated) : #selector(presenterView), keyEquivalent: ""))
        case #selector(animationResolutionChosen(_:)):
            item.state = (item.representedObject as? Int) == animationHeight ? .on : .off
            return previewScene == nil && player == nil && presenter == nil && animatedPlayer == nil
        case #selector(presentFromCurrent), #selector(presenterViewAnimated):
            return sceneName != nil && player == nil && presenter == nil && animatedPlayer == nil
        case #selector(presentFromBeginning):
            return state?.scenes.isEmpty == false && player == nil && presenter == nil && animatedPlayer == nil
        case #selector(deleteSlide): return sceneName != nil && ((state?.scenes.count ?? 0) > 1 || selectedSlideIsUnused) && player == nil
        case #selector(undo): if let t = otherWindowText { return t.undoManager?.canUndo ?? false }; return state?.canUndo ?? true
        case #selector(redo): if let t = otherWindowText { return t.undoManager?.canRedo ?? false }; return state?.canRedo ?? true
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
    func moveStop(_ d: Int) { goToStop(stopIndex + d) }

    /// View ▸ Show Tips: the transient confirmations and hints ("Saved · …", "Inserted …"). Off by default;
    /// errors always show. Headless self-tests read the toast text, so they always get the tips.
    var showTips: Bool {
        UserDefaults.standard.bool(forKey: "showTips")
            || ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("MANIMBLE_TEST_") || $0 == "MANIMBLE_SELFTEST" }
    }
    @objc func toggleTips() {
        UserDefaults.standard.set(!showTips, forKey: "showTips")
        if showTips { toast("Tips on: short confirmations and hints appear here after each action") }
        else { toastWork?.cancel(); toastPill.hide() }
    }

    var toastWork: DispatchWorkItem?
    func toast(_ s: String, error: Bool = false) {
        if !error && !showTips { return }
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
    func windowWillClose(_ n: Notification) { closeDeck() }
}

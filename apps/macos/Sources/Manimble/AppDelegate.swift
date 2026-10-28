import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One controller per deck window, like PowerPoint; the main menu acts on the frontmost one.
    private var controllers: [MainController] = []
    private weak var lastMain: MainController?
    private let router = MenuRouter()
    private var launchURLs: [URL] = []     // decks handed over before the window exists

    /// The deck window menu commands go to: the main window's, else the one used last.
    var controller: MainController! { lastMain ?? controllers.last }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        router.target = { [weak self] in self?.controller }
        func wire(_ menu: NSMenu?) {
            for it in menu?.items ?? [] {
                if let a = it.action, MainController.instancesRespond(to: a) { it.target = router }
                wire(it.submenu)
            }
        }
        wire(NSApp.mainMenu)
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self = self, let w = n.object as? NSWindow else { return }
                if let c = self.controllers.first(where: { $0.window === w }) { self.lastMain = c }
            }
        }
        let c = MainController()
        controllers.append(c)
        c.showWindow()
        NSApp.activate(ignoringOtherApps: true)
        // a deck given at launch wins over the last one; the engine opens it once it is running
        if let u = (launchURLs + commandLineDecks()).first { c.openProject(at: u) }
        c.start()
    }

    /// File ▸ New Deck… with a deck already open: a second window with its own engine, cascaded off the current one.
    @MainActor func openInNewWindow(deck: String) {
        let previous = controller
        let c = MainController()
        controllers.append(c)
        c.showWindow()
        if let f = previous?.window.frame, previous?.window.isVisible == true {
            c.window.setFrame(f.offsetBy(dx: 26, dy: -26), display: false)
        }
        lastMain = c
        c.open(deck: deck)      // held until the engine is up
        c.start()
    }

    /// A deck window closed: drop it unless it is the last one, which stays around for the next deck.
    @MainActor func windowClosed(_ c: MainController) {
        guard controllers.count > 1, let i = controllers.firstIndex(where: { $0 === c }) else { return }
        controllers.remove(at: i)
        c.finish()
        if lastMain === c { lastMain = nil }
    }

    /// `open -a Manimble <deck>`, a drop on the Dock icon, Finder's Open With.
    func application(_ app: NSApplication, open urls: [URL]) {
        guard let c = controller else { launchURLs += urls; return }
        if let u = urls.first { c.openProject(at: u) }
    }

    /// Paths on the command line (`Manimble.app/Contents/MacOS/Manimble <deck>`), skipping `-Key value` defaults.
    private func commandLineDecks() -> [URL] {
        var urls: [URL] = [], args = CommandLine.arguments.dropFirst()[...]
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        while let a = args.popFirst() {
            if a.hasPrefix("-") {
                if let v = args.first, !v.hasPrefix("-") { args.removeFirst() }
                continue
            }
            let u = URL(fileURLWithPath: (a as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL
            if FileManager.default.fileExists(atPath: u.path) { urls.append(u) }
        }
        return urls
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { controller.reopenWindow() }
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for c in controllers {
            if c.workspace != nil || c.sourceDraft != nil { c.window.makeKeyAndOrderFront(nil) }
            if !c.confirmClose(for: "quitting") { return .terminateCancel }
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ n: Notification) { controllers.forEach { $0.finish() } }

    private func item(_ title: String, _ sel: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    private func buildMenu() {
        let main = NSMenu()
        func add(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            let top = NSMenuItem(); top.submenu = m
            main.addItem(top)
        }
        add("Manimble", [
            item("About Manimble", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Install Dependencies…", #selector(MainController.installDependencies), ""),
            item("Choose Python…", #selector(MainController.choosePython), ""),
            .separator(),
            item("Hide Manimble", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Manimble", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let importMenu = NSMenu(title: "Import")
        importMenu.addItem(item("PowerPoint (.pptx)…", #selector(MainController.importPowerPoint), "", []))
        importMenu.addItem(item("Keynote (.key)…", #selector(MainController.importKeynote), "", []))
        importMenu.addItem(item("Beamer (.tex)…", #selector(MainController.importBeamer), "", []))
        let importItem = NSMenuItem(title: "Import", action: nil, keyEquivalent: ""); importItem.submenu = importMenu
        let exportMenu = NSMenu(title: "Export To")
        exportMenu.addItem(item("PowerPoint (.pptx)…", #selector(MainController.exportPowerPoint), "", []))
        exportMenu.addItem(item("Keynote (.key)…", #selector(MainController.exportKeynote), "", []))
        exportMenu.addItem(item("Beamer (.tex)…", #selector(MainController.exportBeamer), "", []))
        exportMenu.addItem(item("PDF…", #selector(MainController.exportPDFPressed), "", []))
        exportMenu.addItem(item("Movie (.mp4, with animations)…", #selector(MainController.exportMovie), "", []))
        exportMenu.addItem(.separator())
        exportMenu.addItem(item("Python (whole deck in one file)…", #selector(MainController.exportPythonPressed), "", []))
        let exportItem = NSMenuItem(title: "Export To", action: nil, keyEquivalent: ""); exportItem.submenu = exportMenu
        add("File", [
            item("New Deck…", #selector(MainController.newDeck), "n"),
            item("Open Deck or Project…", #selector(MainController.openDeck), "o"),
            importItem,
            .separator(),
            item("Save to Original", #selector(MainController.saveToOriginal), "s"),
            item("Save Project Copy…", #selector(MainController.saveProjectFolderPressed), ""),
            item("Package for Sharing…", #selector(MainController.packageProjectPressed), ""),
            item("Revert to Original…", #selector(MainController.revertToOriginal), ""),
            .separator(),
            exportItem,
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        add("Edit", [
            item("Undo", #selector(MainController.undo), "z"),
            item("Redo", #selector(MainController.redo), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find…", #selector(MainController.showFind(_:)), "f"),
            item("Find and Replace…", #selector(MainController.showFindReplace(_:)), "f", [.command, .option]),
            item("Find Next", #selector(MainController.findNext(_:)), ""),
            item("Find Previous", #selector(MainController.findPrevious(_:)), ""),
        ])
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: ""); themeItem.submenu = DeckTheme.menu(target: nil)
        let shapes = NSMenu(title: "Shape")
        for (title, kind) in [("Rectangle", "rectangle"), ("Rounded Rectangle", "rounded"), ("Circle", "circle"), ("Ellipse", "ellipse"),
                              ("Triangle", "triangle"), ("Line", "line"), ("Arrow", "arrow"), ("Double Arrow", "darrow")] {
            let mi = NSMenuItem(title: title, action: #selector(MainController.insertShapePressed(_:)), keyEquivalent: "")
            mi.representedObject = kind
            shapes.addItem(mi)
        }
        let shapeItem = NSMenuItem(title: "Shape", action: nil, keyEquivalent: ""); shapeItem.submenu = shapes
        let draw = NSMenu(title: "Draw")
        for (title, kind) in [("Line", "line"), ("Arrow", "arrow"), ("Double Arrow", "darrow"), ("Rectangle", "rectangle"), ("Ellipse", "ellipse")] {
            let mi = NSMenuItem(title: title, action: #selector(MainController.drawToolMenu(_:)), keyEquivalent: "")
            mi.representedObject = kind
            draw.addItem(mi)
        }
        draw.addItem(.separator())
        let pen = NSMenuItem(title: "Pen (freehand)", action: #selector(MainController.drawToolMenu(_:)), keyEquivalent: "p")
        pen.keyEquivalentModifierMask = [.command, .shift]; pen.representedObject = "pen"
        draw.addItem(pen)
        let penColors = NSMenu(title: "Pen Color")
        for (title, hex) in MainActor.assumeIsolated({ MainController.penSwatches }) {
            let mi = NSMenuItem(title: title, action: #selector(MainController.penColorChosen(_:)), keyEquivalent: "")
            mi.representedObject = hex
            penColors.addItem(mi)
        }
        penColors.addItem(.separator())
        penColors.addItem(item("Other…", #selector(MainController.penColorPanel), "", []))
        let penColorItem = NSMenuItem(title: "Pen Color", action: nil, keyEquivalent: ""); penColorItem.submenu = penColors
        draw.addItem(penColorItem)
        let drawItem = NSMenuItem(title: "Draw (drag on the slide)", action: nil, keyEquivalent: ""); drawItem.submenu = draw
        add("Insert", [
            item("Text", #selector(MainController.insertTextPressed), "t", [.command, .shift]),
            item("Formula…", #selector(MainController.insertFormulaPressed), "e", [.command, .shift]),
            shapeItem,
            drawItem,
            item("BioCartoon Icons…", #selector(MainController.showBioCartoon), "", []),
            { let i = item("Word Table…", #selector(MainController.insertTablePressed), "", []); i.representedObject = "word"; return i }(),
            { let i = item("Math Table…", #selector(MainController.insertTablePressed), "", []); i.representedObject = "math"; return i }(),
            item("Image…", #selector(MainController.insertImagePressed), "i", [.command, .shift]),
            item("Python Plot…", #selector(MainController.insertPythonPlotPressed), "", []),
            item("Extract Elements from Image…", #selector(MainController.extractElementsPressed), "", []),
            .separator(),
            item("Slide Numbers…", #selector(MainController.slideNumbersPressed), "", []),
        ])
        let layouts = NSMenu(title: "New Slide")
        for (title, layout, key) in MainActor.assumeIsolated({ MainController.slideLayouts }) {
            let mi = NSMenuItem(title: title, action: #selector(MainController.newSlideLayout(_:)), keyEquivalent: key)
            mi.keyEquivalentModifierMask = key.isEmpty ? [] : [.command, .shift]
            mi.representedObject = layout
            mi.image = MainActor.assumeIsolated { MainController.layoutIcon(layout) }
            layouts.addItem(mi)
        }
        let newSlideItem = NSMenuItem(title: "New Slide", action: nil, keyEquivalent: ""); newSlideItem.submenu = layouts
        add("Slide", [
            newSlideItem,
            item("New Build", #selector(MainController.newBuild), "", []),
            item("Duplicate Slide", #selector(MainController.duplicateSlide), "d"),
            item("Delete Slide", #selector(MainController.deleteSlide), String(UnicodeScalar(NSBackspaceCharacter)!), [.command, .shift]),
            item("Hide Slide", #selector(MainController.toggleHideSlide), "h", [.command, .shift]),
            item("Restore Slide to Show", #selector(MainController.restoreSlide), "", []),
            .separator(),
            item("Move Slide Up", #selector(MainController.moveSlideUp), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            item("Move Slide Down", #selector(MainController.moveSlideDown), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            .separator(),
            item("Previous Slide", #selector(MainController.prevSlide), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command]),
            item("Next Slide", #selector(MainController.nextSlide), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command]),
            item("Previous Build", #selector(MainController.prevStop), "[", [.command]),
            item("Next Build", #selector(MainController.nextStop), "]", [.command]),
        ])
        let highlight = NSMenu(title: "Highlight")
        for (title, hex) in MainActor.assumeIsolated({ MainController.highlightSwatches }) {
            let mi = NSMenuItem(title: title, action: #selector(MainController.highlightChosen(_:)), keyEquivalent: "")
            mi.representedObject = hex
            highlight.addItem(mi)
        }
        let highlightItem = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: ""); highlightItem.submenu = highlight
        let spacing = NSMenu(title: "Line Spacing")
        for (title, v) in [("1.0", 1.0), ("1.15", 1.15), ("1.5", 1.5), ("2.0", 2.0), ("2.5", 2.5), ("3.0", 3.0)] as [(String, Double?)] + [("Custom…", nil)] {
            let mi = NSMenuItem(title: title, action: #selector(MainController.spacingMenuChosen(_:)), keyEquivalent: "")
            mi.representedObject = v
            spacing.addItem(mi)
        }
        let spacingItem = NSMenuItem(title: "Line Spacing", action: nil, keyEquivalent: ""); spacingItem.submenu = spacing
        let columns = NSMenu(title: "Columns")
        for (title, n) in [("One", 1), ("Two", 2), ("Three", 3), ("Four", 4)] {
            let mi = NSMenuItem(title: title, action: #selector(MainController.columnsMenuChosen(_:)), keyEquivalent: "")
            mi.representedObject = n
            columns.addItem(mi)
        }
        let columnsItem = NSMenuItem(title: "Columns", action: nil, keyEquivalent: ""); columnsItem.submenu = columns
        add("Format", [
            item("Bold", #selector(MainController.formatBold), "b"),
            item("Italic", #selector(MainController.formatItalic), "i"),
            item("Underline", #selector(MainController.formatUnderline), "u"),
            item("Strikethrough", #selector(MainController.formatStrikethrough), "", []),
            item("Superscript", #selector(MainController.formatSuperscript), "+", [.command, .shift]),
            item("Subscript", #selector(MainController.formatSubscript), "_", [.command, .shift]),
            .separator(),
            item("Bigger", #selector(MainController.formatBigger), "=", [.command, .option]),
            item("Smaller", #selector(MainController.formatSmaller), "-", [.command, .option]),
            highlightItem,
            item("Hyperlink…", #selector(MainController.hyperlinkPressed), "k"),
            item("Clear Formatting", #selector(MainController.clearFormatting), "", []),
            .separator(),
            item("Bulleted List", #selector(MainController.toggleBullets), "8", [.command, .shift]),
            item("Numbered List", #selector(MainController.toggleNumbering), "7", [.command, .shift]),
            item("Increase Indent", #selector(MainController.increaseIndent), "]", [.command, .shift]),
            item("Decrease Indent", #selector(MainController.decreaseIndent), "[", [.command, .shift]),
            .separator(),
            item("Align Left", #selector(MainController.alignLeft), "l"),
            item("Center", #selector(MainController.alignCenter), "e"),
            item("Align Right", #selector(MainController.alignRight), "r"),
            item("Justify", #selector(MainController.alignJustify), "j"),
            spacingItem,
            columnsItem,
            .separator(),
            item("Background…", #selector(MainController.formatBackground), "", []),
            themeItem,
            .separator(),
            item("Apply Dark Mode to Deck…", #selector(MainController.applyDarkMode), "", []),
            item("Apply Inverted Colors to Deck…", #selector(MainController.applyInvertColors), "", []),
        ])
        add("Arrange", MainActor.assumeIsolated { MainController.arrangeItems }.map { item($0.title, $0.action, $0.key, $0.mods) } + [
            .separator(),
            item("Group", #selector(MainController.groupObjects), "g"),
            item("Ungroup", #selector(MainController.ungroupObjects), "g", [.command, .shift]),
        ])
        add("View", [
            item("Show Objects", #selector(MainController.toggleObjects), "j", [.command, .option]),
            item("Grid Lines", #selector(MainController.toggleGrid), "g", [.command, .option]),
            item("Ruler", #selector(MainController.toggleRuler), "u", [.command, .option]),
            item("Snap to Objects", #selector(MainController.toggleSnap), "s", [.command, .option]),
            item("Add Vertical Guide", #selector(MainController.addVerticalGuide), "", []),
            item("Add Horizontal Guide", #selector(MainController.addHorizontalGuide), "", []),
            item("Clear Guides", #selector(MainController.clearGuides), "", []),
            item("Show Unused Slides", #selector(MainController.toggleUnusedSlides), "", []),
            item("Speaker Notes", #selector(MainController.toggleNotesPane), "k", [.command, .option]),
            item("Show Tips", #selector(MainController.toggleTips), "", []),
            .separator(),
            item("Dark Mode", #selector(MainController.toggleDarkMode), "d", [.command, .control, .shift]),
            item("Invert Colors", #selector(MainController.toggleInvertColors), "i", [.command, .control, .shift]),
            item("Recolor Images Too", #selector(MainController.toggleDarkImages), "", []),
            .separator(),
            item("Zoom In", #selector(MainController.zoomIn), "="),
            item("Zoom Out", #selector(MainController.zoomOut), "-"),
            item("Fit in Window", #selector(MainController.zoomFit), "0"),
            .separator(),
            item("Show Terminal", #selector(MainController.toggleTerminal), "t", [.command, .option]),
            item("New Terminal", #selector(MainController.newTerminal), "t", [.command, .option, .shift]),
            item("Split Terminal", #selector(MainController.splitTerminal), "\\"),
            item("Terminal Starts in Working Copy", #selector(MainController.toggleTerminalInWorkCopy), "", []),
            .separator(),
            item("Hide/Show Slide Navigator", #selector(MainController.toggleNavigator), "n", [.command, .option]),
            item("Hide/Show Inspector and Source", #selector(MainController.toggleInspector), "i", [.command, .option]),
        ])
        let animations = NSMenu(title: "Animation Resolution")
        for (title, h) in [("720p (fastest builds)", 720), ("1080p", 1080), ("1440p", 1440), ("4K (slowest builds)", 2160)] {
            let mi = NSMenuItem(title: title, action: #selector(MainController.animationResolutionChosen(_:)), keyEquivalent: "")
            mi.representedObject = h
            animations.addItem(mi)
        }
        let animationsItem = NSMenuItem(title: "Animation Resolution", action: nil, keyEquivalent: ""); animationsItem.submenu = animations
        // Show/Hide Animations switches the three items below it between the animated show and the stills slideshow.
        add("Play", [
            item("Show Animations", #selector(MainController.toggleShowAnimations), "a", [.command, .option]),
            .separator(),
            item("Play from Beginning", #selector(MainController.playMenuFromBeginning), "p", [.command, .option, .shift]),
            item("Play from Current Slide", #selector(MainController.playMenuFromCurrent), "p", [.command, .option]),
            item("Presenter View", #selector(MainController.playMenuPresenter), "p", [.command, .control]),
            item("Automatic Presentation", #selector(MainController.autoPresentFromBeginning), "", []),
            item("Automatic Presentation from Current Slide", #selector(MainController.autoPresentFromCurrent), "", []),
            .separator(),
            item("Preview Current Slide’s Animations", #selector(MainController.playCurrentSlideAnimations), "r", [.command, .option]),
            animationsItem,
        ])
        let win = NSMenu(title: "Window")
        win.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        win.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), "", []))
        win.addItem(.separator())
        win.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "", []))
        let top = NSMenuItem(); top.submenu = win; main.addItem(top)
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }
}

/// Target of the main menu's deck commands: forwards each one (and its validation) to the frontmost deck window's
/// controller, so items keep their explicit target instead of going through the key window's responder chain.
final class MenuRouter: NSObject {
    var target: () -> MainController? = { nil }
    override func responds(to s: Selector!) -> Bool { super.responds(to: s) || MainController.instancesRespond(to: s) }
    override func forwardingTarget(for s: Selector!) -> Any? {
        MainController.instancesRespond(to: s) ? target() : super.forwardingTarget(for: s)
    }
}

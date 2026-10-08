import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: MainController!

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        controller = MainController()
        func wire(_ menu: NSMenu?) {
            for it in menu?.items ?? [] {
                if let a = it.action, controller.responds(to: a) { it.target = controller }
                wire(it.submenu)
            }
        }
        wire(NSApp.mainMenu)
        controller.showWindow()
        NSApp.activate(ignoringOtherApps: true)
        controller.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.confirmClose(for: "quitting") ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ n: Notification) { controller?.finish() }

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
            item("Choose Python…", #selector(MainController.choosePython), ""),
            .separator(),
            item("Hide Manimble", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Manimble", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let importMenu = NSMenu(title: "Import")
        importMenu.addItem(item("PowerPoint (.pptx)…", #selector(MainController.importPowerPoint), "", []))
        importMenu.addItem(item("Keynote (.key)…", #selector(MainController.importKeynote), "", []))
        let importItem = NSMenuItem(title: "Import", action: nil, keyEquivalent: ""); importItem.submenu = importMenu
        let exportMenu = NSMenu(title: "Export To")
        exportMenu.addItem(item("PowerPoint (.pptx)…", #selector(MainController.exportPowerPoint), "", []))
        exportMenu.addItem(item("Keynote (.key)…", #selector(MainController.exportKeynote), "", []))
        exportMenu.addItem(item("PDF…", #selector(MainController.exportPDFPressed), "", []))
        let exportItem = NSMenuItem(title: "Export To", action: nil, keyEquivalent: ""); exportItem.submenu = exportMenu
        add("File", [
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
        ])
        let shapes = NSMenu(title: "Shape")
        for (title, kind) in [("Rectangle", "rectangle"), ("Rounded Rectangle", "rounded"), ("Circle", "circle"),
                              ("Triangle", "triangle"), ("Line", "line"), ("Arrow", "arrow")] {
            let mi = NSMenuItem(title: title, action: #selector(MainController.insertShapePressed(_:)), keyEquivalent: "")
            mi.representedObject = kind
            shapes.addItem(mi)
        }
        let shapeItem = NSMenuItem(title: "Shape", action: nil, keyEquivalent: ""); shapeItem.submenu = shapes
        add("Insert", [
            item("Text", #selector(MainController.insertTextPressed), "t", [.command, .shift]),
            item("Formula…", #selector(MainController.insertFormulaPressed), "e", [.command, .shift]),
            shapeItem,
            item("Table…", #selector(MainController.insertTablePressed), "", []),
            item("Image…", #selector(MainController.insertImagePressed), "i", [.command, .shift]),
        ])
        add("Slide", [
            item("New Slide", #selector(MainController.newSlide), "n", [.command, .shift]),
            item("Duplicate Slide", #selector(MainController.duplicateSlide), "d"),
            item("Delete Slide", #selector(MainController.deleteSlide), String(UnicodeScalar(NSBackspaceCharacter)!), [.command, .shift]),
            .separator(),
            item("Move Slide Up", #selector(MainController.moveSlideUp), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]),
            item("Move Slide Down", #selector(MainController.moveSlideDown), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]),
            .separator(),
            item("Previous Slide", #selector(MainController.prevSlide), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command]),
            item("Next Slide", #selector(MainController.nextSlide), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command]),
            item("Previous Build", #selector(MainController.prevStop), "[", [.command]),
            item("Next Build", #selector(MainController.nextStop), "]", [.command]),
        ])
        add("Format", [
            item("Bold", #selector(MainController.formatBold), "b"),
            item("Italic", #selector(MainController.formatItalic), "i"),
            .separator(),
            item("Bigger", #selector(MainController.formatBigger), "=", [.command, .option]),
            item("Smaller", #selector(MainController.formatSmaller), "-", [.command, .option]),
        ])
        add("View", [
            item("Show Objects", #selector(MainController.toggleObjects), "j"),
            .separator(),
            item("Zoom In", #selector(MainController.zoomIn), "="),
            item("Zoom Out", #selector(MainController.zoomOut), "-"),
            item("Fit in Window", #selector(MainController.zoomFit), "0"),
            .separator(),
            item("Show Terminal", #selector(MainController.toggleTerminal), "t", [.command, .option]),
            .separator(),
            item("Hide/Show Slide Navigator", #selector(MainController.toggleNavigator), "n", [.command, .option]),
            item("Hide/Show Inspector and Source", #selector(MainController.toggleInspector), "i", [.command, .option]),
        ])
        add("Play", [
            item("Play from Current Slide", #selector(MainController.playFromCurrent), "p", [.command, .option]),
            item("Play from Beginning", #selector(MainController.playFromBeginning), "p", [.command, .option, .shift]),
            .separator(),
            item("Play with Manim Slides (full animations)…", #selector(MainController.present), "", []),
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

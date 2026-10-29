import AppKit

/// File ▸ Open Recent: the decks opened last, newest first. A .manimble package is listed as its unpacked copy,
/// which is where Save to Original wrote its edits.
enum RecentDecks {
    static let key = "recentDecks"
    static let limit = 10

    /// Before this list existed only the last deck was remembered: it starts the list.
    static var paths: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? UserDefaults.standard.string(forKey: "lastDeck").map { [$0] } ?? []
    }

    static func note(_ deck: String) {
        let p = URL(fileURLWithPath: deck).standardizedFileURL.path
        UserDefaults.standard.set(Array(([p] + paths.filter { $0 != p }).prefix(limit)), forKey: key)
    }

    static func forget(_ deck: String) { UserDefaults.standard.set(paths.filter { $0 != deck }, forKey: key) }

    static func clear() { UserDefaults.standard.set([String](), forKey: key) }
}

extension AppDelegate: NSMenuDelegate {
    /// The Open Recent submenu, filled each time it opens.
    func recentMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "Open Recent")
        menu.delegate = self
        let item = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open Recent" else { return }
        menu.removeAllItems()
        let fm = FileManager.default
        for p in RecentDecks.paths where fm.fileExists(atPath: p) {
            let u = URL(fileURLWithPath: p)
            // "parent / deck", as in the window title: decks are often all called "deck"
            let it = NSMenuItem(title: u.deletingLastPathComponent().lastPathComponent + " / " + u.lastPathComponent,
                                action: #selector(openRecent(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = p
            it.toolTip = p
            it.image = NSWorkspace.shared.icon(forFile: p)
            it.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(it)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: menu.items.isEmpty ? nil : #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @MainActor @objc func openRecent(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        guard FileManager.default.fileExists(atPath: p) else {
            RecentDecks.forget(p)
            let a = NSAlert(); a.messageText = "Could not open deck"; a.informativeText = "\(p) no longer exists."; a.runModal()
            return
        }
        controller.openInWindow(deck: p)
    }

    @objc func clearRecent(_ sender: Any?) { RecentDecks.clear() }
}

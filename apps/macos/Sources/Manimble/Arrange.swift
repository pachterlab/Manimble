import AppKit

extension MainController {
    /// Arrange ▸ Group (⌘G): the selected objects become one group, written as `group1 = Group(a, b)  # manimble group`;
    /// a click on any of them then selects them all, so they move, nudge, delete and stack together.
    @objc func groupObjects() {
        let ids = canvas.selectedIDs
        guard ids.count > 1 else { return }
        submit { [weak self] in await self?.runEdit(["op": "group", "oid": ids[0], "oids": ids]) }
    }

    /// Arrange ▸ Ungroup (⇧⌘G): the groups of the selected objects go; the objects stay selected.
    @objc func ungroupObjects() {
        let ids = canvas.selectedIDs
        guard let first = ids.first else { return }
        submit { [weak self] in await self?.runEdit(["op": "ungroup", "oid": first, "oids": ids]) }
    }

    @objc func bringToFront() { arrange("front") }
    @objc func bringForward() { arrange("forward") }
    @objc func sendBackward() { arrange("backward") }
    @objc func sendToBack() { arrange("back") }

    /// Stacking order of the selection (a `.set_z_index(n)` on each object that has to change); forward and backward
    /// step past the next object that overlaps it.
    func arrange(_ how: String) {
        let ids = canvas.selectedIDs
        guard let first = ids.first else { return }
        submit { [weak self] in await self?.runEdit(["op": "order", "oid": first, "oids": ids, "value": how]) }
    }

    var selectionIsGrouped: Bool { canvas.selectedIDs.contains { scene?.objects?[String($0)]?.group != nil } }

    /// The Arrange items, for the menu bar and the object's right-click menu.
    static let arrangeItems: [(title: String, action: Selector, key: String, mods: NSEvent.ModifierFlags)] = [
        ("Bring to Front", #selector(bringToFront), "f", [.command, .shift]),
        ("Bring Forward", #selector(bringForward), "f", [.command, .option, .shift]),
        ("Send Backward", #selector(sendBackward), "b", [.command, .option, .shift]),
        ("Send to Back", #selector(sendToBack), "b", [.command, .shift]),
    ]

    func validateArrangeItem(_ item: NSMenuItem) -> Bool? {
        let editing = sceneName != nil && player == nil
        switch item.action {
        case #selector(groupObjects): return editing && canvas.selectedIDs.count > 1
        case #selector(ungroupObjects): return editing && selectionIsGrouped
        case #selector(bringToFront), #selector(bringForward), #selector(sendBackward), #selector(sendToBack):
            return editing && !canvas.selectedIDs.isEmpty
        default: return nil
        }
    }

    /// Group / Ungroup and the stacking order, appended to an object's right-click menu.
    func addArrangeItems(to m: NSMenu) {
        if !m.items.isEmpty { m.addItem(.separator()) }
        if canvas.selectedIDs.count > 1 {
            let g = NSMenuItem(title: "Group", action: #selector(groupObjects), keyEquivalent: ""); g.target = self
            m.addItem(g)
        }
        if selectionIsGrouped {
            let u = NSMenuItem(title: "Ungroup", action: #selector(ungroupObjects), keyEquivalent: ""); u.target = self
            m.addItem(u)
        }
        for a in MainController.arrangeItems {
            let i = NSMenuItem(title: a.title, action: a.action, keyEquivalent: ""); i.target = self
            m.addItem(i)
        }
    }
}

import AppKit

/// MANIMBLE_TEST_IDS: headless check that an edit changes the object the user picked: one queued behind a slow
/// render goes to the slide it was asked on even after the user moved to another; after an agent adds an object
/// above the selected one, the selection follows its object and the next edit lands there; undo keeps the agent's
/// line. Runs on the hello example deck; ids.log in MANIMBLE_TEST_OUT.
extension MainController {
    func identityTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        try? "".write(toFile: dir + "ids.log", atomically: true, encoding: .utf8)
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "ids.log") }
        func settle() async { await queueTail?.value; try? await Task.sleep(nanoseconds: 800_000_000) }
        guard let ws = workspace else { log("no workspace"); exit(1) }
        let file = ws.work.appendingPathComponent("slides.py")
        func source() -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
        func classText(_ name: String) -> String {
            let s = source()
            guard let r = s.range(of: "class \(name)(") else { return "" }
            let rest = s[r.lowerBound...]
            let end = rest.dropFirst(6).range(of: "\nclass ")?.lowerBound ?? rest.endIndex
            return String(rest[..<end])
        }
        func id(_ value: String) -> Int? { scene?.objects?.first(where: { $0.value.value == value }).flatMap { Int($0.key) } }
        Task { @MainActor in
            await selectScene("Shapes")
            await settle()
            guard let heading = id("Shapes, lines and text"), let cap = id("drag, resize, retype") else { log("objects missing"); exit(1) }
            let formulaBefore = classText("Formula")

            // an edit queued behind a slow one goes to the slide it was asked on
            selection = heading; commitFontSize(44)
            selection = cap; commitColor("#FF0000")
            await selectScene("Formula")
            await settle()
            log("queued colour: on the caption=\(classText("Shapes").contains("#FF0000")) formula untouched=\(classText("Formula") == formulaBefore) on screen=\(sceneName ?? "-")")

            // an agent adds an object above the selected caption: the selection follows it
            await selectScene("Shapes")
            await settle()
            guard let cap2 = id("drag, resize, retype") else { log("caption gone"); exit(1) }
            selection = cap2
            let agent = source().replacingOccurrences(of: "        caption = label(",
                with: "        extra = label(\"agent added\", 20).move_to((0, 3, 0))\n        self.add(extra)\n        caption = label(")
            try? agent.write(to: file, atomically: true, encoding: .utf8)
            for _ in 0..<120 where id("agent added") == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
            log("agent's object shown=\(id("agent added") != nil) caption id \(cap2) -> \(id("drag, resize, retype").map(String.init) ?? "-")")
            log("selection follows the caption=\(selection.flatMap { scene?.objects?[String($0)]?.value } == "drag, resize, retype")")
            commitFontSize(30)
            await settle()
            let shapes = classText("Shapes")
            let capLine = shapes.split(separator: "\n").first { $0.contains("caption = label(") }.map(String.init) ?? "-"
            let extraLine = shapes.split(separator: "\n").first { $0.contains("extra = label(") }.map(String.init) ?? "-"
            log("font size edit: caption line '\(capLine.trimmingCharacters(in: .whitespaces))'")
            log("               agent's line '\(extraLine.trimmingCharacters(in: .whitespaces))'")

            // undo takes back the size and keeps the agent's line
            doUndo(redo: false)
            await settle()
            log("after undo: agent's line kept=\(source().contains("agent added")) caption size back=\(classText("Shapes").contains("\"drag, resize, retype\", 26"))")
            log("done")
            exit(0)
        }
    }
}

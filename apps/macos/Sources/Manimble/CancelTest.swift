import AppKit

extension MainController {
    /// `MANIMBLE_TEST_CANCEL=1` with the deck as argument: the busy pill's X stops an animated-show build and a
    /// theme switch; cancel.log and cancel-*.png in MANIMBLE_TEST_OUT.
    func cancelTest() {
        let out = ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? NSTemporaryDirectory()
        var lines: [String] = []
        func log(_ s: String) { lines.append(s); try? lines.joined(separator: "\n").write(toFile: out + "/cancel.log", atomically: true, encoding: .utf8) }
        func shot(_ n: String) {
            guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]),
                  let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: out + "/cancel-\(n).png"))
        }
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        func pill() -> String {
            "pill hidden=\(busyPill.isHidden) text=\(busyPill.label.stringValue) x hidden=\(busyPill.cancelButton.isHidden) enabled=\(busyPill.cancelButton.isEnabled)"
        }
        Task { @MainActor in
            await wait(1.5)
            while busy > 0 { await wait(0.3) }
            log("idle: \(pill())")
            // 1. the animated show: building the slides' animations, cancelled
            present(fromCurrent: false)
            await wait(1.2)
            log("building: \(pill())")
            shot("1-building")
            busyPill.cancelButton.performClick(nil)
            await wait(0.2)
            log("pressed: \(pill())")
            for _ in 0..<100 where !busyPill.isHidden { await wait(0.2) }
            await wait(0.3)
            log("after: \(pill()) toast=\(toastPill.label.stringValue) player=\(animatedPlayer != nil)")
            shot("2-cancelled")
            // 2. a theme switch with a flip, cancelled mid-way: nothing is kept
            let undo = state?.undoLabel ?? "-"
            guard let t = DeckTheme.all.first(where: { $0.id == "terminal" }) ?? DeckTheme.all.last else { log("no themes"); log("done"); return }
            runApplyTheme(t, flip: true)
            await wait(0.8)
            log("theme: \(pill())")
            shot("3-theme")
            busyPill.cancelButton.performClick(nil)
            await wait(0.2)
            log("pressed: \(pill())")
            for _ in 0..<200 where busy > 0 { await wait(0.2) }
            await queueTail?.value
            await wait(0.5)
            log("after: \(pill()) toast=\(toastPill.label.stringValue) undo before=\(undo) after=\(state?.undoLabel ?? "-") scene=\(scene?.status ?? "-")")
            shot("4-theme-cancelled")
            // 3. the same switch left alone still lands
            runApplyTheme(t, flip: true)
            for _ in 0..<300 where busy > 0 { await wait(0.2) }
            await queueTail?.value
            await wait(0.5)
            log("uncancelled: toast=\(toastPill.label.stringValue) undo=\(state?.undoLabel ?? "-")")
            log("done")
        }
    }
}

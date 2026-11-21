import AppKit

/// MANIMBLE_TEST_DROP: drags (a pasteboard as Finder fills it) a picture file and a non-picture file onto the slide,
/// and checks that only the picture is taken and lands centred where it was dropped; drop.log in MANIMBLE_TEST_OUT.
extension MainController {
    func dropTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        try? "".write(toFile: dir + "drop.log", atomically: true, encoding: .utf8)
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "drop.log") }
        func images() -> [(String, ObjInfo)] { (scene?.objects ?? [:]).filter { $0.value.kind == "image" }.map { ($0.key, $0.value) } }
        Task { @MainActor in
            await queueTail?.value
            try? await Task.sleep(nanoseconds: 800_000_000)
            let png = URL(fileURLWithPath: dir + "dropped.png")
            let img = NSImage(size: NSSize(width: 200, height: 100), flipped: false) { r in NSColor.systemRed.setFill(); r.fill(); return true }
            try? SlidePaste.png(img)?.write(to: png)
            let txt = URL(fileURLWithPath: dir + "notes.txt")
            try? "hello".write(to: txt, atomically: true, encoding: .utf8)

            let other = NSPasteboard(name: .init("manimble-drop-test-txt")); other.clearContents()
            other.writeObjects([txt as NSURL])
            log("text file accepted: \(canDropPictures(other))")

            let pb = NSPasteboard(name: .init("manimble-drop-test")); pb.clearContents()
            pb.writeObjects([png as NSURL])
            log("picture file accepted: \(canDropPictures(pb))")
            let before = images().count
            let at = CGPoint(x: canvas.frameSize.width * 0.25, y: canvas.frameSize.height * 0.3)
            log("dropped: \(picturesDropped(pb, at: at)) at \(Int(at.x)),\(Int(at.y))")
            for _ in 0..<100 where images().count == before { try? await Task.sleep(nanoseconds: 200_000_000) }
            await queueTail?.value
            try? await Task.sleep(nanoseconds: 500_000_000)
            log("images: \(before) -> \(images().count)")
            if let (k, o) = images().first {
                let v = scene?.stops?[min(stopIndex, (scene?.stops?.count ?? 1) - 1)].visible.first { Int($0[0]) == Int(k) }
                log("new image \(o.image ?? "?") centre " + (v.map { "\(Int(($0[1] + $0[3]) / 2)),\(Int(($0[2] + $0[4]) / 2))" } ?? "not visible"))
            }
            log("done")
        }
    }
}

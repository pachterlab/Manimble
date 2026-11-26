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
            // the other formats: TIFF and BMP become PNGs, a PDF its first page as a PNG, an SVG a vector picture
            let rep = NSBitmapImageRep(data: SlidePaste.png(img)!)!
            let tif = URL(fileURLWithPath: dir + "dropped.tiff"), bmp = URL(fileURLWithPath: dir + "dropped.bmp")
            try? rep.representation(using: .tiff, properties: [:])?.write(to: tif)
            try? rep.representation(using: .bmp, properties: [:])?.write(to: bmp)
            let pdf = URL(fileURLWithPath: dir + "dropped.pdf")
            let pv = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 150)); pv.wantsLayer = true
            pv.layer?.backgroundColor = NSColor.systemBlue.cgColor
            try? pv.dataWithPDF(inside: pv.bounds).write(to: pdf)
            let svg = URL(fileURLWithPath: dir + "dropped.svg")
            try? ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 60"><rect x="5" y="5" width="110" height="50" fill="#2a9d8f" stroke="#264653" stroke-width="4"/><circle cx="60" cy="30" r="15" fill="#e9c46a"/></svg>"##
                .write(to: svg, atomically: true, encoding: .utf8)
            for f in [tif, bmp, pdf, svg] {
                let q = NSPasteboard(name: .init("manimble-drop-test-\(f.pathExtension)")); q.clearContents()
                q.writeObjects([f as NSURL])
                let n = images().count
                log("\(f.pathExtension) accepted: \(canDropPictures(q)) dropped: \(picturesDropped(q, at: at))")
                for _ in 0..<150 where images().count == n { try? await Task.sleep(nanoseconds: 200_000_000) }
                await queueTail?.value
                let names = Set(images().compactMap { $0.1.image })
                log("  images \(n) -> \(images().count): \(names.sorted().joined(separator: ", "))")
            }
            log("done")
        }
    }
}

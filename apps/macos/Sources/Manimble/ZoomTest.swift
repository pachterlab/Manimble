import AppKit

extension MainController {
    /// `MANIMBLE_TEST_ZOOM=1` with the deck as argument: zooms the canvas in on the slide (normal, then dark view,
    /// which composites sprite by sprite) and logs the sharp tiles it gets (ZoomTiles.swift); zoom.log and
    /// zoom-*.png in MANIMBLE_TEST_OUT. MANIMBLE_TEST_SCENE picks the slide.
    func zoomTest() {
        let out = ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? NSTemporaryDirectory()
        var lines: [String] = []
        func log(_ s: String) { lines.append(s); try? lines.joined(separator: "\n").write(toFile: out + "/zoom.log", atomically: true, encoding: .utf8) }
        func shot(_ n: String) {
            guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]),
                  let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: URL(fileURLWithPath: out + "/zoom-\(n).png"))
        }
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        func tiles() -> String {
            guard let h = canvas.hires else { return "none" }
            return String(format: "scale=%.2f rect=[%.0f %.0f %.0f %.0f] full=%@ bg=%@ sprites=%d/%d live=%@", h.scale, h.rect.x0, h.rect.y0,
                          h.rect.x1, h.rect.y1, h.full.map { "\($0.tex.width)x\($0.tex.height)" } ?? "-",
                          h.bg.map { "\($0.tex.width)x\($0.tex.height)" } ?? "-", h.sprites.count, canvas.stop?.sprites.count ?? 0,
                          canvas.liveHires != nil ? "yes" : "no")
        }
        func settle() async -> Double {
            let t0 = Date()
            await wait(0.4)
            for _ in 0..<150 where canvas.hiresInFlight || canvas.hiresTimer != nil { await wait(0.1) }
            return Date().timeIntervalSince(t0)
        }
        Task { @MainActor in
            await wait(1.5)
            while busy > 0 || canvas.stop == nil { await wait(0.3) }
            if let want = ProcessInfo.processInfo.environment["MANIMBLE_TEST_SCENE"], scene?.name != want {
                await loadScene(want, keepStop: false)
                await wait(1)
            }
            log("scene \(scene?.name ?? "-") backing=\(window.backingScaleFactor) fit=\(canvas.fitScale)")
            log(String(format: "fit: %.1fs %@", await settle(), tiles()))
            shot("1-fit")
            canvas.zoom = canvas.fitScale * 4
            log(String(format: "4x: %.1fs %@", await settle(), tiles()))
            shot("2-zoom4")
            canvas.pan = CGPoint(x: canvas.bounds.width * 0.8, y: canvas.bounds.height * 0.6)
            log(String(format: "panned: %.1fs %@", await settle(), tiles()))
            shot("3-panned")
            canvas.colorView = .invert
            await wait(0.5)
            log("dark view: \(tiles())")
            shot("4-dark")
            canvas.colorView = .normal
            canvas.zoom = nil
            log(String(format: "fit again: %.1fs %@", await settle(), tiles()))
            log("done")
        }
    }
}

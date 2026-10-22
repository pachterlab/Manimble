import AppKit
import AVFoundation
import CoreImage

/// How slides are shown (nothing is written to the deck).
enum ColorView: String {
    case normal
    /// near-white and near-black colours have their lightness mirrored (hue and saturation kept, so pure greys become
    /// their complement); saturated colours are left alone
    case dark
    /// every colour becomes its complement, like the display's Invert Colors
    case invert
}

/// Visual-only dark mode and inverted colours. The same maps run on the GPU for the canvas (`darkmap` / `fs_tex_invert`
/// in CanvasView.swift) and in the engine when they are written to the deck (engine/manimble/darkmode.py).
enum DarkMode {
    static var mode: ColorView = ColorView(rawValue: UserDefaults.standard.string(forKey: "colorView") ?? "")
        ?? (UserDefaults.standard.bool(forKey: "darkMode") ? .dark : .normal)
    static var isOn: Bool { mode != .normal }
    static var images = UserDefaults.standard.object(forKey: "darkModeImages") as? Bool ?? true

    /// Chroma (max - min) below `lo` is fully flipped, above `hi` kept.
    static let lo: Float = 0.12, hi: Float = 0.28

    static func map(_ r: Float, _ g: Float, _ b: Float, _ m: ColorView = mode) -> (Float, Float, Float) {
        switch m {
        case .normal: return (r, g, b)
        case .invert: return (1 - r, 1 - g, 1 - b)
        case .dark: break
        }
        let mx = max(r, g, b), mn = min(r, g, b)
        let t = min(max((mx - mn - lo) / (hi - lo), 0), 1)
        let k = (1 - t * t * (3 - 2 * t)) * (1 - mx - mn)
        return (r + k, g + k, b + k)
    }

    static func map(_ c: NSColor) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        let (r, g, b) = map(Float(s.redComponent), Float(s.greenComponent), Float(s.blueComponent))
        return NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: s.alphaComponent)
    }

    // MARK: whole frames (thumbnails, slideshow)

    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    private static var cubes: [ColorView: Data] = [:]
    private static func cube(_ m: ColorView) -> Data {
        if let c = cubes[m] { return c }
        let n = 32
        var d = [Float](); d.reserveCapacity(n * n * n * 4)
        for bi in 0..<n { for gi in 0..<n { for ri in 0..<n {
            let (r, g, b) = map(Float(ri) / Float(n - 1), Float(gi) / Float(n - 1), Float(bi) / Float(n - 1), m)
            d += [r, g, b, 1]
        } } }
        let c = d.withUnsafeBufferPointer { Data(buffer: $0) }
        cubes[m] = c
        return c
    }

    static func apply(_ img: CGImage) -> CGImage? {
        guard let f = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        f.setValue(CIImage(cgImage: img), forKey: kCIInputImageKey)
        f.setValue(32, forKey: "inputCubeDimension")
        f.setValue(cube(mode), forKey: "inputCubeData")
        f.setValue(CGColorSpace(name: CGColorSpace.sRGB)!, forKey: "inputColorSpace")
        guard let out = f.outputImage else { return nil }
        return context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Plays a clip through the same map (the animated player).
    static func videoComposition(for asset: AVAsset) -> AVVideoComposition {
        let data = cube(mode)                 // built here: the handler runs off the main thread
        return AVVideoComposition(asset: asset) { req in
            let f = CIFilter(name: "CIColorCubeWithColorSpace")
            f?.setValue(req.sourceImage, forKey: kCIInputImageKey)
            f?.setValue(32, forKey: "inputCubeDimension")
            f?.setValue(data, forKey: "inputCubeData")
            f?.setValue(CGColorSpace(name: CGColorSpace.sRGB)!, forKey: "inputColorSpace")
            req.finish(with: f?.outputImage ?? req.sourceImage, context: nil)
        }
    }

    /// A slide picture as it should be shown right now (mapped in dark mode or with inverted colours).
    static func cgImage(path: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return isOn ? (apply(img) ?? img) : img
    }

    static func image(path: String) -> NSImage? {
        guard isOn else { return NSImage(contentsOfFile: path) }
        guard let cg = cgImage(path: path) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

extension MainController {
    /// View ▸ Dark Mode and the toolbar's moon.
    @objc func toggleDarkMode() { setColorView(DarkMode.mode == .dark ? .normal : .dark) }
    /// View ▸ Invert Colors.
    @objc func toggleInvertColors() { setColorView(DarkMode.mode == .invert ? .normal : .invert) }

    @objc func toggleDarkImages() {
        DarkMode.images.toggle()
        UserDefaults.standard.set(DarkMode.images, forKey: "darkModeImages")
        canvas.darkImages = DarkMode.images
    }

    func setColorView(_ m: ColorView) {
        DarkMode.mode = m
        UserDefaults.standard.set(m.rawValue, forKey: "colorView")
        canvas.colorView = m
        if let item = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "dark" }) {
            item.image = NSImage(systemSymbolName: m == .dark ? "moon.fill" : "moon", accessibilityDescription: "Dark Mode")
        }
        suppressTable = true; table.reloadData(); suppressTable = false
        if let n = sceneName, let i = state?.scenes.firstIndex(where: { $0.name == n }) { selectRow(i) }
        rebuildSteps()
    }

    /// Format ▸ Apply Dark Mode to Deck… / Apply Inverted Colors to Deck…: write the same map into the source (one undo step).
    @objc func applyDarkMode() { confirmApply(.dark) }
    @objc func applyInvertColors() { confirmApply(.invert) }

    func confirmApply(_ m: ColorView) {
        let a = NSAlert()
        if m == .dark {
            a.messageText = "Apply dark mode to the deck?"
            a.informativeText = "Near-white and near-black colours in your code are swapped (WHITE ↔ BLACK, GRAY_B ↔ GRAY_D, "
                + "\"#F5F5F5\" ↔ \"#0A0A0A\", …), including the background in manim.cfg, and objects that use a default colour get an "
                + "explicit one. Other colours and images are not changed."
        } else {
            a.messageText = "Invert the deck's colours?"
            a.informativeText = "Every colour in your code becomes its complement (WHITE → BLACK, ORANGE → \"#0079D0\", "
                + "\"#2255AA\" → \"#DDAA55\", …), including the background in manim.cfg, and objects that use a default colour get an "
                + "explicit one. Images are not changed."
        }
        a.informativeText += " Every slide is re-rendered, so this can take a while. Undo (⌘Z) reverts it in one step."
        a.addButton(withTitle: "Apply"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            self?.runApplyColors(m)
        }
    }

    func runApplyColors(_ m: ColorView) {
        submit { [weak self] in
            guard let self = self else { return }
            self.busyText = m == .dark ? "Applying dark mode…" : "Inverting colours…"
            self.busy += 1
            var result: EditResult?
            var failure: String?
            do { result = try await self.engine.call("darkmode", ["current": self.sceneName ?? "", "mode": m.rawValue], as: EditResult.self) }
            catch { failure = "\(error)" }
            self.busy -= 1
            self.busyText = "Rendering…"
            if let res = result, res.ok == true {
                self.lastChanged = res.changed
                // the deck itself is mapped now: showing it mapped again would undo the change on screen
                if DarkMode.mode == m { self.setColorView(.normal) }
                self.toast(res.message == "no change" ? "No colours to change" : "Saved · \(res.message ?? "")")
            } else {
                self.toast(failure ?? result?.error ?? "colour change failed", error: true)
            }
            self.canvas.dropTextures()
            if let n = self.sceneName { await self.loadScene(n, keepStop: true) }
            await self.reloadState()
        }
    }
}

extension MainController {
    /// Headless check of dark mode: MANIMBLE_TEST_DARK=<deck>, output in MANIMBLE_SELFTEST.
    func darkModeTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_SELFTEST"] ?? "/tmp") + "/"
        func save(_ img: CGImage?, _ name: String) {
            if let img = img { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name)) }
        }
        func windowShot(_ name: String) {
            if let v = window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
            }
        }
        Task { @MainActor in
            var log = ""
            if let s = scene?.stops?.count { stopIndex = s - 1; applyStop(); rebuildSteps() }
            let m = ColorView(rawValue: ProcessInfo.processInfo.environment["MANIMBLE_TEST_MODE"] ?? "") ?? .dark
            setColorView(.normal)
            try? await Task.sleep(nanoseconds: 500_000_000)
            save(canvas.snapshot(), "dark-0-light.png")
            setColorView(m)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            save(canvas.snapshot(), "dark-1-visual.png")
            windowShot("dark-1-window.png")
            runApplyColors(m)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            while busy > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
            log += "apply toast=\(toastPill.label.stringValue) viewAfter=\(DarkMode.mode)\n"
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            save(canvas.snapshot(), "dark-2-applied.png")
            undo()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while busy > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            save(canvas.snapshot(), "dark-3-undone.png")
            log += "undo toast=\(toastPill.label.stringValue)\n"
            try? (log + "done\n").write(toFile: dir + "dark.log", atomically: true, encoding: .utf8)
        }
    }
}

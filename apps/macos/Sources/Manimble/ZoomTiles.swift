import AppKit
import Metal

// Sharp text and shapes when the editor canvas is zoomed in.
//
// A render's frames and sprites are bitmaps at the deck's frame size (1280 px wide, typically), so the canvas
// magnifies them once it shows more than one device pixel per frame pixel: already ~2× at "Fit in Window" on a
// Retina screen, up to 16× fully zoomed. Once the zoom and pan settle, the canvas asks the engine (`hires`) to
// draw the visible part of the shown build again at the screen's density: the whole frame there, the part no
// sprite owns, and each sprite's part. Manim's objects are vectors, so these tiles are exact at any zoom. They are
// drawn over the low-res pixels and only while they still match: the same render (stop png) and build, nothing
// previewed on the object (a drag, resize or replacement keeps its own sprite).

/// One tile from `hires`: a picture covering frame px [x, x+w) × [y, y+h).
struct HiresTile: Decodable {
    var file: String
    var x: Double, y: Double, w: Double, h: Double
    var oid: Int?
}

struct HiresResult: Decodable {
    var scale: Double?
    var full: HiresTile?
    var bg: HiresTile?
    var sprites: [HiresTile]?
    var stale: Bool?
    var error: String?
}

/// The tiles in use: which render and build they belong to (`png`), at what density and over what region.
struct HiresSet {
    struct Tex { var tex: MTLTexture; var box: Box }
    var png: String
    var scale: Double
    var rect: Box
    var full: Tex?
    var bg: Tex?
    var sprites: [Int: Tex]
}

/// What the canvas would like drawn sharply: the build shown (`png`), device px per frame px, frame-px region.
struct HiresWant: Equatable {
    var png: String
    var scale: Double
    var rect: [Double]       // x0, y0, x1, y1
}

extension CanvasView {
    /// Below this many device pixels per frame pixel the render's own bitmaps are sharp enough.
    static let hiresThreshold = 1.1

    /// Tiles usable for the stop on screen right now (nil when they belong to another render or build).
    var liveHires: HiresSet? {
        guard let h = hires, let s = stop, h.png == s.png, !optimistic else { return nil }
        return h
    }

    /// The frame-px region of the view (with some margin for small pans) and the density it shows the slide at.
    private func hiresNeed() -> HiresWant? {
        guard let s = stop, onWantHires != nil, frameSize.width > 0, bounds.width > 0 else { return nil }
        let device = Double(effectiveScale * (window?.backingScaleFactor ?? 2))
        guard device >= CanvasView.hiresThreshold else { return nil }
        let r = slideRect, k = Double(r.width / frameSize.width)          // points per frame px
        let fw = Double(frameSize.width), fh = Double(frameSize.height)
        var x0 = Double(-r.minX) / k, x1 = Double(bounds.width - r.minX) / k
        var y0 = Double(r.maxY - bounds.height) / k, y1 = Double(r.maxY) / k
        let mx = (x1 - x0) * 0.15, my = (y1 - y0) * 0.15
        x0 = max(-fw, x0 - mx); x1 = min(2 * fw, x1 + mx)
        y0 = max(-fh, y0 - my); y1 = min(2 * fh, y1 + my)
        guard x1 > x0, y1 > y0 else { return nil }
        return HiresWant(png: s.png, scale: min(16, (device * 4).rounded(.up) / 4), rect: [x0, y0, x1, y1])
    }

    /// Whether the tiles in hand already show `w`'s region at least as sharply (and not wastefully finer).
    private func covers(_ h: HiresSet, _ w: HiresWant) -> Bool {
        guard h.png == w.png, h.scale + 0.01 >= w.scale, h.scale <= w.scale * 2.5 else { return false }
        // the margin is slack: the visible part (the region less its margin) has to be inside
        let mx = (w.rect[2] - w.rect[0]) * 0.15 / 1.3, my = (w.rect[3] - w.rect[1]) * 0.15 / 1.3
        return h.rect.x0 <= w.rect[0] + mx + 1 && h.rect.y0 <= w.rect[1] + my + 1
            && h.rect.x1 >= w.rect[2] - mx - 1 && h.rect.y1 >= w.rect[3] - my - 1
    }

    /// Called after every redraw: once the view has settled on something the tiles don't cover, ask for new ones.
    func hiresCheck() {
        guard let w = hiresNeed() else {
            // zoomed back out: tiles far finer than the screen would only alias
            if let h = hires, let s = stop, h.png != s.png || h.scale > Double(effectiveScale * (window?.backingScaleFactor ?? 2)) * 2.5 {
                hires = nil
            }
            hiresTimer?.invalidate(); hiresTimer = nil
            return
        }
        if let h = hires, covers(h, w) { hiresTimer?.invalidate(); hiresTimer = nil; return }
        if w == hiresAsked { return }
        hiresTimer?.invalidate()
        hiresTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hiresFire() }
        }
    }

    private func hiresFire() {
        hiresTimer = nil
        guard let w = hiresNeed() else { return }
        if let h = hires, covers(h, w) { return }
        if hiresInFlight { hiresAsked = w; hiresQueued = true; return }   // sent when the one in flight returns
        hiresAsked = w
        hiresInFlight = true
        onWantHires?(w)
    }

    /// The host's answer to `onWantHires(w)` (nil: nothing to show).
    func hiresDone(_ r: HiresResult?, for w: HiresWant) {
        hiresInFlight = false
        if hiresQueued {
            hiresQueued = false
            hiresAsked = nil
            hiresFire()
        }
        guard let r = r, r.error == nil, r.stale != true, let scale = r.scale, let s = stop, s.png == w.png else {
            if r?.error != nil || r?.stale == true { Engine.note("canvas: no zoom tiles: \(r?.error ?? "stale render")") }
            return
        }
        func load(_ t: HiresTile?) -> HiresSet.Tex? {
            guard let t = t, let tex = makeTexture(path: t.file) else { return nil }
            return HiresSet.Tex(tex: tex, box: Box(x0: t.x, y0: t.y, x1: t.x + t.w, y1: t.y + t.h))
        }
        var sprites: [Int: HiresSet.Tex] = [:]
        for t in r.sprites ?? [] { if let oid = t.oid, let x = load(t) { sprites[oid] = x } }
        hires = HiresSet(png: w.png, scale: scale, rect: Box(x0: w.rect[0], y0: w.rect[1], x1: w.rect[2], y1: w.rect[3]),
                         full: load(r.full), bg: load(r.bg), sprites: sprites)
        setNeedsDisplay(bounds)
    }
}

extension MainController {
    /// The canvas wants sharp tiles of the build it shows (see ZoomTiles.swift).
    func fetchHires(_ w: HiresWant) {
        guard let sc = scene, let stops = sc.stops, stops.indices.contains(stopIndex), stops[stopIndex].png == w.png,
              sc.optimistic != true else {
            canvas.hiresDone(nil, for: w)
            return
        }
        let dir = URL(fileURLWithPath: w.png).deletingLastPathComponent().lastPathComponent
        let args: [String: Any] = ["scene": sc.name, "dir": dir, "stop": stopIndex, "scale": w.scale, "rect": w.rect]
        Task { @MainActor in
            let r = try? await engine.call("hires", args, as: HiresResult.self)
            canvas.hiresDone(r, for: w)
        }
    }
}

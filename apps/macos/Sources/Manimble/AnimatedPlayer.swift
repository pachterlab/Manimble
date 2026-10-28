import AppKit
import AVFoundation
import QuartzCore
import ImageIO

/// One Manim Slides slide (a `next_slide()` stop): the clip that plays when you advance to it.
struct PresentSlide: Decodable {
    var scene: String
    var sceneIndex: Int              // place in order.txt (what chapters and links refer to)
    var number: Int                  // place in this show (hidden slides are left out)
    var index: Int
    var count: Int
    var kind: String                 // video | image
    var file: String?
    var revFile: String?
    var loop: Bool
    var autoNext: Bool
    var rate: Double
    var revRate: Double
    var notes: String
    var buildNotes: String?
    /// Still building: an image page showing the editor's still (`file`), or a "Building…" card when it has none.
    var pending: Bool?
}

struct PresentDeck: Decodable {
    var slides: [PresentSlide]
    var sections: [Int]              // sceneIndex each chapter starts at (keys 1-9, footer clicks)
    var links: [String: [LinkRegion]] // scene index -> clickable regions

    /// [x0, x1, y0, y1, url] as fractions of the slide, y from the top.
    struct LinkRegion: Decodable {
        var x0: Double, x1: Double, y0: Double, y1: Double, url: String
        init(from d: Decoder) throws {
            var c = try d.unkeyedContainer()
            x0 = try c.decode(Double.self); x1 = try c.decode(Double.self)
            y0 = try c.decode(Double.self); y1 = try c.decode(Double.self)
            url = try c.decode(String.self)
        }
    }
}

/// Native replacement for `manim-slides present`: plays the rendered clips with AVFoundation, so the app needs no Qt.
///
/// Keys follow Manim Slides where they exist (→ next, ← previous, space play/pause, R replay, V reverse, Q quit)
/// plus the built-in slideshow's (B blank, P progress, Home/End, Esc). 1-9 jump to the deck's chapters.
final class AnimatedPlayer: NSObject {
    private enum Mode { case play, end, reverse }

    /// One AVPlayer and its layer. Each slide gets a fresh pair, and the old one stays on screen until the new
    /// clip's first frame is ready, so moving between slides never flashes black (or a stale frame).
    private final class Deck {
        let player = AVPlayer()
        let layer: AVPlayerLayer
        var readyObs: NSKeyValueObservation?
        var endObs: NSObjectProtocol?
        init() {
            player.actionAtItemEnd = .pause
            player.preventsDisplaySleepDuringVideoPlayback = true
            layer = AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            layer.backgroundColor = NSColor.clear.cgColor
            layer.opacity = 0
        }
        func clear() {
            readyObs = nil
            if let o = endObs { NotificationCenter.default.removeObserver(o); endObs = nil }
        }
    }

    let window: PlayerWindow
    private let root: NSView
    private var current: Deck?
    private var pending: Deck?
    private let still = CALayer()
    private let progress = CALayer()
    private let counter = CATextLayer()
    private let placeholder = CATextLayer()      // over a page still building that has no still yet
    private var deck = PresentDeck(slides: [], sections: [], links: [:])
    private var index = 0
    private var generation = 0
    private var finished = false
    private var blackedOut = false
    private var showProgress = true
    private var hideWork: DispatchWorkItem?
    private var savedOptions: NSApplication.PresentationOptions = []
    private var shown = true
    var onExit: (() -> Void)?
    /// Called after every slide change and play/pause/end (Presenter View mirrors the audience display).
    var onChange: (() -> Void)?
    /// Bumped whenever `update` replaces the pages, so Presenter View rebuilds its sidebar.
    private(set) var reloadToken = 0

    private var slides: [PresentSlide] { deck.slides }

    init(screen: NSScreen) {
        window = PlayerWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        root = ShowView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init()
        window.backgroundColor = .black
        window.level = .mainMenu + 1
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = root
        still.frame = root.bounds
        still.contentsGravity = .resizeAspect
        still.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.layer?.addSublayer(still)
        progress.backgroundColor = Theme.accent.cgColor
        progress.frame = CGRect(x: 0, y: 0, width: 0, height: 3)
        root.layer?.addSublayer(progress)
        counter.fontSize = 13; counter.foregroundColor = NSColor(white: 1, alpha: 0.8).cgColor
        counter.alignmentMode = .right; counter.contentsScale = screen.backingScaleFactor
        counter.frame = CGRect(x: root.bounds.width - 220, y: 14, width: 204, height: 18)
        counter.autoresizingMask = [.layerMinXMargin]
        root.layer?.addSublayer(counter)
        placeholder.fontSize = 26; placeholder.foregroundColor = NSColor(white: 1, alpha: 0.55).cgColor
        placeholder.alignmentMode = .center; placeholder.contentsScale = screen.backingScaleFactor
        placeholder.frame = CGRect(x: 0, y: root.bounds.midY - 20, width: root.bounds.width, height: 40)
        placeholder.autoresizingMask = [.layerWidthSizable, .layerMinYMargin, .layerMaxYMargin]
        placeholder.isHidden = true
        root.layer?.addSublayer(placeholder)
        window.onKey = { [weak self] e in self?.key(e) }
        window.onMouse = { [weak self] e, primary in self?.click(e, primary: primary) }
        window.overLink = { [weak self] e in
            guard let self, let p = self.slidePoint(e) else { return false }
            return self.link(at: p) != nil
        }
    }

    /// `screen`: where the audience display goes; `visible: false` plays without showing a window.
    /// `ownSpace`: take the display with a full-screen Space of its own (see `PlayerWindow.present`).
    func play(_ d: PresentDeck, startScene: Int, screen: NSScreen? = nil, visible: Bool = true, ownSpace: Bool = false) {
        deck = d
        guard !slides.isEmpty else { return }
        shown = visible
        if visible {
            savedOptions = NSApp.presentationOptions
            if !ownSpace { NSApp.presentationOptions = [.hideDock, .hideMenuBar] }
            window.present(on: screen ?? window.screen ?? NSScreen.main ?? NSScreen.screens[0], ownSpace: ownSpace)
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        show(slides.firstIndex(where: { $0.sceneIndex >= startScene }) ?? 0, .play)
    }

    /// The pages again, as slides that were still building when the show started get their clips (`present`
    /// "update" events). The show stays on the slide and build it is showing; a page that was a placeholder
    /// comes back at the end of its clip, so the picture on screen does not jump back to the build's start.
    func update(_ d: PresentDeck) {
        guard !d.slides.isEmpty else { return }
        let old = currentSlide
        deck = d
        reloadToken += 1
        var i = min(index, slides.count - 1)
        if let o = old {
            i = slides.firstIndex { $0.scene == o.scene && $0.index == o.index }
                ?? slides.firstIndex { $0.scene == o.scene } ?? slides.firstIndex { $0.number >= o.number } ?? slides.count - 1
        }
        index = i
        if old?.pending == true, slides[i].pending != true || slides[i].file != old?.file {
            show(i, .end)
        } else {
            updateChrome()
            onChange?()
        }
    }

    // MARK: Loading clips

    private func show(_ i: Int, _ mode: Mode) {
        guard slides.indices.contains(i) else { return }
        index = i
        generation += 1
        finished = false
        let gen = generation, slide = slides[i]
        updateChrome()
        discard(pending); pending = nil
        placeholder.string = "Building slide \(slide.number + 1)…"
        placeholder.isHidden = blackedOut || slide.pending != true || slide.file != nil
        if slide.kind == "image" {
            discard(current); current = nil
            setStill(slide.file.flatMap(loadImage))
            finished = true
            onChange?()
            return
        }
        let path = mode == .reverse ? (slide.revFile ?? slide.file) : slide.file
        guard let p = path, FileManager.default.fileExists(atPath: p) else {
            finished = true                          // nothing to play: count the page as settled so stepping and scripts go on
            onChange?()
            return
        }
        let next = Deck()
        next.layer.frame = root.bounds
        next.layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.layer?.insertSublayer(next.layer, below: still)
        pending = next
        let item = AVPlayerItem(url: URL(fileURLWithPath: p))
        if DarkMode.isOn { item.videoComposition = DarkMode.videoComposition(for: item.asset) }
        next.player.replaceCurrentItem(with: item)
        let rate = Float(mode == .reverse ? slide.revRate : slide.rate)
        next.endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) {
            [weak self] _ in self?.ended(gen, mode)
        }
        let reveal: () -> Void = { [weak self, weak next] in
            guard let self = self, let next = next, gen == self.generation else { return }
            next.readyObs = nil
            self.swap(to: next)
            if mode == .end { self.finished = true } else { next.player.playImmediately(atRate: rate) }
            self.onChange?()
        }
        let waitForFrame = { [weak next] in
            guard let next = next else { return }
            if next.layer.isReadyForDisplay { reveal(); return }
            next.readyObs = next.layer.observe(\.isReadyForDisplay, options: [.new]) { l, _ in
                if l.isReadyForDisplay { DispatchQueue.main.async(execute: reveal) }
            }
        }
        if mode == .end {
            Task { @MainActor in
                let dur = (try? await item.asset.load(.duration)) ?? .zero
                guard gen == self.generation else { return }
                let last = CMTimeMaximum(.zero, CMTimeSubtract(dur, CMTime(value: 1, timescale: 60)))
                await next.player.seek(to: last, toleranceBefore: .zero, toleranceAfter: .zero)
                guard gen == self.generation else { return }
                waitForFrame()
            }
        } else {
            waitForFrame()
        }
        prewarm(i + 1)
    }

    private func swap(to d: Deck) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        d.layer.opacity = blackedOut ? 0 : 1
        still.contents = nil
        CATransaction.commit()
        if current !== d { discard(current) }
        current = d
        if pending === d { pending = nil }
        onChange?()
    }

    private func discard(_ d: Deck?) {
        guard let d = d else { return }
        d.player.pause(); d.clear(); d.player.replaceCurrentItem(with: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        d.layer.removeFromSuperlayer()
        CATransaction.commit()
    }

    private func setStill(_ img: CGImage?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        still.contents = blackedOut ? nil : img
        CATransaction.commit()
    }

    private func ended(_ gen: Int, _ mode: Mode) {
        guard gen == generation else { return }
        let slide = slides[index]
        if mode == .play && slide.loop, let p = current?.player {
            p.seek(to: .zero)
            p.playImmediately(atRate: Float(slide.rate))
        } else if mode == .play && slide.autoNext && index + 1 < slides.count {
            show(index + 1, .play)
        } else {
            finished = true
            onChange?()
        }
    }

    /// Opening the next file ahead of time keeps the first frame of the next slide from stalling.
    private func prewarm(_ i: Int) {
        guard slides.indices.contains(i), let f = slides[i].file else { return }
        let a = AVURLAsset(url: URL(fileURLWithPath: f))
        Task { _ = try? await a.load(.duration, .tracks) }
    }

    private func loadImage(_ path: String) -> CGImage? { DarkMode.cgImage(path: path) }

    /// The build on screen, and whether it has finished playing (a looping one counts once it is up).
    var currentSlide: PresentSlide? { slides.indices.contains(index) ? slides[index] : nil }
    var isSettled: Bool { finished || (currentSlide?.loop == true && current != nil && pending == nil) }

    /// Where the slide is drawn in the window: the clip's picture, else the still's, else a 16:9 fit.
    var slideRectOnScreen: CGRect {
        if let v = current?.layer.videoRect, v.width > 0, current?.layer.superlayer != nil { return v }
        let b = root.bounds
        var aspect: CGFloat = 16 / 9
        if let c = still.contents, CFGetTypeID(c as CFTypeRef) == CGImage.typeID {
            let img = c as! CGImage
            aspect = CGFloat(img.width) / CGFloat(max(1, img.height))
        }
        let w = min(b.width, b.height * aspect), h = w / aspect
        return CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
    }

    // MARK: Navigation

    func next() { if index == slides.count - 1 { if finished { exit() } } else { show(index + 1, .play) } }
    func previous() { if index > 0 { show(index - 1, .end) } }
    /// Jump to a page (Presenter View's thumbnails) and play its build.
    func go(_ i: Int) { show(i, .play) }
    private func replay() { show(index, .play) }
    private func reverse() { show(index, .reverse) }

    private func playPause() {
        if finished { next(); return }
        guard let p = current?.player else { return }
        if p.timeControlStatus == .paused { p.playImmediately(atRate: Float(slides[index].rate)) } else { p.pause() }
        onChange?()
    }

    // MARK: Presenter View

    var isBlackedOut: Bool { blackedOut }
    var pageCount: Int { slides.count }
    var pageIndex: Int { index }
    var slideCount: Int { (slides.last?.number ?? 0) + 1 }
    /// The clip on screen, for Presenter View to show live (one AVPlayer can drive several layers).
    var livePlayer: AVPlayer? { current?.player }
    var playbackState: String? {
        if slides.indices.contains(index), slides[index].kind == "image" { return nil }
        if finished { return "Build done" }
        return current?.player.timeControlStatus == .paused ? "Paused" : "Playing"
    }

    func presenterPage(_ i: Int) -> PresenterPage {
        let s = slides[i]
        return PresenterPage(slide: s.number, build: s.index, builds: s.count, scene: s.scene, notes: s.notes, buildNotes: s.buildNotes ?? "",
                             still: s.kind == "image" ? s.file : nil, clip: s.kind == "video" ? s.file : nil)
    }

    /// Notes typed in Presenter View, once saved: the slide's go to every build of its scene, a build's to that page.
    func setNotes(_ text: String, forPage i: Int, build: Bool) {
        guard slides.indices.contains(i) else { return }
        if build { deck.slides[i].buildNotes = text; return }
        for k in deck.slides.indices where deck.slides[k].scene == slides[i].scene { deck.slides[k].notes = text }
    }

    /// Handle a key from another window (Presenter View). Returns false for keys it does not know.
    @discardableResult func handleKey(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 124, 125, 49, 36, 76, 121, 123, 126, 51, 116, 115, 119, 53: key(e); return true
        default:
            let c = e.charactersIgnoringModifiers?.lowercased() ?? ""
            if let n = Int(c), n >= 1 { key(e); return true }
            switch c {
            case "q", "v", "b", ".", "p", "n": key(e); return true
            default: return false
            }
        }
    }

    /// For the headless test: where the show is and what the visible clip is doing.
    var debugState: String {
        let s = slides[index], p = current?.player
        let file = (p?.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent ?? "-"
        let t = p.map { String(format: "%.2f", $0.currentTime().seconds) } ?? "-"
        let st = p.map { ["paused", "waiting", "playing"][$0.timeControlStatus.rawValue] } ?? "-"
        return "slide \(index + 1)/\(slides.count) \(s.scene)#\(s.index) file=\(file) t=\(t) \(st) finished=\(finished) pending=\(pending != nil) building=\(slides.filter { $0.pending == true }.count) layers=\(root.layer?.sublayers?.count ?? 0)"
    }

    func jump(section k: Int) {
        guard deck.sections.indices.contains(k),
              let i = slides.firstIndex(where: { $0.sceneIndex == deck.sections[k] }) else { return }
        show(i, .play)
    }

    private func key(_ e: NSEvent) {
        switch e.keyCode {
        case 124, 125, 36, 76, 121: next()                 // → ↓ return enter pageDown
        case 49: playPause()                               // space
        case 123, 126, 51, 116: previous()                 // ← ↑ delete pageUp
        case 115: show(0, .play)                           // home
        case 119: show(slides.count - 1, .end)             // end
        case 53: exit()                                    // esc
        default:
            let c = e.charactersIgnoringModifiers?.lowercased() ?? ""
            if let n = Int(c), n >= 1 { jump(section: n - 1); return }
            switch c {
            case "q": exit()
            case "r": replay()
            case "v": reverse()
            case "b", ".":
                blackedOut.toggle()
                CATransaction.begin(); CATransaction.setAnimationDuration(0.25)
                current?.layer.opacity = blackedOut ? 0 : 1
                CATransaction.commit()
                if slides[index].kind == "image" { setStill(blackedOut ? nil : slides[index].file.flatMap(loadImage)) }
                placeholder.isHidden = blackedOut || slides[index].pending != true || slides[index].file != nil
                onChange?()
            case "p": showProgress.toggle(); updateChrome()
            case "n": // next scene, skipping the rest of this one's stops
                if let t = slides.firstIndex(where: { $0.number > slides[index].number }) { show(t, .play) }
            default: break
            }
        }
    }

    /// Link regions open in the browser, the bottom strip jumps to a chapter (when the deck has chapters),
    /// any other click advances; a right click goes back.
    private func click(_ e: NSEvent, primary: Bool) {
        guard primary else { previous(); return }
        guard let p = slidePoint(e) else { next(); return }
        let x = p.x, y = p.y
        if let u = link(at: p) { NSWorkspace.shared.open(u); return }
        if y >= 0.94, !deck.sections.isEmpty {
            jump(section: min(deck.sections.count - 1, Int(Double(deck.sections.count) * x)))
            return
        }
        next()
    }

    /// Where an event falls on the slide, as fractions (y from the top); nil off the picture.
    private func slidePoint(_ e: NSEvent) -> CGPoint? {
        let vr = current?.layer.videoRect ?? .zero
        let r = vr.isEmpty ? root.bounds : vr
        let p = e.locationInWindow
        let x = (p.x - r.minX) / r.width, y = 1 - (p.y - r.minY) / r.height
        return (0...1).contains(x) && (0...1).contains(y) ? CGPoint(x: x, y: y) : nil
    }

    /// The link region of the slide on screen under a point given as fractions of the slide.
    func link(at p: CGPoint) -> URL? {
        guard slides.indices.contains(index), !blackedOut else { return nil }
        return PresentDeck.LinkRegion.url(at: p, in: deck.links[String(slides[index].sceneIndex)] ?? [])
    }

    // MARK: Chrome

    private func updateChrome() {
        let s = slides[index]
        let scenes = (slides.last?.number ?? 0) + 1
        let w = root.bounds.width
        CATransaction.begin(); CATransaction.setAnimationDuration(0.25)
        progress.frame = CGRect(x: 0, y: 0, width: showProgress ? w * CGFloat(index + 1) / CGFloat(slides.count) : 0, height: 3)
        CATransaction.commit()
        counter.string = showProgress ? "\(s.number + 1) / \(scenes)" + (s.count > 1 ? "  ·  \(s.index + 1)/\(s.count)" : "") : ""
        counter.opacity = 1
        hideWork?.cancel()
        let hw = DispatchWorkItem { [weak self] in
            CATransaction.begin(); CATransaction.setAnimationDuration(0.6); self?.counter.opacity = 0; CATransaction.commit()
        }
        hideWork = hw
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: hw)
    }

    func exit() {
        generation += 1
        discard(pending); discard(current); pending = nil; current = nil
        hideWork?.cancel()
        if shown { NSApp.presentationOptions = savedOptions }
        window.dismiss()
        onExit?()
    }
}

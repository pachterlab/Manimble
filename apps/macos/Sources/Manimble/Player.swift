import AppKit
import AVFoundation
import QuartzCore
import ImageIO

/// The show's content view. A click on a window that is not key normally only activates it (the mouse-down is
/// dropped); with Presenter View on the other display that is the show's situation, so take the first click too.
final class ShowView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Borderless full-screen window that plays the deck build by build.
final class PlayerWindow: NSWindow {
    /// A native full-screen transition is under way (see `whenSettled`).
    private var transitioning = false
    private var settled: [() -> Void] = []
    var onKey: ((NSEvent) -> Void)?
    var onClick: ((Bool) -> Void)?          // true = forward
    var onMouse: ((NSEvent, Bool) -> Void)? // takes over from onClick when the position matters (true = left button)
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
    override func mouseDown(with event: NSEvent) { if let m = onMouse { m(event, true) } else { onClick?(true) } }
    override func rightMouseDown(with event: NSEvent) { if let m = onMouse { m(event, false) } else { onClick?(false) } }

    /// Shows the window as the whole of `screen`. `ownSpace`: as a native full-screen window with a Space of its
    /// own, so the display switches to the show whatever it was showing (another app's full-screen Space included),
    /// the way PowerPoint and Keynote take a display. Otherwise a borderless window above the menu bar that joins
    /// the Space on view (the single-display show, where Presenter View floats above it).
    func present(on screen: NSScreen, ownSpace: Bool) {
        if ownSpace {
            collectionBehavior = [.fullScreenPrimary]
            level = .normal
            setFrame(screen.frame, display: true)
            makeKeyAndOrderFront(nil)
            if !styleMask.contains(.fullScreen) { enterFullScreen() }
        } else {
            setFrame(screen.frame, display: true)
            makeKeyAndOrderFront(nil)
        }
    }

    /// Hides the window, leaving its full-screen Space first when it has one.
    func dismiss() {
        guard styleMask.contains(.fullScreen) else { orderOut(nil); return }
        once(NSWindow.didExitFullScreenNotification) { [weak self] in self?.orderOut(nil) }
        toggleFullScreen(nil)
    }

    /// Moves the show to another display (Presenter View's Swap Displays), through a full-screen round trip when
    /// it has a Space of its own: leave, let the transition settle, move, enter again. `done` runs once the show
    /// is up on the new display.
    func move(to screen: NSScreen, done: (() -> Void)? = nil) {
        guard styleMask.contains(.fullScreen) else { setFrame(screen.frame, display: true); done?(); return }
        once(NSWindow.didExitFullScreenNotification) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard let self else { return }
                self.setFrame(screen.frame, display: true)
                self.once(NSWindow.didEnterFullScreenNotification) { done?() }
                self.enterFullScreen()
            }
        }
        toggleFullScreen(nil)
    }

    /// Enters native full screen, noting the transition so `whenSettled` can wait for it.
    private func enterFullScreen() {
        transitioning = true
        once(NSWindow.didEnterFullScreenNotification) { [weak self] in
            guard let self else { return }
            self.transitioning = false
            let work = self.settled; self.settled = []
            work.forEach { $0() }
        }
        toggleFullScreen(nil)
    }

    /// Runs `work` once the window is up: now, or when the full-screen transition under way has finished (two
    /// windows entering full screen on two displays at once leaves one of them where it was).
    func whenSettled(_ work: @escaping () -> Void) {
        if transitioning { settled.append(work) } else { work() }
    }
}

extension NSWindow {
    /// Runs `work` the next time this window posts `name`.
    func once(_ name: Notification.Name, _ work: @escaping () -> Void) {
        final class Token { var value: NSObjectProtocol? }
        let token = Token()
        token.value = NotificationCenter.default.addObserver(forName: name, object: self, queue: .main) { _ in
            if let t = token.value { NotificationCenter.default.removeObserver(t); token.value = nil }
            work()
        }
    }
}

final class SlidePlayer: NSObject {
    struct Page { var slide: Int; var build: Int; var builds: Int; var path: String }

    let window: PlayerWindow
    private let content = CALayer()
    private let progress = CALayer()
    private let counter = CATextLayer()
    private(set) var pages: [Page] = []
    private(set) var index = 0
    /// Speaker notes per slide, and each slide's notes per build, for Presenter View.
    var notes: [String] = []
    var buildNotes: [[String]] = []
    /// Called after every page change (the presenter view mirrors the audience display).
    var onChange: (() -> Void)?
    private var cache: [String: CGImage] = [:]
    private var blackedOut = false
    private var showProgress = true
    private var hideWork: DispatchWorkItem?
    private var savedOptions: NSApplication.PresentationOptions = []
    var onExit: (() -> Void)?

    init(screen: NSScreen) {
        window = PlayerWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.backgroundColor = .black
        window.level = .mainMenu + 1
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        let root = ShowView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = root
        content.frame = root.bounds
        content.contentsGravity = .resizeAspect
        content.magnificationFilter = .linear; content.minificationFilter = .trilinear
        content.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.layer?.addSublayer(content)
        progress.backgroundColor = Theme.accent.cgColor
        progress.frame = CGRect(x: 0, y: 0, width: 0, height: 3)
        root.layer?.addSublayer(progress)
        counter.fontSize = 13; counter.foregroundColor = NSColor(white: 1, alpha: 0.8).cgColor
        counter.alignmentMode = .right; counter.contentsScale = screen.backingScaleFactor
        counter.frame = CGRect(x: root.bounds.width - 140, y: 14, width: 124, height: 18)
        counter.autoresizingMask = [.layerMinXMargin]
        root.layer?.addSublayer(counter)
        window.onKey = { [weak self] e in self?.key(e) }
        window.onClick = { [weak self] forward in forward ? self?.next() : self?.previous() }
    }

    /// slides: for each slide the PNG of every build. `screen`: where the audience display goes; `visible: false`
    /// keeps the pages and navigation without showing a window.
    /// `ownSpace`: take the display with a full-screen Space of its own (see `PlayerWindow.present`).
    func play(slides: [[String]], startSlide: Int, screen: NSScreen? = nil, visible: Bool = true, ownSpace: Bool = false) {
        pages = []
        for (si, builds) in slides.enumerated() {
            for (bi, p) in builds.enumerated() { pages.append(Page(slide: si, build: bi, builds: builds.count, path: p)) }
        }
        guard !pages.isEmpty else { return }
        index = pages.firstIndex(where: { $0.slide >= startSlide }) ?? 0
        shown = visible
        if visible {
            savedOptions = NSApp.presentationOptions
            if !ownSpace { NSApp.presentationOptions = [.hideDock, .hideMenuBar] }
            window.present(on: screen ?? NSScreen.main ?? NSScreen.screens[0], ownSpace: ownSpace)
        }
        show(animated: false)
        if visible { NSCursor.setHiddenUntilMouseMoves(true) }
    }
    private var shown = true
    var slideCount: Int { Set(pages.map { $0.slide }).count }

    private func image(_ path: String) -> CGImage? {
        if let c = cache[path] { return c }
        guard let img = DarkMode.cgImage(path: path) else { return nil }
        if cache.count > 12 { cache.removeAll() }
        cache[path] = img
        return img
    }

    private func show(animated: Bool, slideChange: Bool = false) {
        let page = pages[index]
        if animated {
            let t = CATransition(); t.type = .fade; t.duration = slideChange ? 0.35 : 0.2
            t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            content.add(t, forKey: "fade")
        }
        content.contents = blackedOut ? nil : image(page.path)
        let w = window.contentView?.bounds.width ?? 1
        CATransaction.begin(); CATransaction.setAnimationDuration(0.25)
        progress.frame = CGRect(x: 0, y: 0, width: showProgress ? w * CGFloat(index + 1) / CGFloat(pages.count) : 0, height: 3)
        CATransaction.commit()
        counter.string = showProgress ? "\(page.slide + 1) / \(Set(pages.map { $0.slide }).count)" + (page.builds > 1 ? "  ·  \(page.build + 1)/\(page.builds)" : "") : ""
        counter.opacity = 1
        hideWork?.cancel()
        let w2 = DispatchWorkItem { [weak self] in
            CATransaction.begin(); CATransaction.setAnimationDuration(0.6); self?.counter.opacity = 0; CATransaction.commit()
        }
        hideWork = w2
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: w2)
        // warm the neighbours
        for k in [index + 1, index - 1] where pages.indices.contains(k) { _ = image(pages[k].path) }
        onChange?()
    }

    func go(_ i: Int) {
        guard pages.indices.contains(i), i != index else { return }
        let slideChange = pages[i].slide != pages[index].slide
        index = i
        show(animated: true, slideChange: slideChange)
    }
    func next() { if index == pages.count - 1 { exit() } else { go(index + 1) } }
    func previous() { go(index - 1) }

    private func key(_ e: NSEvent) {
        switch e.keyCode {
        case 124, 125, 49, 36, 76, 121: next()            // → ↓ space return enter pageDown
        case 123, 126, 51, 116: previous()                 // ← ↑ delete pageUp
        case 115: go(0)                                    // home
        case 119: go(pages.count - 1)                      // end
        case 53: exit()                                    // esc
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "q": exit()
            case "b", ".": blackedOut.toggle(); show(animated: true)
            case "p": showProgress.toggle(); show(animated: false)
            case "n": // jump to the next slide, skipping its builds
                if let t = pages.firstIndex(where: { $0.slide > pages[index].slide }) { go(t) }
            default: break
            }
        }
    }

    func exit() {
        if shown { NSApp.presentationOptions = savedOptions }
        window.dismiss()
        onExit?()
    }

    /// Handle a navigation key from another window (the presenter view). Returns false for keys it does not know.
    @discardableResult func handleKey(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 124, 125, 49, 36, 76, 121, 123, 126, 51, 116, 115, 119, 53: key(e); return true
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "q", "b", ".", "p", "n": key(e); return true
            default: return false
            }
        }
    }
    var isBlackedOut: Bool { blackedOut }
}

extension SlidePlayer: PresenterSource {
    var pageCount: Int { pages.count }
    var pageIndex: Int { index }
    var livePlayer: AVPlayer? { nil }
    var playbackState: String? { nil }
    func presenterPage(_ i: Int) -> PresenterPage {
        let p = pages[i]
        let builds = buildNotes.indices.contains(p.slide) ? buildNotes[p.slide] : []
        return PresenterPage(slide: p.slide, build: p.build, builds: p.builds,
                             notes: notes.indices.contains(p.slide) ? notes[p.slide] : "",
                             buildNotes: builds.indices.contains(p.build) ? builds[p.build] : "", still: p.path, clip: nil)
    }
}

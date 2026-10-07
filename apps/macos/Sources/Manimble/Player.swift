import AppKit
import QuartzCore
import ImageIO

/// Borderless full-screen window that plays the deck build by build.
final class PlayerWindow: NSWindow {
    var onKey: ((NSEvent) -> Void)?
    var onClick: ((Bool) -> Void)?          // true = forward
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
    override func mouseDown(with event: NSEvent) { onClick?(true) }
    override func rightMouseDown(with event: NSEvent) { onClick?(false) }
}

final class SlidePlayer: NSObject {
    struct Page { var slide: Int; var build: Int; var builds: Int; var path: String }

    let window: PlayerWindow
    private let content = CALayer()
    private let progress = CALayer()
    private let counter = CATextLayer()
    private var pages: [Page] = []
    private var index = 0
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
        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
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

    /// slides: for each slide the PNG of every build.
    func play(slides: [[String]], startSlide: Int) {
        pages = []
        for (si, builds) in slides.enumerated() {
            for (bi, p) in builds.enumerated() { pages.append(Page(slide: si, build: bi, builds: builds.count, path: p)) }
        }
        guard !pages.isEmpty else { return }
        index = pages.firstIndex(where: { $0.slide >= startSlide }) ?? 0
        savedOptions = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.setFrame(NSScreen.main?.frame ?? window.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        show(animated: false)
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func image(_ path: String) -> CGImage? {
        if let c = cache[path] { return c }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
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
    }

    private func go(_ i: Int) {
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
        NSApp.presentationOptions = savedOptions
        window.orderOut(nil)
        onExit?()
    }
}

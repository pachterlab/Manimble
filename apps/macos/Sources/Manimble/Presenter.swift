import AppKit
import AVFoundation

/// One page of a show as Presenter View sees it: a build of a slide, with its notes and what to picture it by.
struct PresenterPage {
    var slide: Int, build: Int, builds: Int
    var notes: String
    var still: String?                       // PNG of the build (stills slideshow, image slides)
    var clip: String?                        // the build's animation; its last frame previews it
}

/// What Presenter View drives: the stills slideshow (`SlidePlayer`) or the animated show (`AnimatedPlayer`).
protocol PresenterSource: AnyObject {
    var window: PlayerWindow { get }
    var onChange: (() -> Void)? { get set }
    var onExit: (() -> Void)? { get set }
    var pageCount: Int { get }
    var pageIndex: Int { get }
    var slideCount: Int { get }
    var isBlackedOut: Bool { get }
    /// The clip on the audience display, shown live in the presenter's current-slide panel (nil for stills).
    var livePlayer: AVPlayer? { get }
    /// "Playing", "Paused", "Build done" for clips; nil for stills.
    var playbackState: String? { get }
    func presenterPage(_ i: Int) -> PresenterPage
    func next()
    func exit()
    @discardableResult func handleKey(_ e: NSEvent) -> Bool
}

extension AnimatedPlayer: PresenterSource {}

/// Shows an AVPlayer's picture; lets clicks through to the slide image underneath.
final class LiveVideoView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The presenter's window: current slide, next slide, speaker notes, clock, elapsed time and the slide counter.
final class PresenterWindow: NSWindow {
    var onKey: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
}

/// Presenter view: two windows. The audience display is the regular full-screen show (on the second screen when
/// there is one, else on the same screen); the presenter window shows the notes, what comes next and the timer.
/// On a single screen it floats above the show, so both are in view. With the animated show the current slide
/// plays live, mirroring the audience display.
@MainActor
final class PresenterController: NSObject, NSWindowDelegate {
    let source: PresenterSource
    let window: PresenterWindow
    var onExit: (() -> Void)?

    private let current = NSImageView()
    private let live = LiveVideoView()
    private let badge = NSTextField(labelWithString: "")
    private let next = NSImageView()
    private let notes = NSTextView()
    private let nextCaption = NSTextField(labelWithString: "NEXT")
    private let counter = NSTextField(labelWithString: "")
    private let clock = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "")
    private let blank = NSTextField(labelWithString: "SCREEN BLANKED")
    private var started = Date()
    private var timer: Timer?
    private var finished = false
    private var cache: [String: NSImage] = [:]
    private var pendingFrames: Set<String> = []
    private let animated: Bool
    private let presenterScreen: NSScreen

    /// The stills slideshow: one PNG per build.
    convenience init(slides: [[String]], notes: [String], startSlide: Int, presenterScreen: NSScreen, audienceScreen: NSScreen?) {
        let p = SlidePlayer(screen: audienceScreen ?? presenterScreen)
        p.notes = notes
        self.init(source: p, animated: false, presenterScreen: presenterScreen, sharedScreen: audienceScreen == nil)
        p.play(slides: slides, startSlide: startSlide, screen: audienceScreen ?? presenterScreen)
        begin()
    }

    /// The animated show: the Manim Slides clips, played natively.
    convenience init(deck: PresentDeck, startScene: Int, presenterScreen: NSScreen, audienceScreen: NSScreen?) {
        let p = AnimatedPlayer(screen: audienceScreen ?? presenterScreen)
        self.init(source: p, animated: true, presenterScreen: presenterScreen, sharedScreen: audienceScreen == nil)
        p.play(deck, startScene: startScene, screen: audienceScreen ?? presenterScreen)
        begin()
    }

    /// The presenter window is an ordinary window of about two thirds of its display, never the whole display.
    /// `sharedScreen`: the show is full screen on the same display, so the window floats above it.
    private init(source: PresenterSource, animated: Bool, presenterScreen: NSScreen, sharedScreen: Bool) {
        self.source = source
        self.animated = animated
        self.presenterScreen = presenterScreen
        let frame = Self.floatingFrame(on: presenterScreen)
        window = PresenterWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                 backing: .buffered, defer: false)
        super.init()
        window.title = animated ? "Presenter View with Animations" : "Presenter View"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.07, alpha: 1)
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        // Joins whatever Space its display shows, including a full-screen one (the editor or another app in native
        // full screen). Without .fullScreenAuxiliary macOS cannot place the window on such a Space and moves it to
        // the other display, where it lands behind the show.
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        // on a shared display, above the show (PlayerWindow sits at mainMenu + 1)
        if sharedScreen { window.level = .mainMenu + 2 }
        window.delegate = self
        window.contentView = buildContent()
        window.onKey = { [weak self] e in self?.key(e) }
        source.onChange = { [weak self] in self?.refresh() }
        source.onExit = { [weak self] in self?.finish() }
    }

    /// Where the presenter window goes: about two thirds of its display, centred (never below the window's minimum
    /// size), so on a shared display the show stays visible around it.
    private static func floatingFrame(on screen: NSScreen) -> NSRect {
        let s = screen.visibleFrame
        let w = max(820, min(s.width * 0.68, s.width - 48))
        let h = max(520, min(s.height * 0.68, s.height - 48))
        return NSRect(x: s.midX - w / 2, y: s.midY - h / 2, width: w, height: h).integral
    }

    /// The display behind an NSScreen (NSScreen objects are not reliably comparable across calls).
    private static func id(of screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func begin() {
        window.makeKeyAndOrderFront(nil)
        // If the system still moved the window to another display, put it back where the presenter is.
        if let s = window.screen, Self.id(of: s) != Self.id(of: presenterScreen) {
            window.setFrame(Self.floatingFrame(on: presenterScreen), display: true)
            window.makeKeyAndOrderFront(nil)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refresh()
        tick()
    }

    private func buildContent() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        func caption(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.font = Theme.font(11, .semibold); l.textColor = NSColor(white: 1, alpha: 0.45)
            return l
        }
        for iv in [current, next] {
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.backgroundColor = NSColor.black.cgColor
            iv.layer?.cornerRadius = 6; iv.layer?.masksToBounds = true
            iv.translatesAutoresizingMaskIntoConstraints = false
        }
        let click = NSClickGestureRecognizer(target: self, action: #selector(advance))
        current.addGestureRecognizer(click)
        live.translatesAutoresizingMaskIntoConstraints = false
        live.isHidden = true
        badge.font = Theme.font(11, .semibold); badge.textColor = .white
        badge.wantsLayer = true; badge.drawsBackground = true; badge.backgroundColor = NSColor(white: 0, alpha: 0.55)
        badge.layer?.cornerRadius = 4; badge.layer?.masksToBounds = true
        badge.isHidden = true; badge.translatesAutoresizingMaskIntoConstraints = false
        blank.font = Theme.font(20, .bold); blank.textColor = NSColor(white: 1, alpha: 0.6); blank.isHidden = true
        blank.translatesAutoresizingMaskIntoConstraints = false
        notes.isEditable = false; notes.isSelectable = true
        notes.font = Theme.font(20)
        notes.textColor = NSColor(white: 0.95, alpha: 1)
        notes.backgroundColor = NSColor(white: 1, alpha: 0.05)
        notes.textContainerInset = NSSize(width: 12, height: 12)
        notes.isVerticallyResizable = true; notes.isHorizontallyResizable = false
        notes.autoresizingMask = [.width]; notes.textContainer?.widthTracksTextView = true
        let notesScroll = NSScrollView(); notesScroll.documentView = notes; notesScroll.hasVerticalScroller = true
        notesScroll.drawsBackground = true; notesScroll.backgroundColor = notes.backgroundColor
        notesScroll.wantsLayer = true; notesScroll.layer?.cornerRadius = 6; notesScroll.layer?.masksToBounds = true
        notesScroll.translatesAutoresizingMaskIntoConstraints = false
        let nextCap = nextCaption; nextCap.font = Theme.font(11, .semibold); nextCap.textColor = NSColor(white: 1, alpha: 0.45)
        let right = NSStackView(views: [nextCap, next, caption("NOTES"), notesScroll])
        right.orientation = .vertical; right.alignment = .leading; right.spacing = 8
        right.translatesAutoresizingMaskIntoConstraints = false
        // bottom bar
        for l in [counter, clock, elapsed] { l.font = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .medium); l.textColor = .white }
        let hint = NSTextField(labelWithString: animated
            ? "→  next  ·  ←  back  ·  space  pause  ·  V  reverse  ·  1–9  chapter  ·  B  blank  ·  N  next slide  ·  R  reset timer  ·  esc  end"
            : "→ / space  next  ·  ←  back  ·  B  blank  ·  N  next slide  ·  click the timer to reset  ·  esc  end")
        hint.font = Theme.font(11); hint.textColor = NSColor(white: 1, alpha: 0.4)
        let elapsedBox = NSStackView(views: [caption("ELAPSED"), elapsed]); elapsedBox.orientation = .vertical; elapsedBox.alignment = .leading; elapsedBox.spacing = 1
        let clockBox = NSStackView(views: [caption("TIME"), clock]); clockBox.orientation = .vertical; clockBox.alignment = .leading; clockBox.spacing = 1
        let counterBox = NSStackView(views: [caption("SLIDE"), counter]); counterBox.orientation = .vertical; counterBox.alignment = .leading; counterBox.spacing = 1
        elapsedBox.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(resetTimer)))
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [counterBox, elapsedBox, clockBox, spacer, hint])
        bar.orientation = .horizontal; bar.alignment = .centerY; bar.spacing = 36
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(current); root.addSubview(live); root.addSubview(badge); root.addSubview(blank)
        root.addSubview(right); root.addSubview(bar)
        NSLayoutConstraint.activate([
            current.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            current.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            current.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.6),
            current.heightAnchor.constraint(equalTo: current.widthAnchor, multiplier: 9.0 / 16.0),
            live.leadingAnchor.constraint(equalTo: current.leadingAnchor), live.trailingAnchor.constraint(equalTo: current.trailingAnchor),
            live.topAnchor.constraint(equalTo: current.topAnchor), live.bottomAnchor.constraint(equalTo: current.bottomAnchor),
            badge.leadingAnchor.constraint(equalTo: current.leadingAnchor, constant: 10),
            badge.topAnchor.constraint(equalTo: current.topAnchor, constant: 10),
            blank.centerXAnchor.constraint(equalTo: current.centerXAnchor), blank.centerYAnchor.constraint(equalTo: current.centerYAnchor),
            right.leadingAnchor.constraint(equalTo: current.trailingAnchor, constant: 24),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            right.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            right.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -16),
            next.widthAnchor.constraint(equalTo: right.widthAnchor),
            next.heightAnchor.constraint(equalTo: next.widthAnchor, multiplier: 9.0 / 16.0),
            notesScroll.widthAnchor.constraint(equalTo: right.widthAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            bar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            bar.heightAnchor.constraint(equalToConstant: 48),
            bar.topAnchor.constraint(greaterThanOrEqualTo: current.bottomAnchor, constant: 16),
        ])
        return root
    }

    private func image(_ path: String) -> NSImage? {
        if let i = cache[path] { return i }
        guard let i = DarkMode.image(path: path) else { return nil }
        remember(i, for: path)
        return i
    }

    private func remember(_ i: NSImage, for key: String) {
        if cache.count > 16 { cache.removeAll() }
        cache[key] = i
    }

    /// How a page looks once its build has played: its PNG, or the last frame of its clip (made in the background,
    /// shown by the refresh that follows).
    private func picture(_ p: PresenterPage) -> NSImage? {
        if let s = p.still { return image(s) }
        guard let clip = p.clip else { return nil }
        if let i = cache[clip] { return i }
        if pendingFrames.insert(clip).inserted {
            Task { @MainActor in
                let asset = AVURLAsset(url: URL(fileURLWithPath: clip))
                let g = AVAssetImageGenerator(asset: asset)
                g.appliesPreferredTrackTransform = true
                g.maximumSize = CGSize(width: 1280, height: 720)
                g.requestedTimeToleranceAfter = .zero
                let dur = (try? await asset.load(.duration)) ?? .zero
                let t = CMTimeMaximum(.zero, CMTimeSubtract(dur, CMTime(value: 1, timescale: 30)))
                pendingFrames.remove(clip)
                guard let cg = try? await g.image(at: t).image else { return }
                let img = DarkMode.isOn ? (DarkMode.apply(cg) ?? cg) : cg
                remember(NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)), for: clip)
                refresh()
            }
        }
        return nil
    }

    func refresh() {
        guard (0..<source.pageCount).contains(source.pageIndex) else { return }
        let page = source.presenterPage(source.pageIndex)
        let player = source.livePlayer
        if live.playerLayer.player !== player { live.playerLayer.player = player }
        live.isHidden = player == nil
        current.image = player == nil ? picture(page) : nil
        current.alphaValue = source.isBlackedOut ? 0.25 : 1
        live.alphaValue = source.isBlackedOut ? 0.25 : 1
        blank.isHidden = !source.isBlackedOut
        if let st = source.playbackState {
            badge.stringValue = "  " + (st == "Playing" ? "▶︎  " : st == "Paused" ? "❙❙  " : "■  ") + st.uppercased() + "  "
            badge.isHidden = false
        } else { badge.isHidden = true }
        if source.pageIndex + 1 < source.pageCount {
            let n = source.presenterPage(source.pageIndex + 1)
            next.image = picture(n)
            nextCaption.stringValue = n.slide == page.slide ? "NEXT  ·  build \(n.build + 1) of \(n.builds)" : "NEXT  ·  slide \(n.slide + 1)"
        } else {
            next.image = nil
            nextCaption.stringValue = "NEXT  ·  end of the show"
        }
        counter.stringValue = "\(page.slide + 1) / \(source.slideCount)" + (page.builds > 1 ? "   build \(page.build + 1)/\(page.builds)" : "")
        if page.notes.isEmpty {
            if notes.string != Self.noNotes {
                notes.string = Self.noNotes
                notes.textColor = NSColor(white: 1, alpha: 0.35)
            }
        } else if notes.string != page.notes {
            notes.string = page.notes
            notes.textColor = NSColor(white: 0.95, alpha: 1)
        }
    }
    /// For the headless test: whether the live panel has a frame of the current clip to draw.
    var liveFrameReady: Bool { !live.isHidden && live.playerLayer.isReadyForDisplay }

    private static let noNotes = "No notes for this slide. Type them in the Speaker Notes box under the slide in the editor."

    private func tick() {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        clock.stringValue = f.string(from: Date())
        let s = Int(Date().timeIntervalSince(started))
        elapsed.stringValue = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    @objc private func resetTimer() { started = Date(); tick() }
    @objc private func advance() { source.next() }

    private func key(_ e: NSEvent) {
        if e.keyCode == 15, e.charactersIgnoringModifiers?.lowercased() == "r" { resetTimer(); return }
        if !source.handleKey(e) { NSSound.beep() }
    }

    func windowWillClose(_ notification: Notification) {
        if !finished { source.exit() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate(); timer = nil
        window.delegate = nil
        live.playerLayer.player = nil
        window.orderOut(nil)
        onExit?()
    }
}

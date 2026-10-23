import AppKit
import AVFoundation

/// One page of a show as Presenter View sees it: a build of a slide, with its notes (the slide's, then the build's
/// own) and what to picture it by.
struct PresenterPage {
    var slide: Int, build: Int, builds: Int
    var notes: String
    var buildNotes: String
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
    func previous()
    /// Jump to page `i` (a thumbnail click).
    func go(_ i: Int)
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

/// The current slide in Presenter View: a left click advances, a right click goes back, like the show itself,
/// and the first click counts even when the window is not key (the presenter just clicked the show).
final class SlideView: NSImageView {
    var onClick: ((Bool) -> Void)?   // true = forward
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?(true) }
    override func rightMouseDown(with event: NSEvent) { onClick?(false) }
}

/// The presenter's window: current slide, next slide, speaker notes, clock, elapsed time and the slide counter.
final class PresenterWindow: NSWindow {
    var onKey: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
}

/// One slide in the strip along the bottom of Presenter View: its picture and number; the current one is outlined.
final class SlideThumb: NSView {
    let image = NSImageView()
    let number = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?
    var selected = false {
        didSet {
            image.layer?.borderColor = (selected ? Theme.accent : NSColor(white: 1, alpha: 0.12)).cgColor
            image.layer?.borderWidth = selected ? 3 : 1
            number.textColor = selected ? Theme.accent : NSColor(white: 1, alpha: 0.6)
        }
    }
    static let size = NSSize(width: 160, height: 90)

    init(number n: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.backgroundColor = NSColor.black.cgColor
        image.layer?.cornerRadius = 4; image.layer?.masksToBounds = true
        image.translatesAutoresizingMaskIntoConstraints = false
        image.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        image.setContentCompressionResistancePriority(.init(1), for: .vertical)
        number.stringValue = "\(n)"
        number.font = Theme.font(11, .medium)
        number.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image); addSubview(number)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: leadingAnchor), image.trailingAnchor.constraint(equalTo: trailingAnchor),
            image.topAnchor.constraint(equalTo: topAnchor),
            image.widthAnchor.constraint(equalToConstant: Self.size.width),
            image.heightAnchor.constraint(equalToConstant: Self.size.height),
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            number.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 3),
            number.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        selected = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Presenter view: two windows. The audience display is the regular full-screen show (on the second screen when
/// there is one, else on the same screen); the presenter window is laid out like PowerPoint's: End Show, Swap
/// Displays and Use Slide Show at the top, the timer and clock under them, the current slide large with the speaker
/// notes beside it, the slide counter with arrows, and a strip of every slide along the bottom. On a single screen
/// it floats above the show, so both are in view. With the animated show the current slide plays live, mirroring
/// the audience display.
@MainActor
final class PresenterController: NSObject, NSWindowDelegate {
    let source: PresenterSource
    let window: PresenterWindow
    var onExit: (() -> Void)?
    /// "Use Slide Show": the presenter window is gone but the show goes on; the caller takes the source back.
    var onDetach: ((PresenterSource) -> Void)?

    private let current = SlideView()
    private let live = LiveVideoView()
    private let badge = NSTextField(labelWithString: "")
    private let notes = NSTextView()
    private let buildNotes = NSTextView()
    private let counter = NSTextField(labelWithString: "")
    private let clock = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "")
    private let blank = NSTextField(labelWithString: "SCREEN BLANKED")
    private let pauseButton = NSButton()
    private let progress = NSView()
    private var progressWidth: NSLayoutConstraint?
    private let strip = NSScrollView()
    private var thumbs: [SlideThumb] = []
    /// For each slide of the show: its first page (where a thumbnail click goes) and last page (its picture).
    private var slideRange: [(first: Int, last: Int)] = []
    private var started = Date()
    private var accumulated: TimeInterval = 0
    private var paused = false
    private var timer: Timer?
    private var finished = false
    private var cache: [String: NSImage] = [:]
    private var pendingFrames: Set<String> = []
    private let animated: Bool
    private var presenterScreen: NSScreen
    private let sharedScreen: Bool
    /// The window is on its way into native full screen (see `fillScreen`).
    private var filling = false
    /// The user is closing the window (its red button).
    private var closing = false

    /// The stills slideshow: one PNG per build.
    convenience init(slides: [[String]], notes: [String], buildNotes: [[String]], startSlide: Int, presenterScreen: NSScreen, audienceScreen: NSScreen?) {
        let p = SlidePlayer(screen: audienceScreen ?? presenterScreen)
        p.notes = notes; p.buildNotes = buildNotes
        self.init(source: p, animated: false, presenterScreen: presenterScreen, sharedScreen: audienceScreen == nil)
        p.play(slides: slides, startSlide: startSlide, screen: audienceScreen ?? presenterScreen, ownSpace: audienceScreen != nil)
        begin()
    }

    /// The animated show: the Manim Slides clips, played natively.
    convenience init(deck: PresentDeck, startScene: Int, presenterScreen: NSScreen, audienceScreen: NSScreen?) {
        let p = AnimatedPlayer(screen: audienceScreen ?? presenterScreen)
        self.init(source: p, animated: true, presenterScreen: presenterScreen, sharedScreen: audienceScreen == nil)
        p.play(deck, startScene: startScene, screen: audienceScreen ?? presenterScreen, ownSpace: audienceScreen != nil)
        begin()
    }

    /// `sharedScreen`: the show is full screen on the same display, so the window floats above it as an ordinary
    /// window of about two thirds of the display. With a display of its own the window takes it whole, in native
    /// full screen like the show on the other display (see `fillScreen`).
    private init(source: PresenterSource, animated: Bool, presenterScreen: NSScreen, sharedScreen: Bool) {
        self.source = source
        self.animated = animated
        self.presenterScreen = presenterScreen
        self.sharedScreen = sharedScreen
        let frame = Self.floatingFrame(on: presenterScreen)
        window = PresenterWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                 backing: .buffered, defer: false)
        super.init()
        window.title = animated ? "Presenter View with Animations" : "Presenter View"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.07, alpha: 1)
        window.minSize = NSSize(width: 820, height: 560)
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
        let h = max(560, min(s.height * 0.68, s.height - 48))
        return NSRect(x: s.midX - w / 2, y: s.midY - h / 2, width: w, height: h).integral
    }

    /// Takes the presenter display whole: native full screen with a Space of its own, like the show on the other
    /// display. Only when the window has a display to itself; on a shared display it floats above the show.
    private func fillScreen() {
        guard !sharedScreen, !finished, !window.styleMask.contains(.fullScreen), !filling else { return }
        filling = true
        window.collectionBehavior = [.fullScreenPrimary]
        window.setFrame(Self.floatingFrame(on: presenterScreen), display: true)
        window.makeKeyAndOrderFront(nil)
        window.once(NSWindow.didEnterFullScreenNotification) { [weak self] in self?.filling = false }
        window.toggleFullScreen(nil)
    }

    /// Leaves native full screen (when in it) and then runs `then`; otherwise runs it at once. A window the user
    /// is closing is left alone: AppKit takes it out of full screen itself.
    private func leaveFullScreen(then: @escaping () -> Void) {
        guard window.styleMask.contains(.fullScreen), !closing else { then(); return }
        final class Once { var done = false }
        let once = Once()
        let go = { if !once.done { once.done = true; then() } }
        window.once(NSWindow.didExitFullScreenNotification, go)
        // should the transition never report back (the show leaving its display at the same moment), carry on
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { Task { @MainActor in go() } }
        window.toggleFullScreen(nil)
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
        if !sharedScreen {
            // once the show has taken its display: two windows entering full screen at once on two displays leaves
            // one of them where it was (and a fallback, should the show never get there)
            source.window.whenSettled { [weak self] in self?.fillScreen() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Task { @MainActor [weak self] in self?.fillScreen() } }
        }
        buildStrip()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        refresh()
        tick()
    }

    // MARK: Layout

    private func toolButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        b.imagePosition = .imageAbove
        b.isBordered = false
        b.contentTintColor = NSColor(white: 1, alpha: 0.85)
        b.font = Theme.font(12)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    private func iconButton(_ symbol: String, _ label: String, size: CGFloat = 16, action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium)) ?? NSImage(), target: self, action: action)
        b.isBordered = false
        b.contentTintColor = NSColor(white: 1, alpha: 0.85)
        b.toolTip = label
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    private func buildContent() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        func caption(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.font = Theme.font(11, .semibold); l.textColor = NSColor(white: 1, alpha: 0.45)
            return l
        }
        // top: End Show · Swap Displays · Use Slide Show
        let endShow = toolButton("End Show", symbol: "xmark.circle.fill", action: #selector(endShow))
        let swap = toolButton("Swap Displays", symbol: "arrow.left.arrow.right", action: #selector(swapDisplays))
        swap.isEnabled = !sharedScreen
        swap.toolTip = sharedScreen ? "Needs a second display" : "Show the slides on this display and the notes on the other"
        let useShow = toolButton("Use Slide Show", symbol: "play.rectangle", action: #selector(useSlideShow))
        useShow.toolTip = "Close Presenter View and keep the show running"
        let toolbar = NSStackView(views: [endShow, swap, useShow])
        toolbar.orientation = .horizontal; toolbar.alignment = .top; toolbar.spacing = 22
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        // timer row: elapsed, pause, reset … clock
        elapsed.font = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .regular); elapsed.textColor = .white
        clock.font = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .regular); clock.textColor = NSColor(white: 1, alpha: 0.85)
        pauseButton.image = Self.pauseImage(paused: false)
        pauseButton.target = self; pauseButton.action = #selector(togglePause)
        pauseButton.isBordered = false; pauseButton.contentTintColor = NSColor(white: 1, alpha: 0.85)
        pauseButton.toolTip = "Pause the timer"
        let reset = iconButton("arrow.counterclockwise", "Reset the timer", action: #selector(resetTimer))
        let timerRow = NSStackView(views: [elapsed, pauseButton, reset])
        timerRow.orientation = .horizontal; timerRow.alignment = .centerY; timerRow.spacing = 14
        timerRow.translatesAutoresizingMaskIntoConstraints = false
        clock.translatesAutoresizingMaskIntoConstraints = false
        // the current slide, live clip, badge and blanking notice
        current.imageScaling = .scaleProportionallyUpOrDown
        current.wantsLayer = true
        current.layer?.backgroundColor = NSColor.black.cgColor
        current.translatesAutoresizingMaskIntoConstraints = false
        // The slide PNGs are far bigger than the panel. Without this, Auto Layout refuses to shrink the image view
        // below the image size and grows the window to thousands of points, pushing it onto the other display.
        current.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        current.setContentCompressionResistancePriority(.init(1), for: .vertical)
        current.setContentHuggingPriority(.init(1), for: .horizontal)
        current.setContentHuggingPriority(.init(1), for: .vertical)
        current.onClick = { [weak self] forward in forward ? self?.advance() : self?.goBack() }
        live.translatesAutoresizingMaskIntoConstraints = false
        live.isHidden = true
        badge.font = Theme.font(11, .semibold); badge.textColor = .white
        badge.wantsLayer = true; badge.drawsBackground = true; badge.backgroundColor = NSColor(white: 0, alpha: 0.55)
        badge.layer?.cornerRadius = 4; badge.layer?.masksToBounds = true
        badge.isHidden = true; badge.translatesAutoresizingMaskIntoConstraints = false
        blank.font = Theme.font(20, .bold); blank.textColor = NSColor(white: 1, alpha: 0.6); blank.isHidden = true
        blank.translatesAutoresizingMaskIntoConstraints = false
        // speaker notes beside the slide: the slide's (every build) on top, this build's own beneath
        func notesBox(_ tv: NSTextView) -> NSScrollView {
            tv.isEditable = false; tv.isSelectable = true
            tv.font = Theme.font(20)
            tv.textColor = NSColor(white: 0.95, alpha: 1)
            tv.backgroundColor = NSColor(white: 1, alpha: 0.05)
            tv.textContainerInset = NSSize(width: 12, height: 12)
            tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false
            tv.autoresizingMask = [.width]; tv.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView(); scroll.documentView = tv; scroll.hasVerticalScroller = true
            scroll.drawsBackground = true; scroll.backgroundColor = tv.backgroundColor
            scroll.wantsLayer = true; scroll.layer?.cornerRadius = 6; scroll.layer?.masksToBounds = true
            scroll.translatesAutoresizingMaskIntoConstraints = false
            return scroll
        }
        let notesScroll = notesBox(notes), buildScroll = notesBox(buildNotes)
        let right = NSStackView(views: [caption("SLIDE NOTES"), notesScroll, caption("BUILD NOTES"), buildScroll])
        right.orientation = .vertical; right.alignment = .leading; right.spacing = 6
        right.setCustomSpacing(14, after: notesScroll)
        right.translatesAutoresizingMaskIntoConstraints = false
        // counter row: ‹ Slide N of M › with a thin progress line, keys hint at the right
        counter.font = Theme.font(16); counter.textColor = NSColor(white: 1, alpha: 0.85)
        counter.alignment = .center
        let prev = iconButton("chevron.left", "Previous", size: 20, action: #selector(goBack))
        let next = iconButton("chevron.right", "Next", size: 20, action: #selector(advance))
        let counterRow = NSStackView(views: [prev, counter, next])
        counterRow.orientation = .horizontal; counterRow.alignment = .centerY; counterRow.spacing = 18
        counterRow.translatesAutoresizingMaskIntoConstraints = false
        let track = NSView(); track.wantsLayer = true; track.layer?.backgroundColor = NSColor(white: 1, alpha: 0.15).cgColor
        track.layer?.cornerRadius = 1.5
        track.translatesAutoresizingMaskIntoConstraints = false
        progress.wantsLayer = true; progress.layer?.backgroundColor = Theme.accent.cgColor; progress.layer?.cornerRadius = 1.5
        progress.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(progress)
        let hint = NSTextField(labelWithString: animated
            ? "→ next · ← back · space pause · V reverse · 1–9 chapter · B blank · N next slide · esc end"
            : "→ / space next · ← back · B blank · N next slide · esc end")
        hint.font = Theme.font(11); hint.textColor = NSColor(white: 1, alpha: 0.4)
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.init(1), for: .horizontal)   // never widens the window
        hint.translatesAutoresizingMaskIntoConstraints = false
        // strip of slides along the bottom
        strip.hasHorizontalScroller = true; strip.hasVerticalScroller = false
        strip.drawsBackground = true; strip.backgroundColor = NSColor(white: 0.1, alpha: 1)
        strip.horizontalScrollElasticity = .allowed
        strip.translatesAutoresizingMaskIntoConstraints = false

        for v in [toolbar, timerRow, clock, current, live, badge, blank, right, counterRow, track, hint, strip] { root.addSubview(v) }
        let pw = progress.widthAnchor.constraint(equalToConstant: 0)
        progressWidth = pw
        let slideWidth = current.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.62)
        slideWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            timerRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            timerRow.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            clock.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            clock.centerYAnchor.constraint(equalTo: timerRow.centerYAnchor),
            current.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            current.topAnchor.constraint(equalTo: timerRow.bottomAnchor, constant: 10),
            slideWidth,
            current.heightAnchor.constraint(equalTo: current.widthAnchor, multiplier: 9.0 / 16.0),
            current.bottomAnchor.constraint(lessThanOrEqualTo: counterRow.topAnchor, constant: -8),
            live.leadingAnchor.constraint(equalTo: current.leadingAnchor), live.trailingAnchor.constraint(equalTo: current.trailingAnchor),
            live.topAnchor.constraint(equalTo: current.topAnchor), live.bottomAnchor.constraint(equalTo: current.bottomAnchor),
            badge.leadingAnchor.constraint(equalTo: current.leadingAnchor, constant: 10),
            badge.topAnchor.constraint(equalTo: current.topAnchor, constant: 10),
            blank.centerXAnchor.constraint(equalTo: current.centerXAnchor), blank.centerYAnchor.constraint(equalTo: current.centerYAnchor),
            right.leadingAnchor.constraint(equalTo: current.trailingAnchor, constant: 20),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            right.topAnchor.constraint(equalTo: current.topAnchor),
            right.bottomAnchor.constraint(equalTo: current.bottomAnchor),
            notesScroll.widthAnchor.constraint(equalTo: right.widthAnchor),
            buildScroll.widthAnchor.constraint(equalTo: right.widthAnchor),
            buildScroll.heightAnchor.constraint(equalTo: notesScroll.heightAnchor),
            counterRow.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            counterRow.bottomAnchor.constraint(equalTo: track.topAnchor, constant: -6),
            track.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            track.widthAnchor.constraint(equalToConstant: 220),
            track.heightAnchor.constraint(equalToConstant: 3),
            track.bottomAnchor.constraint(equalTo: strip.topAnchor, constant: -12),
            progress.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            progress.topAnchor.constraint(equalTo: track.topAnchor), progress.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            pw,
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            hint.centerYAnchor.constraint(equalTo: counterRow.centerYAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: counterRow.trailingAnchor, constant: 16),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            strip.heightAnchor.constraint(equalToConstant: SlideThumb.size.height + 44),
        ])
        return root
    }

    /// One thumbnail per slide (not per build): the picture of its last build, a click goes to its first.
    private func buildStrip() {
        slideRange = []
        for i in 0..<source.pageCount {
            let p = source.presenterPage(i)
            if let k = slideRange.indices.last, source.presenterPage(slideRange[k].first).slide == p.slide {
                slideRange[k].last = i
            } else {
                slideRange.append((first: i, last: i))
            }
        }
        thumbs = slideRange.enumerated().map { k, r in
            let t = SlideThumb(number: k + 1)
            t.onClick = { [weak self] in self?.source.go(r.first) }
            return t
        }
        let row = NSStackView(views: thumbs)
        row.orientation = .horizontal; row.alignment = .top; row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 10, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        let doc = NSView()
        doc.addSubview(row)
        doc.translatesAutoresizingMaskIntoConstraints = false
        strip.documentView = doc
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: doc.leadingAnchor), row.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            row.topAnchor.constraint(equalTo: doc.topAnchor), row.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.heightAnchor.constraint(equalTo: strip.heightAnchor),
        ])
        loadThumbnails()
    }

    /// Small pictures for the strip, decoded in the background at thumbnail size (the full PNGs would take hundreds
    /// of megabytes for a long deck).
    private func loadThumbnails() {
        for (k, r) in slideRange.enumerated() {
            let page = source.presenterPage(r.last)
            let dark = DarkMode.isOn
            Task { @MainActor [weak self] in
                guard let img = await Self.thumbnailImage(page, dark: dark) else { return }
                self?.thumbs[safe: k]?.image.image = img
            }
        }
    }

    /// Decoded off the main thread (a nonisolated async function runs on the cooperative pool).
    nonisolated private static func thumbnailImage(_ page: PresenterPage, dark: Bool) async -> NSImage? {
        var cg: CGImage?
        if let s = page.still { cg = thumbnail(path: s) }
        else if let c = page.clip { cg = await lastFrame(of: c, maxSize: CGSize(width: 480, height: 270)) }
        guard var img = cg else { return nil }
        if dark, let d = DarkMode.apply(img) { img = d }
        return NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
    }

    nonisolated private static func thumbnail(path: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 480,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    nonisolated private static func lastFrame(of clip: String, maxSize: CGSize) async -> CGImage? {
        let asset = AVURLAsset(url: URL(fileURLWithPath: clip))
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.maximumSize = maxSize
        g.requestedTimeToleranceAfter = .zero
        let dur = (try? await asset.load(.duration)) ?? .zero
        let t = CMTimeMaximum(.zero, CMTimeSubtract(dur, CMTime(value: 1, timescale: 30)))
        return try? await g.image(at: t).image
    }

    // MARK: Pictures

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
                let cg = await Self.lastFrame(of: clip, maxSize: CGSize(width: 1280, height: 720))
                pendingFrames.remove(clip)
                guard let cg else { return }
                let img = DarkMode.isOn ? (DarkMode.apply(cg) ?? cg) : cg
                remember(NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)), for: clip)
                refresh()
            }
        }
        return nil
    }

    // MARK: State

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
        counter.stringValue = "Slide \(page.slide + 1) of \(source.slideCount)" + (page.builds > 1 ? "  ·  build \(page.build + 1)/\(page.builds)" : "")
        progressWidth?.constant = 220 * CGFloat(source.pageIndex + 1) / CGFloat(max(1, source.pageCount))
        Self.show(page.notes, in: notes, empty: Self.noNotes)
        Self.show(page.buildNotes, in: buildNotes, empty: Self.noBuildNotes)
        // the strip: outline the current slide and keep it in view
        if let k = slideRange.firstIndex(where: { $0.first <= source.pageIndex && source.pageIndex <= $0.last }) {
            for (i, t) in thumbs.enumerated() where t.selected != (i == k) { t.selected = i == k }
            if let t = thumbs[safe: k], t.frame.width > 0 {
                let visible = strip.contentView.bounds
                let f = t.frame.insetBy(dx: -16, dy: 0)
                if !visible.contains(f) {
                    let x = max(0, min(f.minX, (strip.documentView?.frame.width ?? 0) - visible.width))
                    strip.contentView.animator().setBoundsOrigin(NSPoint(x: f.minX < visible.minX ? f.minX : x, y: 0))
                }
            }
        }
    }
    /// For the headless test: whether the live panel has a frame of the current clip to draw.
    var liveFrameReady: Bool { !live.isHidden && live.playerLayer.isReadyForDisplay }

    private static let noNotes = "No notes for this slide. Type them on the Slide Notes tab under the slide in the editor."
    private static let noBuildNotes = "No notes for this build. Type them on the Build Notes tab under the slide in the editor."

    /// Notes in a panel, or a dimmed hint when there are none.
    private static func show(_ text: String, in tv: NSTextView, empty: String) {
        let shown = text.isEmpty ? empty : text
        guard tv.string != shown else { return }
        tv.string = shown
        tv.textColor = text.isEmpty ? NSColor(white: 1, alpha: 0.35) : NSColor(white: 0.95, alpha: 1)
    }

    private static func pauseImage(paused: Bool) -> NSImage? {
        NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: paused ? "Resume" : "Pause")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
    }

    private func tick() {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        clock.stringValue = f.string(from: Date())
        let s = Int(accumulated + (paused ? 0 : Date().timeIntervalSince(started)))
        elapsed.stringValue = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: Actions

    @objc private func resetTimer() { accumulated = 0; started = Date(); tick() }
    @objc private func togglePause() {
        if paused { started = Date() } else { accumulated += Date().timeIntervalSince(started) }
        paused.toggle()
        pauseButton.image = Self.pauseImage(paused: paused)
        pauseButton.toolTip = paused ? "Resume the timer" : "Pause the timer"
        tick()
    }
    @objc private func advance() { source.next() }
    @objc private func goBack() { source.previous() }
    @objc private func endShow() { source.exit() }

    /// Swap which display shows the slides and which the notes.
    @objc private func swapDisplays() {
        guard let showScreen = source.window.screen, Self.id(of: showScreen) != Self.id(of: presenterScreen) else { NSSound.beep(); return }
        let notesScreen = presenterScreen
        presenterScreen = showScreen
        // the notes window leaves its full-screen Space first, then follows once the show is up on its new display
        // (moving both at once mid-transition leaves them where they were)
        leaveFullScreen { [weak self] in
            guard let self, !self.finished else { return }
            self.source.window.move(to: notesScreen) { [weak self] in
                guard let self, !self.finished else { return }
                self.window.setFrame(Self.floatingFrame(on: showScreen), display: true)
                self.window.makeKeyAndOrderFront(nil)
                self.fillScreen()
            }
        }
    }

    /// Close the presenter window and carry on with the plain show.
    @objc private func useSlideShow() {
        guard !finished else { return }
        finished = true
        timer?.invalidate(); timer = nil
        window.delegate = nil
        live.playerLayer.player = nil
        source.onChange = nil
        hideWindow()
        source.window.makeKeyAndOrderFront(nil)
        onDetach?(source)
    }

    /// Hides the presenter window, leaving its full-screen Space first when it has one (ordering out a
    /// full-screen window leaves an empty Space behind).
    private func hideWindow() {
        leaveFullScreen { [weak self] in self?.window.orderOut(nil) }
    }

    private func key(_ e: NSEvent) {
        if e.keyCode == 15, e.charactersIgnoringModifiers?.lowercased() == "r" { resetTimer(); return }
        if !source.handleKey(e) { NSSound.beep() }
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        if !finished { source.exit() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate(); timer = nil
        window.delegate = nil
        live.playerLayer.player = nil
        hideWindow()
        onExit?()
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

import AppKit
import AVFoundation

/// One page of a show as Presenter View sees it: a build of a slide, with its notes (the slide's, then the build's
/// own) and what to picture it by.
struct PresenterPage {
    var slide: Int, build: Int, builds: Int
    var scene: String?                       // where notes typed in Presenter View are saved
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
    /// Changes whenever the pages are replaced (stills arriving for slides that were still rendering).
    var reloadToken: Int { get }
    func next()
    func previous()
    /// Jump to page `i` (a thumbnail click).
    func go(_ i: Int)
    /// The hyperlink on the page on screen under a point given as fractions of the slide (y from the top).
    func link(at p: CGPoint) -> URL?
    func exit()
    @discardableResult func handleKey(_ e: NSEvent) -> Bool
    /// Notes typed in Presenter View, once saved: the slide's (`build` false) or page `i`'s own.
    func setNotes(_ text: String, forPage i: Int, build: Bool)
}

extension PresenterSource {
    var reloadToken: Int { 0 }
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

/// The current slide in Presenter View: a left click advances (or opens the hyperlink under it), a right click goes
/// back, like the show itself, and the first click counts even when the window is not key (the presenter just
/// clicked the show).
final class SlideView: NSImageView {
    var onClick: ((Bool) -> Void)?   // true = forward
    var onLink: ((NSEvent) -> Bool)? // opened a link: the click does not advance
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { if onLink?(event) != true { onClick?(true) } }
    override func rightMouseDown(with event: NSEvent) { onClick?(false) }
}

/// A notes panel of Presenter View: read-only until clicked, then it takes typing (see `PresenterWindow`); losing
/// focus saves it.
final class NotesTextView: NSTextView {
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?
    /// The panel shows the dimmed "no notes" hint rather than notes.
    var showsHint = false
    /// Pictures pasted or dropped in while typing (see `PresenterController.noteImageBase`); true when it took them.
    var onImages: ((NSPasteboard) -> Bool)?
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        onImages == nil ? super.readablePasteboardTypes : [.fileURL, .png, .tiff] + super.readablePasteboardTypes
    }
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if let f = onImages, f(pboard) { return true }
        return super.readSelection(from: pboard, type: type)
    }
    /// The notes as text, pictures as their Markdown (see `NoteImages`).
    var notesText: String { NoteImages.markup(attributedString()) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Only a click starts typing: AppKit must not hand the keys to a panel on its own (as the window's initial
    /// first responder), or the arrow keys would stop driving the show.
    override func becomeFirstResponder() -> Bool {
        guard NSApp.currentEvent?.type == .leftMouseDown, super.becomeFirstResponder() else { return false }
        onFocus?()
        return true
    }
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        onBlur?()
        return true
    }
}

/// The presenter's window: current slide, next slide, speaker notes, clock, elapsed time and the slide counter.
final class PresenterWindow: NSWindow {
    var onKey: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
    /// Every plain key press drives the show, whatever view is first responder (the sidebar's scroll view would
    /// otherwise keep the arrow keys), except while a notes panel or a feedback note is being typed in: then keys
    /// type, and esc or ⌘↵ saves the text and gives the keys back to the show. A click anywhere outside a feedback
    /// note being typed ends that too (nothing else in the window would take the focus from it).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, firstResponder is NotesTextView || firstResponder is FeedbackTextView {
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            if event.keyCode == 53 || ((event.keyCode == 36 || event.keyCode == 76) && mods == .command) {
                makeFirstResponder(nil)
                return
            }
        } else if event.type == .leftMouseDown || event.type == .rightMouseDown, let fr = firstResponder as? FeedbackTextView,
                  let hit = contentView?.hitTest(event.locationInWindow), !hit.isDescendant(of: fr) {
            makeFirstResponder(nil)
        } else if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let k = onKey {
            k(event)
            return
        }
        super.sendEvent(event)
    }
}

/// A picture that never asks for its image's size: the sidebar panels are sized by their width, not by the PNG.
private func thumbImageView() -> NSImageView {
    let iv = NSImageView()
    iv.imageScaling = .scaleProportionallyUpOrDown
    iv.translatesAutoresizingMaskIntoConstraints = false
    iv.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    iv.setContentCompressionResistancePriority(.init(1), for: .vertical)
    iv.setContentHuggingPriority(.init(1), for: .horizontal)
    iv.setContentHuggingPriority(.init(1), for: .vertical)
    return iv
}

/// One build of a slide in Presenter View's sidebar, nested under its slide like the editor's navigator: a smaller
/// 16:9 panel with its number; the build on the audience display is outlined.
final class BuildThumb: NSView {
    let image = thumbImageView()
    var onClick: (() -> Void)?
    var selected = false {
        didSet {
            layer?.borderWidth = selected ? 2 : 1
            layer?.borderColor = (selected ? Theme.accent : NSColor(white: 1, alpha: 0.18)).cgColor
            image.alphaValue = selected ? 1 : 0.72
        }
    }

    init(number n: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5; layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(image)
        let l = NSTextField(labelWithString: String(n)); l.font = Theme.font(9, .bold); l.textColor = .white; l.alignment = .center
        l.wantsLayer = true; l.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor; l.layer?.cornerRadius = 3
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalTo: widthAnchor, multiplier: 9.0 / 16.0),
            image.leadingAnchor.constraint(equalTo: leadingAnchor), image.trailingAnchor.constraint(equalTo: trailingAnchor),
            image.topAnchor.constraint(equalTo: topAnchor), image.bottomAnchor.constraint(equalTo: bottomAnchor),
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), l.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            l.widthAnchor.constraint(equalToConstant: 14), l.heightAnchor.constraint(equalToConstant: 12),
        ])
        toolTip = "Build \(n)"
        selected = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Clicks land here, not on the image view inside (an NSControl, which would swallow them).
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// One slide in the sidebar of Presenter View, laid out like the editor's navigator: its number in a column at
/// the left, its picture (16:9, as wide as the column allows) and, when it has builds, every build as an indented
/// panel beneath, always expanded. The current slide is outlined.
final class SlideThumb: NSView {
    let image = thumbImageView()
    let number = NSTextField(labelWithString: "")
    let builds: [BuildThumb]
    /// A red dot on the picture: the slide has feedback notes.
    private let flag = NSView()
    var hasFeedback = false { didSet { flag.isHidden = !hasFeedback } }
    var onClick: (() -> Void)?
    var selected = false {
        didSet {
            image.layer?.borderColor = (selected ? Theme.accent : NSColor(white: 1, alpha: 0.12)).cgColor
            image.layer?.borderWidth = selected ? 2.5 : 1
            number.textColor = selected ? Theme.accent : NSColor(white: 1, alpha: 0.5)
        }
    }
    /// Number column and margins (as in the editor) and the extra indent of the builds.
    static let numberColumn: CGFloat = 2 + 20 + 8
    static let buildIndent: CGFloat = 16

    init(number n: Int, builds count: Int) {
        builds = count > 1 ? (1...count).map { BuildThumb(number: $0) } : []
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        number.stringValue = String(n)
        number.font = Theme.font(11, .medium); number.alignment = .right
        number.translatesAutoresizingMaskIntoConstraints = false
        image.wantsLayer = true
        image.layer?.backgroundColor = NSColor.black.cgColor
        image.layer?.cornerRadius = 5; image.layer?.masksToBounds = true
        let stack = NSStackView(views: builds)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        flag.wantsLayer = true; flag.layer?.backgroundColor = FeedbackBox.red.cgColor; flag.layer?.cornerRadius = 5
        flag.layer?.borderWidth = 1.5; flag.layer?.borderColor = NSColor.white.cgColor
        flag.isHidden = true; flag.toolTip = "Has feedback"
        flag.translatesAutoresizingMaskIntoConstraints = false
        addSubview(number); addSubview(image); addSubview(stack); addSubview(flag)
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), number.widthAnchor.constraint(equalToConstant: 20),
            number.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.numberColumn),
            image.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            image.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            image.heightAnchor.constraint(equalTo: image.widthAnchor, multiplier: 9.0 / 16.0),
            flag.widthAnchor.constraint(equalToConstant: 10), flag.heightAnchor.constraint(equalToConstant: 10),
            flag.trailingAnchor.constraint(equalTo: image.trailingAnchor, constant: -4), flag.topAnchor.constraint(equalTo: image.topAnchor, constant: 4),
            stack.leadingAnchor.constraint(equalTo: image.leadingAnchor, constant: Self.buildIndent),
            stack.trailingAnchor.constraint(equalTo: image.trailingAnchor),
            stack.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 6),
            (builds.isEmpty ? image : stack).bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        for b in builds { b.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        selected = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// A click on the slide's picture lands here (its image view would swallow it); a click on a build panel
    /// stays with the panel.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let v = super.hitTest(point) else { return nil }
        if v === flag { return self }
        return v.isDescendant(of: self) && builds.contains(where: { v.isDescendant(of: $0) }) ? v : self
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Presenter view: two windows. The audience display is the regular full-screen show (on the second screen when
/// there is one, else on the same screen); the presenter window has End Show, Swap Displays and Use Slide Show at
/// the top, the timer and clock under them, then a sidebar of every slide with its builds expanded (as the
/// editor's navigator shows the current slide) down the left, the current slide large to its right, the slide
/// notes and build notes side by side under it, and the slide counter with arrows at the bottom. On a single screen
/// it floats above the show, so both are in view. With the animated show the current slide plays live, mirroring
/// the audience display.
@MainActor
final class PresenterController: NSObject, NSWindowDelegate {
    let source: PresenterSource
    let window: PresenterWindow
    var onExit: (() -> Void)?
    /// "Use Slide Show": the presenter window is gone but the show goes on; the caller takes the source back.
    var onDetach: ((PresenterSource) -> Void)?
    /// Saves notes typed here: the scene, the build (nil for the slide's notes) and the text. `done` says whether
    /// they were saved.
    var onSaveNotes: ((_ scene: String, _ build: Int?, _ text: String, _ done: @escaping (Bool) -> Void) -> Void)?
    /// The deck folder, where the pictures in the notes are (see `NoteImages`); pictures pasted in are copied there.
    var noteImageBase: URL? {
        didSet {
            for tv in [notes, buildNotes] {
                tv.onImages = noteImageBase == nil ? nil : { [weak self, weak tv] pb in
                    guard let self, let tv, let base = self.noteImageBase,
                          let paths = NoteImages.importImages(from: pb, into: base) else { return false }
                    NoteImages.insert(paths, in: tv, base: base, maxWidth: self.imageWidth(tv))
                    return true
                }
            }
            if !finished { shown = [:]; refresh() }
        }
    }
    /// Pictures shown in the slide notes panel, for the headless test.
    var notesImageCount: Int {
        var n = 0
        notes.attributedString().enumerateAttribute(.attachment, in: NSRange(location: 0, length: notes.attributedString().length)) { v, _, _ in
            if v is NoteImageAttachment { n += 1 }
        }
        return n
    }
    /// The text each notes panel shows, so a refresh leaves an unchanged panel (and its pictures) alone.
    private var shown: [ObjectIdentifier: String] = [:]    /// The deck's feedback notes (set by the controller that opened the show): shown over the current slide, and
    /// in Feedback Mode new ones are typed there. The audience display never shows them.
    var feedback: FeedbackStore? {
        didSet { feedbackLayer.store = feedback; feedbackButton.isEnabled = feedback != nil; if !finished { refresh() } }
    }
    /// Feedback Mode: clicks on the current slide add notes instead of advancing.
    private(set) var feedbackMode = false

    private let current = SlideView()
    private let live = LiveVideoView()
    private let feedbackLayer = FeedbackLayer()
    private var feedbackButton = NSButton()
    private var slideNotesButton = NSButton()
    private var buildNotesButton = NSButton()
    /// The two notes panels with their captions, and the row holding them under the slide.
    private var slideNotesColumn = NSView(), buildNotesColumn = NSView(), notesRow = NSView()
    /// Active while any notes panel shows: the panels keep some height, and the slide leaves them room.
    private var notesRoom: [NSLayoutConstraint] = []
    /// Notes panels hidden with the toolbar buttons (kept for the next show).
    private var hideSlideNotes = UserDefaults.standard.bool(forKey: "presenterHideSlideNotes")
    private var hideBuildNotes = UserDefaults.standard.bool(forKey: "presenterHideBuildNotes")
    private let badge = NSTextField(labelWithString: "")
    private let notes = NotesTextView()
    private let buildNotes = NotesTextView()
    /// The page whose notes are being typed in (set when a notes panel takes focus).
    private var editingPage: Int?
    private let counter = NSTextField(labelWithString: "")
    private let clock = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "")
    private let blank = NSTextField(labelWithString: "SCREEN BLANKED")
    private let pauseButton = NSButton()
    private let progress = NSView()
    private var progressWidth: NSLayoutConstraint?
    private let sidebar = NSScrollView()
    private var thumbs: [SlideThumb] = []
    private var sidebarToken = 0                 // the source's `reloadToken` the sidebar was built for
    private var thumbCache: [String: NSImage] = [:]   // sidebar pictures by file, kept across sidebar rebuilds
    /// For each slide of the show: its first page (where a thumbnail click goes) and last page (its picture).
    private var slideRange: [(first: Int, last: Int)] = []
    static let sidebarWidth: CGFloat = 250
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
    convenience init(slides: [[String]], links: [[[PresentDeck.LinkRegion]]] = [], scenes: [String], notes: [String],
                     buildNotes: [[String]], startSlide: Int, presenterScreen: NSScreen, audienceScreen: NSScreen?) {
        let p = SlidePlayer(screen: audienceScreen ?? presenterScreen)
        p.notes = notes; p.buildNotes = buildNotes; p.scenes = scenes
        self.init(source: p, animated: false, presenterScreen: presenterScreen, sharedScreen: audienceScreen == nil)
        p.play(slides: slides, links: links, startSlide: startSlide, screen: audienceScreen ?? presenterScreen, ownSpace: audienceScreen != nil)
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
        buildSidebar()
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
        slideNotesButton = toolButton("Hide Slide Notes", symbol: "note.text", action: #selector(toggleSlideNotes))
        buildNotesButton = toolButton("Hide Build Notes", symbol: "list.bullet.rectangle", action: #selector(toggleBuildNotes))
        feedbackButton = toolButton("Feedback Mode", symbol: "text.bubble", action: #selector(toggleFeedbackMode))
        feedbackButton.toolTip = "Click the slide here to type red feedback notes on it (F). The audience never sees them; the editor shows them afterwards."
        feedbackButton.isEnabled = false
        let toolbar = NSStackView(views: [endShow, swap, useShow, slideNotesButton, buildNotesButton, feedbackButton])
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
        current.onLink = { [weak self] e in
            guard let self, !self.source.isBlackedOut else { return false }
            let r = self.feedbackLayer.slideRect()
            guard r.width > 0, r.height > 0 else { return false }
            let p = self.feedbackLayer.convert(e.locationInWindow, from: nil)
            guard let u = self.source.link(at: CGPoint(x: (p.x - r.minX) / r.width, y: 1 - (p.y - r.minY) / r.height)) else { return false }
            NSWorkspace.shared.open(u)
            return true
        }
        live.translatesAutoresizingMaskIntoConstraints = false
        live.isHidden = true
        // feedback notes over the slide (above the live clip); the slide's place within the panel follows the
        // picture's fit, or the clip's
        feedbackLayer.translatesAutoresizingMaskIntoConstraints = false
        feedbackLayer.slideRect = { [weak self] in
            guard let self else { return .zero }
            let b = self.feedbackLayer.bounds
            if !self.live.isHidden, self.live.playerLayer.isReadyForDisplay {
                let v = self.live.playerLayer.videoRect
                if v.width > 0, v.height > 0 { return v }
            }
            let aspect: CGFloat = {
                if let s = self.current.image?.size, s.width > 0, s.height > 0 { return s.width / s.height }
                return 16.0 / 9.0
            }()
            let w = min(b.width, b.height * aspect), h = w / aspect
            return CGRect(x: b.midX - w / 2, y: b.midY - h / 2, width: w, height: h)
        }
        feedbackLayer.onAdd = { [weak self] in self?.markFeedback() }
        current.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: current, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.feedbackLayer.relayout() }
        }
        badge.font = Theme.font(11, .semibold); badge.textColor = .white
        badge.wantsLayer = true; badge.drawsBackground = true; badge.backgroundColor = NSColor(white: 0, alpha: 0.55)
        badge.layer?.cornerRadius = 4; badge.layer?.masksToBounds = true
        badge.isHidden = true; badge.translatesAutoresizingMaskIntoConstraints = false
        blank.font = Theme.font(20, .bold); blank.textColor = NSColor(white: 1, alpha: 0.6); blank.isHidden = true
        blank.translatesAutoresizingMaskIntoConstraints = false
        // speaker notes under the slide: the slide's (every build) at the left, this build's own at the right
        func notesBox(_ tv: NotesTextView) -> NSScrollView {
            tv.isEditable = true; tv.isSelectable = true; tv.isRichText = false
            tv.allowsUndo = true
            tv.font = Theme.font(20)
            tv.textColor = NSColor(white: 0.95, alpha: 1)
            tv.insertionPointColor = .white
            tv.typingAttributes = [.font: Theme.font(20), .foregroundColor: NSColor(white: 0.95, alpha: 1)]
            tv.onFocus = { [weak self, weak tv] in if let tv { self?.beginNotes(tv) } }
            tv.onBlur = { [weak self, weak tv] in if let tv { self?.endNotes(tv) } }
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
        func column(_ title: String, _ scroll: NSScrollView) -> NSStackView {
            let s = NSStackView(views: [caption(title), scroll])
            s.orientation = .vertical; s.alignment = .leading; s.spacing = 6
            s.translatesAutoresizingMaskIntoConstraints = false
            scroll.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
            return s
        }
        slideNotesColumn = column("SLIDE NOTES", notesScroll); buildNotesColumn = column("BUILD NOTES", buildScroll)
        // a hidden column leaves the stack, so the other one takes the whole row
        let notesRow = NSStackView(views: [slideNotesColumn, buildNotesColumn])
        notesRow.orientation = .horizontal; notesRow.alignment = .top; notesRow.spacing = 20
        notesRow.distribution = .fillEqually
        notesRow.translatesAutoresizingMaskIntoConstraints = false
        self.notesRow = notesRow
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
            ? "→ next · ← back · space pause · V reverse · 1–9 chapter · B blank · N next slide · F feedback · esc end · click notes to edit"
            : "→ / space next · ← back · B blank · N next slide · F feedback · esc end · click notes to edit")
        hint.font = Theme.font(11); hint.textColor = NSColor(white: 1, alpha: 0.4)
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.init(1), for: .horizontal)   // never widens the window
        hint.translatesAutoresizingMaskIntoConstraints = false
        // the sidebar of slides down the left
        sidebar.hasVerticalScroller = true; sidebar.hasHorizontalScroller = false
        sidebar.drawsBackground = true; sidebar.backgroundColor = NSColor(white: 0.1, alpha: 1)
        sidebar.verticalScrollElasticity = .allowed
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        // everything right of the sidebar
        let main = NSView()
        main.translatesAutoresizingMaskIntoConstraints = false

        for v in [toolbar, timerRow, clock, sidebar, main] { root.addSubview(v) }
        for v in [current, live, feedbackLayer, badge, blank, notesRow, counterRow, track, hint] { main.addSubview(v) }
        let pw = progress.widthAnchor.constraint(equalToConstant: 0)
        progressWidth = pw
        // the slide: as wide as the main area, unless that leaves too little height for the notes under it; then
        // as tall as the room allows, centred
        let slideWidth = current.widthAnchor.constraint(equalTo: main.widthAnchor, constant: -48)
        slideWidth.priority = .init(400)      // below the window's own size (500): the slide shrinks, the window never grows
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            timerRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            timerRow.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            clock.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            clock.centerYAnchor.constraint(equalTo: timerRow.centerYAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: timerRow.bottomAnchor, constant: 10),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: Self.sidebarWidth),
            main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.topAnchor.constraint(equalTo: sidebar.topAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            current.centerXAnchor.constraint(equalTo: main.centerXAnchor),
            current.topAnchor.constraint(equalTo: main.topAnchor),
            slideWidth,
            current.widthAnchor.constraint(lessThanOrEqualTo: main.widthAnchor, constant: -48),
            current.heightAnchor.constraint(equalTo: current.widthAnchor, multiplier: 9.0 / 16.0),
            live.leadingAnchor.constraint(equalTo: current.leadingAnchor), live.trailingAnchor.constraint(equalTo: current.trailingAnchor),
            live.topAnchor.constraint(equalTo: current.topAnchor), live.bottomAnchor.constraint(equalTo: current.bottomAnchor),
            feedbackLayer.leadingAnchor.constraint(equalTo: current.leadingAnchor), feedbackLayer.trailingAnchor.constraint(equalTo: current.trailingAnchor),
            feedbackLayer.topAnchor.constraint(equalTo: current.topAnchor), feedbackLayer.bottomAnchor.constraint(equalTo: current.bottomAnchor),
            badge.leadingAnchor.constraint(equalTo: current.leadingAnchor, constant: 10),
            badge.topAnchor.constraint(equalTo: current.topAnchor, constant: 10),
            blank.centerXAnchor.constraint(equalTo: current.centerXAnchor), blank.centerYAnchor.constraint(equalTo: current.centerYAnchor),
            notesRow.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 24),
            notesRow.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -24),
            notesRow.topAnchor.constraint(equalTo: current.bottomAnchor, constant: 14),
            notesRow.bottomAnchor.constraint(equalTo: counterRow.topAnchor, constant: -12),
            notesRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            notesScroll.heightAnchor.constraint(equalTo: notesRow.heightAnchor, constant: -20),
            buildScroll.heightAnchor.constraint(equalTo: notesRow.heightAnchor, constant: -20),
            counterRow.centerXAnchor.constraint(equalTo: main.centerXAnchor),
            counterRow.bottomAnchor.constraint(equalTo: track.topAnchor, constant: -6),
            track.centerXAnchor.constraint(equalTo: main.centerXAnchor),
            track.widthAnchor.constraint(equalToConstant: 220),
            track.heightAnchor.constraint(equalToConstant: 3),
            track.bottomAnchor.constraint(equalTo: main.bottomAnchor, constant: -14),
            progress.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            progress.topAnchor.constraint(equalTo: track.topAnchor), progress.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            pw,
            hint.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -24),
            hint.centerYAnchor.constraint(equalTo: counterRow.centerYAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: counterRow.trailingAnchor, constant: 16),
        ])
        // with both notes panels hidden the slide grows into their room, down to the counter row
        notesRoom = [notesRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
                     current.heightAnchor.constraint(lessThanOrEqualTo: root.heightAnchor, multiplier: 0.6)]
        applyNotesVisibility()
        return root
    }

    @objc private func toggleSlideNotes() {
        hideSlideNotes.toggle()
        UserDefaults.standard.set(hideSlideNotes, forKey: "presenterHideSlideNotes")
        applyNotesVisibility()
    }

    @objc private func toggleBuildNotes() {
        hideBuildNotes.toggle()
        UserDefaults.standard.set(hideBuildNotes, forKey: "presenterHideBuildNotes")
        applyNotesVisibility()
    }

    /// Shows or hides each notes panel as the toolbar buttons say; a panel being typed in saves first.
    private func applyNotesVisibility() {
        if let tv = window.firstResponder as? NotesTextView,
           (tv === notes && hideSlideNotes) || (tv === buildNotes && hideBuildNotes) { window.makeFirstResponder(nil) }
        slideNotesColumn.isHidden = hideSlideNotes
        buildNotesColumn.isHidden = hideBuildNotes
        let none = hideSlideNotes && hideBuildNotes
        notesRow.isHidden = none
        if none { NSLayoutConstraint.deactivate(notesRoom) } else { NSLayoutConstraint.activate(notesRoom) }
        for (b, hidden, what) in [(slideNotesButton, hideSlideNotes, "Slide"), (buildNotesButton, hideBuildNotes, "Build")] {
            b.title = hidden ? "Show \(what) Notes" : "Hide \(what) Notes"
            b.contentTintColor = hidden ? Theme.accent : NSColor(white: 1, alpha: 0.85)
            b.toolTip = hidden ? "Show the \(what.lowercased()) notes under the slide" : "Hide the \(what.lowercased()) notes; the other panel, or the slide, takes their room"
        }
    }

    /// One entry per slide: the picture of its last build (a click goes to its first) with every build nested
    /// beneath it (a click goes to that build).
    private func buildSidebar() {
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
            let t = SlideThumb(number: k + 1, builds: r.last - r.first + 1)
            t.onClick = { [weak self] in self?.source.go(r.first) }
            for (b, panel) in t.builds.enumerated() { panel.onClick = { [weak self] in self?.source.go(r.first + b) } }
            return t
        }
        let column = NSStackView(views: thumbs)
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 4
        column.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 12, right: 0)
        column.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()                         // so the list starts at the top
        doc.addSubview(column)
        doc.translatesAutoresizingMaskIntoConstraints = false
        sidebar.documentView = doc
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: doc.leadingAnchor), column.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            column.topAnchor.constraint(equalTo: doc.topAnchor), column.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: sidebar.contentView.widthAnchor),
            doc.topAnchor.constraint(equalTo: sidebar.contentView.topAnchor),
        ])
        for t in thumbs { t.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        loadThumbnails()
    }

    /// Small pictures for the sidebar, one per page, decoded in the background at thumbnail size (the full PNGs
    /// would take hundreds of megabytes for a long deck). A slide shows its last build; its panels show each build.
    private func loadThumbnails() {
        let dark = DarkMode.isOn
        for (k, r) in slideRange.enumerated() {
            for i in r.first...r.last {
                let page = source.presenterPage(i)
                let file = page.still ?? page.clip ?? ""
                if file.isEmpty { continue }                        // still rendering: no picture yet
                if let img = thumbCache[file], let t = thumbs[safe: k] {
                    if i == r.last { t.image.image = img }
                    t.builds[safe: i - r.first]?.image.image = img
                    continue
                }
                Task { @MainActor [weak self] in
                    guard let img = await Self.thumbnailImage(page, dark: dark), let self, let t = self.thumbs[safe: k] else { return }
                    if self.thumbCache.count > 400 { self.thumbCache.removeAll() }
                    self.thumbCache[file] = img
                    if i == r.last { t.image.image = img }
                    t.builds[safe: i - r.first]?.image.image = img
                }
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

    /// Pictures for slides that were still rendering when the show started (the stills show only).
    func updateStills(slides: [[String]], links: [[[PresentDeck.LinkRegion]]], scenes: [String], notes: [String], buildNotes: [[String]]) {
        guard let p = source as? SlidePlayer else { return }
        p.update(slides: slides, links: links, scenes: scenes, notes: notes, buildNotes: buildNotes)
        refresh()
    }

    func refresh() {
        if source.reloadToken != sidebarToken {
            sidebarToken = source.reloadToken
            buildSidebar()
        }
        guard (0..<source.pageCount).contains(source.pageIndex) else { return }
        // the show moved on while notes were being typed: save them for the page they belong to
        if let e = editingPage, e != source.pageIndex { window.makeFirstResponder(nil) }
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
        // a panel being typed in keeps its text; the other one shows this page's
        if window.firstResponder !== notes { show(page.notes, in: notes, empty: Self.noNotes) }
        if window.firstResponder !== buildNotes { show(page.buildNotes, in: buildNotes, empty: Self.noBuildNotes) }
        // feedback notes of this slide over its picture (a note being typed is saved when the show moves on)
        if feedbackLayer.scene != page.scene { feedbackLayer.endEditing() }
        feedbackLayer.build = page.build
        feedbackLayer.scene = page.scene
        feedbackLayer.relayout()
        markFeedback()
        // the sidebar: outline the current slide and its current build, and keep them in view
        if let k = slideRange.firstIndex(where: { $0.first <= source.pageIndex && source.pageIndex <= $0.last }) {
            for (i, t) in thumbs.enumerated() where t.selected != (i == k) { t.selected = i == k }
            if let t = thumbs[safe: k] {
                let b = source.pageIndex - slideRange[k].first
                for (i, p) in t.builds.enumerated() where p.selected != (i == b) { p.selected = i == b }
                let target: NSView = t.builds[safe: b] ?? t
                if t.frame.height > 0 {
                    let r = target.convert(target.bounds, to: sidebar.documentView).insetBy(dx: 0, dy: -24)
                    sidebar.documentView?.scrollToVisible(r)
                }
            }
        }
    }
    /// For the headless test: whether the live panel has a frame of the current clip to draw.
    var liveFrameReady: Bool { !live.isHidden && live.playerLayer.isReadyForDisplay }

    // MARK: Feedback Mode

    /// Flag the slides with feedback in the sidebar.
    private func markFeedback() {
        guard let store = feedback else { return }
        for (k, r) in slideRange.enumerated() {
            let has = source.presenterPage(r.first).scene.map { !store.notes(for: $0).isEmpty } ?? false
            if let t = thumbs[safe: k], t.hasFeedback != has { t.hasFeedback = has }
        }
    }

    /// The store changed (a note added, edited or removed, here or in the editor): show what is.
    func feedbackChanged() {
        guard !finished else { return }
        feedbackLayer.rebuild()
        markFeedback()
    }

    /// For the headless test: where the slide is drawn in the presenter's panel, in window coordinates.
    var feedbackSlideRectInWindow: CGRect { feedbackLayer.convert(feedbackLayer.slideRect(), to: nil) }
    var feedbackLayerDebug: String { "frame=\(feedbackLayer.frame.integral) placing=\(feedbackLayer.placing) scene=\(feedbackLayer.scene ?? "nil") store=\(feedbackLayer.store != nil) hidden=\(feedbackLayer.isHiddenOrHasHiddenAncestor) super=\(type(of: feedbackLayer.superview as Any)) idx=\(feedbackLayer.superview?.subviews.firstIndex(of: feedbackLayer) ?? -1)/\(feedbackLayer.superview?.subviews.count ?? -1)" }
    func setFeedbackMode(_ on: Bool) { if on != feedbackMode { toggleFeedbackMode() } }

    @objc private func toggleFeedbackMode() {
        guard feedback != nil else { NSSound.beep(); return }
        feedbackMode.toggle()
        feedbackLayer.placing = feedbackMode
        if !feedbackMode { feedbackLayer.endEditing() }
        feedbackButton.contentTintColor = feedbackMode ? Theme.accent : NSColor(white: 1, alpha: 0.85)
        feedbackButton.title = feedbackMode ? "Feedback On" : "Feedback Mode"
        current.toolTip = feedbackMode ? "Click to add a feedback note" : nil
    }

    private static let noNotes = "No notes for this slide. Click here to type them."
    private static let noBuildNotes = "No notes for this build. Click here to type them."

    /// Notes in a panel, pictures and all, or a dimmed hint when there are none.
    private func show(_ text: String, in tv: NotesTextView, empty: String) {
        let s = text.isEmpty ? empty : text
        tv.showsHint = text.isEmpty
        guard shown[ObjectIdentifier(tv)] != s || tv.notesText != s else { return }
        shown[ObjectIdentifier(tv)] = s
        let color = text.isEmpty ? NSColor(white: 1, alpha: 0.35) : NSColor(white: 0.95, alpha: 1)
        tv.textStorage?.setAttributedString(NoteImages.attributed(s, base: noteImageBase, attributes: [.font: Theme.font(20), .foregroundColor: color],
                                                                  maxWidth: imageWidth(tv)))
    }

    /// Pictures in a notes panel at most this wide: the panel's text width, up to 480 pt.
    private func imageWidth(_ tv: NSTextView) -> CGFloat { min(480, max(120, (tv.textContainer?.size.width ?? 480) - 12)) }

    // MARK: Typing notes

    /// A notes panel took focus: note the page it is for and clear the hint.
    private func beginNotes(_ tv: NotesTextView) {
        guard !finished else { return }
        editingPage = source.pageIndex
        if tv.showsHint { tv.string = ""; tv.showsHint = false; shown[ObjectIdentifier(tv)] = nil }
        tv.textColor = NSColor(white: 0.95, alpha: 1)
    }

    /// A notes panel lost focus (esc, ⌘↵, a click elsewhere, the show moving on): save what changed.
    private func endNotes(_ tv: NotesTextView) {
        guard let i = editingPage else { return }
        editingPage = nil
        let isBuild = tv === buildNotes
        let page = source.presenterPage(i)
        let text = tv.notesText
        let old = isBuild ? page.buildNotes : page.notes
        if text != old, let scene = page.scene, let save = onSaveNotes {
            source.setNotes(text, forPage: i, build: isBuild)
            save(scene, isBuild ? page.build : nil, text) { [weak self] ok in
                guard let self, !ok else { return }
                self.source.setNotes(old, forPage: i, build: isBuild)      // not saved: back to what is
                if !self.finished { self.refresh() }
            }
        }
        // after the focus has moved: changing the text of a panel that is still resigning first responder (a
        // click from one panel into the other) restarts its insertion point, which then blinks beside the new one
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            self.refresh()
        }
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
        window.makeFirstResponder(nil)      // saves notes being typed
        finished = true
        timer?.invalidate(); timer = nil
        window.delegate = nil
        live.playerLayer.player = nil
        source.onChange = nil
        hideWindow()
        source.window.makeKeyAndOrderFront(nil)
        onDetach?(source)
    }

    /// Hides the presenter window for good, leaving its full-screen Space first when it has one (ordering out a
    /// full-screen window leaves an empty Space behind). Holds the window, not the controller: the caller lets go of
    /// the controller as soon as the show ends, long before the window is out of full screen, and a `[weak self]`
    /// here left the window on screen at its floating size. Looks again a moment later, should the exit transition
    /// have been dropped (the show leaving full screen on the other display at the same moment).
    private func hideWindow() {
        let w = window
        let userClosing = closing
        func gone() {
            w.orderOut(nil)
            if !userClosing { w.close() }
        }
        func leave(_ tries: Int) {
            guard w.styleMask.contains(.fullScreen), !userClosing, tries > 0 else { gone(); return }
            final class Once { var done = false }
            let once = Once()
            w.once(NSWindow.didExitFullScreenNotification) {
                guard !once.done else { return }
                once.done = true
                // let the exit transition settle (ordering out at its very end can be undone by AppKit)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Task { @MainActor in gone() } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                Task { @MainActor in
                    guard !once.done else { return }
                    once.done = true
                    leave(tries - 1)
                }
            }
            w.toggleFullScreen(nil)
        }
        leave(3)
    }

    private func key(_ e: NSEvent) {
        if e.keyCode == 15, e.charactersIgnoringModifiers?.lowercased() == "r" { resetTimer(); return }
        if e.keyCode == 3, e.charactersIgnoringModifiers?.lowercased() == "f" { toggleFeedbackMode(); return }
        if !source.handleKey(e) { NSSound.beep() }
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        if !finished { source.exit() }
    }

    private func finish() {
        guard !finished else { return }
        window.makeFirstResponder(nil)      // saves notes being typed
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

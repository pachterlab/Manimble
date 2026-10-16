import AppKit

/// The presenter's window: current slide, next slide, speaker notes, clock, elapsed time and the slide counter.
final class PresenterWindow: NSWindow {
    var onKey: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) { onKey?(event) }
}

/// Presenter view: drives a `SlidePlayer` (the audience display on another screen, or an invisible one for
/// rehearsing on a single screen) from a window that shows the notes and what comes next.
@MainActor
final class PresenterController: NSObject, NSWindowDelegate {
    let player: SlidePlayer
    let window: PresenterWindow
    var onExit: (() -> Void)?

    private let current = NSImageView()
    private let next = NSImageView()
    private let notes = NSTextView()
    private let nextCaption = NSTextField(labelWithString: "NEXT")
    private let counter = NSTextField(labelWithString: "")
    private let clock = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "")
    private let blank = NSTextField(labelWithString: "SCREEN BLANKED")
    private let slideNotes: [String]
    private var started = Date()
    private var timer: Timer?
    private var finished = false
    private var cache: [String: NSImage] = [:]

    init(slides: [[String]], notes: [String], startSlide: Int, presenterScreen: NSScreen, audienceScreen: NSScreen?) {
        slideNotes = notes
        player = SlidePlayer(screen: audienceScreen ?? presenterScreen)
        let frame = presenterScreen.visibleFrame
        window = PresenterWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                 backing: .buffered, defer: false)
        super.init()
        window.title = audienceScreen == nil ? "Presenter View (rehearsal)" : "Presenter View"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.07, alpha: 1)
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = buildContent()
        window.onKey = { [weak self] e in self?.key(e) }
        player.onChange = { [weak self] in self?.refresh() }
        player.onExit = { [weak self] in self?.finish() }
        player.play(slides: slides, startSlide: startSlide, screen: audienceScreen, visible: audienceScreen != nil)
        window.makeKeyAndOrderFront(nil)
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
        let hint = NSTextField(labelWithString: "→ / space  next  ·  ←  back  ·  B  blank  ·  N  next slide  ·  click the timer to reset  ·  esc  end")
        hint.font = Theme.font(11); hint.textColor = NSColor(white: 1, alpha: 0.4)
        let elapsedBox = NSStackView(views: [caption("ELAPSED"), elapsed]); elapsedBox.orientation = .vertical; elapsedBox.alignment = .leading; elapsedBox.spacing = 1
        let clockBox = NSStackView(views: [caption("TIME"), clock]); clockBox.orientation = .vertical; clockBox.alignment = .leading; clockBox.spacing = 1
        let counterBox = NSStackView(views: [caption("SLIDE"), counter]); counterBox.orientation = .vertical; counterBox.alignment = .leading; counterBox.spacing = 1
        elapsedBox.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(resetTimer)))
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [counterBox, elapsedBox, clockBox, spacer, hint])
        bar.orientation = .horizontal; bar.alignment = .centerY; bar.spacing = 36
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(current); root.addSubview(blank); root.addSubview(right); root.addSubview(bar)
        NSLayoutConstraint.activate([
            current.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            current.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            current.widthAnchor.constraint(equalTo: root.widthAnchor, multiplier: 0.6),
            current.heightAnchor.constraint(equalTo: current.widthAnchor, multiplier: 9.0 / 16.0),
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
        if cache.count > 16 { cache.removeAll() }
        cache[path] = i
        return i
    }

    func refresh() {
        guard player.pages.indices.contains(player.index) else { return }
        let page = player.pages[player.index]
        current.image = image(page.path)
        current.alphaValue = player.isBlackedOut ? 0.25 : 1
        blank.isHidden = !player.isBlackedOut
        if player.pages.indices.contains(player.index + 1) {
            let n = player.pages[player.index + 1]
            next.image = image(n.path)
            nextCaption.stringValue = n.slide == page.slide ? "NEXT  ·  build \(n.build + 1) of \(n.builds)" : "NEXT  ·  slide \(n.slide + 1)"
        } else {
            next.image = nil
            nextCaption.stringValue = "NEXT  ·  end of the show"
        }
        counter.stringValue = "\(page.slide + 1) / \(player.slideCount)" + (page.builds > 1 ? "   build \(page.build + 1)/\(page.builds)" : "")
        let text = slideNotes.indices.contains(page.slide) ? slideNotes[page.slide] : ""
        if text.isEmpty {
            notes.string = "No notes for this slide. Type them in the Speaker Notes box under the slide in the editor."
            notes.textColor = NSColor(white: 1, alpha: 0.35)
        } else {
            notes.string = text
            notes.textColor = NSColor(white: 0.95, alpha: 1)
        }
    }

    private func tick() {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        clock.stringValue = f.string(from: Date())
        let s = Int(Date().timeIntervalSince(started))
        elapsed.stringValue = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    @objc private func resetTimer() { started = Date(); tick() }
    @objc private func advance() { player.next() }

    private func key(_ e: NSEvent) {
        if e.keyCode == 15, e.charactersIgnoringModifiers?.lowercased() == "r" { resetTimer(); return }
        if !player.handleKey(e) { NSSound.beep() }
    }

    func windowWillClose(_ notification: Notification) {
        if !finished { player.exit() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate(); timer = nil
        window.delegate = nil
        window.orderOut(nil)
        onExit?()
    }
}

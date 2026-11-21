import AppKit

/// What the window shows while no deck is open (at launch, after the deck is closed): New Deck, Open and the recent
/// decks, laid over the editor so its controls, which have nothing to act on, can't be clicked.
final class StartScreen: NSView {
    var onNew: (() -> Void)?
    var onOpen: (() -> Void)?
    var onRecent: ((String) -> Void)?
    private let recentStack = NSStackView()
    private let recentTitle = NSTextField(labelWithString: "Recent")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true
        let title = NSTextField(labelWithString: "No deck is open")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let sub = NSTextField(labelWithString: "Create a new deck, or open a deck folder, project folder or .manimble package.")
        sub.textColor = .secondaryLabelColor

        let new = NSButton(title: "New Deck…", target: self, action: #selector(newPressed))
        new.bezelStyle = .rounded; new.controlSize = .large; new.keyEquivalent = "\r"
        new.bezelColor = Theme.accent
        let open = NSButton(title: "Open…", target: self, action: #selector(openPressed))
        open.bezelStyle = .rounded; open.controlSize = .large
        let buttons = NSStackView(views: [new, open])
        buttons.spacing = 12

        recentTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        recentTitle.textColor = .secondaryLabelColor
        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 2

        let stack = NSStackView(views: [icon, title, sub, buttons, recentTitle, recentStack])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(18, after: icon)
        stack.setCustomSpacing(22, after: sub)
        stack.setCustomSpacing(30, after: buttons)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
        ])
        reloadRecent()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    override var wantsUpdateLayer: Bool { true }

    /// The recent decks that still exist, newest first, as in File ▸ Open Recent.
    func reloadRecent() {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let fm = FileManager.default
        for p in RecentDecks.paths.filter({ fm.fileExists(atPath: $0) }).prefix(6) {
            let u = URL(fileURLWithPath: p)
            let b = NSButton(title: u.deletingLastPathComponent().lastPathComponent + " / " + u.lastPathComponent,
                             target: self, action: #selector(recentPressed(_:)))
            b.isBordered = false
            b.contentTintColor = Theme.accent
            b.toolTip = p
            b.identifier = NSUserInterfaceItemIdentifier(p)
            b.image = NSWorkspace.shared.icon(forFile: p)
            b.image?.size = NSSize(width: 16, height: 16)
            b.imagePosition = .imageLeading
            recentStack.addArrangedSubview(b)
        }
        recentTitle.isHidden = recentStack.arrangedSubviews.isEmpty
        recentStack.isHidden = recentTitle.isHidden
    }

    @objc private func newPressed() { onNew?() }
    @objc private func openPressed() { onOpen?() }
    @objc private func recentPressed(_ b: NSButton) { if let p = b.identifier?.rawValue { onRecent?(p) } }

    // the editor underneath gets no clicks, scrolls or drops while this is up
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {}
}

extension MainController {
    /// The start screen up while no deck is open (and no deck is on its way), gone once one is.
    func syncStartScreen() {
        guard let content = window.contentView else { return }
        let show = workspace == nil && pendingDeck == nil && !openingDeck
        if show {
            if startScreen == nil {
                let s = StartScreen(frame: content.bounds)
                s.onNew = { [weak self] in self?.newDeck() }
                s.onOpen = { [weak self] in self?.openDeck() }
                s.onRecent = { [weak self] p in self?.openInWindow(deck: p) }
                startScreen = s
            }
            guard let s = startScreen else { return }
            s.reloadRecent()
            s.frame = content.bounds
            if s.superview == nil { content.addSubview(s, positioned: .above, relativeTo: nil) }
            window.makeFirstResponder(s)
        } else if let s = startScreen, s.superview != nil {
            s.removeFromSuperview()
            if window.firstResponder == nil || window.firstResponder === window { window.makeFirstResponder(canvas) }
        }
    }
}

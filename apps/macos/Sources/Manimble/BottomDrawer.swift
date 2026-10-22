import AppKit

/// The drawer below the slide: the speaker notes and the terminals share it as tabs ("Notes | Terminal 1 | Terminal 2 …"),
/// so there is only one divider between it and the slide.
final class BottomDrawer: NSView {
    enum Page { case notes, terminal }
    private(set) var page: Page = .notes
    private let notes: NSView
    let terminal: TerminalPanel
    private let strip = NSStackView()
    private let notesHint = NSTextField(labelWithString: "shown in Presenter View and by Manim Slides  ·  ⌘↵ or click away to save")
    /// About to switch pages (the notes commit before they are hidden).
    var willChangePage: ((Page) -> Void)?
    /// The + button: open a new terminal (the controller starts the first shell in the deck's folder).
    var onNewTerminal: (() -> Void)?
    var onHide: (() -> Void)?

    init(notes: NSView, terminal: TerminalPanel) {
        self.notes = notes; self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.canvasBottom.cgColor

        // header: the tabs, then the active page's tools, then hide
        let bar = NSView(); bar.wantsLayer = true
        bar.layer?.backgroundColor = drawerBarBackground.cgColor
        strip.spacing = 0; strip.alignment = .centerY
        notesHint.font = Theme.font(10); notesHint.textColor = NSColor(white: 1, alpha: 0.3)
        notesHint.lineBreakMode = .byTruncatingTail
        notesHint.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        let plus = barButton("plus", "New terminal (⇧⌥⌘T)", self, #selector(plusPressed))
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [strip, plus, spacer, notesHint, terminal.actions,
                                      barButton("chevron.down", "Hide (⌥⌘K notes, ⌥⌘T terminal)", self, #selector(hidePressed))])
        row.spacing = 10; row.alignment = .centerY
        row.setCustomSpacing(6, after: strip)
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)

        let body = NSView()
        for v in [notes, terminal] { v.translatesAutoresizingMaskIntoConstraints = false; body.addSubview(v) }
        for v in [bar, body] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor), bar.heightAnchor.constraint(equalToConstant: 28),
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 4), row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: bar.topAnchor), row.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor), body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: bar.bottomAnchor), body.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 90),
        ])
        for v in [notes, terminal] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: body.leadingAnchor), v.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                v.topAnchor.constraint(equalTo: body.topAnchor), v.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            ])
        }
        terminal.onChange = { [weak self] in self?.rebuildStrip() }
        show(.notes)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Bring a page to the front (the terminal page shows its active tab).
    func show(_ p: Page) {
        if p != page { willChangePage?(p) }
        page = p
        notes.isHidden = p != .notes
        terminal.isHidden = p != .terminal
        notesHint.isHidden = p != .notes
        terminal.actions.isHidden = p != .terminal
        rebuildStrip()
    }

    private func rebuildStrip() {
        strip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        strip.addArrangedSubview(DrawerTab(title: "Notes", tip: "Speaker notes (⌥⌘K)", selected: page == .notes,
                                           onSelect: { [weak self] in self?.show(.notes) }, onClose: nil))
        let active = page == .terminal ? terminal.activeTabIndex : nil
        for (i, t) in terminal.tabTitles.enumerated() {
            strip.addArrangedSubview(DrawerTab(title: t.title, tip: t.tip, selected: i == active,
                                               onSelect: { [weak self] in self?.terminal.selectTab(i); self?.show(.terminal) },
                                               onClose: { [weak self] in self?.terminal.closeTab(i) }))
        }
    }

    @objc private func plusPressed() { onNewTerminal?() }
    @objc private func hidePressed() { onHide?() }
}

/// A tab in the drawer's strip: a title, an accent line under the selected one, and (terminals) a close button on hover.
private final class DrawerTab: NSView {
    private let onSelect: () -> Void
    private let onClose: (() -> Void)?
    private let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close") ?? NSImage(), target: nil, action: nil)
    private let selected: Bool
    private var tracking: NSTrackingArea?

    init(title: String, tip: String, selected: Bool, onSelect: @escaping () -> Void, onClose: (() -> Void)?) {
        self.onSelect = onSelect; self.onClose = onClose; self.selected = selected
        super.init(frame: .zero)
        toolTip = tip.isEmpty ? nil : tip
        let label = NSTextField(labelWithString: title)
        label.font = Theme.font(11, selected ? .semibold : .regular)
        label.textColor = NSColor(white: 1, alpha: selected ? 0.9 : 0.5)
        close.isBordered = false; close.toolTip = "Kill terminal"; close.contentTintColor = NSColor(white: 1, alpha: 0.6)
        close.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
        close.target = self; close.action = #selector(closePressed)
        close.isHidden = true
        let edge = NSView(); edge.wantsLayer = true; edge.layer?.backgroundColor = Theme.accent.cgColor
        edge.isHidden = !selected
        for v in [label, close, edge] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 4), close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: onClose == nil ? 0 : 12),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: onClose == nil ? -6 : -8),
            edge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), edge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor), edge.heightAnchor.constraint(equalToConstant: 2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { close.isHidden = onClose == nil }
    override func mouseExited(with event: NSEvent) { close.isHidden = true }
    // after the event: both rebuild the strip, removing this tab
    override func mouseDown(with event: NSEvent) { DispatchQueue.main.async { [onSelect] in onSelect() } }
    @objc private func closePressed() { DispatchQueue.main.async { [onClose] in onClose?() } }
}

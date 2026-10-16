import AppKit
import SwiftTerm

private let termBackground = NSColor(srgbRed: 0.098, green: 0.102, blue: 0.125, alpha: 1)
private let barBackground = NSColor(srgbRed: 0.125, green: 0.13, blue: 0.158, alpha: 1)

private func barButton(_ symbol: String, _ tip: String, _ target: AnyObject, _ sel: Selector) -> NSButton {
    let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: target, action: sel)
    b.isBordered = false; b.toolTip = tip; b.contentTintColor = NSColor(white: 1, alpha: 0.6)
    b.symbolConfiguration = .init(pointSize: 11, weight: .medium)
    return b
}

/// One terminal tab: one shell, or several split side by side.
private final class TerminalTab {
    let panes = GrabSplitView()
    var sessions: [TerminalSession] = []
    init() { panes.isVertical = true; panes.dividerStyle = .thin }
}

/// The docked terminal, VS Code style: tabs of login shells in the working copy of the deck (e.g. `claude` in one,
/// a plain shell in another), listed vertically on the right once there is more than one; a tab can be split.
final class TerminalPanel: NSView {
    private let title = NSTextField(labelWithString: "TERMINAL")
    private let body = GrabSplitView()
    private let content = NSView()
    private let tabList = NSStackView()
    private let tabListScroll = NSScrollView()
    private var tabs: [TerminalTab] = []
    private var activeTab: TerminalTab?
    private weak var active: TerminalSession?
    private var directory: String = NSHomeDirectory()
    private var original: String?
    private var focusObservation: NSKeyValueObservation?
    var onHide: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = termBackground.cgColor

        // header bar: actions act on the active terminal
        let bar = NSView(); bar.wantsLayer = true
        bar.layer?.backgroundColor = barBackground.cgColor
        title.font = Theme.font(10, .semibold); title.textColor = NSColor(white: 1, alpha: 0.5)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let claude = NSButton(title: "Run claude", target: self, action: #selector(runClaude))
        claude.bezelStyle = .inline; claude.controlSize = .small; claude.font = Theme.font(11, .medium)
        claude.contentTintColor = Theme.accent
        let row = NSStackView(views: [
            title, NSView(), claude,
            barButton("plus", "New terminal (⇧⌥⌘T)", self, #selector(addPressed)),
            barButton("square.split.2x1", "Split terminal (⌘\\)", self, #selector(splitPressed)),
            barButton("arrow.clockwise", "Restart shell", self, #selector(restartPressed)),
            barButton("trash", "Kill terminal", self, #selector(killPressed)),
            barButton("chevron.down", "Hide terminal (⌥⌘T)", self, #selector(hidePressed)),
        ])
        row.spacing = 10; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14), row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        // body: the active tab on the left, the tab list on the right
        tabList.orientation = .vertical; tabList.alignment = .leading; tabList.spacing = 0
        tabList.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        tabList.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(tabList)
        tabListScroll.documentView = doc
        tabListScroll.hasVerticalScroller = true; tabListScroll.drawsBackground = true
        tabListScroll.backgroundColor = barBackground.withAlphaComponent(0.5)
        NSLayoutConstraint.activate([
            tabList.leadingAnchor.constraint(equalTo: doc.leadingAnchor), tabList.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            tabList.topAnchor.constraint(equalTo: doc.topAnchor), tabList.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: tabListScroll.contentView.widthAnchor),
            tabListScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
        ])
        tabListScroll.isHidden = true
        body.isVertical = true; body.dividerStyle = .thin
        body.addArrangedSubview(content); body.addArrangedSubview(tabListScroll)
        body.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        body.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        let stack = NSStackView(views: [bar, body]); stack.orientation = .vertical; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        bar.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 28), bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    // the terminal holding keyboard focus is the active one, which the header buttons, `type` and `contents` act on
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusObservation = window?.observe(\.firstResponder, options: [.new]) { [weak self] w, _ in
            DispatchQueue.main.async {
                guard let self = self, let r = w.firstResponder as? NSView,
                      let s = self.allSessions.first(where: { r.isDescendant(of: $0) }), s !== self.active else { return }
                self.activate(s, focus: false)
            }
        }
    }

    private var allSessions: [TerminalSession] { tabs.flatMap(\.sessions) }

    /// Start the first shell, or restart every open shell in a new folder (another deck was opened).
    func start(in dir: String, original o: String?) {
        directory = dir; original = o
        if tabs.isEmpty { addTab() } else { allSessions.forEach { $0.start(in: dir, original: o) } }
    }

    /// Open a new tab with a fresh shell and switch to it.
    func addTab() {
        let tab = TerminalTab()
        tabs.append(tab)
        tab.panes.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tab.panes)
        NSLayoutConstraint.activate([
            tab.panes.leadingAnchor.constraint(equalTo: content.leadingAnchor), tab.panes.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tab.panes.topAnchor.constraint(equalTo: content.topAnchor), tab.panes.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        addSession(to: tab)
    }

    /// Split the active tab: another shell beside the active one.
    func splitActive() {
        guard let tab = activeTab else { addTab(); return }
        addSession(to: tab)
    }

    private func addSession(to tab: TerminalTab) {
        let s = TerminalSession()
        s.onTitle = { [weak self] in self?.refresh() }
        let at = active.flatMap { a in tab.sessions.firstIndex(where: { $0 === a }) }.map { $0 + 1 } ?? tab.sessions.count
        tab.sessions.insert(s, at: at)
        tab.panes.insertArrangedSubview(s, at: at)
        s.start(in: directory, original: original)
        activate(s, focus: true)
        DispatchQueue.main.async { tab.panes.equalize() }
    }

    private func activate(_ s: TerminalSession, focus: Bool) {
        active = s
        activeTab = tabs.first { $0.sessions.contains { $0 === s } }
        for t in tabs { t.panes.isHidden = t !== activeTab }
        refresh()
        if focus { DispatchQueue.main.async { s.focus() } }
    }

    /// End a shell; closing the last one hides the terminal.
    private func kill(_ s: TerminalSession) {
        guard let ti = tabs.firstIndex(where: { $0.sessions.contains { $0 === s } }) else { return }
        let tab = tabs[ti]
        let si = tab.sessions.firstIndex { $0 === s }!
        s.terminate()
        tab.sessions.remove(at: si)
        s.removeFromSuperview()
        var next: TerminalSession?
        if tab.sessions.isEmpty {
            tab.panes.removeFromSuperview()
            tabs.remove(at: ti)
            if !tabs.isEmpty { next = tabs[min(ti, tabs.count - 1)].sessions.first }
        } else {
            tab.panes.equalize()
            next = tab.sessions[min(si, tab.sessions.count - 1)]
        }
        if s !== active, let a = active { next = a }
        if let n = next { activate(n, focus: true) } else { active = nil; activeTab = nil; refresh(); onHide?() }
    }

    /// Rebuild the header title, the split highlight and the tab list.
    private func refresh() {
        title.stringValue = "TERMINAL" + (active.map { $0.shellTitle.isEmpty ? "" : "  ·  " + $0.shellTitle } ?? "")
        for t in tabs { for s in t.sessions { s.highlighted = t.sessions.count > 1 && s === active } }
        tabList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for t in tabs {
            for (i, s) in t.sessions.enumerated() {
                // split tabs are grouped with tree lines, as in VS Code
                let n = t.sessions.count
                let group: TerminalTabRow.Group = n == 1 ? .none : i == 0 ? .first : i == n - 1 ? .last : .middle
                let row = TerminalTabRow(group: group, selected: s === active,
                                         onSelect: { [weak self, weak s] in if let s = s { self?.activate(s, focus: true) } },
                                         onClose: { [weak self, weak s] in if let s = s { self?.kill(s) } })
                tabList.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: tabList.widthAnchor).isActive = true
            }
        }
        let showList = allSessions.count > 1
        if showList == tabListScroll.isHidden {
            tabListScroll.isHidden = !showList
            body.adjustSubviews()
            if showList { body.setPosition(body.bounds.width - 72, ofDividerAt: 0) }
        }
    }

    var hasStarted: Bool { !tabs.isEmpty }
    var count: Int { allSessions.count }
    var tabCount: Int { tabs.count }
    func type(_ text: String) { active?.type(text) }
    func contents() -> String { active?.contents() ?? "" }
    func focus() { active?.focus() }

    @objc private func runClaude() { active?.type("claude\r"); active?.focus() }
    @objc private func addPressed() { addTab() }
    @objc private func splitPressed() { splitActive() }
    @objc private func restartPressed() { active?.start(in: directory, original: original); active?.focus() }
    @objc private func killPressed() { if let a = active { kill(a) } }
    @objc private func hidePressed() { onHide?() }
}

private extension NSSplitView {
    /// Give every pane the same width.
    func equalize() {
        let n = arrangedSubviews.count
        guard n > 1 else { return }
        let w = bounds.width - dividerThickness * CGFloat(n - 1)
        for i in 0..<(n - 1) { setPosition(w * CGFloat(i + 1) / CGFloat(n) + dividerThickness * CGFloat(i), ofDividerAt: i) }
    }
}

/// A row in the tab list: a terminal icon and a close button.
private final class TerminalTabRow: NSView {
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private let close: NSButton
    private let selected: Bool
    private let group: Group
    private var tracking: NSTrackingArea?
    enum Group { case none, first, middle, last }

    init(group: Group, selected: Bool, onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onSelect = onSelect; self.onClose = onClose; self.selected = selected; self.group = group
        close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Kill terminal") ?? NSImage(), target: nil, action: nil)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = selected ? Theme.accentSoft.cgColor : NSColor.clear.cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: "terminal", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        icon.contentTintColor = NSColor(white: 1, alpha: selected ? 0.85 : 0.5)
        close.isBordered = false; close.toolTip = "Kill terminal"; close.contentTintColor = NSColor(white: 1, alpha: 0.6)
        close.symbolConfiguration = .init(pointSize: 9, weight: .medium)
        close.target = self; close.action = #selector(closePressed)
        close.isHidden = !selected
        for v in [icon, close] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: group == .none ? 12 : 20),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), close.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if selected {   // accent bar on the left edge of the active row
            let edge = NSView(); edge.wantsLayer = true; edge.layer?.backgroundColor = Theme.accent.cgColor
            edge.translatesAutoresizingMaskIntoConstraints = false
            addSubview(edge)
            NSLayoutConstraint.activate([
                edge.leadingAnchor.constraint(equalTo: leadingAnchor), edge.widthAnchor.constraint(equalToConstant: 2),
                edge.topAnchor.constraint(equalTo: topAnchor), edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // split tabs only: the tree line grouping the tab's terminals
    override func draw(_ dirtyRect: NSRect) {
        guard group != .none else { return }
        let x: CGFloat = 10, mid = bounds.midY
        let top = group == .first ? mid : bounds.maxY, bottom = group == .last ? mid : bounds.minY
        NSColor(white: 1, alpha: 0.3).setFill()
        NSRect(x: x, y: bottom, width: 1, height: top - bottom).fill()
        if group != .middle { NSRect(x: x, y: mid, width: 5, height: 1).fill() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { close.isHidden = false }
    override func mouseExited(with event: NSEvent) { close.isHidden = !selected }
    override func mouseDown(with event: NSEvent) { onSelect() }
    @objc private func closePressed() { onClose() }
}

/// One shell. In a split tab the active one is marked by an accent line along its top.
final class TerminalSession: NSView, LocalProcessTerminalViewDelegate {
    private let term = LocalProcessTerminalView(frame: .zero)
    private let marker = NSView()
    private var started = false
    private(set) var shellTitle = ""
    private var directory: String = NSHomeDirectory()
    var onTitle: (() -> Void)?
    var highlighted = false { didSet { marker.isHidden = !highlighted } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = termBackground.cgColor

        term.processDelegate = self
        term.nativeBackgroundColor = termBackground
        term.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        term.font = Theme.mono(12)
        term.caretViewTracksFocus = true
        marker.wantsLayer = true; marker.layer?.backgroundColor = Theme.accent.cgColor; marker.isHidden = true

        for v in [term, marker] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6), term.trailingAnchor.constraint(equalTo: trailingAnchor),
            term.topAnchor.constraint(equalTo: topAnchor, constant: 4), term.bottomAnchor.constraint(equalTo: bottomAnchor),
            marker.leadingAnchor.constraint(equalTo: leadingAnchor), marker.trailingAnchor.constraint(equalTo: trailingAnchor),
            marker.topAnchor.constraint(equalTo: topAnchor), marker.heightAnchor.constraint(equalToConstant: 2),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Start (or restart in a new folder) the shell.
    func start(in dir: String, original o: String?) {
        directory = dir; shellTitle = ""
        if started { term.terminate() }
        started = true
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        env["MANIMBLE_DECK"] = dir
        if let o = o { env["MANIMBLE_ORIGINAL_DECK"] = o }
        let extra = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)).joined(separator: ":")
        let shell = env["SHELL"] ?? "/bin/zsh"
        term.startProcess(executable: shell, args: ["-l"], environment: env.map { "\($0.key)=\($0.value)" },
                          execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: dir)
        onTitle?()
    }

    func terminate() { if started { term.terminate() } }
    func type(_ text: String) { term.send(txt: text) }
    func contents() -> String { String(data: term.getTerminal().getBufferAsData(), encoding: .utf8) ?? "" }
    func focus() { window?.makeFirstResponder(term) }

    // MARK: LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title t: String) {
        if !t.isEmpty, t != shellTitle { shellTitle = t; onTitle?() }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        term.feed(text: "\r\n[process finished — press ↻ to start a new shell]\r\n")
    }
}

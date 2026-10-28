import AppKit
import SwiftTerm


func barButton(_ symbol: String, _ tip: String, _ target: AnyObject, _ sel: Selector) -> NSButton {
    let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: target, action: sel)
    b.isBordered = false; b.toolTip = tip; b.contentTintColor = Theme.ink(0.6)
    b.symbolConfiguration = .init(pointSize: 11, weight: .medium)
    return b
}

/// One terminal tab: one shell, or several split side by side.
private final class TerminalTab {
    let panes = GrabSplitView()
    let number: Int
    var sessions: [TerminalSession] = []
    weak var lastActive: TerminalSession?
    init(number: Int) { self.number = number; panes.isVertical = true; panes.dividerStyle = .thin }
}

/// The terminals, VS Code style: tabs of login shells in the working copy of the deck (e.g. `claude` in one,
/// a plain shell in another); a tab can be split. The tabs themselves are listed in the bottom drawer's tab strip.
final class TerminalPanel: NSView {
    private let content = NSView()
    private var tabs: [TerminalTab] = []
    private var activeTab: TerminalTab?
    private weak var active: TerminalSession?
    private var directory: String = NSHomeDirectory()
    private var original: String?
    private var focusObservation: NSKeyValueObservation?
    /// The last shell was killed.
    var onHide: (() -> Void)?
    /// The tabs, their titles or the active one changed.
    var onChange: (() -> Void)?
    /// Buttons acting on the active terminal, shown in the drawer's header while a terminal tab is up.
    let actions = NSStackView()
    private let runButton = NSButton(title: "", target: nil, action: nil)
    /// Agent commands found on the login shell's PATH; nil until the first check finishes.
    private var installed: Set<String>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        Theme.layerColors(self) { $0.layer?.backgroundColor = Theme.codeBackground.cgColor }
        runButton.target = self; runButton.action = #selector(runAgent)
        runButton.bezelStyle = .inline; runButton.controlSize = .small; runButton.font = Theme.font(11, .medium)
        runButton.contentTintColor = Theme.accent
        let chooser = barButton("chevron.down", "Choose the AI coding agent", self, #selector(chooseAgent(_:)))
        chooser.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        let run = NSStackView(views: [runButton, chooser]); run.spacing = 2
        updateRunButton()
        for v in [run,
                  barButton("square.split.2x1", "Split terminal (⌘\\)", self, #selector(splitPressed)),
                  barButton("arrow.clockwise", "Restart shell", self, #selector(restartPressed)),
                  barButton("trash", "Kill terminal", self, #selector(killPressed))] { actions.addArrangedSubview(v) }
        actions.spacing = 10; actions.alignment = .centerY
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
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
        if tabs.isEmpty { addTab(); checkInstalled() } else { allSessions.forEach { $0.start(in: dir, original: o) } }
    }

    /// Open a new tab with a fresh shell and switch to it.
    func addTab() {
        let used = Set(tabs.map(\.number))
        let tab = TerminalTab(number: (1...).first { !used.contains($0) }!)
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
        activeTab?.lastActive = s
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

    /// Mark the active split and tell the drawer to redraw its tabs.
    private func refresh() {
        for t in tabs { for s in t.sessions { s.highlighted = t.sessions.count > 1 && s === active } }
        onChange?()
    }

    // MARK: tabs, for the drawer's tab strip

    /// "Terminal 1", "Terminal 2", … with the shell's own title as a tooltip.
    var tabTitles: [(title: String, tip: String)] {
        tabs.map { t in ("Terminal \(t.number)" + (t.sessions.count > 1 ? " ×\(t.sessions.count)" : ""),
                         t.sessions.map(\.shellTitle).filter { !$0.isEmpty }.joined(separator: "  ·  ")) }
    }
    var activeTabIndex: Int? { activeTab.flatMap { a in tabs.firstIndex { $0 === a } } }
    func selectTab(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        if let s = tabs[i].lastActive ?? tabs[i].sessions.first { activate(s, focus: true) }
    }
    /// Kill every shell of a tab.
    func closeTab(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        for s in tabs[i].sessions.reversed() { kill(s) }
    }

    var hasStarted: Bool { !tabs.isEmpty }
    var count: Int { allSessions.count }
    var tabCount: Int { tabs.count }
    func type(_ text: String) { active?.type(text) }
    func contents() -> String { active?.contents() ?? "" }
    func focus() { active?.focus() }

    // MARK: Run agent

    private var agent: String {
        get { UserDefaults.standard.string(forKey: "terminal.agent") ?? "claude" }
        set { UserDefaults.standard.set(newValue, forKey: "terminal.agent"); updateRunButton() }
    }
    private func updateRunButton() {
        let name = agent.split(separator: " ").first.map(String.init) ?? agent
        runButton.title = "Run \(name)"
        runButton.toolTip = "Type `\(agent)` into the active terminal"
    }

    /// Which agents are on the PATH of an interactive login shell (where nvm, npm and Homebrew usually add themselves).
    private func checkInstalled(then done: (() -> Void)? = nil) {
        let names = Set(AIAgent.all.map(\.command) + [agent.split(separator: " ").first.map(String.init) ?? agent])
        let script = "for c in \(names.sorted().joined(separator: " ")); do command -v $c >/dev/null 2>&1 && echo \"@@$c\"; done"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            p.arguments = ["-ilc", script]
            var env = ProcessInfo.processInfo.environment
            let extra = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            env["PATH"] = (extra + (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)).joined(separator: ":")
            p.environment = env
            p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            var found: Set<String>?
            if (try? p.run()) != nil {
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationReason == .exit {
                    found = Set((String(data: data, encoding: .utf8) ?? "").split(separator: "\n")
                        .filter { $0.hasPrefix("@@") }.map { String($0.dropFirst(2)) })
                }
            }
            DispatchQueue.main.async { if let f = found { self.installed = f }; done?() }
        }
    }

    @objc private func runAgent() {
        let cmd = agent, name = cmd.split(separator: " ").first.map(String.init) ?? cmd
        let go = { [weak self] in
            guard let self = self else { return }
            if let i = self.installed, !i.contains(name) { self.offerInstall(name) } else { self.active?.type(cmd + "\r"); self.active?.focus() }
        }
        if installed == nil || installed?.contains(name) == false { checkInstalled(then: go) } else { go() }
    }

    /// The agent isn't on the PATH: say how to get it, and type the install command (unsent) if there is one.
    private func offerInstall(_ name: String) {
        let a = AIAgent.all.first { $0.command == name }
        let alert = NSAlert()
        alert.messageText = "\(a?.title ?? name) isn't installed"
        alert.informativeText = a.map { "Install it with:\n\n\($0.install)\n\nthen sign in the first time you run it." }
            ?? "`\(name)` wasn't found on your shell's PATH."
        if a != nil { alert.addButton(withTitle: "Type Install Command") }
        alert.addButton(withTitle: a != nil ? "Cancel" : "OK")
        guard let w = window else { return }
        alert.beginSheetModal(for: w) { [weak self] r in
            guard let self = self, let a = a, r == .alertFirstButtonReturn else { return }
            self.active?.type(a.install); self.active?.focus()
        }
    }

    @objc private func chooseAgent(_ sender: NSButton) {
        let menu = NSMenu()
        for a in AIAgent.all {
            let title = a.title + (installed.map { $0.contains(a.command) ? "" : "  (not installed)" } ?? "")
            let item = NSMenuItem(title: title, action: #selector(pickAgent(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = a.command; item.state = agent == a.command ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let isCustom = !AIAgent.all.contains { $0.command == agent }
        let custom = NSMenuItem(title: isCustom ? "Custom: \(agent)…" : "Custom Command…", action: #selector(customAgent), keyEquivalent: "")
        custom.target = self; custom.state = isCustom ? .on : .off
        menu.addItem(custom)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
        if installed == nil { checkInstalled() }
    }

    @objc private func pickAgent(_ item: NSMenuItem) {
        guard let c = item.representedObject as? String else { return }
        agent = c; runAgent()
    }

    @objc private func customAgent() {
        let alert = NSAlert()
        alert.messageText = "Custom agent command"
        alert.informativeText = "Typed into the active terminal by the Run button, e.g. `aider` or `claude --model opus`."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.stringValue = agent
        alert.accessoryView = field
        alert.addButton(withTitle: "Use"); alert.addButton(withTitle: "Cancel")
        guard let w = window else { return }
        alert.beginSheetModal(for: w) { [weak self] r in
            let c = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self = self, r == .alertFirstButtonReturn, !c.isEmpty else { return }
            self.agent = c; self.checkInstalled()
        }
        DispatchQueue.main.async { w.attachedSheet?.makeFirstResponder(field) }
    }

    @objc private func splitPressed() { splitActive() }
    @objc private func restartPressed() { active?.start(in: directory, original: original); active?.focus() }
    @objc private func killPressed() { if let a = active { kill(a) } }
}

/// The coding agents the terminal's Run button knows how to start.
private struct AIAgent {
    let title, command, install: String
    static let all = [
        AIAgent(title: "Claude Code", command: "claude", install: "curl -fsSL https://claude.ai/install.sh | bash"),
        AIAgent(title: "Codex (OpenAI)", command: "codex", install: "npm install -g @openai/codex"),
        AIAgent(title: "Gemini CLI (Google)", command: "gemini", install: "npm install -g @google/gemini-cli"),
    ]
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
        term.processDelegate = self
        // the terminal keeps resolved RGB colours, so set them again on a light/dark switch
        Theme.layerColors(self) { s in
            s.layer?.backgroundColor = Theme.codeBackground.cgColor
            let fg = Theme.dynamic(light: NSColor(white: 0.12, alpha: 1), dark: NSColor(white: 0.9, alpha: 1))
            s.term.nativeBackgroundColor = Theme.codeBackground.usingColorSpace(.sRGB) ?? Theme.codeBackground
            s.term.nativeForegroundColor = fg.usingColorSpace(.sRGB) ?? fg
            s.term.needsDisplay = true
        }
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

import AppKit
import SwiftTerm

/// A docked terminal (login shell in the working copy of the deck), e.g. to run `claude` next to the slides.
final class TerminalPanel: NSView, LocalProcessTerminalViewDelegate {
    private let term = LocalProcessTerminalView(frame: .zero)
    private let title = NSTextField(labelWithString: "TERMINAL")
    private var started = false
    private var directory: String = NSHomeDirectory()
    var onHide: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let bg = NSColor(srgbRed: 0.098, green: 0.102, blue: 0.125, alpha: 1)
        layer?.backgroundColor = bg.cgColor

        // header bar
        let bar = NSView(); bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(srgbRed: 0.125, green: 0.13, blue: 0.158, alpha: 1).cgColor
        title.font = Theme.font(10, .semibold); title.textColor = NSColor(white: 1, alpha: 0.5)
        title.lineBreakMode = .byTruncatingMiddle
        func btn(_ symbol: String, _ tip: String, _ sel: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(), target: self, action: sel)
            b.isBordered = false; b.toolTip = tip; b.contentTintColor = NSColor(white: 1, alpha: 0.6)
            b.symbolConfiguration = .init(pointSize: 11, weight: .medium)
            return b
        }
        let claude = NSButton(title: "Run claude", target: self, action: #selector(runClaude))
        claude.bezelStyle = .inline; claude.controlSize = .small; claude.font = Theme.font(11, .medium)
        claude.contentTintColor = Theme.accent
        let restart = btn("arrow.clockwise", "Restart shell", #selector(restart))
        let hide = btn("xmark", "Hide terminal", #selector(hidePressed))
        let row = NSStackView(views: [title, NSView(), claude, restart, hide]); row.spacing = 10; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14), row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        term.processDelegate = self
        term.nativeBackgroundColor = bg
        term.nativeForegroundColor = NSColor(white: 0.9, alpha: 1)
        term.font = Theme.mono(12)
        term.caretViewTracksFocus = true

        let stack = NSStackView(views: [bar, term]); stack.orientation = .vertical; stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        bar.translatesAutoresizingMaskIntoConstraints = false
        term.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 28), bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            term.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Start (or restart in a new folder) the shell.
    func start(in dir: String, original: String?) {
        directory = dir
        title.stringValue = "TERMINAL  ·  " + dir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        if started { term.terminate() }
        started = true
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"; env["COLORTERM"] = "truecolor"
        env["MANIMBLE_DECK"] = dir
        if let o = original { env["MANIMBLE_ORIGINAL_DECK"] = o }
        let extra = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)).joined(separator: ":")
        let shell = env["SHELL"] ?? "/bin/zsh"
        term.startProcess(executable: shell, args: ["-l"], environment: env.map { "\($0.key)=\($0.value)" },
                          execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: dir)
    }

    var hasStarted: Bool { started }
    func type(_ text: String) { term.send(txt: text) }
    func contents() -> String { String(data: term.getTerminal().getBufferAsData(), encoding: .utf8) ?? "" }
    func focus() { window?.makeFirstResponder(term) }

    @objc private func runClaude() { term.send(txt: "claude\r"); focus() }
    @objc private func restart() { start(in: directory, original: ProcessInfo.processInfo.environment["MANIMBLE_ORIGINAL_DECK"]); focus() }
    @objc private func hidePressed() { onHide?() }

    // MARK: LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title t: String) {
        if !t.isEmpty { title.stringValue = "TERMINAL  ·  " + t }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        term.feed(text: "\r\n[process finished — press ↻ to start a new shell]\r\n")
    }
}

import AppKit

/// First-launch setup. Checks for what the engine needs (a Python that imports manim, a TeX with manim's packages)
/// and, once the user agrees, installs whatever is missing with install_dependencies.sh. What is already on the
/// Mac is used as it is.
final class Setup: NSObject, NSWindowDelegate {
    enum TeX: String { case ok, missing, packages }
    struct Status { var python: String?; var tex: TeX }

    /// Set by "Not Now" when only LaTeX is missing, so later launches don't ask again (Manimble ▸ Install Dependencies… still does).
    static let skipTeXKey = "setupSkipTeX"
    static let tinyTeXBin = NSHomeDirectory() + "/Library/TinyTeX/bin/universal-darwin"

    static var script: String? {
        let fm = FileManager.default
        if let r = Bundle.main.resourcePath, fm.fileExists(atPath: r + "/install_dependencies.sh") { return r + "/install_dependencies.sh" }
        // running from a checkout (apps/macos)
        let local = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("install_dependencies.sh").path
        return fm.fileExists(atPath: local) ? local : nil
    }

    /// Slow (it starts Pythons to see whether they import manim): call it off the main thread.
    static func check() -> Status {
        // MANIMBLE_TEST_SETUP=python,tex|packages[,install]: the first check reports those as missing (and presses Install)
        if let t = ProcessInfo.processInfo.environment["MANIMBLE_TEST_SETUP"], !testUsed {
            testUsed = true
            let parts = t.split(separator: ",")
            return Status(python: parts.contains("python") ? nil : Engine.findPython(),
                          tex: parts.contains("tex") ? .missing : parts.contains("packages") ? .packages : checkTeX())
        }
        return Status(python: Engine.findPython(), tex: checkTeX())
    }
    private static var testUsed = false

    private static func checkTeX() -> TeX {
        guard let script = script else { return .ok }      // nothing to install with, so nothing to offer
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script, "check-tex"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return .ok }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return TeX(rawValue: out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .ok
    }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let status: Status
    private let pythonBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let texBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let installButton = NSButton(title: "Install", target: nil, action: nil)
    private let otherPythonButton = NSButton(title: "Use Another Python…", target: nil, action: nil)
    private let laterButton = NSButton(title: "Not Now", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let stepLabel = NSTextField(labelWithString: "")
    private let log = NSTextView()
    private let logScroll = NSScrollView()
    private var proc: Process?
    private var pending = ""
    private var installedPython = false
    /// Called when the window goes away; true when a Python was installed (the engine can start now).
    var onDone: ((Bool) -> Void)?
    var onChoosePython: (() -> Void)?

    init(status: Status) {
        self.status = status
        super.init()
        window.title = "Set Up Manimble"
        window.delegate = self
        window.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: status.python == nil || status.tex != .ok
                                ? "Manimble needs a few more things" : "Everything Manimble needs is installed")
        title.font = .boldSystemFont(ofSize: 15)
        let needsPassword = status.tex == .packages && !texIsUserOwned()
        let body = NSTextField(wrappingLabelWithString:
            "Manimble draws slides with Manim, which runs in Python and uses LaTeX for formulas. "
            + "Ticked items are downloaded and installed into your Library folder; anything already on this Mac is used as it is."
            + (needsPassword ? " Adding packages to your TeX installation asks for an administrator password." : ""))
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 512

        func row(_ box: NSButton, _ name: String, found: String?, offer: String) -> NSView {
            box.title = name
            box.state = .on
            box.isEnabled = found == nil
            let detail = NSTextField(wrappingLabelWithString: found.map { "Found: \($0)" } ?? offer)
            detail.textColor = .secondaryLabelColor
            detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            detail.preferredMaxLayoutWidth = 490
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 490).isActive = true
            let v = NSStackView(views: [box, detail])
            v.orientation = .vertical; v.alignment = .leading; v.spacing = 2
            v.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            detail.translatesAutoresizingMaskIntoConstraints = false
            detail.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20).isActive = true
            return v
        }
        let pythonRow = row(pythonBox, "Python with Manim", found: status.python,
                            offer: "Downloads about 150 MB; uses about 600 MB in ~/Library/Application Support/Manimble.")
        let texFound: String? = status.tex == .ok ? "a LaTeX installation with the packages Manim uses" : nil
        let texOffer = status.tex == .packages
            ? "Your LaTeX lacks packages Manim uses (standalone, preview, dvisvgm, …); they will be added."
            : "TinyTeX: downloads about 80 MB; uses about 270 MB in ~/Library/TinyTeX. Only formulas need it."
        let texRow = row(texBox, status.tex == .packages ? "LaTeX packages" : "LaTeX", found: texFound, offer: texOffer)

        progress.style = .bar; progress.isIndeterminate = true; progress.isHidden = true
        progress.minValue = 0; progress.maxValue = 100
        stepLabel.isHidden = true
        stepLabel.lineBreakMode = .byTruncatingTail
        log.isEditable = false
        log.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        log.textContainerInset = NSSize(width: 4, height: 4)
        log.isVerticallyResizable = true
        log.autoresizingMask = [.width]
        log.textContainer?.widthTracksTextView = true
        logScroll.documentView = log
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.isHidden = true
        logScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true

        installButton.target = self; installButton.action = #selector(install)
        installButton.keyEquivalent = "\r"
        installButton.isEnabled = (status.python == nil || status.tex != .ok) && Setup.script != nil
        otherPythonButton.target = self; otherPythonButton.action = #selector(chooseOtherPython)
        otherPythonButton.isHidden = status.python != nil
        laterButton.target = self; laterButton.action = #selector(later)
        if status.python == nil { laterButton.title = "Quit" }
        else if status.python != nil && status.tex == .ok { laterButton.title = "Close" }
        let buttons = NSStackView(views: [otherPythonButton, NSView(), laterButton, installButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [title, body, pythonRow, texRow, progress, stepLabel, logScroll, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.setCustomSpacing(18, after: body)
        stack.setCustomSpacing(18, after: texRow)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        for v in [progress, stepLabel, logScroll, buttons] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 560),
        ])
        window.contentView = content
        fit()
    }

    /// Size the window to its content (the progress bar and log appear once an install starts).
    private func fit() {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        if ProcessInfo.processInfo.environment["MANIMBLE_TEST_SETUP"]?.contains("install") == true, installButton.isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.install() }
        }
    }

    /// TinyTeX (or any TeX the user can write to) takes packages without a password.
    private func texIsUserOwned() -> Bool {
        FileManager.default.isWritableFile(atPath: NSHomeDirectory() + "/Library/TinyTeX/tlpkg")
    }

    @objc private func install() {
        guard let script = Setup.script else { return }
        var steps: [String] = []
        if status.python == nil && pythonBox.state == .on { steps.append("python") }
        if status.tex != .ok && texBox.state == .on { steps.append(status.tex == .missing ? "tex" : "tex-packages") }
        guard !steps.isEmpty else { finish(); return }
        for b in [installButton, otherPythonButton, pythonBox, texBox] { b.isEnabled = false }
        laterButton.title = "Cancel"
        progress.isHidden = false; stepLabel.isHidden = false; logScroll.isHidden = false
        fit()
        progress.isIndeterminate = true; progress.startAnimation(nil)
        stepLabel.textColor = .labelColor
        run(script, steps)
    }

    /// Run the script once per step, one after another, streaming its output into the window.
    private func run(_ script: String, _ steps: [String]) {
        guard let step = steps.first else {
            progress.stopAnimation(nil)
            stepLabel.stringValue = "Done."
            finish()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script, step]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { self?.consume(s) }
        }
        p.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self = self, self.proc === p else { return }
                self.proc = nil
                if p.terminationStatus == 0 {
                    if step == "python" { self.installedPython = true }
                    self.run(script, Array(steps.dropFirst()))
                } else {
                    self.failed()
                }
            }
        }
        do { try p.run(); proc = p } catch { append("\(error)\n"); failed() }
    }

    /// curl's progress bar redraws one line with \r; "@@ " lines name the step.
    private func consume(_ s: String) {
        pending += s
        while let r = pending.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n")) {
            let line = String(pending[..<r.lowerBound])
            pending.removeSubrange(..<r.upperBound)
            if line.hasPrefix("@@ ") {
                stepLabel.stringValue = String(line.dropFirst(3)) + "…"
                progress.isIndeterminate = true; progress.startAnimation(nil)
                append(line.dropFirst(3) + "\n")
            } else if let m = line.range(of: #"[0-9.]+%$"#, options: .regularExpression), line.hasPrefix("#") || line.hasPrefix(" ") {
                progress.isIndeterminate = false
                progress.doubleValue = Double(line[m].dropLast()) ?? 0
            } else if !line.isEmpty {
                append(line + "\n")
            }
        }
    }

    private func append(_ s: String) {
        log.textStorage?.append(NSAttributedString(string: s, attributes: [.font: log.font!, .foregroundColor: NSColor.textColor]))
        log.scrollToEndOfDocument(nil)
    }

    private func failed() {
        progress.stopAnimation(nil); progress.isHidden = true
        stepLabel.stringValue = "Installation did not finish. The log above says why; you can try again."
        stepLabel.textColor = .systemRed
        installButton.title = "Try Again"; installButton.isEnabled = true
        pythonBox.isEnabled = status.python == nil
        texBox.isEnabled = status.tex != .ok
        otherPythonButton.isEnabled = true
        laterButton.title = status.python == nil && !installedPython ? "Quit" : "Not Now"
    }

    private func finish() {
        let done = onDone
        onDone = nil
        window.close()
        done?(installedPython)
    }

    @objc private func chooseOtherPython() {
        let choose = onChoosePython
        finish()
        choose?()
    }

    @objc private func later() {
        if let p = proc {
            proc = nil
            p.terminate()
            failed()
            stepLabel.stringValue = "Cancelled."
            return
        }
        if status.python == nil && !installedPython { NSApp.terminate(nil); return }
        if status.tex != .ok { UserDefaults.standard.set(true, forKey: Setup.skipTeXKey) }
        finish()
    }

    func windowWillClose(_ n: Notification) {
        proc?.terminate()
        proc = nil
        let done = onDone
        onDone = nil
        // the title bar's close button with no Python to run: same as the Quit button (the app can do nothing without one)
        if done != nil && status.python == nil && !installedPython { NSApp.terminate(nil); return }
        done?(installedPython)
    }
}

import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// What a Python plot runs: its own code, or a .py file it links to.
struct PlotSpec: Codable, Equatable {
    var code: String?
    var file: String?          // relative to the deck folder, or absolute
}

/// Python plots: a picture on a slide drawn by running some Python. The picture is an ordinary ImageMobject of
/// `<stem>@<hash>.png` in the deck folder, and `<stem>.plot.json` beside it says what to run, so the plot can be
/// run again later; each new output gets its own file, so running it again is an edit like any other (⌘Z undoes it).
enum PythonPlot {
    static let template = """
        import numpy as np
        import matplotlib.pyplot as plt

        x = np.linspace(0, 2 * np.pi, 200)
        fig, ax = plt.subplots(figsize=(6, 4))
        ax.plot(x, np.sin(x), label="sin x")
        ax.plot(x, np.cos(x), label="cos x")
        ax.legend()
        """

    /// The plot editor on screen (a popover keeps no owner of its own while shown).
    static var popover: NSPopover?

    /// The plot a picture belongs to: `plot1@1a2b3c4d.png` next to `plot1.plot.json`.
    static func plot(ofImage path: String) -> (dir: URL, stem: String)? {
        let u = URL(fileURLWithPath: path), name = u.deletingPathExtension().lastPathComponent
        guard u.pathExtension.lowercased() == "png", let at = name.lastIndex(of: "@") else { return nil }
        let stem = String(name[..<at]), dir = u.deletingLastPathComponent()
        guard !stem.isEmpty, FileManager.default.fileExists(atPath: specURL(dir, stem).path) else { return nil }
        return (dir, stem)
    }
    static func specURL(_ dir: URL, _ stem: String) -> URL { dir.appendingPathComponent(stem + ".plot.json") }
    static func load(_ dir: URL, _ stem: String) -> PlotSpec? {
        (try? Data(contentsOf: specURL(dir, stem))).flatMap { try? JSONDecoder().decode(PlotSpec.self, from: $0) }
    }
    static func save(_ spec: PlotSpec, _ dir: URL, _ stem: String) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(spec).write(to: specURL(dir, stem), options: .atomic)
    }
    static func freeStem(in dir: URL) -> String {
        var n = 1
        while FileManager.default.fileExists(atPath: specURL(dir, "plot\(n)").path) { n += 1 }
        return "plot\(n)"
    }

    // MARK: the Python that runs plots

    private static var found: String?
    /// The interpreter chosen in the plot editor, else the first that can import matplotlib (Manimble's own, then
    /// the login shell's and the usual installs), else Manimble's own.
    static func python() -> String {
        if let p = UserDefaults.standard.string(forKey: "plotPython"), FileManager.default.isExecutableFile(atPath: p) { return p }
        if let p = found { return p }
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let p = ProcessInfo.processInfo.environment["MANIMBLE_PYTHON"] { candidates.append(p) }
        if let p = UserDefaults.standard.string(forKey: "python") { candidates.append(p) }
        candidates.append(Workspace.base.appendingPathComponent("python/bin/python").path)
        let own = candidates.first { fm.isExecutableFile(atPath: $0) }
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        sh.arguments = ["-lc", "which -a python3 python 2>/dev/null"]
        let pipe = Pipe()
        sh.standardOutput = pipe; sh.standardError = FileHandle.nullDevice
        if (try? sh.run()) != nil {
            candidates += (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").split(separator: "\n").map(String.init)
        }
        candidates += ["miniforge3", "miniconda3", "anaconda3", "mambaforge"].map { "\(home)/\($0)/bin/python" }
        candidates += ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        var seen = Set<String>()
        for c in candidates where fm.isExecutableFile(atPath: c) && !Engine.isDeveloperToolsStub(c) && seen.insert(c).inserted {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: c); p.arguments = ["-c", "import matplotlib.pyplot"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            if p.terminationStatus == 0 { found = c; return c }
        }
        found = own ?? "/usr/bin/python3"
        return found!
    }

    // MARK: running

    /// Runs the script, then saves the last matplotlib figure, unless the code saved a picture to
    /// MANIMBLE_PLOT_OUT itself (plotly, seaborn's own savefig, PIL …).
    private static let runner = """
        import os, runpy, sys
        script, out = sys.argv[1], sys.argv[2]
        sys.argv = [script]
        sys.path.insert(0, os.path.dirname(os.path.abspath(script)))
        try:
            runpy.run_path(script, run_name="__main__")
        except Exception as e:                  # the traceback from the plot's own code on, not this runner's
            import traceback
            tb = e.__traceback__
            while tb is not None and tb.tb_frame.f_code.co_filename != script:
                tb = tb.tb_next
            traceback.print_exception(type(e), e, tb or e.__traceback__)
            sys.exit(1)
        plt = sys.modules.get("matplotlib.pyplot")
        if not os.path.exists(out) and plt is not None and plt.get_fignums():
            plt.gcf().savefig(out, dpi=200, bbox_inches="tight")
        if not os.path.exists(out):
            sys.exit("The code ran but drew nothing: plot with matplotlib, or save a PNG to os.environ['MANIMBLE_PLOT_OUT'].")
        """

    enum RunError: Error, LocalizedError {
        case failed(String)
        /// The code imports seaborn and this Python doesn't have it (offered to install).
        case noSeaborn(python: String, log: String)
        var errorDescription: String? {
            switch self {
            case .failed(let m): return m
            case .noSeaborn(_, let log): return log
            }
        }
    }

    /// `python -m pip install seaborn` into the Python that runs plots; returns pip's output if it failed.
    static func installSeaborn(_ python: String) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = ["-m", "pip", "install", "--disable-pip-version-check", "seaborn"]
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "PYTHONPATH"); env.removeValue(forKey: "PYTHONHOME")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { return "Could not start \(python): \(error.localizedDescription)" }
            let log = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return nil }
            let text = String(decoding: log, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.split(separator: "\n").suffix(14).joined(separator: "\n")
        }.value
    }

    /// Runs a plot and returns the PNG it drew. Its own code runs in the deck folder, a linked file in its folder.
    static func run(_ spec: PlotSpec, deck: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { () throws -> Data in
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("manimble-plot-" + UUID().uuidString)
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            let script: URL, cwd: URL
            if let f = spec.file, !f.isEmpty {
                script = f.hasPrefix("/") ? URL(fileURLWithPath: f) : deck.appendingPathComponent(f)
                guard fm.fileExists(atPath: script.path) else { throw RunError.failed("Can't find \(script.path)") }
                cwd = script.deletingLastPathComponent()
            } else {
                script = tmp.appendingPathComponent("plot.py")
                try (spec.code ?? "").write(to: script, atomically: true, encoding: .utf8)
                cwd = deck
            }
            let run = tmp.appendingPathComponent("run.py"), out = tmp.appendingPathComponent("out.png")
            try runner.write(to: run, atomically: true, encoding: .utf8)
            let python = python()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: python)
            p.arguments = [run.path, script.path, out.path]
            p.currentDirectoryURL = cwd
            var env = ProcessInfo.processInfo.environment
            env["MPLBACKEND"] = "Agg"; env["MANIMBLE_PLOT_OUT"] = out.path; env["PYTHONUNBUFFERED"] = "1"
            env.removeValue(forKey: "PYTHONPATH"); env.removeValue(forKey: "PYTHONHOME")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            do { try p.run() } catch { throw RunError.failed("Could not start \(python): \(error.localizedDescription)") }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: killer)
            let log = pipe.fileHandleForReading.readDataToEndOfFile()        // until the process closes it
            p.waitUntilExit()
            killer.cancel()
            if p.terminationStatus == 0, let png = try? Data(contentsOf: out) { return png }
            let text = String(decoding: log, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            var msg = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(14).joined(separator: "\n")
            if p.terminationReason == .uncaughtSignal { msg = "The code ran for 5 minutes and was stopped.\n" + msg }
            if text.contains("No module named 'seaborn'") { throw RunError.noSeaborn(python: python, log: msg) }
            if text.contains("No module named") {
                msg += "\n\nThis Python (\(python)) is missing a package: install it there, or choose another Python below."
            }
            throw RunError.failed(msg.isEmpty ? "The code failed (exit \(p.terminationStatus))." : msg)
        }.value
    }

    /// Writes a plot's output into the deck folder as `<stem>@<hash>.png` (once per distinct picture) and returns its name.
    static func store(_ png: Data, stem: String, in dir: URL) throws -> String {
        let h = SHA256.hash(data: png).prefix(4).map { String(format: "%02x", $0) }.joined()
        let name = "\(stem)@\(h).png", u = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: u.path) { try png.write(to: u, options: .atomic) }
        return name
    }
}

/// The plot editor: code, or a linked .py file. Clicking away runs it; Cancel leaves everything as it was.
final class PlotEditor: NSViewController, NSPopoverDelegate {
    var onDone: ((PlotSpec) -> Void)?
    private let initial: PlotSpec, error: String?, deck: URL
    private var cancelled = false
    private let mode = NSSegmentedControl(labels: ["Code", "File"], trackingMode: .selectOne, target: nil, action: nil)
    private let codeView = NSTextView()
    private let codeScroll = NSScrollView()
    private let fileField = NSTextField()
    private lazy var fileRow = NSStackView(views: [fileField, NSButton(title: "Choose…", target: self, action: #selector(chooseFile))])
    private let pythonLabel = NSTextField(labelWithString: "")

    init(spec: PlotSpec, error: String?, deck: URL) {
        initial = spec; self.error = error; self.deck = deck
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    var spec: PlotSpec {
        mode.selectedSegment == 1 ? PlotSpec(code: nil, file: fileField.stringValue.trimmingCharacters(in: .whitespaces))
                                  : PlotSpec(code: codeView.string, file: nil)
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "Python Plot")
        title.font = .boldSystemFont(ofSize: 13)
        mode.target = self; mode.action = #selector(modeChanged)
        mode.selectedSegment = initial.file != nil ? 1 : 0
        let head = NSStackView(views: [title, NSView(), mode])

        codeView.isRichText = false
        codeView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        codeView.isAutomaticQuoteSubstitutionEnabled = false; codeView.isAutomaticDashSubstitutionEnabled = false
        codeView.isAutomaticTextReplacementEnabled = false; codeView.isAutomaticSpellingCorrectionEnabled = false
        codeView.isContinuousSpellCheckingEnabled = false; codeView.smartInsertDeleteEnabled = false
        codeView.allowsUndo = true
        codeView.textContainerInset = NSSize(width: 4, height: 6)
        codeView.isVerticallyResizable = true; codeView.autoresizingMask = [.width]
        codeView.string = initial.code ?? PythonPlot.template
        codeScroll.documentView = codeView
        codeScroll.hasVerticalScroller = true; codeScroll.borderType = .bezelBorder
        codeScroll.heightAnchor.constraint(equalToConstant: 260).isActive = true

        fileField.placeholderString = "/path/to/plot.py"
        fileField.stringValue = initial.file.map { $0.hasPrefix("/") ? $0 : deck.appendingPathComponent($0).path } ?? ""
        fileField.lineBreakMode = .byTruncatingHead

        let hint = NSTextField(wrappingLabelWithString: "Runs when you click away. The last matplotlib (or seaborn) figure becomes the picture "
                               + "(or save one to os.environ[\"MANIMBLE_PLOT_OUT\"]). Hover the plot and press ▶ to run it again.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor

        pythonLabel.font = .systemFont(ofSize: 11); pythonLabel.textColor = .secondaryLabelColor
        pythonLabel.lineBreakMode = .byTruncatingMiddle
        pythonLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let change = NSButton(title: "Change…", target: self, action: #selector(choosePython)); change.controlSize = .small
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        let render = NSButton(title: "Render", target: self, action: #selector(renderPressed)); render.keyEquivalent = "\r"
        render.keyEquivalentModifierMask = [.command]
        render.toolTip = "Run the code now (⌘↩)"
        let foot = NSStackView(views: [pythonLabel, change, NSView(), cancel, render])

        var rows: [NSView] = [head, codeScroll, fileRow, hint]
        if let e = error {
            let l = NSTextField(wrappingLabelWithString: e)
            l.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular); l.textColor = .systemRed; l.isSelectable = true
            let sv = NSScrollView(); sv.documentView = l; sv.hasVerticalScroller = true; sv.drawsBackground = false
            l.frame = NSRect(x: 0, y: 0, width: 520, height: l.sizeThatFits(NSSize(width: 520, height: 10_000)).height)
            sv.heightAnchor.constraint(equalToConstant: min(140, l.frame.height + 4)).isActive = true
            rows.append(sv)
        }
        rows.append(foot)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for v in rows { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        stack.widthAnchor.constraint(equalToConstant: 560).isActive = true
        view = stack
        modeChanged()
        updatePython()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(mode.selectedSegment == 0 ? codeView : fileField)
    }

    private func updatePython() {
        let p = UserDefaults.standard.string(forKey: "plotPython")
        pythonLabel.stringValue = "Python: " + (p ?? "automatic (one with matplotlib)")
        pythonLabel.toolTip = p
    }

    @objc private func modeChanged() {
        codeScroll.isHidden = mode.selectedSegment == 1
        fileRow.isHidden = mode.selectedSegment == 0
    }
    @objc private func chooseFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pythonScript]
        p.message = "Choose a Python file that draws the plot"
        guard p.runModal() == .OK, let u = p.url else { return }
        fileField.stringValue = u.path
    }
    @objc private func choosePython() {
        let p = NSOpenPanel()
        p.message = "Choose the Python that runs plots (a python3 with matplotlib)"
        p.treatsFilePackagesAsDirectories = true; p.showsHiddenFiles = true
        guard p.runModal() == .OK, let u = p.url else { return }
        UserDefaults.standard.set(u.path, forKey: "plotPython")
        updatePython()
    }
    @objc private func cancelPressed() { cancelled = true; PythonPlot.popover?.performClose(nil) }
    @objc private func renderPressed() { PythonPlot.popover?.performClose(nil) }

    func popoverDidClose(_ notification: Notification) {
        if PythonPlot.popover === notification.object as? NSPopover { PythonPlot.popover = nil }
        if !cancelled { onDone?(spec) }
    }
}

extension MainController {
    /// The plot (folder and stem) an object on the slide shows, if it is a Python plot.
    func plotOf(_ oid: Int) -> (dir: URL, stem: String)? {
        guard let o = scene?.objects?[String(oid)], o.kind == "image", let p = o.imagePath else { return nil }
        return PythonPlot.plot(ofImage: p)
    }

    @objc func insertPythonPlotPressed() {
        guard sceneName != nil, workspace != nil else { return }
        openPlotEditor(PlotSpec(code: PythonPlot.template, file: nil), oid: nil, error: nil)
    }

    func editPlot(_ oid: Int) {
        guard let (dir, stem) = plotOf(oid), let spec = PythonPlot.load(dir, stem) else { return }
        openPlotEditor(spec, oid: oid, error: nil)
    }

    /// ▶ on a plot: run its code again; the picture changes only if the output did.
    func rerunPlot(_ oid: Int) {
        guard let (dir, stem) = plotOf(oid), let spec = PythonPlot.load(dir, stem) else { return }
        commitPlot(spec, oid: oid, force: true)
    }

    func openPlotEditor(_ spec: PlotSpec, oid: Int?, error: String?) {
        guard let ws = workspace else { return }
        PythonPlot.popover?.close()
        let ed = PlotEditor(spec: spec, error: error, deck: ws.work)
        ed.onDone = { [weak self] s in
            guard let self = self, s.code?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || s.file?.isEmpty == false else { return }
            DispatchQueue.main.async { self.commitPlot(s, oid: oid, force: false) }
        }
        let pop = NSPopover()
        pop.behavior = .semitransient          // a click on the slide runs it; the file panels don't close it
        pop.contentViewController = ed; pop.delegate = ed
        var anchor = CGRect(x: canvas.bounds.midX - 1, y: canvas.bounds.midY - 1, width: 2, height: 2)
        if let oid = oid, let b = canvas.stop?.box(of: oid) { anchor = canvas.viewRect(b).intersection(canvas.bounds) }
        if anchor.isNull || anchor.isEmpty { anchor = CGRect(x: canvas.bounds.midX - 1, y: canvas.bounds.midY - 1, width: 2, height: 2) }
        PythonPlot.popover = pop
        pop.show(relativeTo: anchor, of: canvas, preferredEdge: .maxX)
    }

    /// Run a plot and put what it draws on the slide: a new picture, or the plot `oid` pointed at its new output.
    func commitPlot(_ spec: PlotSpec, oid: Int?, force: Bool) {
        guard let ws = workspace, let name = sceneName else { return }
        let old = oid.flatMap { plotOf($0) }
        if let (dir, stem) = old, !force, PythonPlot.load(dir, stem) == spec { return }
        var spec = spec
        // a file inside the deck's own folders is kept relative (and stays live through the working copy's links)
        if let f = spec.file, f.hasPrefix(ws.original.path + "/") {
            let rel = String(f.dropFirst(ws.original.path.count + 1))
            if rel.contains("/") { spec.file = rel }
        }
        Task { @MainActor in
            busyText = "Running the plot's code…"
            busy += 1
            let result: Result<Data, Error>
            do { result = .success(try await PythonPlot.run(spec, deck: ws.work)) } catch { result = .failure(error) }
            busy -= 1; busyText = "Rendering…"
            let png: Data
            switch result {
            case .failure(PythonPlot.RunError.noSeaborn(let python, _)):
                offerSeaborn(python, spec, oid: oid)
                return
            case .failure(let e):
                toast("The plot's code failed", error: true)
                if sceneName == name { openPlotEditor(spec, oid: oid, error: e.localizedDescription) }
                return
            case .success(let d): png = d
            }
            let dir = old?.dir ?? ws.work, stem = old?.stem ?? PythonPlot.freeStem(in: ws.work)
            let file: String
            do {
                file = try PythonPlot.store(png, stem: stem, in: dir)
                try PythonPlot.save(spec, dir, stem)
            } catch { alert("Could not save the plot", "\(error)"); return }
            guard let oid = oid else {
                insert(kind: "image", extra: ["file": file, "path": dir.appendingPathComponent(file).path, "width": 6])
                return
            }
            if scene?.objects?[String(oid)]?.image == file { toast("The plot is up to date"); return }
            submit { [weak self] in
                guard let self = self else { return }
                self.busy += 1
                let r = try? await self.engine.call("insert_many", ["scene": name, "stop": self.stopIndex, "items": [[String: Any]](),
                                                                     "replace_image": ["oid": oid, "file": file]], as: EditResult.self)
                self.busy -= 1
                guard let res = r, res.ok == true else { self.toast(r?.error ?? "could not update the plot", error: true); return }
                self.lastChanged = res.changed
                await self.loadScene(name, keepStop: true)
                await self.reloadState()
                self.toast("Plot updated · ⌘Z goes back to the old one")
            }
        }
    }
}

extension MainController {
    /// The plot needs seaborn and the Python running it lacks it: offer to pip install it there and run the plot again.
    func offerSeaborn(_ python: String, _ spec: PlotSpec, oid: Int?) {
        let a = NSAlert()
        a.messageText = "Seaborn isn't installed"
        a.informativeText = "This plot uses seaborn, which the Python that runs plots doesn't have:\n\(python)\n\n"
            + "Manimble can install it there with “pip install seaborn” and then run the plot again."
        a.addButton(withTitle: "Install Seaborn")
        a.addButton(withTitle: "Close")
        let name = sceneName
        let reopen = { [weak self] (error: String) in
            guard let self = self, self.sceneName == name else { return }
            self.openPlotEditor(spec, oid: oid, error: error)
        }
        a.beginSheetModal(for: window) { [weak self] r in
            guard let self = self else { return }
            guard r == .alertFirstButtonReturn else {
                reopen("ModuleNotFoundError: No module named 'seaborn'\n\nInstall seaborn into \(python), or choose another Python below.")
                return
            }
            Task { @MainActor in
                self.busyText = "Installing seaborn…"
                self.busy += 1
                let failure = await PythonPlot.installSeaborn(python)
                self.busy -= 1
                if let f = failure {
                    self.toast("Could not install seaborn", error: true)
                    reopen("pip install seaborn failed:\n" + f)
                    return
                }
                self.toast("Seaborn installed")
                self.commitPlot(spec, oid: oid, force: true)
            }
        }
    }
}

extension MainController {
    /// MANIMBLE_TEST_PLOT=<deck>: insert a plot through the editor, hover it for ▶, run changed code again, run it
    /// unchanged, then a failing run (the editor comes back with the error); plot.log and plot-*.png in MANIMBLE_TEST_OUT.
    /// MANIMBLE_TEST_PLOT=delete: insert a plot, then click it and press ⌫ (brings the window to the front).
    func plotTest() {
        let out = ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? NSTemporaryDirectory()
        var lines: [String] = []
        func log(_ s: String) { lines.append(s); try? lines.joined(separator: "\n").write(toFile: out + "/plot.log", atomically: true, encoding: .utf8) }
        func shot(_ n: String, _ v: NSView? = nil) {
            guard let v = v ?? window.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/plot-\(n).png"))
        }
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        func plots() -> [(Int, String)] {
            (scene?.objects ?? [:]).compactMap { k, o in o.kind == "image" && plotOf(Int(k) ?? -1) != nil ? (Int(k) ?? -1, o.image ?? "") : nil }
        }
        func until(_ what: String, _ ok: () -> Bool) async -> Bool {
            for _ in 0..<240 { if ok() && busy == 0 { return true }; await wait(0.5) }
            log("timed out waiting for \(what)"); return false
        }
        /// A real click on the plot through the window (the window made key), then ⌫: the plot goes.
        func clickAndDelete(_ oid: Int) async {
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            await wait(0.5)
            guard let b = canvas.stop?.box(of: oid) else { log("no box"); return }
            let r = canvas.viewRect(b), at = canvas.convert(CGPoint(x: r.midX, y: r.midY), to: nil)
            for kind in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: kind, location: at, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(e) }
            }
            await wait(0.5)
            log("clicked: selection \(canvas.selection.map(String.init) ?? "nil") firstResponder \(window.firstResponder.map { "\(type(of: $0))" } ?? "nil")")
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51) {
                NSApp.sendEvent(e)
            }
            for _ in 0..<20 where !plots().isEmpty { await wait(0.5) }
            log("after ⌫: plots \(plots().count)")
        }
        Task { @MainActor in
            await wait(1)
            log("python: \(PythonPlot.python())")
            insertPythonPlotPressed()
            await wait(1)
            log("editor open: \(PythonPlot.popover?.isShown == true)")
            if let v = PythonPlot.popover?.contentViewController?.view { shot("editor", v) }
            PythonPlot.popover?.performClose(nil)               // clicking away runs it
            guard await until("the plot", { !plots().isEmpty }), let (oid, file) = plots().first else { log("no plot"); log("done"); return }
            log("inserted: oid \(oid) \(file)")
            if ProcessInfo.processInfo.environment["MANIMBLE_TEST_PLOT"] == "delete" { await clickAndDelete(oid); log("done"); return }
            canvas.hover = oid; canvas.pan = canvas.pan
            let button = canvas.subviews.first { ($0 as? NSButton)?.toolTip?.contains("plot's code") == true }
            log("run button shown: \(button.map { !$0.isHidden } ?? false) at \(button.map { NSStringFromRect($0.frame) } ?? "-")")
            shot("hover")
            guard let (dir, stem) = plotOf(oid), var spec = PythonPlot.load(dir, stem) else { log("no spec"); log("done"); return }
            spec.code = (spec.code ?? "").replacingOccurrences(of: "np.sin(x)", with: "np.sin(3 * x)")
            try? PythonPlot.save(spec, dir, stem)
            (button as? NSButton)?.performClick(nil)            // ▶
            _ = await until("the new picture", { plots().first?.1 != file })
            log("after ▶ with new code: \(plots().first?.1 ?? "-")")
            shot("rerun")
            let now = plots().first?.1
            rerunPlot(oid)
            await wait(1); _ = await until("the run", { true })
            log("after ▶ unchanged: \(plots().first?.1 ?? "-") same=\(plots().first?.1 == now)")
            commitPlot(PlotSpec(code: "raise ValueError('boom')", file: nil), oid: oid, force: true)
            _ = await until("the error", { PythonPlot.popover?.isShown == true })
            log("editor back with the error: \(PythonPlot.popover?.isShown == true)")
            if let v = PythonPlot.popover?.contentViewController?.view { shot("error", v) }
            log("spec kept: \(PythonPlot.load(dir, stem)?.code?.contains("sin(3 * x)") == true)")
            log("done")
        }
    }
}

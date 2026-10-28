import AppKit
import AVFoundation

/// The Script panel, in the edit panel's place (top right): the script of the build on screen as a list of steps
/// (Speak, Mouse, Pause) with Add buttons, and the deck's voice settings. A click on a step plays it on the slide
/// the way PowerPoint previews an animation; Play Build plays them all.
@MainActor
final class ScriptPane: NSView {
    let store: ScriptStore
    var onClose: (() -> Void)?
    var onPlay: ((ScriptStep) -> Void)?
    var onPlayAll: (() -> Void)?
    var onStopPlaying: (() -> Void)?
    /// Start or end setting a move's track on the slide (nil ends it).
    var onCapture: ((String?) -> Void)?
    var onSelect: ((String?) -> Void)?
    private(set) var scene: String?
    private(set) var build = 0
    private(set) var selected: String?
    var capturing: String? { didSet { for r in rows { r.capturing = r.id == capturing } } }
    var playing = false { didSet { playAll.title = playing ? "Stop" : "Play Build"; playAll.image = NSImage(systemSymbolName: playing ? "stop.fill" : "play.fill", accessibilityDescription: nil) } }

    private let where_ = NSTextField(labelWithString: "")
    private let column = NSStackView()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let playAll = NSButton(title: "Play Build", target: nil, action: nil)
    private let voicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Beside the voice menu when the chosen voice needs an account: connect it (or shows it is connected).
    private let accountButton = NSButton(title: "", target: nil, action: nil)
    private var accountObserver: Any?
    private let rateSlider = NSSlider(value: 0.5, minValue: 0.3, maxValue: 0.7, target: nil, action: nil)
    private let holdField = NSTextField(string: "")
    private var rows: [ScriptRow] = []
    /// The canvas: a click on it (off the slide's capture overlay) puts the selection away.
    weak var canvasView: NSView?
    private var clickMonitor: Any?

    init(store: ScriptStore) {
        self.store = store
        super.init(frame: .zero)
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            MainActor.assumeIsolated { self?.clickAway(e) }
            return e
        }
        wantsLayer = true
        Theme.layerColors(self) { $0.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
        // title row, like the feedback list's: symbol, "Script", Done
        let img = NSImageView(image: NSImage(systemSymbolName: "scroll", accessibilityDescription: nil)
                              ?? NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil) ?? NSImage())
        img.symbolConfiguration = .init(pointSize: 15, weight: .medium); img.contentTintColor = Theme.accent
        let title = NSTextField(labelWithString: "Script"); title.font = Theme.font(14, .semibold)
        let sub = NSTextField(labelWithString: "words to speak and pointer moves"); sub.font = Theme.mono(10); sub.textColor = .tertiaryLabelColor
        let col = NSStackView(views: [title, sub]); col.orientation = .vertical; col.alignment = .leading; col.spacing = 0
        col.setContentHuggingPriority(.init(1), for: .horizontal)
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .texturedRounded; done.controlSize = .small; done.font = Theme.font(11)
        done.toolTip = "Back to the edit panel"
        let titleRow = NSStackView(views: [img, col, done])
        titleRow.orientation = .horizontal; titleRow.alignment = .centerY; titleRow.spacing = 9
        let rule = NSBox(); rule.boxType = .separator; rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        where_.font = Theme.font(10, .semibold); where_.textColor = .secondaryLabelColor
        // add buttons
        func add(_ t: String, _ sym: String, _ tip: String, _ sel: Selector) -> NSButton {
            let b = NSButton(title: t, target: self, action: sel)
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: t); b.imagePosition = .imageLeading
            b.bezelStyle = .texturedRounded; b.controlSize = .small; b.font = Theme.font(11); b.toolTip = tip
            return b
        }
        let addRow = NSStackView(views: [
            add("Speak", "text.bubble", "Add words to be read out by text to speech", #selector(addSpeak)),
            add("Mouse", "cursorarrow.motionlines", "Add a pointer move: click on the slide for where it goes, or drag to trace its track", #selector(addMove)),
            add("Pause", "pause.circle", "Add a pause", #selector(addPause)),
        ])
        addRow.orientation = .horizontal; addRow.spacing = 6
        column.orientation = .vertical; column.alignment = .leading; column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        empty.font = Theme.font(12); empty.textColor = .secondaryLabelColor
        empty.stringValue = "No script for this build. Add words to speak, pointer moves and pauses; Play ▸ Scripted Presentation plays them build by build."
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(column)
        let scroll = NSScrollView()
        scroll.documentView = doc; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        // footer: play the build, voice, rate, hold
        playAll.target = self; playAll.action = #selector(playAllPressed)
        playAll.bezelStyle = .texturedRounded; playAll.controlSize = .small; playAll.font = Theme.font(11)
        playAll.imagePosition = .imageLeading
        playAll.toolTip = "Play every step of this build on the slide"
        playing = false
        voicePopup.controlSize = .small; voicePopup.font = Theme.font(11)
        voicePopup.target = self; voicePopup.action = #selector(voiceChosen)
        voicePopup.toolTip = "The voice that reads the script (System Settings ▸ Accessibility ▸ Spoken Content adds more; "
            + "voices marked ✦ come from an online service and need an account)"
        accountButton.bezelStyle = .inline; accountButton.isBordered = false; accountButton.font = Theme.font(11)
        accountButton.target = self; accountButton.action = #selector(connectAccount)
        accountButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        fillVoices()
        accountObserver = NotificationCenter.default.addObserver(forName: CloudVoice.accountsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fillVoices() }
        }
        rateSlider.controlSize = .small; rateSlider.target = self; rateSlider.action = #selector(rateChanged)
        rateSlider.floatValue = store.rate; rateSlider.toolTip = "Speaking rate"
        holdField.controlSize = .small; holdField.font = Theme.font(11); holdField.alignment = .right
        holdField.stringValue = String(format: "%g", store.hold)
        holdField.target = self; holdField.action = #selector(holdChanged)
        holdField.toolTip = "How long a build with no script stays up in a scripted presentation"
        holdField.widthAnchor.constraint(equalToConstant: 36).isActive = true
        func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.font = Theme.font(11); l.textColor = .secondaryLabelColor; return l }
        let voiceRow = NSStackView(views: [label("Voice"), voicePopup, accountButton]); voiceRow.spacing = 6
        voicePopup.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let rateRow = NSStackView(views: [label("Speaking speed"), rateSlider]); rateRow.spacing = 6
        let holdRow = NSStackView(views: [label("Builds with no script stay up"), holdField, label("s")]); holdRow.spacing = 4
        let footRule = NSBox(); footRule.boxType = .separator; footRule.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let foot = NSStackView(views: [playAll, voiceRow, rateRow, holdRow])
        foot.orientation = .vertical; foot.alignment = .leading; foot.spacing = 6
        for v in [titleRow, rule, where_, addRow, scroll, footRule, foot] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), titleRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            rule.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: 10),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            where_.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 10),
            where_.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), where_.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            addRow.topAnchor.constraint(equalTo: where_.bottomAnchor, constant: 8),
            addRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: addRow.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            footRule.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            footRule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), footRule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            foot.topAnchor.constraint(equalTo: footRule.bottomAnchor, constant: 8),
            foot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), foot.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            foot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            voiceRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            rateSlider.widthAnchor.constraint(equalToConstant: 140),
            voicePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
            column.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8), column.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: doc.topAnchor), column.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -8),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func fillVoices() {
        voicePopup.removeAllItems()
        voicePopup.addItem(withTitle: "System Voice")
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang) || $0.identifier == store.voice }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
        for v in voices {
            let q = v.quality == .premium ? " (Premium)" : v.quality == .enhanced ? " (Enhanced)" : ""
            voicePopup.addItem(withTitle: "\(v.name)\(q) · \(v.language)")
            voicePopup.lastItem?.representedObject = v.identifier
        }
        // the online services' voices, each marked with the AI sparkle: they need an account
        let sparkle = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Needs an account")
        for service in CloudVoiceService.allCases {
            voicePopup.menu?.addItem(.separator())
            let head = NSMenuItem(title: service.name + (service.connected ? "" : " · needs an account"), action: nil, keyEquivalent: "")
            head.isEnabled = false
            voicePopup.menu?.addItem(head)
            var list = service.voices
            if let c = CloudVoice(store.voice), c.service == service, !list.contains(where: { $0.id == c.voice }) { list.append((c.voice, c.voice)) }
            for v in list {
                voicePopup.addItem(withTitle: "\(v.name) · \(service.name)")
                voicePopup.lastItem?.representedObject = CloudVoice(service: service, voice: v.id).identifier
                voicePopup.lastItem?.image = sparkle
                voicePopup.lastItem?.indentationLevel = 1
            }
        }
        if let id = store.voice, let i = voicePopup.itemArray.firstIndex(where: { $0.representedObject as? String == id }) {
            voicePopup.selectItem(at: i)
        } else { voicePopup.selectItem(at: 0) }
        updateAccountButton()
    }

    /// Shown only for a voice that needs an account: "Connect…" until it is, then a quiet "Connected".
    private func updateAccountButton() {
        guard let c = CloudVoice(store.voice) else { accountButton.isHidden = true; return }
        accountButton.isHidden = false
        let on = c.service.connected
        let title = on ? "Connected" : "Connect…"
        accountButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.font(11), .foregroundColor: on ? NSColor.secondaryLabelColor : NSColor.linkColor,
            .underlineStyle: on ? 0 : NSUnderlineStyle.single.rawValue])
        accountButton.image = NSImage(systemSymbolName: on ? "checkmark.circle" : "sparkles", accessibilityDescription: nil)
        accountButton.imagePosition = .imageLeading
        accountButton.contentTintColor = on ? .secondaryLabelColor : .linkColor
        accountButton.toolTip = on ? "\(c.service.name) is connected. Click to change the key or disconnect."
            : "Sign in to \(c.service.name) with an API key so this voice can read the script"
    }

    @objc private func connectAccount() {
        guard let c = CloudVoice(store.voice) else { return }
        CloudVoiceAccount.connect(c.service, from: window) { [weak self] _ in self?.fillVoices() }
    }

    @objc private func close() { onClose?() }
    @objc private func voiceChosen() {
        store.setVoice(voicePopup.selectedItem?.representedObject as? String)
        updateAccountButton()
    }
    @objc private func rateChanged() { store.setRate(rateSlider.floatValue) }
    @objc private func holdChanged() {
        let v = min(60, max(0, holdField.doubleValue))
        holdField.stringValue = String(format: "%g", v)
        store.setHold(v)
    }
    @objc private func playAllPressed() { playing ? onStopPlaying?() : onPlayAll?() }

    @objc private func addSpeak() { add(.speak) }
    @objc private func addMove() { add(.move) }
    @objc private func addPause() { add(.pause) }
    private func add(_ k: ScriptStep.Kind) {
        guard let scene else { return }
        let s = store.add(k, scene: scene, build: build, after: selected)
        select(s.id, play: false)
        if let r = rows.first(where: { $0.id == s.id }) {
            r.scrollToVisible(r.bounds)
            if k == .speak { r.focusText() }
        }
        if k == .move { onCapture?(s.id) }      // straight to the slide for where it goes
    }

    /// The build on screen changed (or the panel opened): list its script.
    func show(scene: String?, build: Int, label: String) {
        where_.stringValue = label.uppercased()
        guard scene != self.scene || build != self.build else { return }
        self.scene = scene; self.build = build
        selected = nil
        rebuild()
    }

    /// The store changed: rebuild when steps came or went, else refresh the rows in place (the one being typed in
    /// keeps its text and focus).
    func reload() {
        let steps = scene.map { store.steps(scene: $0, build: build) } ?? []
        if steps.map(\.id) != rows.map(\.id) { rebuild(); return }
        for (r, s) in zip(rows, steps) { r.update(s, number: number(of: s, in: steps)) }
    }

    private func number(of s: ScriptStep, in steps: [ScriptStep]) -> Int {
        (steps.filter { $0.kind == .move }.firstIndex { $0.id == s.id } ?? -1) + 1
    }

    private func rebuild() {
        for v in column.arrangedSubviews { column.removeArrangedSubview(v); v.removeFromSuperview() }
        rows = []
        let steps = scene.map { store.steps(scene: $0, build: build) } ?? []
        if steps.isEmpty {
            column.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -8).isActive = true
            column.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 0, right: 0)
        } else { column.edgeInsets = NSEdgeInsets() }
        if let s = selected, !steps.contains(where: { $0.id == s }) { selected = nil }
        for (i, s) in steps.enumerated() {
            let r = ScriptRow(step: s, index: i + 1, moveNumber: number(of: s, in: steps))
            r.selected = s.id == selected
            r.capturing = s.id == capturing
            r.onClick = { [weak self] in self?.select(s.id, play: s.kind != .speak) }
            r.onFocus = { [weak self] in self?.select(s.id, play: false) }
            r.onPlay = { [weak self] in self?.select(s.id, play: true) }
            r.onDelete = { [weak self] in self?.remove(s.id) }
            r.onShift = { [weak self] d in self?.store.shift(s.id, by: d) }
            r.onCapture = { [weak self] in
                guard let self else { return }
                self.select(s.id, play: false)
                self.onCapture?(self.capturing == s.id ? nil : s.id)
            }
            r.onChange = { [weak self] change in self?.store.update(s.id, change) }
            column.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            rows.append(r)
        }
        onSelect?(selected)
    }

    private func remove(_ id: String) {
        if capturing == id { onCapture?(nil) }
        if selected == id { selected = nil }
        store.remove(id)
    }

    /// A click that lands on neither a step nor the capture overlay: stop editing, drop the selection (and so the
    /// track on the slide).
    private func clickAway(_ e: NSEvent) {
        guard !isHidden, let win = window, e.window === win, let content = win.contentView else { return }
        let hit = content.hitTest(content.convert(e.locationInWindow, from: nil))
        var v = hit
        while let x = v { if x is ScriptRow { return }; v = x.superview }
        let inPane = hit?.isDescendant(of: self) ?? false
        let inCanvas = !inPane && (hit?.isDescendant(of: canvasView ?? self) ?? false) && !(hit is ScriptLayer)
        guard inPane || inCanvas else { return }
        if inPane, hit is NSControl || hit is NSTextView { return }     // buttons, sliders and fields keep their job
        win.makeFirstResponder(nil)
        if inCanvas, capturing != nil { onCapture?(nil) }
        if selected != nil { select(nil, play: false) }
    }

    func select(_ id: String?, play: Bool) {
        selected = id
        for r in rows { r.selected = r.id == id }
        onSelect?(id)
        if play, let id, let s = store.step(id) { onPlay?(s) }
    }
}

/// One step of the Script panel: a header (number, kind, play, reorder, delete) over the step's own controls.
@MainActor
private final class ScriptRow: NSView, NSTextFieldDelegate {
    let id: String
    var onClick: (() -> Void)?
    var onFocus: (() -> Void)?
    var onPlay: (() -> Void)?
    var onDelete: (() -> Void)?
    var onShift: ((Int) -> Void)?
    var onCapture: (() -> Void)?
    var onChange: (((inout ScriptStep) -> Void) -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    var capturing = false { didSet { captureButton?.state = capturing ? .on : .off; captureButton?.title = capturing ? "Setting on Slide…" : "Set on Slide" } }
    private let kind: ScriptStep.Kind
    private let heading = NSTextField(labelWithString: "")
    private var text: NSTextField?
    private var seconds: NSTextField?
    private var stepper: NSStepper?
    private var summary: NSTextField?
    private var captureButton: NSButton?
    private var speedPopup: NSPopUpButton?
    private var noiseSlider: NSSlider?

    init(step s: ScriptStep, index: Int, moveNumber: Int) {
        id = s.id; kind = s.kind
        super.init(frame: .zero)
        let sym = s.kind == .speak ? "text.bubble" : s.kind == .move ? "cursorarrow.motionlines" : "pause.circle"
        let icon = NSImageView(image: NSImage(systemSymbolName: sym, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Theme.accent
        heading.font = Theme.font(11, .semibold)
        heading.stringValue = "\(index). " + (s.kind == .speak ? "Speak" : s.kind == .move ? "Mouse \(moveNumber)" : "Pause")
        heading.setContentHuggingPriority(.init(1), for: .horizontal)
        func small(_ sym: String, _ tip: String, _ sel: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: sym, accessibilityDescription: tip) ?? NSImage(), target: self, action: sel)
            b.isBordered = false; b.toolTip = tip
            b.widthAnchor.constraint(equalToConstant: 18).isActive = true
            return b
        }
        let head = NSStackView(views: [icon, heading, small("play.fill", "Play this step on the slide", #selector(playPressed)),
                                       small("chevron.up", "Earlier", #selector(upPressed)), small("chevron.down", "Later", #selector(downPressed)),
                                       small("trash", "Delete this step", #selector(deletePressed))])
        head.orientation = .horizontal; head.spacing = 5
        var body: [NSView] = [head]
        switch s.kind {
        case .speak:
            let t = NSTextField(string: s.text)
            t.placeholderString = "Words to speak…"
            t.font = Theme.font(12)
            t.cell?.wraps = true; t.cell?.isScrollable = false; t.usesSingleLineMode = false
            t.maximumNumberOfLines = 0
            t.delegate = self
            t.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
            t.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            text = t; body.append(t)
        case .pause:
            let f = NSTextField(string: String(format: "%g", s.seconds)); f.controlSize = .small; f.font = Theme.font(11); f.alignment = .right
            f.widthAnchor.constraint(equalToConstant: 44).isActive = true
            f.target = self; f.action = #selector(secondsTyped)
            let st = NSStepper(); st.controlSize = .small; st.minValue = 0; st.maxValue = 600; st.increment = 1; st.doubleValue = s.seconds
            st.target = self; st.action = #selector(secondsStepped)
            let l1 = NSTextField(labelWithString: "Wait"), l2 = NSTextField(labelWithString: "seconds")
            for l in [l1, l2] { l.font = Theme.font(11); l.textColor = .secondaryLabelColor }
            let row = NSStackView(views: [l1, f, st, l2]); row.spacing = 4
            seconds = f; stepper = st; body.append(row)
        case .move:
            let sum = NSTextField(labelWithString: ""); sum.font = Theme.font(11); sum.textColor = .secondaryLabelColor
            let cap = NSButton(title: "Set on Slide", target: self, action: #selector(capturePressed))
            cap.setButtonType(.pushOnPushOff); cap.bezelStyle = .texturedRounded; cap.controlSize = .small; cap.font = Theme.font(11)
            cap.image = NSImage(systemSymbolName: "scope", accessibilityDescription: nil); cap.imagePosition = .imageLeading
            cap.toolTip = "Click on the slide for where the pointer goes, or drag on it to trace the track it follows"
            let r1 = NSStackView(views: [cap, sum]); r1.spacing = 8
            let sp = NSPopUpButton(frame: .zero, pullsDown: false); sp.controlSize = .small; sp.font = Theme.font(11)
            for (t, v) in ScriptStep.speeds { sp.addItem(withTitle: t); sp.lastItem?.representedObject = v }
            sp.target = self; sp.action = #selector(speedChosen)
            sp.toolTip = "How fast the pointer travels"
            let nz = NSSlider(value: s.noise, minValue: 0, maxValue: 1, target: self, action: #selector(noiseChanged))
            nz.controlSize = .small; nz.toolTip = "Wobble: a little noise in the movement, like a hand on a mouse"
            nz.widthAnchor.constraint(equalToConstant: 70).isActive = true
            let l1 = NSTextField(labelWithString: "Speed"), l2 = NSTextField(labelWithString: "Wobble")
            for l in [l1, l2] { l.font = Theme.font(11); l.textColor = .secondaryLabelColor }
            let r2 = NSStackView(views: [l1, sp, l2, nz]); r2.spacing = 5
            summary = sum; captureButton = cap; speedPopup = sp; noiseSlider = nz
            body += [r1, r2]
        }
        let stack = NSStackView(views: body)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
        ])
        if let t = text { t.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true }
        update(s, number: moveNumber)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(_ s: ScriptStep, number: Int) {
        if s.kind == .move { heading.stringValue = heading.stringValue.replacingOccurrences(of: #"Mouse \d+"#, with: "Mouse \(number)", options: .regularExpression) }
        if let t = text, t.currentEditor() == nil, t.stringValue != s.text { t.stringValue = s.text }
        if let f = seconds, f.currentEditor() == nil { f.stringValue = String(format: "%g", s.seconds); stepper?.doubleValue = s.seconds }
        if let sum = summary {
            let pts = s.points
            if pts.isEmpty { sum.stringValue = "no target yet" }
            else if pts.count == 1 { sum.stringValue = String(format: "to %.0f%%, %.0f%%", pts[0].x * 100, pts[0].y * 100) }
            else { sum.stringValue = "traced track, \(pts.count) points" }
            sum.textColor = pts.isEmpty ? .systemOrange : .secondaryLabelColor
        }
        if let sp = speedPopup {
            let i = ScriptStep.speeds.enumerated().min { abs($0.element.1 - s.speed) < abs($1.element.1 - s.speed) }?.offset ?? 1
            sp.selectItem(at: i)
        }
        noiseSlider?.doubleValue = s.noise
    }

    func focusText() { if let t = text { window?.makeFirstResponder(t) } }

    func controlTextDidBeginEditing(_ n: Notification) { onFocus?() }

    /// Return starts a new line; clicking away ends the edit.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        textView.insertNewlineIgnoringFieldEditor(nil)
        return true
    }

    func controlTextDidChange(_ n: Notification) {
        guard let t = text else { return }
        let v = t.stringValue
        onChange? { $0.text = v }
    }

    @objc private func playPressed() { onPlay?() }
    @objc private func upPressed() { onShift?(-1) }
    @objc private func downPressed() { onShift?(1) }
    @objc private func deletePressed() { onDelete?() }
    @objc private func capturePressed() { onCapture?() }
    @objc private func secondsTyped() {
        let v = min(600, max(0, seconds?.doubleValue ?? 1)); onChange? { $0.seconds = v }
    }
    @objc private func secondsStepped() { let v = stepper?.doubleValue ?? 1; seconds?.stringValue = String(format: "%g", v); onChange? { $0.seconds = v } }
    @objc private func speedChosen() { let v = speedPopup?.selectedItem?.representedObject as? Double ?? 0.5; onChange? { $0.speed = v } }
    @objc private func noiseChanged() { let v = ((noiseSlider?.doubleValue ?? 0) * 100).rounded() / 100; onChange? { $0.noise = v } }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (selected ? Theme.accentSoft : NSColor.controlBackgroundColor.withAlphaComponent(0.6)).setFill(); p.fill()
        (selected ? Theme.accent : NSColor.separatorColor).setStroke(); p.lineWidth = 1; p.stroke()
    }
    /// A click on the row (not on one of its controls) selects the step and plays it.
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(nil); onClick?() }
}

// MARK: - the editor side

/// What the editor keeps for the script: the store, the panel, the overlay, the preview and the running show.
@MainActor
final class ScriptState {
    var store: ScriptStore?
    var pane: ScriptPane?
    var layer: ScriptLayer?
    var preview: ScriptPerformer?
    var previewTask: Task<Void, Never>?
    var runner: ScriptRunner?
    /// The next animated show is a scripted presentation.
    var autoPending = false
    /// A movie export with the script, waiting for the engine's movie to lay the narration and pointer over.
    var movieExport: ScriptMovieExport?
}

extension MainController {
    /// Open the deck's script alongside its working copy.
    func openScript(_ ws: Workspace) {
        let original = ws.original.appendingPathComponent("script.json")
        let store = ScriptStore(url: ws.work.appendingPathComponent("script.json"),
                                originalHasFile: FileManager.default.fileExists(atPath: original.path))
        store.onChange = { [weak self] in self?.scriptChanged() }
        stopScriptPreview()
        if let p = script.pane { p.removeFromSuperview(); script.pane = nil; formatBar?.script.state = .off }
        script.store = store
        if script.layer == nil {
            let l = ScriptLayer(frame: canvas.bounds)
            l.autoresizingMask = [.width, .height]
            l.slideRect = { [weak self] in self?.canvas.slideRect ?? .zero }
            l.isHidden = true
            l.onCaptured = { [weak self] id, pts in
                guard let self else { return }
                self.script.store?.update(id) { $0.path = pts.map { [Double($0.x), Double($0.y)] } }
                self.setScriptCapture(nil)
                if let s = self.script.store?.step(id) { self.playScriptStep(s) }
            }
            canvas.addSubview(l)
            canvas.scriptLayer = l
            script.layer = l
        }
        syncScriptButton()
    }

    func scriptChanged() {
        updateDocumentState()
        syncScriptButton()
        script.pane?.reload()
        syncScriptLayer()
    }

    func syncScriptButton() {
        formatBar?.script.title = "Script"
    }

    /// The build on screen changed: the panel and the overlay follow it.
    func syncScriptPage() {
        guard let p = script.pane, !p.isHidden else { return }
        let builds = scene?.stops?.count ?? 1
        let label = (sceneName.map { feedbackSlideLabel($0) } ?? "No slide") + (builds > 1 ? " · build \(stopIndex + 1) of \(builds)" : "")
        if p.scene != sceneName || p.build != stopIndex { stopScriptPreview(); setScriptCapture(nil) }
        p.show(scene: sceneName, build: stopIndex, label: label)
        syncScriptLayer()
    }

    private func syncScriptLayer() {
        guard let l = script.layer else { return }
        let open = !(script.pane?.isHidden ?? true)
        l.isHidden = !open
        l.steps = open ? (sceneName.map { script.store?.steps(scene: $0, build: stopIndex) ?? [] } ?? []) : []
        l.selected = script.pane?.selected
    }

    /// "Script": the panel takes the edit panel's place (top right). Again, or Done, puts the edit panel back.
    @objc func viewScript(_ sender: NSButton) {
        if let p = script.pane, !p.isHidden { hideScriptPane(); return }
        guard let store = script.store else { sender.state = .off; return }
        let pane = script.pane ?? ScriptPane(store: store)
        if script.pane == nil {
            pane.translatesAutoresizingMaskIntoConstraints = false
            inspectorHost.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.leadingAnchor.constraint(equalTo: inspectorHost.leadingAnchor), pane.trailingAnchor.constraint(equalTo: inspectorHost.trailingAnchor),
                pane.topAnchor.constraint(equalTo: inspectorHost.topAnchor), pane.bottomAnchor.constraint(equalTo: inspectorHost.bottomAnchor),
            ])
            pane.onClose = { [weak self] in self?.hideScriptPane() }
            pane.onPlay = { [weak self] s in self?.playScriptStep(s) }
            pane.onPlayAll = { [weak self] in self?.playScriptBuild() }
            pane.onStopPlaying = { [weak self] in self?.stopScriptPreview() }
            pane.onCapture = { [weak self] id in self?.setScriptCapture(id) }
            pane.onSelect = { [weak self] id in self?.script.layer?.selected = id }
            pane.canvasView = canvas
            script.pane = pane
        }
        hideFeedbackPane()
        hideBioCartoon()
        inspectorScroll?.isHidden = true
        pane.isHidden = false
        formatBar?.script.state = .on
        if let right = mainSplit?.subviews.last, right.isHidden { right.isHidden = false; mainSplit?.adjustSubviews() }
        syncScriptPage()
    }

    /// The edit panel back in the top right.
    func hideScriptPane() {
        formatBar?.script.state = .off
        stopScriptPreview()
        setScriptCapture(nil)
        guard let p = script.pane, !p.isHidden else { return }
        p.isHidden = true
        syncScriptLayer()
        if (biocartoonPane?.view.isHidden ?? true) && (feedbackPane?.isHidden ?? true) { inspectorScroll?.isHidden = false }
    }

    func setScriptCapture(_ id: String?) {
        script.pane?.capturing = id
        script.layer?.capturing = id
        if id != nil { stopScriptPreview() }
    }

    private func makePreview() -> ScriptPerformer? {
        guard let store = script.store, let l = script.layer else { return nil }
        stopScriptPreview()
        let p = ScriptPerformer()
        p.voice = store.voice; p.rate = store.rate
        p.draw = { [weak l] pt in l?.showPointer(pt) }
        p.slideSize = { [weak l] in l?.slideRect().size ?? CGSize(width: 16, height: 9) }
        script.preview = p
        return p
    }

    /// A click on a step plays it on the slide (a move starts where the build's earlier moves leave the pointer).
    func playScriptStep(_ s: ScriptStep) {
        guard let p = makePreview() else { return }
        p.pointer = script.store?.pointer(before: s.id)
        script.pane?.playing = true
        script.previewTask = Task { @MainActor [weak self] in
            await p.perform(s)
            if s.kind == .move { await p.wait(0.6) }
            self?.endScriptPreview(p)
        }
    }

    /// Play Build: every step of the build on screen, in order.
    func playScriptBuild() {
        guard let name = sceneName, let store = script.store, let p = makePreview() else { return }
        let steps = store.steps(scene: name, build: stopIndex)
        guard !steps.isEmpty else { return }
        script.pane?.playing = true
        script.previewTask = Task { @MainActor [weak self] in
            for s in steps {
                guard !p.stopped else { break }
                self?.script.pane?.select(s.id, play: false)
                await p.perform(s)
            }
            if !p.stopped { await p.wait(0.6) }
            self?.endScriptPreview(p)
        }
    }

    private func endScriptPreview(_ p: ScriptPerformer) {
        guard script.preview === p else { return }
        script.preview = nil; script.previewTask = nil
        script.layer?.showPointer(nil)
        script.pane?.playing = false
    }

    func stopScriptPreview() {
        guard let p = script.preview else { return }
        p.stop()
        script.previewTask?.cancel()
        endScriptPreview(p)
    }

    // MARK: scripted presentation

    @objc func autoPresentFromBeginning() { autoPresent(fromCurrent: false) }
    @objc func autoPresentFromCurrent() { autoPresent(fromCurrent: true) }

    /// Play ▸ Scripted Presentation: the show (animated or stills, as Play shows it) plays itself, reading each
    /// build's script aloud and moving the pointer, then going on to the next build.
    func autoPresent(fromCurrent: Bool) {
        guard player == nil, presenter == nil, animatedPlayer == nil else { return }
        hideScriptPane()
        if script.store?.isEmpty ?? true {
            toast("No script yet: each build stays up \(String(format: "%g", script.store?.hold ?? 3)) s (Script, top right, adds words and pointer moves)")
        }
        if showAnimations { present(fromCurrent: fromCurrent, auto: true) } else { play(fromCurrent: fromCurrent, auto: true) }
    }

    /// Hand a show that has just opened to the script.
    func startScriptRunner(on show: ScriptShow) {
        guard let store = script.store else { return }
        script.runner?.stop()
        let r = ScriptRunner(store: store, show: show)
        r.onEnd = { [weak self, weak r] in if self?.script.runner === r { self?.script.runner = nil } }
        script.runner = r
        r.start()
    }
}

extension MainController {
    /// MANIMBLE_TEST_SCRIPT=1 with the deck as argument: the Script panel, a step of each kind (the move traced on
    /// the slide through window events), a step's preview, then a scripted presentation of the stills show;
    /// script.log and script-*.png in MANIMBLE_TEST_OUT.
    func scriptTest() {
        let out = ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? NSTemporaryDirectory()
        var lines: [String] = []
        func log(_ s: String) { lines.append(s); try? lines.joined(separator: "\n").write(toFile: out + "/script.log", atomically: true, encoding: .utf8) }
        func shot(_ n: String, _ w: NSWindow? = nil) {
            guard let v = (w ?? window).contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "/script-\(n).png"))
        }
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
        var pressed: NSView?
        func mouse(_ type: NSEvent.EventType, _ fx: CGFloat, _ fy: CGFloat) {
            let r = canvas.slideRect
            let p = canvas.convert(CGPoint(x: r.minX + r.width * fx, y: r.maxY - r.height * fy), to: nil)
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  let cv = window.contentView else { return }
            // straight to the view under the point: the window drops clicks sent to it while it is not key (a headless run)
            switch type {
            case .leftMouseDown: pressed = cv.hitTest(cv.convert(p, from: nil)); pressed?.mouseDown(with: e)
            case .leftMouseDragged: pressed?.mouseDragged(with: e)
            case .leftMouseUp: pressed?.mouseUp(with: e); pressed = nil
            default: window.sendEvent(e)
            }
        }
        Task { @MainActor in
            await wait(1.5)
            guard let store = self.script.store, let name = self.sceneName else { log("no store"); return }
            self.viewScript(self.formatBar.script)
            log("pane up: \(!(self.script.pane?.isHidden ?? true)) inspector hidden: \(self.inspectorScroll?.isHidden ?? false) button \(self.formatBar.script.state == .on)")
            log("page: \(self.script.pane?.scene ?? "-") build \(self.script.pane?.build ?? -1)")
            let sp = store.add(.speak, scene: name, build: self.stopIndex)
            store.update(sp.id) { $0.text = "One." }
            // Mouse: Add goes straight to capture; a press-and-release sets a target
            self.script.pane?.perform(Selector(("addMove")))
            await wait(0.3)
            log("capturing: \(self.script.layer?.capturing != nil) row \(self.script.pane?.capturing != nil)")
            shot("capture")
            mouse(.leftMouseDown, 0.8, 0.3); mouse(.leftMouseUp, 0.8, 0.3)
            await wait(0.2)
            let m1 = store.steps(scene: name, build: self.stopIndex).first { $0.kind == .move }
            log("move 1 path: \(m1?.path ?? []) capturing after: \(self.script.layer?.capturing != nil)")
            self.stopScriptPreview()
            // a second move traced by dragging
            let m2 = store.add(.move, scene: name, build: self.stopIndex)
            self.setScriptCapture(m2.id)
            mouse(.leftMouseDown, 0.2, 0.2)
            for k in 1...30 { let t = CGFloat(k) / 30; mouse(.leftMouseDragged, 0.2 + 0.6 * t, 0.2 + 0.5 * t * t) }
            mouse(.leftMouseUp, 0.8, 0.7)
            await wait(0.2)
            log("move 2 points: \(store.step(m2.id)?.points.count ?? 0) last \(store.step(m2.id)?.path.last ?? [])")
            store.update(m2.id) { $0.noise = 0.8; $0.speed = 1 }
            store.add(.pause, scene: name, build: self.stopIndex)
            log("steps: \(store.steps(scene: name, build: self.stopIndex).map(\.kind.rawValue))")
            self.stopScriptPreview()
            // preview the traced move: the pointer starts where move 1 ends
            self.script.pane?.select(m2.id, play: true)
            await wait(0.4)
            let pl = self.script.layer?.pointer.layer
            log("preview mid: hidden \(pl?.isHidden ?? true) at \(pl.map { NSStringFromPoint($0.position) } ?? "-") playing \(self.script.pane?.playing ?? false)")
            shot("preview")
            await wait(1.6)
            log("preview end: playing \(self.script.pane?.playing ?? true) pointer hidden \(pl?.isHidden ?? false)")
            log("file: \(FileManager.default.fileExists(atPath: store.url.path)) edited \(self.window.isDocumentEdited) title \(self.formatBar.script.title)")
            // motion maths: a move takes length/speed seconds and ends on its target
            let mo = ScriptMotion(points: [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0)], size: CGSize(width: 16, height: 9), speed: 0.5, noise: 1, seed: "x")
            log(String(format: "motion: duration %.2f mid %.3f,%.3f end %.3f,%.3f", mo.duration, mo.point(at: 0.5).x, mo.point(at: 0.5).y, mo.point(at: 1).x, mo.point(at: 1).y))
            // scripted presentation (stills), every build without a script held 0.5 s
            store.setHold(0.5)
            self.autoPresent(fromCurrent: true)
            var seen: [String] = []
            var shotTaken = false
            for _ in 0..<200 {
                await wait(0.1)
                guard let p = self.player else { break }
                let pg = p.scriptPage.map { "\($0.scene)#\($0.build)" } ?? "-"
                if seen.last != pg { seen.append(pg) }
                if !shotTaken, pg == "\(name)#0", let r = self.script.runner, !Mirror(reflecting: r).children.isEmpty, p.window.isVisible {
                    await wait(1.2); shot("auto", p.window); shotTaken = true
                }
            }
            log("auto pages: \(seen)")
            log("auto ended: player \(self.player == nil ? "closed" : "open") runner \(self.script.runner == nil ? "gone" : "left")")
            store.removeAll()
            log("done")
        }
    }
}

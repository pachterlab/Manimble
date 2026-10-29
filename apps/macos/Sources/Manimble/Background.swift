import AppKit
import UniformTypeIdentifiers

/// A slide's background as the engine reports it (`background` command, op `get`).
struct BackgroundInfo: Decodable {
    var mode: String?            // "none", "color" or "image"
    var color: String?
    var image: String?           // absolute path of the picture
    var transparency: Double?
    var `default`: String?       // the deck-wide colour from manim.cfg
}

/// What the user picked in the Format Background sheet.
struct BackgroundChoice {
    var mode: String             // "color" or "image"
    var color: String
    var image: URL?
    var transparency: Double
}

/// PowerPoint-style Format Background sheet: solid colour or picture, transparency, Apply to All / Reset.
final class BackgroundSheet: NSObject {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    private let solid = NSButton(radioButtonWithTitle: "Solid color", target: nil, action: nil)
    private let picture = NSButton(radioButtonWithTitle: "Picture", target: nil, action: nil)
    private let well = NSColorWell()
    private let chooseButton = NSButton(title: "Choose Picture…", target: nil, action: nil)
    private let fileLabel = NSTextField(labelWithString: "No picture chosen")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let percent = NSTextField(labelWithString: "0%")
    private let preview = NSView()
    private let fill = CALayer()
    private var applyButtons: [NSButton] = []
    private let base: NSColor
    private var swatches: [NSButton] = []
    /// One-click colours (the colour panel's wheel is all black while the current colour is black).
    static let presets = ["#000000", "#1E1E1E", "#3C3C3C", "#808080", "#D9D9D9", "#FFFFFF", "#FDF6E3", "#E8E4D9", "#002B36", "#0C1B33",
                          "#1F3A5F", "#2E5E8C", "#236B8E", "#58C4DD", "#83C167", "#FFFF00", "#FF862F", "#FC6255", "#9A72AC", "#7C5CFF"]
    private var image: URL?
    private var nsImage: NSImage?
    private let applyFn: (BackgroundChoice, Bool) -> Void
    private let resetFn: () -> Void

    init(info: BackgroundInfo, apply: @escaping (BackgroundChoice, Bool) -> Void, reset: @escaping () -> Void) {
        applyFn = apply; resetFn = reset
        base = NSColor(hex: info.default ?? "#000000")
        super.init()
        window.title = "Format Background"
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = content

        for b in [solid, picture] { b.target = self; b.action = #selector(modeChanged) }
        well.color = NSColor(hex: info.color ?? info.default ?? "#000000")
        well.target = self; well.action = #selector(changed)
        if #available(macOS 14.0, *) { well.colorWellStyle = .expanded }      // swatch popover + a button for the full panel
        chooseButton.target = self; chooseButton.action = #selector(choosePicture)
        fileLabel.textColor = .secondaryLabelColor; fileLabel.lineBreakMode = .byTruncatingMiddle
        slider.target = self; slider.action = #selector(changed); slider.isContinuous = true
        slider.doubleValue = ((info.transparency ?? 0) * 100).rounded()
        percent.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); percent.alignment = .right
        percent.widthAnchor.constraint(equalToConstant: 40).isActive = true
        if let p = info.image { image = URL(fileURLWithPath: p); nsImage = NSImage(contentsOf: URL(fileURLWithPath: p)) }
        (info.mode == "image" ? picture : solid).state = .on

        // live preview: the deck's own background with the fill on top at (1 - transparency)
        preview.wantsLayer = true
        preview.layer?.backgroundColor = base.cgColor
        preview.layer?.cornerRadius = 6; preview.layer?.masksToBounds = true
        preview.layer?.borderWidth = 1; preview.layer?.borderColor = NSColor.separatorColor.cgColor
        fill.contentsGravity = .resize
        preview.layer?.addSublayer(fill)
        preview.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(layoutPreview), name: NSView.frameDidChangeNotification, object: preview)

        let modeRow = NSStackView(views: [fieldLabel("Fill"), solid, picture]); modeRow.spacing = 14
        let grid = NSGridView(views: [Array(Self.presets[..<10]), Array(Self.presets[10...])].map { row in row.map { hex -> NSView in
            let b = NSButton(title: "", target: self, action: #selector(swatchPicked(_:)))
            b.isBordered = false; b.wantsLayer = true; b.toolTip = hex; b.identifier = NSUserInterfaceItemIdentifier(hex)
            b.layer?.backgroundColor = NSColor(hex: hex).cgColor; b.layer?.cornerRadius = 4
            b.layer?.borderWidth = 1; b.layer?.borderColor = NSColor.separatorColor.cgColor
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true; b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            swatches.append(b)
            return b
        } })
        grid.rowSpacing = 5; grid.columnSpacing = 5
        let colorRow = NSStackView(views: [fieldLabel("Color"), well, grid]); colorRow.spacing = 10; colorRow.alignment = .centerY
        well.widthAnchor.constraint(equalToConstant: 56).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(panelOpened), name: NSWindow.didBecomeKeyNotification, object: NSColorPanel.shared)
        NotificationCenter.default.addObserver(self, selector: #selector(panelOpened), name: NSWindow.didUpdateNotification, object: NSColorPanel.shared)
        let pictureRow = NSStackView(views: [fieldLabel("Picture"), chooseButton, fileLabel]); pictureRow.spacing = 10
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tRow = NSStackView(views: [fieldLabel("Transparency"), slider, percent]); tRow.spacing = 10

        let reset = NSButton(title: "Reset Background", target: self, action: #selector(resetPressed))
        let all = NSButton(title: "Apply to All", target: self, action: #selector(applyAllPressed))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed)); cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "Apply", target: self, action: #selector(applyPressed)); ok.keyEquivalent = "\r"
        applyButtons = [all, ok]
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [reset, all, spacer, cancel, ok]); buttons.spacing = 8

        let heading = NSTextField(labelWithString: "Format Background"); heading.font = Theme.font(13, .semibold)
        let stack = NSStackView(views: [heading, modeRow, colorRow, pictureRow, preview, tRow, hairline(), buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.setCustomSpacing(18, after: tRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor), preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 9.0 / 16.0),
            tRow.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pictureRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        for l in [modeRow, colorRow, pictureRow, tRow].compactMap({ $0.views.first }) { l.widthAnchor.constraint(equalToConstant: 84).isActive = true }
        if let p = image { fileLabel.stringValue = p.lastPathComponent }
        modeChanged()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private var isPicture: Bool { picture.state == .on }

    @objc private func modeChanged() {
        well.isEnabled = !isPicture
        chooseButton.isEnabled = isPicture
        fileLabel.textColor = isPicture ? .labelColor : .tertiaryLabelColor
        changed()
    }

    @objc private func swatchPicked(_ b: NSButton) {
        guard let hex = b.identifier?.rawValue else { return }
        well.color = NSColor(hex: hex)
        if well.isActive { NSColorPanel.shared.color = well.color }
        changed()
    }

    /// Put the colour panel beside this sheet the first time it shows, instead of a far corner of the screen.
    private var panelPlaced = false
    @objc private func panelOpened() {
        let panel = NSColorPanel.shared
        guard !panelPlaced, panel.isVisible, let screen = window.screen ?? NSScreen.main else { return }
        panelPlaced = true
        let f = window.frame, vis = screen.visibleFrame
        var x = f.maxX + 12
        if x + panel.frame.width > vis.maxX { x = max(vis.minX, f.minX - 12 - panel.frame.width) }
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: min(f.maxY, vis.maxY)))
    }

    @objc private func changed() {
        percent.stringValue = "\(Int(slider.doubleValue.rounded()))%"
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.opacity = Float(1 - slider.doubleValue / 100)
        if isPicture {
            fill.backgroundColor = nil
            fill.contents = nsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        } else {
            fill.contents = nil
            fill.backgroundColor = (well.color.usingColorSpace(.sRGB) ?? well.color).cgColor
        }
        CATransaction.commit()
        let cur = well.color.hexString
        for b in swatches {
            let on = !isPicture && b.identifier?.rawValue == cur
            b.layer?.borderWidth = on ? 2.5 : 1
            b.layer?.borderColor = (on ? Theme.accent : NSColor.separatorColor).cgColor
            b.isEnabled = !isPicture; b.alphaValue = isPicture ? 0.35 : 1
        }
        for b in applyButtons { b.isEnabled = !isPicture || image != nil }
        layoutPreview()
    }

    @objc private func layoutPreview() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame = preview.bounds
        CATransaction.commit()
    }

    @objc private func choosePicture() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .tiff, .gif, .heic]
        p.message = "Choose a background picture"
        p.beginSheetModal(for: window) { [weak self] r in
            guard let self = self, r == .OK, let u = p.url else { return }
            self.image = u
            self.nsImage = NSImage(contentsOf: u)
            self.fileLabel.stringValue = u.lastPathComponent
            self.changed()
        }
    }

    private var choice: BackgroundChoice {
        BackgroundChoice(mode: isPicture ? "image" : "color", color: well.color.hexString, image: isPicture ? image : nil,
                         transparency: slider.doubleValue / 100)
    }

    private func close(then work: @escaping () -> Void) {
        NSColorPanel.shared.orderOut(nil)
        window.sheetParent?.endSheet(window)
        DispatchQueue.main.async(execute: work)         // the controller drops this sheet when it closes
    }

    @objc private func cancelPressed() { close {} }
    @objc private func applyPressed() { let c = choice, fn = applyFn; close { fn(c, false) } }
    @objc private func applyAllPressed() { let c = choice, fn = applyFn; close { fn(c, true) } }
    @objc private func resetPressed() { let fn = resetFn; close { fn() } }
}

extension MainController {
    /// Format ▸ Background… and the canvas's right-click menu.
    @objc func formatBackground() {
        guard let name = sceneName, player == nil else { return }
        Task { @MainActor in
            let info: BackgroundInfo
            do { info = try await engine.call("background", ["op": "get", "scene": name], as: BackgroundInfo.self) }
            catch { toast("Could not read the background: \(error.localizedDescription)", error: true); return }
            let sheet = BackgroundSheet(info: info,
                                        apply: { [weak self] c, all in self?.applyBackground(c, all: all) },
                                        reset: { [weak self] in self?.runBackground(["op": "reset"]) })
            backgroundSheet = sheet
            window.beginSheet(sheet.window) { [weak self] _ in self?.backgroundSheet = nil }
        }
    }

    func applyBackground(_ c: BackgroundChoice, all: Bool) {
        var req: [String: Any] = ["op": "set", "mode": c.mode, "color": c.color, "transparency": c.transparency, "all": all]
        if c.mode == "image" {
            guard let ws = workspace, let u = c.image else { return }
            if u.deletingLastPathComponent().standardizedFileURL.path == ws.work.standardizedFileURL.path {
                req["file"] = u.lastPathComponent              // already in the deck
            } else {
                // copy it next to the scenes (like inserted images), so Save and packaging carry it along
                var name = "background_" + u.lastPathComponent
                var dest = ws.work.appendingPathComponent(name)
                var n = 1
                while FileManager.default.fileExists(atPath: dest.path) {
                    name = "background_" + u.deletingPathExtension().lastPathComponent + "_\(n)." + u.pathExtension
                    dest = ws.work.appendingPathComponent(name); n += 1
                }
                do { try FileManager.default.copyItem(at: u, to: dest) } catch { alert("Could not copy the picture", "\(error)"); return }
                req["file"] = name
            }
        }
        runBackground(req)
    }

    func runBackground(_ req: [String: Any]) {
        submit { [weak self] in
            guard let self = self, let name = self.sceneName else { return }
            self.busy += 1
            var r = req; r["scene"] = name
            var result: EditResult?
            var failure: String?
            do { result = try await self.engine.call("background", r, as: EditResult.self) } catch { failure = "\(error)" }
            self.busy -= 1
            if let res = result, res.ok == true {
                self.lastChanged = res.changed
                self.toast(res.message == "no change" ? "No change" : "Saved · \(res.message ?? "")")
            } else {
                self.toast(failure ?? result?.error ?? "background change failed", error: true)
            }
            await self.loadScene(name, keepStop: true)
            await self.reloadState()
        }
    }

    /// Right-click: on an object, only what applies to it; on the empty slide, the slide's own options.
    func canvasMenu() -> NSMenu? {
        guard sceneName != nil, player == nil else { return nil }
        let m = NSMenu()
        if let o = objInfo {
            if o.kind == "text" || o.kind == "tex" {
                let link = NSMenuItem(title: o.format?.link == nil ? "Add Hyperlink…" : "Edit Hyperlink…",
                                      action: #selector(hyperlinkPressed), keyEquivalent: "")
                link.target = self
                if let u = o.format?.link { link.toolTip = u }
                m.addItem(link)
            }
            for item in bioCartoonMenuItems() { m.addItem(item) }
            addArrangeItems(to: m)
            return m
        }
        let bg = NSMenuItem(title: "Format Background…", action: #selector(formatBackground), keyEquivalent: "")
        bg.target = self
        m.addItem(bg)
        return m
    }
}

extension MainController {
    /// Headless check of Format Background: MANIMBLE_TEST_BG=<deck>, output in MANIMBLE_SELFTEST.
    func backgroundTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_SELFTEST"] ?? "/tmp") + "/"
        func shot(_ name: String) {
            if let img = canvas.snapshot() {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
            }
        }
        Task { @MainActor in
            formatBackground()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            var log = ""
            if let v = backgroundSheet?.window.contentView {
                func find<T: NSView>(_ v: NSView) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { find($0) as [T] } }
                if let sw = (find(v) as [NSButton]).first(where: { $0.identifier?.rawValue == "#58C4DD" }) {
                    sw.performClick(nil)
                    log += "swatch->well=\((find(v) as [NSColorWell]).first?.color.hexString ?? "-") "
                }
            }
            if let w = backgroundSheet?.window, let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "bg-sheet.png"))
                window.endSheet(w)
            }
            applyBackground(BackgroundChoice(mode: "color", color: "#2255AA", image: nil, transparency: 0.25), all: false)
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            shot("bg-color.png")
            runBackground(["op": "reset"])
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            shot("bg-reset.png")
            try? (log + "done toast=\(toastPill.label.stringValue)").write(toFile: dir + "bg.log", atomically: true, encoding: .utf8)
        }
    }
}

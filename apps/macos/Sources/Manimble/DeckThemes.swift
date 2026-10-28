import AppKit

/// A deck theme: a complete common.py in the engine's manimble/themes folder (see its README.md).
struct DeckTheme {
    var id: String              // the file's name, what the engine's `theme` command takes
    var name: String            // THEME
    var source: String          // written as a new deck's common.py
    var background: String      // BACKGROUND, for manim.cfg
    var text: String            // TEXT_COLOR

    /// The bundled themes, Midnight (the old black default) first, then by name.
    static let all: [DeckTheme] = {
        let dir = URL(fileURLWithPath: Engine.enginePath()).appendingPathComponent("manimble/themes")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        func constant(_ name: String, _ src: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: "^\(name)\\s*=\\s*\"([^\"]*)\"", options: .anchorsMatchLines),
                  let m = re.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)),
                  let r = Range(m.range(at: 1), in: src) else { return nil }
            return String(src[r])
        }
        let themes: [DeckTheme] = files.filter { $0.pathExtension == "py" }.compactMap { url in
            guard let src = try? String(contentsOf: url, encoding: .utf8), let name = constant("THEME", src) else { return nil }
            return DeckTheme(id: url.deletingPathExtension().lastPathComponent, name: name, source: src,
                             background: constant("BACKGROUND", src) ?? "#000000", text: constant("TEXT_COLOR", src) ?? "#FFFFFF")
        }
        return themes.sorted { a, b in a.id == "midnight" || (b.id != "midnight" && a.name < b.name) }
    }()

    /// A menu icon: "Aa" in the theme's text colour on its background.
    var swatch: NSImage {
        let (bg, fg) = (background, text)
        return NSImage(size: NSSize(width: 28, height: 18), flipped: false) { r in
            let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            NSColor(hex: bg).setFill(); box.fill()
            NSColor.separatorColor.setStroke(); box.stroke()
            let s = NSAttributedString(string: "Aa", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                                                                  .foregroundColor: NSColor(hex: fg)])
            let z = s.size()
            s.draw(at: NSPoint(x: (r.width - z.width) / 2, y: (r.height - z.height) / 2))
            return true
        }
    }

    /// One item per theme, sending `themeChosen(_:)` with the theme's id (the Theme toolbar button, Format ▸ Theme).
    static func menu(target: AnyObject?) -> NSMenu {
        let m = NSMenu(title: "Theme")
        for t in all {
            let mi = NSMenuItem(title: t.name, action: #selector(MainController.themeChosen(_:)), keyEquivalent: "")
            mi.representedObject = t.id; mi.target = target; mi.image = t.swatch
            m.addItem(mi)
        }
        return m
    }
}

private struct ThemeInfo: Decodable {
    var ok: Bool?
    var theme: String?
    var slide_theme: String?
    var crosses: Bool?
    var error: String?
}

private struct ThemePreview: Decodable {
    var ok: Bool?
    var png: String?
    var error: String?
}

/// The sheet Format ▸ Theme opens: the slide on screen rendered in the theme, then Apply to the whole deck or, with
/// "Apply to selected slide only", to that slide alone.
final class ThemeSheet: NSObject {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
    private let picker = NSPopUpButton()
    private let slideOnly = NSButton(checkboxWithTitle: "Apply to selected slide only", target: nil, action: nil)
    private let flip = NSButton(checkboxWithTitle: "Also swap whites and blacks in the slides (for text that does not use TEXT_COLOR)",
                                target: nil, action: nil)
    private let imageView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let engine: Engine
    private let scene: String
    private var crosses: [String: Bool] = [:]
    private var previews: [String: NSImage] = [:]    // "<theme id>|<slide only>|<swap>"
    private var generation = 0
    private let applyFn: (DeckTheme, Bool, Bool) -> Void

    init(theme: DeckTheme, scene: String, engine: Engine, apply: @escaping (DeckTheme, _ slideOnly: Bool, _ flip: Bool) -> Void) {
        self.engine = engine; self.scene = scene; applyFn = apply
        super.init()
        window.title = "Theme"
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = content

        for t in DeckTheme.all {
            picker.addItem(withTitle: t.name)
            picker.lastItem?.representedObject = t.id; picker.lastItem?.image = t.swatch
        }
        picker.selectItem(at: DeckTheme.all.firstIndex { $0.id == theme.id } ?? 0)
        picker.target = self; picker.action = #selector(changed)
        slideOnly.target = self; slideOnly.action = #selector(changed)
        flip.target = self; flip.action = #selector(flipChanged)
        flip.state = .on
        flip.font = Theme.font(11)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6; imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1; imageView.layer?.borderColor = NSColor.separatorColor.cgColor
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        imageView.addSubview(spinner)
        status.font = Theme.font(11); status.textColor = .secondaryLabelColor; status.alignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false
        imageView.addSubview(status)
        detail.font = Theme.font(11); detail.textColor = .secondaryLabelColor; detail.preferredMaxLayoutWidth = 480
        flip.cell?.wraps = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed)); cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "Apply", target: self, action: #selector(applyPressed)); ok.keyEquivalent = "\r"
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, ok]); buttons.spacing = 8

        let heading = NSTextField(labelWithString: "Apply Theme"); heading.font = Theme.font(13, .semibold)
        let themeRow = NSStackView(views: [fieldLabel("Theme"), picker]); themeRow.spacing = 10
        let caption = fieldLabel("Preview of \(scene)")
        let stack = NSStackView(views: [heading, themeRow, caption, imageView, slideOnly, flip, detail, hairline(), buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.setCustomSpacing(6, after: caption)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalToConstant: 480),
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor), imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor, multiplier: 9.0 / 16.0),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor), flip.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            spinner.centerXAnchor.constraint(equalTo: imageView.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            status.centerXAnchor.constraint(equalTo: imageView.centerXAnchor), status.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: imageView.widthAnchor, constant: -40),
        ])
        changed()
    }

    private var chosen: DeckTheme {
        let id = picker.selectedItem?.representedObject as? String
        return DeckTheme.all.first { $0.id == id } ?? DeckTheme.all[0]
    }

    /// The theme or the checkbox changed: the explanation, the dark/light swap offer and the preview follow.
    @objc private func changed() {
        let t = chosen, one = slideOnly.state == .on
        detail.stringValue = one
            ? "This slide gets the theme's background, and its own code uses the theme's FONT, TEXT_COLOR, MUTED_COLOR and "
              + "ACCENT; helpers shared with other slides keep the deck's. Choosing the deck's own theme here takes the "
              + "slide back to the deck's. Undo (⌘Z) reverts it."
            : "The deck's font, text colour and accent constants (FONT, TEXT_COLOR, MUTED_COLOR, ACCENT) and its background "
              + "are set to the theme's, and slides with a theme of their own take the deck's. Every slide is re-rendered. "
              + "Undo (⌘Z) reverts it in one step."
        flip.isHidden = one || crosses[t.id] != true
        if crosses[t.id] == nil {
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let info = try? await self.engine.call("theme", ["op": "get", "theme": t.id], as: ThemeInfo.self)
                self.crosses[t.id] = info?.crosses == true
                if self.chosen.id == t.id {
                    self.flip.isHidden = self.slideOnly.state == .on || info?.crosses != true
                    self.loadPreview()                  // with the swap, now that it is known to apply
                }
            }
        }
        if crosses[t.id] != nil { loadPreview() }
    }

    @objc private func flipChanged() { loadPreview() }

    /// Whether Apply will also swap whites and blacks.
    private var flipping: Bool { !flip.isHidden && flip.state == .on }

    private func loadPreview() {
        let t = chosen, one = slideOnly.state == .on, f = flipping, key = "\(t.id)|\(one)|\(f)"
        generation += 1
        let gen = generation
        status.stringValue = ""
        if let img = previews[key] { imageView.image = img; spinner.stopAnimation(nil); return }
        imageView.alphaValue = 0.35
        spinner.startAnimation(nil)
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            var res: ThemePreview?
            var failure: String?
            do { res = try await self.engine.call("theme", ["op": "preview", "theme": t.id, "scene": self.scene,
                                                                      "slide_only": one, "flip": f],
                                                   as: ThemePreview.self) }
            catch { failure = error.localizedDescription }
            // read it now: the next preview of this theme re-renders into the same folder
            let img = res?.png.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }.flatMap { NSImage(data: $0) }
            if let img = img { self.previews[key] = img }
            guard gen == self.generation else { return }
            self.spinner.stopAnimation(nil)
            self.imageView.alphaValue = 1
            if let img = img {
                self.imageView.image = img
            } else {
                self.imageView.image = nil
                self.status.stringValue = "No preview: " + (failure ?? res?.error ?? "the slide did not render")
            }
        }
    }

    private func close(then work: @escaping () -> Void) {
        generation += 1
        window.sheetParent?.endSheet(window)
        DispatchQueue.main.async(execute: work)         // the controller drops this sheet when it closes
    }

    @objc private func cancelPressed() { close {} }
    @objc private func applyPressed() {
        let t = chosen, one = slideOnly.state == .on, f = flipping, fn = applyFn
        close { fn(t, one, f) }
    }
}

extension MainController {
    /// Format ▸ Theme and the Theme toolbar button: a sheet with the theme rendered on the slide on screen, applied to
    /// the deck (its FONT / TEXT_COLOR / ... constants and manim.cfg's background, one undo step) or to that slide only.
    /// Going between a dark and a light background also offers to swap whites and blacks, as Format ▸ Apply Dark Mode
    /// to Deck does, so text that does not use TEXT_COLOR stays readable.
    @objc func themeChosen(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let t = DeckTheme.all.first(where: { $0.id == id }),
              let name = sceneName, themeSheet == nil else { return }
        let sheet = ThemeSheet(theme: t, scene: name, engine: engine) { [weak self] t, one, flip in
            self?.runApplyTheme(t, flip: flip, slideOnly: one)
        }
        themeSheet = sheet
        window.beginSheet(sheet.window) { [weak self] _ in self?.themeSheet = nil }
    }

    func runApplyTheme(_ t: DeckTheme, flip: Bool, slideOnly: Bool = false) {
        submit { [weak self] in
            guard let self = self else { return }
            self.busyText = "Applying the \(t.name) theme…"
            self.busy += 1
            var result: EditResult?
            var failure: String?
            do { result = try await self.engine.call("theme", ["theme": t.id, "flip": flip, "slide_only": slideOnly,
                                                                "current": self.sceneName ?? ""], as: EditResult.self) }
            catch { failure = "\(error)" }
            self.busy -= 1
            self.busyText = "Rendering…"
            if let res = result, res.ok == true {
                self.lastChanged = res.changed
                self.toast(res.message == "no change" ? (slideOnly ? "The slide already has this theme" : "The deck already has this theme")
                           : "Saved · \(res.message ?? "")")
            } else {
                self.toast(failure ?? result?.error ?? "theme change failed", error: true)
            }
            self.canvas.dropTextures()
            if let n = self.sceneName { await self.loadScene(n, keepStop: true) }
            await self.reloadState()
        }
    }
}

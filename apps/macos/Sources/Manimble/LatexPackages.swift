import AppKit

/// LaTeX packages a Beamer deck uses that this Mac's TeX lacks. Nothing is ever downloaded on its own: the import asks
/// first, and a deck imported without them shows a banner (Install / Not Now / Don't Ask Again). After installing,
/// the pictures the import left as placeholders are typeset again in place, so edits to the slides are kept.
struct LatexMissing: Decodable { var missing: [String]; var tlmgr: Bool }
struct LatexStatus: Decodable { var missing: [String]; var placeholders: Int; var source: String? }
struct LatexInstall: Decodable { var ok: Bool; var error: String?; var installed: [String]?; var missing: [String]? }
struct LatexRetypeset: Decodable { var ok: Bool; var error: String?; var updated: Int?; var failed: Int? }

/// The strip under the Home bar of a deck whose LaTeX packages are missing.
final class LatexBanner: NSView {
    /// Decks whose banner "Don't Ask Again" turned off (original deck paths).
    static let mutedKey = "latexBannerMutedDecks"
    /// Decks whose banner is hidden until they are opened again: "Not Now", or "Import Without Them" just now.
    static var notNow = Set<String>()

    let label = NSTextField(wrappingLabelWithString: "")
    let install = NSButton(title: "Install", target: nil, action: nil)
    let later = NSButton(title: "Not Now", target: nil, action: nil)
    let never = NSButton(title: "Don't Ask Again", target: nil, action: nil)
    let spinner = NSProgressIndicator()
    private var height: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.16).cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "LaTeX packages") ?? NSImage())
        icon.contentTintColor = .systemOrange
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for b in [install, later, never] { b.bezelStyle = .rounded; b.controlSize = .small; b.font = .systemFont(ofSize: 11) }
        install.keyEquivalent = ""
        install.bezelColor = .controlAccentColor
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let row = NSStackView(views: [icon, label, spinner, install, later, never])
        row.spacing = 8; row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let line = hairline(); line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor), height,
        ])
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String) {
        label.stringValue = text
        busy(false)
        isHidden = false; height.constant = 38
    }

    func hide() { isHidden = true; height.constant = 0 }

    func busy(_ on: Bool) {
        for b in [install, later, never] { b.isEnabled = !on }
        if on { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    static func names(_ files: [String]) -> String {
        files.map { ($0 as NSString).deletingPathExtension }.joined(separator: ", ")
    }
}

extension MainController {
    /// Before a Beamer import: ask whether to install the LaTeX packages the file uses that are missing here.
    /// false: the user cancelled the import.
    func offerLatexPackages(for src: URL, deck: URL) async -> Bool {
        guard let m = try? await engine.call("latex_missing", ["src": src.path], as: LatexMissing.self), !m.missing.isEmpty else { return true }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "\(src.lastPathComponent) uses LaTeX packages that aren't installed"
        let list = LatexBanner.names(m.missing)
        if m.tlmgr {
            a.informativeText = "Missing: \(list).\n\nManimble can install them with TeX Live's package manager (tlmgr), which downloads them from CTAN. "
                + "A TeX installed for all users (MacTeX, BasicTeX) asks for an administrator password.\n\n"
                + "Without them, pictures that need these packages are imported as placeholders. You can install them later from the deck."
            a.addButton(withTitle: "Install and Import"); a.addButton(withTitle: "Import Without Them"); a.addButton(withTitle: "Cancel")
        } else {
            a.informativeText = "Missing: \(list).\n\nNo TeX package manager (tlmgr) was found, so they can't be installed from Manimble. "
                + "Pictures that need them are imported as placeholders."
            a.addButton(withTitle: "Import Without Them"); a.addButton(withTitle: "Cancel")
        }
        let r = a.runModal()
        let choice = m.tlmgr ? r : NSApplication.ModalResponse(rawValue: r.rawValue + 1)
        switch choice {
        case .alertFirstButtonReturn:
            busyPill.show("Installing LaTeX packages…", symbol: nil, tint: nil, spinning: true, cancellable: false)
            let res = try? await engine.call("latex_install", ["files": m.missing], as: LatexInstall.self)
            busyPill.hide()
            if res?.ok != true {
                alert("The LaTeX packages were not installed", (res?.error ?? "tlmgr did not answer")
                      + "\n\nThe presentation is imported anyway; pictures that need them are placeholders until they are installed.")
                LatexBanner.notNow.insert(deck.appendingPathComponent("deck").standardizedFileURL.path)
            } else {
                toast("Installed " + (res?.installed ?? []).joined(separator: ", "))
            }
            return true
        case .alertSecondButtonReturn:
            // just declined: the new deck's banner waits until it is opened again
            LatexBanner.notNow.insert(deck.appendingPathComponent("deck").standardizedFileURL.path)
            return true
        default:
            return false
        }
    }

    /// After a deck opens: show the banner when packages are missing; typeset placeholders again once they are not
    /// (installed some other way).
    func checkLatexPackages() async {
        guard let ws = workspace else { latexBanner.hide(); return }
        guard let st = try? await engine.call("latex_status", as: LatexStatus.self) else { latexBanner.hide(); return }
        let key = ws.original.path
        if st.missing.isEmpty {
            latexBanner.hide()
            if st.placeholders > 0 { await retypesetLatexPictures() }
            return
        }
        let muted = UserDefaults.standard.stringArray(forKey: LatexBanner.mutedKey) ?? []
        if muted.contains(key) || LatexBanner.notNow.contains(where: { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == key }) {
            latexBanner.hide(); return
        }
        let pics = st.placeholders == 0 ? "" : st.placeholders == 1 ? " One picture is a placeholder until they are installed."
            : " \(st.placeholders) pictures are placeholders until they are installed."
        latexBanner.show("This deck\(st.source.map { $0.isEmpty ? "" : " (from \($0))" } ?? "") needs LaTeX packages that aren't installed: "
                         + LatexBanner.names(st.missing) + "." + pics)
        latexBanner.install.target = self; latexBanner.install.action = #selector(latexBannerInstall)
        latexBanner.later.target = self; latexBanner.later.action = #selector(latexBannerNotNow)
        latexBanner.never.target = self; latexBanner.never.action = #selector(latexBannerNever)
    }

    @objc func latexBannerInstall() {
        Task { @MainActor in
            guard let st = try? await engine.call("latex_status", as: LatexStatus.self), !st.missing.isEmpty else {
                await checkLatexPackages(); return
            }
            latexBanner.busy(true)
            latexBanner.label.stringValue = "Installing " + LatexBanner.names(st.missing) + " with tlmgr…"
            let res = try? await engine.call("latex_install", ["files": st.missing], as: LatexInstall.self)
            if res?.ok != true {
                latexBanner.busy(false)
                alert("The LaTeX packages were not installed", res?.error ?? "tlmgr did not answer")
                await checkLatexPackages()
                return
            }
            toast("Installed " + (res?.installed ?? []).joined(separator: ", "))
            await checkLatexPackages()          // hides the banner and typesets the placeholders
        }
    }

    @objc func latexBannerNotNow() {
        if let ws = workspace { LatexBanner.notNow.insert(ws.original.path) }
        latexBanner.hide()
    }

    @objc func latexBannerNever() {
        if let ws = workspace {
            var muted = UserDefaults.standard.stringArray(forKey: LatexBanner.mutedKey) ?? []
            let key = ws.original.path
            if !muted.contains(key) { muted.append(key) }
            UserDefaults.standard.set(muted, forKey: LatexBanner.mutedKey)
        }
        latexBanner.hide()
        toast("This deck won't ask about LaTeX packages again")
    }

    /// Typeset the placeholder pictures again (their packages are installed now) and show the slides with them.
    func retypesetLatexPictures() async {
        busyPill.show("Typesetting LaTeX pictures…", symbol: nil, tint: nil, spinning: true, cancellable: false)
        let r = try? await engine.call("latex_retypeset", as: LatexRetypeset.self)
        busyPill.hide()
        guard let r, r.ok else { toast(r?.error ?? "could not typeset the LaTeX pictures", error: true); return }
        if let n = r.updated, n > 0 {
            toast("Typeset \(n) LaTeX picture\(n == 1 ? "" : "s")")
            await reloadState()
            if let name = sceneName { await loadScene(name, keepStop: true) }
        }
    }
}

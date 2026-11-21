import AppKit

/// Manimble ▸ Check for Updates…, plus a quiet check at most once a day after launch.
/// Asks GitHub for the latest release, compares its tag with the bundle version and, when it is newer, offers the DMG.
/// It never downloads or installs anything itself.
@MainActor enum Updates {
    private static let api = URL(string: "https://api.github.com/repos/pachterlab/Manimble/releases/latest")!
    private static let autoKey = "checkForUpdatesAutomatically"
    private static let lastKey = "lastUpdateCheck"
    private static let skipKey = "skippedUpdateVersion"
    private static var checking = false

    static var current: String? {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return v.flatMap { components($0).isEmpty ? nil : $0 }
    }

    /// The launch check: skipped under the test hooks, for an unversioned build, when turned off, or within a day of
    /// the last one, and put off while a slideshow fills the screen.
    static func checkInBackground() {
        UserDefaults.standard.register(defaults: [autoKey: true])
        let env = ProcessInfo.processInfo.environment
        guard current != nil, UserDefaults.standard.bool(forKey: autoKey),
              !env.keys.contains(where: { $0.hasPrefix("MANIMBLE_TEST") || $0 == "MANIMBLE_SELFTEST" }) else { return }
        let last = UserDefaults.standard.double(forKey: lastKey)
        guard Date().timeIntervalSince1970 - last > 24 * 3600 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.fullScreen) }) { return }
            check(userInitiated: false)
        }
    }

    static func check(userInitiated: Bool) {
        guard !checking else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            let release: Release
            do { release = try await fetch() } catch {
                if userInitiated { tell("Couldn’t check for updates", error.localizedDescription) }
                return
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
            guard let have = current else {
                if userInitiated { tell("This build has no version number", "The latest release is \(release.version).") }
                return
            }
            guard isNewer(release.version, than: have) else {
                if userInitiated { tell("You’re up to date", "Manimble \(have) is the latest version.") }
                return
            }
            if !userInitiated && UserDefaults.standard.string(forKey: skipKey) == release.version { return }
            offer(release, have: have, userInitiated: userInitiated)
        }
    }

    // MARK: - GitHub

    struct Release {
        let version: String      // tag without the leading "v"
        let notes: String
        let download: URL        // the DMG, else the release page
    }

    private static func fetch() async throws -> Release {
        var req = URLRequest(url: api, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Manimble/\(current ?? "dev")", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String, let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "GitHub answered with status \(code)."]) }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String) == "Manimble-macOS.dmg" }?["browser_download_url"] as? String
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: json["body"] as? String ?? "",
                       download: dmg.flatMap(URL.init(string:)) ?? page)
    }

    /// Numeric parts of "0.4.8" (anything after a "-" or "+" is ignored).
    static func components(_ v: String) -> [Int] {
        let core = v.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? v
        let parts = core.split(separator: ".").map { Int($0) }
        return parts.contains(nil) ? [] : parts.compactMap { $0 }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = components(a), y = components(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // MARK: - Alerts

    private static func offer(_ r: Release, have: String, userInitiated: Bool) {
        let a = NSAlert()
        a.messageText = "Manimble \(r.version) is available"
        var notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 700 { notes = String(notes.prefix(700)) + "…" }
        a.informativeText = "You have \(have). Download the new version, then drag it into Applications to replace this one."
            + (notes.isEmpty ? "" : "\n\n" + notes)
        a.addButton(withTitle: "Download")
        a.addButton(withTitle: "Later")
        if !userInitiated { a.addButton(withTitle: "Skip This Version") }
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Check for updates automatically"
        a.suppressionButton?.state = UserDefaults.standard.bool(forKey: autoKey) ? .on : .off
        NSApp.activate(ignoringOtherApps: true)
        let answer = a.runModal()
        UserDefaults.standard.set(a.suppressionButton?.state == .on, forKey: autoKey)
        switch answer {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(r.download)
        case .alertThirdButtonReturn: UserDefaults.standard.set(r.version, forKey: skipKey)
        default: break
        }
    }

    private static func tell(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

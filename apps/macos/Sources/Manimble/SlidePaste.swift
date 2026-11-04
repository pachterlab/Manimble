import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// What Edit ▸ Paste puts on a slide, read from the clipboard: pictures (files copied in the Finder, pictures from a
/// web page or Google Slides, picture data from Preview, Keynote, PowerPoint or a screenshot), or else text with the
/// bold, italics and colours of its characters.
enum SlidePaste {
    case pictures([Picture])
    case text(String, styles: [String: [CharRun]])

    enum Picture {
        case file(URL)            // a picture file on this Mac
        case data(Data)           // PNG
        case remote(URL)          // a picture a web page (or Google Slides) links to: downloaded when pasted
    }

    static let pictureTypes: [UTType] = [.png, .jpeg, .tiff, .gif, .heic, .bmp, .webP]

    /// What the clipboard holds that a slide can take, or nil.
    @MainActor static func read(_ pb: NSPasteboard) -> SlidePaste? {
        let files = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { u in UTType(filenameExtension: u.pathExtension).map { t in pictureTypes.contains { t.conforms(to: $0) } } ?? false }
        if !files.isEmpty { return .pictures(files.map { .file($0) }) }
        let text = (pb.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let html = pb.string(forType: .html)
        if text.isEmpty {
            // copied from a web page or Google Slides: the HTML links to the pictures
            let srcs = html.map(imageSources) ?? []
            if !srcs.isEmpty { return .pictures(srcs.map { .remote($0) }) }
            if let png = pngData(pb) { return .pictures([.data(png)]) }
            return nil
        }
        if let html = html, let styled = styledText(html), !styled.0.isEmpty { return .text(styled.0, styles: styled.1) }
        return .text(text, styles: [:])
    }

    /// The pictures an HTML fragment shows (`<img src=...>`): web addresses, and pictures written into it (data: URLs).
    static func imageSources(_ html: String) -> [URL] {
        guard let re = try? NSRegularExpression(pattern: #"<img\b[^>]*?\bsrc\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        return re.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let s = ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            guard let u = URL(string: s), ["http", "https", "data"].contains(u.scheme?.lowercased() ?? "") else { return nil }
            return u
        }
    }

    /// The clipboard's picture as PNG (PNG, TIFF or PDF data, as apps put them there).
    static func pngData(_ pb: NSPasteboard) -> Data? {
        if let d = pb.data(forType: .png) { return d }
        guard pb.availableType(from: [.tiff, .pdf]) != nil, let img = NSImage(pasteboard: pb) else { return nil }
        return png(img)
    }

    static func png(_ img: NSImage) -> Data? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// Text and its formatting from the HTML a browser or another app put on the clipboard: which characters are bold
    /// and italic, and the colours of those not in the text's main colour (that one gives way to the slide's own).
    @MainActor static func styledText(_ html: String) -> (String, [String: [CharRun]])? {
        // pictures out first: reading HTML would fetch them, on this thread
        let bare = html.replacingOccurrences(of: #"<img\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        guard let data = bare.data(using: .utf8),
              let a = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                    .characterEncoding: String.Encoding.utf8.rawValue],
                                              documentAttributes: nil) else { return nil }
        // trailing and leading blank lines (block elements end in a newline) are not part of the text
        let full = a.string as NSString
        var lo = 0, hi = full.length
        let ws = CharacterSet.whitespacesAndNewlines
        while lo < hi, let u = UnicodeScalar(full.character(at: lo)), ws.contains(u) { lo += 1 }
        while hi > lo, let u = UnicodeScalar(full.character(at: hi - 1)), ws.contains(u) { hi -= 1 }
        guard hi > lo else { return nil }
        let body = a.attributedSubstring(from: NSRange(location: lo, length: hi - lo))
        let text = body.string.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{2028}", with: "\n")
        let scalars = { (n: Int) in String(decoding: Array(body.string.utf16.prefix(n)), as: UTF16.self).unicodeScalars.count }
        var italic: [CharRun] = [], bold: [CharRun] = [], colors: [(CharRun, String)] = []
        var weight: [String: Int] = [:]
        body.enumerateAttributes(in: NSRange(location: 0, length: body.length)) { attrs, r, _ in
            let a = scalars(r.location), b = scalars(r.location + r.length)
            if let f = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: f)
                if traits.contains(.italicFontMask) { add(&italic, a, b) }
                if traits.contains(.boldFontMask) { add(&bold, a, b) }
            }
            if let c = (attrs[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB) {
                let hex = c.hexString.uppercased()
                colors.append((CharRun(a, b, hex), hex))
                weight[hex, default: 0] += b - a
            } else {
                weight["", default: 0] += b - a            // no colour of its own: the default (black, as imported)
            }
        }
        // the main colour is the text's colour in the other app (black on a white slide, say): the slide's own replaces it
        let main = weight.max { $0.value < $1.value }?.key
        var colored: [CharRun] = []
        for (r, hex) in colors where hex != main { add(&colored, r.start, r.end, hex) }
        var styles: [String: [CharRun]] = [:]
        if !italic.isEmpty { styles["italic"] = italic }
        if !bold.isEmpty { styles["bold"] = bold }
        if !colored.isEmpty { styles["color"] = colored }
        return (text, styles)
    }

    private static func add(_ runs: inout [CharRun], _ a: Int, _ b: Int, _ color: String? = nil) {
        guard b > a else { return }
        if let last = runs.last, last.end == a, last.color == color { runs[runs.count - 1].end = b }
        else { runs.append(CharRun(a, b, color)) }
    }

    /// A picture saved into the deck folder (the same picture keeps one file); its file name.
    static func save(_ data: Data, ext: String, into dir: URL) -> String? {
        let h = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        let name = "pasted_\(h).\(ext)"
        let dest = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: dest.path) {
            do { try data.write(to: dest) } catch { return nil }
        }
        return name
    }
}

extension MainController {
    /// Edit ▸ Paste (⌘V) on the slide: pictures or text from the clipboard, inserted on the build on screen.
    @objc func paste(_ sender: Any?) { pasteOnSlide(from: .general) }

    func pasteOnSlide(from pb: NSPasteboard) {
        guard let ws = workspace, sceneName != nil else { return }
        guard let what = SlidePaste.read(pb) else {
            toast("Nothing on the clipboard can go on a slide: copy a picture or some text", error: true); return
        }
        // each paste a little below and right of the one before, as PowerPoint pastes them, so they don't cover each other
        func centre() -> (Double, Double) {
            let k = MainController.pastes[sceneName ?? "", default: 0]
            MainController.pastes[sceneName ?? ""] = (k + 1) % 6
            let d = Double(k) * 0.04 * Double(canvas.frameSize.width)
            return (Double(canvas.frameSize.width) / 2 + d, Double(canvas.frameSize.height) / 2 + d)
        }
        switch what {
        case .text(let text, let styles):
            let (cx, cy) = centre()
            var extra: [String: Any] = ["value": text, "sx": cx - 1, "sy": cy, "ex": cx + 1, "ey": cy]
            if !styles.isEmpty { extra["styles"] = styles.mapValues { $0.map(\.json) } }
            insert(kind: "text", extra: extra)
        case .pictures(let pics):
            Task { @MainActor in
                for pic in pics {
                    guard let name = await pastedPicture(pic, into: ws.work) else { continue }
                    let (cx, cy) = centre()
                    let half = 2 * Double(canvas.unitPx)
                    insert(kind: "image", extra: ["file": name, "path": ws.work.appendingPathComponent(name).path,
                                                  "sx": cx - half, "sy": cy, "ex": cx + half, "ey": cy])
                }
            }
        }
    }

    /// A pasted picture's file in the deck folder: copied, written, or downloaded (and made a PNG when it is not one
    /// manim reads).
    private func pastedPicture(_ pic: SlidePaste.Picture, into dir: URL) async -> String? {
        switch pic {
        case .file(let u):
            guard let d = try? Data(contentsOf: u) else { return nil }
            let ext = u.pathExtension.lowercased()
            if ["png", "jpg", "jpeg", "gif"].contains(ext) { return SlidePaste.save(d, ext: ext, into: dir) }
            return NSImage(data: d).flatMap(SlidePaste.png).flatMap { SlidePaste.save($0, ext: "png", into: dir) }
        case .data(let d):
            return SlidePaste.save(d, ext: "png", into: dir)
        case .remote(let u):
            busyPill.show("Downloading the pasted picture…", symbol: nil, tint: nil, spinning: true, cancellable: false)
            defer { busyPill.hide() }
            let got: Data?
            if u.scheme?.lowercased() == "data" { got = try? Data(contentsOf: u) }
            else { got = try? await URLSession.shared.data(from: u).0 }
            guard let d = got, let img = NSImage(data: d), let png = SlidePaste.png(img) else {
                toast("Could not get the pasted picture from \(u.host ?? "the web")", error: true); return nil
            }
            return SlidePaste.save(png, ext: "png", into: dir)
        }
    }

    /// How many times something was pasted on each slide (mod 6), to place the next paste.
    static var pastes: [String: Int] = [:]

    /// Whether Edit ▸ Paste has something for the slide.
    var canPasteOnSlide: Bool {
        guard sceneName != nil, player == nil else { return false }
        let pb = NSPasteboard.general
        return pb.availableType(from: [.fileURL, .string, .html, .png, .tiff, .pdf]) != nil
    }
}

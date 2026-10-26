import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// Pictures in speaker notes. The notes stay plain text in the slide's source, a picture as a Markdown image
/// (`![](note_1a2b3c4d.png)`, relative to the deck folder, where the file is copied like a slide's image), and the
/// notes editors show it inline: the text views hold `NoteImageAttachment`s, turned back into Markdown on save.
enum NoteImages {
    /// `![alt](path)` on one line; group 1 is the path.
    static let regex = try! NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(([^)\n]+)\)"#)
    static let types: [UTType] = [.png, .jpeg, .tiff, .gif, .heic, .bmp]

    /// Whether the text has any picture in it.
    static func has(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// The notes for a text view: plain text in `attributes`, each picture (found under `base`) as an attachment
    /// at most `maxWidth` wide; a picture whose file is missing stays as its Markdown.
    static func attributed(_ text: String, base: URL?, attributes: [NSAttributedString.Key: Any],
                           maxWidth: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ns = text as NSString
        var at = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let path = ns.substring(with: m.range(at: 1))
            guard let a = attachment(path, base: base, maxWidth: maxWidth) else { continue }
            out.append(NSAttributedString(string: ns.substring(with: NSRange(location: at, length: m.range.location - at)), attributes: attributes))
            let s = NSMutableAttributedString(attachment: a)
            s.addAttributes(attributes, range: NSRange(location: 0, length: s.length))
            out.append(s)
            at = m.range.location + m.range.length
        }
        out.append(NSAttributedString(string: ns.substring(from: at), attributes: attributes))
        return out
    }

    /// The text view's contents as notes text: each picture back to its Markdown.
    static func markup(_ s: NSAttributedString) -> String {
        var out = ""
        let ns = s.string as NSString
        s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { value, r, _ in
            if let a = value as? NoteImageAttachment {
                out += String(repeating: "![](\(a.path))", count: r.length)
            } else {
                out += ns.substring(with: r).replacingOccurrences(of: "\u{FFFC}", with: "")
            }
        }
        return out
    }

    static func attachment(_ path: String, base: URL?, maxWidth: CGFloat) -> NoteImageAttachment? {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base?.appendingPathComponent(path)
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        return NoteImageAttachment(path: path, image: image, maxWidth: maxWidth)
    }

    /// Pictures on a pasteboard (image files, or image data such as a screenshot) copied into `deck` as
    /// `note_<hash>.<ext>`: their paths relative to it, nil when the pasteboard has no picture.
    static func importImages(from pb: NSPasteboard, into deck: URL) -> [String]? {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { u in UTType(filenameExtension: u.pathExtension).map { t in types.contains { t.conforms(to: $0) } } ?? false }
        if !urls.isEmpty {
            let saved = urls.compactMap { u in (try? Data(contentsOf: u)).flatMap { save($0, ext: u.pathExtension.lowercased(), into: deck) } }
            return saved.isEmpty ? nil : saved
        }
        // text copied from another app may carry a picture of itself as well: paste the text
        if pb.availableType(from: [.string]) != nil { return nil }
        if let d = pb.data(forType: .png) { return save(d, ext: "png", into: deck).map { [$0] } }
        if let d = pb.data(forType: .tiff), let png = NSBitmapImageRep(data: d)?.representation(using: .png, properties: [:]) {
            return save(png, ext: "png", into: deck).map { [$0] }
        }
        return nil
    }

    /// The same picture always gets the same name, so pasting it twice keeps one file.
    static func save(_ data: Data, ext: String, into deck: URL) -> String? {
        let h = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        let name = "note_\(h).\(ext.isEmpty ? "png" : ext)"
        let dest = deck.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: dest.path) {
            do { try data.write(to: dest) } catch { return nil }
        }
        return name
    }

    /// Ask for picture files to put in the notes; their paths relative to `deck`.
    @MainActor static func choose(into deck: URL) -> [String] {
        let p = NSOpenPanel()
        p.allowedContentTypes = types
        p.allowsMultipleSelection = true
        p.message = "Choose pictures for the speaker notes"
        guard p.runModal() == .OK else { return [] }
        return p.urls.compactMap { u in (try? Data(contentsOf: u)).flatMap { save($0, ext: u.pathExtension.lowercased(), into: deck) } }
    }

    /// Insert pictures at the selection of a notes text view, each on a line of its own, as typing would (undoable).
    @MainActor static func insert(_ paths: [String], in tv: NSTextView, base: URL, maxWidth: CGFloat) {
        let s = NSMutableAttributedString()
        let attrs = tv.typingAttributes
        let r = tv.selectedRange()
        let text = tv.string as NSString
        if r.location > 0, text.character(at: r.location - 1) != 10 { s.append(NSAttributedString(string: "\n", attributes: attrs)) }
        for (i, p) in paths.enumerated() {
            guard let a = attachment(p, base: base, maxWidth: maxWidth) else { continue }
            let piece = NSMutableAttributedString(attachment: a)
            piece.addAttributes(attrs, range: NSRange(location: 0, length: piece.length))
            s.append(piece)
            if i < paths.count - 1 { s.append(NSAttributedString(string: "\n", attributes: attrs)) }
        }
        let end = r.location + r.length
        if end >= text.length || text.character(at: end) != 10 { s.append(NSAttributedString(string: "\n", attributes: attrs)) }
        guard s.length > 0, tv.shouldChangeText(in: r, replacementString: s.string) else { return }
        tv.textStorage?.replaceCharacters(in: r, with: s)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: r.location + s.length, length: 0))
    }
}

/// A picture in the notes, remembering the path its Markdown names.
final class NoteImageAttachment: NSTextAttachment {
    let path: String
    init(path: String, image: NSImage, maxWidth: CGFloat) {
        self.path = path
        super.init(data: nil, ofType: nil)
        self.image = image
        let size = image.size
        let scale = min(1, maxWidth / max(size.width, 1), 240 / max(size.height, 1))
        bounds = CGRect(x: 0, y: 0, width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
    required init?(coder: NSCoder) { fatalError() }
}

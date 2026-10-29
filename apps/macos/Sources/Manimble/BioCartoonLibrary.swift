import AppKit
import SQLite3

/// Right-click ▸ Add to Local BioCartoon Library… / Upload to Online BioCartoon Library…: the BioCartoon editor's
/// "Add to your library" and "Add to BioCartoon library" dialogs. Your library is the editor's own: the picture goes
/// into its `user_generated` folder and a `user/<slug>` row of the catalog file the command line shares with it
/// (as the editor's `insert_user`). A submission is POSTed to the submissions Worker the way the editor sends it,
/// and kept in Your library meanwhile.
enum BCLibrary {
    /// Limits the Worker enforces (the editor's submit.rs): they hold for Your library too.
    static let maxPNGBytes = 2 * 1024 * 1024
    static let maxSVGBytes = 2 * 1024 * 1024
    static let maxImageSide = 4096
    static let maxPerHour = 10
    static let licenses = [("CC0-1.0", "CC0 (no credit needed)"), ("CC-BY-4.0", "CC BY 4.0 (users must credit you)")]
    static let ccByNeedsNoAI = "This license is not compatible with generative AI content. Check \"No generative AI was used\" above (if correct) to select this license."
    static let alreadySubmitted = "Icon has already been submitted"

    static var submitURL: String {
        let e = ProcessInfo.processInfo.environment["BIOCARTOON_SUBMIT_URL"] ?? ""
        return e.isEmpty ? "https://api.biocartoon.com" : e
    }

    // MARK: the picture

    /// What is added: the SVG's text (kept as one) or nil, and the PNG drawn from it or read from the raster picture,
    /// made smaller when its PNG would be over the limit.
    struct Picture {
        var svg: String?
        var png: Data
        var size: CGSize                // the PNG's, or the SVG's own
        var bytes: Int                  // what is added: the SVG's or the PNG's
        var reducedFrom: CGSize?        // a raster picture's own size, when it was made smaller
        var preview: NSImage
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    static func isSVG(_ d: Data) -> Bool {
        guard let head = String(data: d.prefix(4096), encoding: .utf8)?.lowercased() else { return false }
        return head.contains("<svg")
    }

    static func read(_ path: String) throws -> Picture {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        if isSVG(data), let text = String(data: data, encoding: .utf8) {
            // NSImage draws SVG from macOS 14; the PNG beside it is what Your library and search previews show
            guard let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else {
                throw Failure(description: "This Mac can't draw the SVG (macOS 14 or later is needed)")
            }
            let long = max(img.size.width, img.size.height)
            let k = min(Double(maxImageSide), max(1024, long)) / long
            let w = max(1, Int((img.size.width * k).rounded())), h = max(1, Int((img.size.height * k).rounded()))
            guard let cg = draw(w, h, { NSGraphicsContext.current = NSGraphicsContext(cgContext: $0, flipped: false)
                                         img.draw(in: NSRect(x: 0, y: 0, width: w, height: h)) }),
                  let (fit, png) = fitPNG(cg) else { throw Failure(description: "The SVG could not be drawn") }
            return Picture(svg: text, png: png, size: img.size, bytes: data.count, reducedFrom: nil,
                           preview: NSImage(cgImage: fit, size: NSSize(width: fit.width, height: fit.height)))
        }
        var cg = try ImageExtractor.load(path: path)
        let own = CGSize(width: cg.width, height: cg.height)
        if max(cg.width, cg.height) > maxImageSide, let s = scaled(cg, Double(maxImageSide) / Double(max(cg.width, cg.height))) { cg = s }
        guard let (fit, png) = fitPNG(cg) else { throw Failure(description: "The picture could not be read") }
        let size = CGSize(width: fit.width, height: fit.height)
        return Picture(svg: nil, png: png, size: size, bytes: png.count, reducedFrom: size == own ? nil : own,
                       preview: NSImage(cgImage: fit, size: size))
    }

    private static func draw(_ w: Int, _ h: Int, _ body: (CGContext) -> Void) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        body(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func scaled(_ cg: CGImage, _ k: Double) -> CGImage? {
        let w = max(1, Int((Double(cg.width) * k).rounded())), h = max(1, Int((Double(cg.height) * k).rounded()))
        return draw(w, h) { $0.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)) }
    }

    /// The editor's fit_png: full size when its PNG fits, else scaled down (in proportion) to about the largest that does.
    static func fitPNG(_ cg: CGImage) -> (CGImage, Data)? {
        guard var png = ImageExtractor.png(cg) else { return nil }
        var out = cg, k = 1.0
        while png.count > maxPNGBytes && max(out.width, out.height) > 1 {
            k *= min(sqrt(Double(maxPNGBytes) / Double(png.count)) * 0.98, 0.95)
            guard let s = scaled(cg, k), let p = ImageExtractor.png(s) else { return nil }
            out = s; png = p
        }
        return (out, png)
    }

    static func humanBytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    // MARK: submitted once

    /// FNV-1a of the file, noted when it is submitted so it goes to the BioCartoon library once.
    static func fingerprint(_ path: String) -> String? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        var h: UInt64 = 0xcbf29ce484222325
        d.withUnsafeBytes { for b in $0 { h = (h ^ UInt64(b)) &* 0x100000001b3 } }
        return String(format: "file:%016llx", h)
    }

    static var submitted: [String] {
        get { UserDefaults.standard.stringArray(forKey: "biocartoonSubmitted") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "biocartoonSubmitted") }
    }

    static func wasSubmitted(_ path: String) -> Bool { fingerprint(path).map { submitted.contains($0) } ?? false }

    /// A sliding hour of submission times, so a stuck button can't burn the Worker's daily quota.
    private static var times: [Date] = []
    static func takeSlot() -> String? {
        times.removeAll { -$0.timeIntervalSinceNow >= 3600 }
        guard times.count < maxPerHour else {
            return "Too many submissions; try again in \(Int(ceil((3600 + times[0].timeIntervalSinceNow) / 60))) min"
        }
        times.append(Date())
        return nil
    }

    /// A plausible email address, or empty (the field is optional), as the editor and the Worker check it.
    static func checkEmail(_ s: String) -> String? {
        let s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return s }
        let parts = s.split(separator: "@", omittingEmptySubsequences: false)
        guard s.count <= 254, !s.contains(where: \.isWhitespace), parts.count == 2, !parts[0].isEmpty,
              parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return nil }
        return s
    }

    // MARK: Your library

    struct Row {
        var title, category, description, license, author: String
        var tags: [String]
        var aiUsed: Bool?
    }

    /// The editor's slug for a new library icon: the name, then the time with sub-second digits.
    static func slug(_ name: String) -> String {
        var out = "", dash = false
        for c in name.lowercased() {
            if c.isLetter || c.isNumber { out.append(c); dash = false } else if !dash { out.append("-"); dash = true }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"; f.timeZone = TimeZone(identifier: "UTC")
        let micros = Int(Date().timeIntervalSince1970 * 1_000_000) % 1_000_000
        return "\(out.isEmpty ? "icon" : out)-\(f.string(from: Date()))\(String(format: "%04x", micros & 0xffff))"
    }

    /// Write the picture into the editor's `user_generated` folder and list it in Your library (the shared catalog
    /// file) as `user/<id>`, where `id` is the submission's id once it was accepted, else the slug.
    static func save(_ pic: Picture, _ row: Row, catalog: String, id: String? = nil) throws {
        let dir = URL(fileURLWithPath: catalog).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("user_generated")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let slug = slug(row.title)
        var svgPath: String? = nil
        if let svg = pic.svg {
            let u = dir.appendingPathComponent(slug + ".svg")
            try Data(svg.utf8).write(to: u)
            svgPath = u.path
        }
        let png = dir.appendingPathComponent(slug + ".png")
        try pic.png.write(to: png)
        let key = id ?? slug
        let credited = !(row.author.isEmpty || row.author == "anonymous")
        let credit = "\"\(row.title)\"" + (credited ? " by \(row.author)" : "") + (row.license.isEmpty ? "" : ", \(row.license)")
        let (licenseURL, attribution): (String?, Int) = row.license == "CC-BY-4.0" ? ("https://creativecommons.org/licenses/by/4.0/", 1)
            : row.license == "CC0-1.0" ? ("https://creativecommons.org/publicdomain/zero/1.0/", 0) : (nil, 0)
        let tags = String(data: (try? JSONSerialization.data(withJSONObject: row.tags)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        let w = pic.svg == nil ? Int(pic.size.width) : Int(pic.preview.size.width)
        let h = pic.svg == nil ? Int(pic.size.height) : Int(pic.preview.size.height)

        var db: OpaquePointer?
        guard sqlite3_open_v2(catalog, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db); throw Failure(description: "Could not open the BioCartoon catalog")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000)
        func exec(_ sql: String, _ args: [Any?]) throws {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw Failure(description: String(cString: sqlite3_errmsg(db))) }
            defer { sqlite3_finalize(st) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, a) in args.enumerated() {
                let n = Int32(i + 1)
                switch a {
                case let s as String: sqlite3_bind_text(st, n, s, -1, transient)
                case let v as Int: sqlite3_bind_int64(st, n, Int64(v))
                case let b as Bool: sqlite3_bind_int64(st, n, b ? 1 : 0)
                default: sqlite3_bind_null(st, n)
                }
            }
            guard sqlite3_step(st) == SQLITE_DONE else { throw Failure(description: String(cString: sqlite3_errmsg(db))) }
        }
        let cols = Set((try? columns(db)) ?? [])
        // as the editor's Worker::insert_user (the same license urls and attribution flags as published uploads)
        try exec("INSERT OR REPLACE INTO assets (id, source, source_name, source_id, title, variant, description, category, "
                 + "tags, license, license_raw, license_url, attribution_required, share_alike, author, source_url, doi, credit, "
                 + "svg_key, png_key, png_is_raster, png_width, png_height, svg_bytes, png_bytes, "
                 + "svg_local, png_local, extra, uploaded_at) VALUES (?1, 'user', 'User-generated', ?2, ?3, '', ?4, ?5, ?6, "
                 + "?7, ?7, ?8, ?9, 0, ?10, NULL, NULL, ?11, ?12, ?13, 0, ?14, ?15, NULL, NULL, NULL, ?16, '{\"generated\": true}', NULL)",
                 ["user/" + key, slug, row.title, row.description, row.category, tags, row.license, licenseURL, attribution,
                  row.author, credit, svgPath, "user/\(key).png", w, h, png.path])
        if cols.contains("generative_ai_used") {
            try exec("UPDATE assets SET generative_ai_used = ?1 WHERE id = ?2", [row.aiUsed, "user/" + key])
        }
        // the search index is external-content: it is told about new rows explicitly
        try? exec("INSERT INTO assets_fts(rowid, title, description, tags, category, variant) "
                  + "SELECT rowid, title, description, tags, category, variant FROM assets WHERE id=?1", ["user/" + key])
    }

    private static func columns(_ db: OpaquePointer?) throws -> [String] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM pragma_table_info('assets')", -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [String] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(String(cString: sqlite3_column_text(st, 0))) }
        return out
    }

    // MARK: the BioCartoon library

    struct Meta: Encodable {
        var title, description, category: String
        var tags: [String]
        var author, license: String
        var generative_ai_used: Bool?
        var email: String
        var official: Bool
        enum CodingKeys: CodingKey { case title, description, category, tags, author, license, generative_ai_used, email, official }
        func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(title, forKey: .title); try c.encode(description, forKey: .description); try c.encode(category, forKey: .category)
            if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
            try c.encode(author, forKey: .author); try c.encode(license, forKey: .license)
            try c.encode(generative_ai_used, forKey: .generative_ai_used)    // null: undisclosed
            if !email.isEmpty { try c.encode(email, forKey: .email) }
            if official { try c.encode(true, forKey: .official) }
        }
    }

    /// POST the picture to `<server>/submit` as the editor does: the SVG when it has one (the Worker renders its PNG),
    /// the PNG when the SVG is too large or refused. The submission's id, and why the SVG was refused when the PNG went.
    static func submit(_ pic: Picture, _ meta: Meta) async throws -> (id: String, asPNG: String?) {
        let m = String(data: try JSONEncoder().encode(meta), encoding: .utf8) ?? "{}"
        func send(_ name: String, _ bytes: Data, _ mime: String) async throws -> String {
            let boundary = "biocartoon-\(UUID().uuidString)"
            var body = Data()
            func part(_ header: String, _ value: Data) {
                body.append(Data("--\(boundary)\r\n\(header)\r\n\r\n".utf8)); body.append(value); body.append(Data("\r\n".utf8))
            }
            part("Content-Disposition: form-data; name=\"kind\"", Data("asset".utf8))
            part("Content-Disposition: form-data; name=\"meta\"", Data(m.utf8))
            part("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(name)\"\r\nContent-Type: \(mime)", bytes)
            body.append(Data("--\(boundary)--\r\n".utf8))
            var req = URLRequest(url: URL(string: submitURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/submit")!, timeoutInterval: 120)
            req.httpMethod = "POST"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let (data, res): (Data, URLResponse)
            do { (data, res) = try await URLSession.shared.upload(for: req, from: body) }
            catch { throw Failure(description: "Couldn't reach the submission server: \(error.localizedDescription)") }
            let v = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let status = (res as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                guard let id = v["id"] as? String else { throw Failure(description: "The submission server sent an unexpected reply") }
                return id
            }
            throw Failure(description: v["error"] as? String ?? "The submission server answered HTTP \(status)")
        }
        if let svg = pic.svg, svg.utf8.count <= maxSVGBytes {
            do { return (try await send("svg", Data(svg.utf8), "image/svg+xml"), nil) }
            catch let why as Failure { return (try await send("image", pic.png, "image/png"), why.description) }
        }
        return (try await send("image", pic.png, "image/png"), nil)
    }
}

/// The dialog itself, as the editor lays it out: a large preview, and the details beside it.
@MainActor
final class BCLibraryDialog: NSObject, NSTextFieldDelegate, NSComboBoxDelegate {
    let panel: NSPanel
    let share: Bool
    let pic: BCLibrary.Picture
    var onDone: ((BCLibraryDialog?) -> Void)?

    let nameField = NSTextField()
    let category = NSComboBox()
    let descriptionField = NSTextField()
    let tagsField = NSTextField()
    let noAI = NSButton(checkboxWithTitle: "No generative AI was used to create this asset.", target: nil, action: nil)
    let license = NSPopUpButton(frame: .zero, pullsDown: false)
    let creditField = NSTextField()
    let emailField = NSTextField()
    let official = NSButton(checkboxWithTitle: "Submit as official BioCartoon asset", target: nil, action: nil)
    let pngOK = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let reducedOK = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    let action = NSButton(title: "", target: nil, action: nil)

    private static let formWidth: CGFloat = 320

    init(file: String, picture: BCLibrary.Picture, share: Bool, categories: [BCCategory], within parent: NSWindow) {
        self.share = share
        pic = picture
        let screen = parent.frame.size
        let size = NSSize(width: min(max(screen.width * 0.86, 760), 1400), height: min(max(screen.height * 0.84, 560), 1000))
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        panel.title = share ? "Add to BioCartoon library" : "Add to your library"

        let stem = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        nameField.stringValue = stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        category.isEditable = true; category.completes = true; category.numberOfVisibleItems = 14
        category.placeholderString = "pick one or type your own"
        category.toolTip = "Current categories"
        let tops = categories.filter { !$0.slug.contains(".") }
        for t in tops {
            category.addItem(withObjectValue: t.name)
            for c in categories where c.slug.hasPrefix(t.slug + ".") { category.addItem(withObjectValue: "    " + c.name) }
        }
        descriptionField.placeholderString = "optional"
        descriptionField.usesSingleLineMode = false; descriptionField.cell?.wraps = true; descriptionField.cell?.isScrollable = false
        descriptionField.heightAnchor.constraint(equalToConstant: 56).isActive = true
        tagsField.placeholderString = "optional, commas between"
        tagsField.toolTip = "Words to find it by in search, up to 20 (each up to 40 characters)"
        for (key, name) in BCLibrary.licenses { license.addItem(withTitle: name); license.lastItem?.representedObject = key }
        license.autoenablesItems = false
        creditField.placeholderString = "your name"
        creditField.stringValue = UserDefaults.standard.string(forKey: "biocartoonCredit") ?? ""
        emailField.placeholderString = "optional, never published"
        emailField.toolTip = "Only the BioCartoon team sees it, in case they have a question about your submission"
        emailField.stringValue = UserDefaults.standard.string(forKey: "biocartoonEmail") ?? ""

        // the form, top to bottom, as the editor's
        var rows: [NSView] = [], labels: [NSView] = []
        func field(_ label: String, _ v: NSView) {
            let l = NSTextField(labelWithString: label)
            labels.append(l)
            rows.append(l); rows.append(v)
            v.widthAnchor.constraint(equalToConstant: Self.formWidth).isActive = true
        }
        func dim(_ s: String, _ color: NSColor = .secondaryLabelColor) -> NSTextField {
            let t = NSTextField(wrappingLabelWithString: s)
            t.font = .systemFont(ofSize: NSFont.smallSystemFontSize); t.textColor = color
            t.preferredMaxLayoutWidth = Self.formWidth
            t.widthAnchor.constraint(equalToConstant: Self.formWidth).isActive = true
            return t
        }
        func confirm(_ box: NSButton, _ text: String) -> NSView {
            let label = dim(text, .labelColor)
            label.preferredMaxLayoutWidth = Self.formWidth - 22
            label.widthAnchor.constraint(equalToConstant: Self.formWidth - 22).isActive = true
            let row = NSStackView(views: [box, label])
            row.alignment = .top; row.spacing = 4
            return row
        }
        field("Name", nameField)
        field("Category", category)
        field("Description", descriptionField)
        field("Tags", tagsField)
        if share {
            rows.append(noAI)
            field("License", license)
            field("Credit as", creditField)
            field("Email", emailField)
            rows.append(official)
            rows.append(dim("List under the official BioCartoon library rather than the User-Generated library. You are still listed as the author. Reviewers reserve the right to redirect your submission to the User-Generated library."))
            rows.append(dim("It is reviewed before anyone else sees it, and kept in Your library meanwhile. Once approved, the name, credit and details above are public."))
            rows.append(dim("You keep the copyright. BioCartoon and its users only get the license you chose."))
            rows.append(dim("To submit anonymously, choose the CC0 license and leave \"Credit as\" blank."))
        } else {
            rows.append(dim("Saved on this computer only."))
        }
        let limit = picture.svg != nil ? BCLibrary.maxSVGBytes : BCLibrary.maxPNGBytes
        let over = picture.bytes > limit
        rows.append(NSTextField(labelWithString: "Size: \(Int(picture.size.width.rounded())) × \(Int(picture.size.height.rounded())) px (\(BCLibrary.humanBytes(picture.bytes)))"))
        if over { rows.append(dim("Icons can be up to \(BCLibrary.humanBytes(limit)): simplify the drawing.", .systemRed)) }
        rows.append(NSTextField(labelWithString: picture.svg != nil ? "File type: SVG (vector)" : "File type: PNG (raster)"))
        if picture.svg == nil {
            rows.append(confirm(pngOK, "This file is a PNG (raster). SVG (vector) is recommended for upload. Please check here to confirm this choice."))
        }
        if let o = picture.reducedFrom {
            let pct = Int((100 * (1 - picture.size.width / o.width)).rounded())
            rows.append(confirm(reducedOK, "The image size was reduced \(pct)% (\(Int(o.width)) × \(Int(o.height)) px → \(Int(picture.size.width)) × \(Int(picture.size.height)) px) in order to meet the maximum upload size. Please check here to confirm this choice."))
        }
        action.title = share ? "Submit" : "Save"
        action.bezelStyle = .rounded; action.keyEquivalent = "\r"
        action.bezelColor = Theme.accent
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.keyEquivalent = "\u{1b}"
        // pinned under the form, so they stay in view however long it is
        let buttons = NSStackView(views: [action, cancel])

        let form = NSStackView(views: rows)
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 4
        // a gap above each field, as the editor's add_space
        for (i, v) in rows.enumerated() where i > 0 && labels.contains(where: { $0 === v }) { form.setCustomSpacing(10, after: rows[i - 1]) }
        if share { for v in [noAI, official] { form.setCustomSpacing(10, after: v) } }
        form.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        form.translatesAutoresizingMaskIntoConstraints = false
        let flipped = BCFlipped()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(form)
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = flipped
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: flipped.topAnchor), form.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: flipped.trailingAnchor), form.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(equalToConstant: Self.formWidth + 4),
        ])

        // the preview: the picture fitted into a large panel
        let preview = NSImageView(image: picture.preview)
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.imageAlignment = .alignCenter
        let well = NSBox()
        well.boxType = .custom; well.cornerRadius = 8; well.borderColor = .separatorColor
        well.fillColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1) }
        well.contentViewMargins = NSSize(width: 16, height: 16)
        well.contentView = preview

        let content = NSView()
        for v in [well, scroll, buttons] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        NSLayoutConstraint.activate([
            well.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), well.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            well.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.leadingAnchor.constraint(equalTo: well.trailingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalToConstant: Self.formWidth + 20),
            flipped.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        panel.contentView = content
        panel.initialFirstResponder = nameField

        for f in [nameField, creditField, descriptionField, tagsField, emailField] { f.delegate = self }
        category.delegate = self
        for b in [noAI, official, pngOK, reducedOK] { b.target = self; b.action = #selector(changed) }
        license.target = self; license.action = #selector(changed)
        action.target = self; action.action = #selector(actionPressed)
        refresh()
    }

    private func trimmed(_ f: NSTextField) -> String { f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    var name: String { String(trimmed(nameField).prefix(80)) }
    var categoryName: String { String(category.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)) }
    var descriptionText: String { String(trimmed(descriptionField).prefix(500)) }
    var tags: [String] {
        var seen = Set<String>()
        return tagsField.stringValue.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces).prefix(40)) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(20).map { $0 }
    }
    var credit: String { String(trimmed(creditField).prefix(60)) }
    var email: String { trimmed(emailField) }
    var licenseKey: String { license.selectedItem?.representedObject as? String ?? "CC0-1.0" }
    var noAIChecked: Bool { noAI.state == .on }
    var isOfficial: Bool { official.state == .on }

    /// Why Save / Submit can't be pressed yet, or nil (the editor's reasons, in its order).
    private var why: String? {
        let over = pic.bytes > (pic.svg != nil ? BCLibrary.maxSVGBytes : BCLibrary.maxPNGBytes)
        if name.isEmpty { return "Give it a name first" }
        if share && licenseKey == "CC-BY-4.0" && credit.isEmpty { return "CC BY needs a name to credit, or choose CC0" }
        if over { return "Too large: simplify it first" }
        if pic.svg == nil && pngOK.state != .on { return "Confirm adding it as a PNG first" }
        if pic.reducedFrom != nil && reducedOK.state != .on { return "Confirm adding it at the reduced size first" }
        return nil
    }

    func refresh() {
        // CC BY only for work made without generative AI
        let ccBy = license.item(at: 1)
        ccBy?.isEnabled = noAI.state == .on
        ccBy?.toolTip = noAI.state == .on ? nil : BCLibrary.ccByNeedsNoAI
        if noAI.state != .on && licenseKey == "CC-BY-4.0" { license.selectItem(at: 0) }
        let w = why
        action.isEnabled = w == nil
        action.toolTip = w
    }

    @objc private func changed() { refresh() }
    func controlTextDidChange(_ n: Notification) { refresh() }
    func comboBoxSelectionDidChange(_ n: Notification) {
        // a subcategory is listed indented: keep just its name
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.category.stringValue = self.category.stringValue.trimmingCharacters(in: .whitespaces)
        }
    }
    @objc private func cancelPressed() { onDone?(nil) }
    @objc private func actionPressed() { if why == nil { onDone?(self) } }
}

private final class BCFlipped: NSView { override var isFlipped: Bool { true } }

extension MainController {
    /// The right-click menu's BioCartoon items for a picture of the user's own (as the editor's canvas menu):
    /// keep it in Your library, or submit it to the shared library (once).
    func bioCartoonLibraryItems(_ path: String) -> [NSMenuItem] {
        let local = BCMenuItem("Add to Local BioCartoon Library…") { [weak self] in self?.addToBioCartoonLibrary(path, share: false) }
        local.toolTip = "Keep this picture in Your library, on this computer"
        let online: NSMenuItem
        if BCLibrary.wasSubmitted(path) {
            online = NSMenuItem(title: "Upload to Online BioCartoon Library…", action: nil, keyEquivalent: "")
            online.toolTip = BCLibrary.alreadySubmitted
        } else {
            online = BCMenuItem("Upload to Online BioCartoon Library…") { [weak self] in self?.addToBioCartoonLibrary(path, share: true) }
            online.toolTip = "Submit this picture to the shared BioCartoon library"
        }
        return [local, online]
    }

    /// The editor's "Add to your library" (`share` false) or "Add to BioCartoon library" dialog for the picture at `path`.
    func addToBioCartoonLibrary(_ path: String, share: Bool) {
        Task { @MainActor in
            guard case .success(let exe) = await BioCartoonCLI.usable() else {
                toast("BioCartoon needs installing or updating: open Insert ▸ BioCartoon Icons…", error: true)
                return
            }
            guard let catalog = await BioCartoonCLI.catalogPath(exe), FileManager.default.fileExists(atPath: catalog) else {
                toast("The BioCartoon catalog is not downloaded yet: open Insert ▸ BioCartoon Icons… first", error: true)
                return
            }
            let pic: BCLibrary.Picture
            do { pic = try await Task.detached { try BCLibrary.read(path) }.value }
            catch { toast("Could not read the picture: \(error)", error: true); return }
            let cats = (try? await BioCartoonCLI.categories(exe)) ?? []
            let d = BCLibraryDialog(file: path, picture: pic, share: share, categories: cats, within: window)
            d.onDone = { [weak self] done in
                guard let self else { return }
                if let done {
                    guard self.finishBioCartoonLibrary(done, path: path, catalog: catalog) else { return }
                }
                self.window.endSheet(d.panel)
                d.onDone = nil      // it held the dialog while the sheet was up
            }
            window.beginSheet(d.panel, completionHandler: nil)
        }
    }

    /// Save (and with `share`, submit) what the dialog says; false keeps the dialog open (a problem was shown).
    func finishBioCartoonLibrary(_ d: BCLibraryDialog, path: String, catalog: String) -> Bool {
        let pic = d.pic, title = d.name
        let aiUsed: Bool? = d.noAIChecked ? false : nil
        guard d.share else {
            do {
                try BCLibrary.save(pic, .init(title: title, category: d.categoryName, description: d.descriptionText, license: "",
                                              author: d.credit, tags: d.tags, aiUsed: aiUsed), catalog: catalog)
            } catch { toast("Could not add \"\(title)\" to your library: \(error)", error: true); return false }
            toast("Added \"\(title)\" to your library")
            biocartoonPane?.reload()
            return true
        }
        if d.licenseKey == "CC-BY-4.0" && !d.noAIChecked { toast(BCLibrary.ccByNeedsNoAI, error: true); return false }
        guard let email = BCLibrary.checkEmail(d.email) else {
            toast("\"\(d.email)\" doesn't look like an email address", error: true); return false
        }
        let fingerprint = BCLibrary.fingerprint(path)
        if let f = fingerprint, BCLibrary.submitted.contains(f) {
            toast("\"\(title)\" was submitted to the BioCartoon library already", error: true); return true
        }
        if let busy = BCLibrary.takeSlot() { toast(busy, error: true); return false }
        UserDefaults.standard.set(d.credit, forKey: "biocartoonCredit")
        UserDefaults.standard.set(email, forKey: "biocartoonEmail")
        let author = d.credit.isEmpty ? "anonymous" : d.credit
        let meta = BCLibrary.Meta(title: title, description: d.descriptionText, category: d.categoryName, tags: d.tags,
                                  author: author, license: d.licenseKey, generative_ai_used: aiUsed, email: email, official: d.isOfficial)
        let row = BCLibrary.Row(title: title, category: d.categoryName, description: d.descriptionText, license: d.licenseKey,
                                author: author, tags: d.tags, aiUsed: aiUsed)
        // noted now, so it can't be submitted again while this one is on its way; dropped if it fails
        if let f = fingerprint { BCLibrary.submitted.append(f) }
        busyPill.show("Submitting \(title)…", symbol: nil, tint: nil, spinning: true, cancellable: false)
        Task { @MainActor in
            defer { busyPill.hide(); biocartoonPane?.reload() }
            do {
                let (id, asPNG) = try await BCLibrary.submit(pic, meta)
                try? BCLibrary.save(pic, row, catalog: catalog, id: id)
                if let why = asPNG {
                    toast("Submitted \"\(title)\" for review as a PNG (the SVG was refused: \(why)). Your library keeps the SVG.")
                } else {
                    toast("Submitted \"\(title)\" for review. It is in your library now and shared once approved.")
                }
            } catch {
                if let f = fingerprint, let i = BCLibrary.submitted.lastIndex(of: f) { BCLibrary.submitted.remove(at: i) }
                try? BCLibrary.save(pic, row, catalog: catalog)
                toast("\"\(title)\" is in your library but was not submitted: \(error)", error: true)
            }
        }
        return true
    }
}

extension MainController {
    // MARK: headless check (MANIMBLE_TEST_BCLIBRARY=1, MANIMBLE_TEST_OUT=dir with catalog/<copy>.sqlite)

    /// Both dialogs on a made-up picture: shots of each, Save into the catalog copy, Submit to BIOCARTOON_SUBMIT_URL.
    func bcLibraryTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "bclibrary.log") }
        func shot(_ v: NSView?, _ name: String) {
            guard let v = v, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
        }
        Task { @MainActor in
            let catalog = dir + "catalog/test.sqlite"
            let png = dir + "test_cell-picture.png"
            let img = NSImage(size: NSSize(width: 600, height: 400), flipped: false) { r in
                NSColor.systemTeal.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 40, dy: 40)).fill(); return true
            }
            try? ImageExtractor.png(img.cgImage(forProposedRect: nil, context: nil, hints: nil)!)?.write(to: URL(fileURLWithPath: png))
            let svg = dir + "test-vector.svg"
            try? ##"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect x="10" y="10" width="180" height="80" fill="#c33"/></svg>"##.write(toFile: svg, atomically: true, encoding: .utf8)
            log("menu items: " + bioCartoonLibraryItems(png).map { "\($0.title) enabled \($0.action != nil)" }.joined(separator: "; "))
            let cats = ((try? await BioCartoonCLI.categories(BioCartoonCLI.find() ?? "")) ?? [])
            for (file, share, name) in [(png, false, "local"), (png, true, "online"), (svg, true, "online-svg")] {
                guard let pic = try? BCLibrary.read(file) else { log("\(name): unreadable"); continue }
                log("\(name): svg \(pic.svg != nil) size \(pic.size) bytes \(pic.bytes)")
                let d = BCLibraryDialog(file: file, picture: pic, share: share, categories: cats, within: window)
                window.beginSheet(d.panel, completionHandler: nil)
                try? await Task.sleep(nanoseconds: 600_000_000)
                log("  enabled before confirming: \(d.action.isEnabled) (\(d.action.toolTip ?? "-"))")
                d.category.stringValue = "Cells"; d.tagsField.stringValue = "cell, Cell, test"
                d.descriptionField.stringValue = "A test picture"
                if share { d.noAI.state = .on; d.refresh(); d.license.selectItem(at: 1); d.creditField.stringValue = "Tester" }
                d.pngOK.state = .on; d.refresh()
                log("  enabled after: \(d.action.isEnabled), tags \(d.tags), license \(d.licenseKey)")
                try? await Task.sleep(nanoseconds: 300_000_000)
                shot(d.panel.contentView, "bclibrary-\(name).png")
                let ok = finishBioCartoonLibrary(d, path: file, catalog: catalog)
                window.endSheet(d.panel)
                log("  finished: \(ok)")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            log("submitted list: \(BCLibrary.submitted.count), menu now: " + bioCartoonLibraryItems(png).map { "\($0.title) enabled \($0.action != nil)" }.joined(separator: "; "))
            log("done")
        }
    }
}

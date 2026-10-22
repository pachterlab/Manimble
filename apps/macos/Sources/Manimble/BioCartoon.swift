import AppKit
import ImageIO

/// One icon of the BioCartoon catalog, as `biocartoon search --json` lists it.
struct BCIcon: Codable, Equatable {
    var id: String
    var title: String
    var source: String
    var source_name: String?
    var credit: String?
    var license: String?
    var category: String?       // the database's own categories, ", " between several
    var author: String?
    var url: String?            // a web URL, or a local path for the user's own uploads
    var png_local: String?
    var width: Double?
    var height: Double?

    /// The database the icon is listed under: BioCartoon's own drawings are uploads (source `user`) by "BioCartoon".
    var database: String { source == "user" && author == "BioCartoon" ? "biocartoon" : source }
}

/// A category of BioCartoon's taxonomy (`biocartoon --categories --json`); a slug with a dot is a subcategory.
struct BCCategory: Decodable {
    var slug: String
    var name: String
    var icons: Int?
}

/// How many icons each filter choice finds under the search words and the other filters (`biocartoon search --facets --json`):
/// a choice isn't counted under its own dropdown, so picking one leaves the others of that dropdown listed.
struct BCFacets: Decodable {
    struct Row: Decodable {
        var source: String?
        var license: String?
        var slug: String?
        var category: String?
        var icons: Int
    }
    var sources: [Row]
    var licenses: [Row]
    var categories: [Row]
    var db_categories: [Row]

    func source(_ key: String) -> Int { sources.first { $0.source == key }?.icons ?? 0 }
    func taxon(_ slug: String) -> Int { categories.first { $0.slug == slug }?.icons ?? 0 }
}

/// A collection of the catalog (`biocartoon --sources --json`).
struct BCSource: Decodable {
    var code: String
    var name: String
    var source: String
    var icons: Int?
}

/// The `biocartoon` command line: the catalog search, downloads and the catalog sync all go through it.
enum BioCartoonCLI {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Manimble's own Python environment, where `pip install biocartoon` puts the command.
    static var python: String {
        if let saved = UserDefaults.standard.string(forKey: "python") { return saved }
        return Workspace.base.appendingPathComponent("python/bin/python").path
    }

    /// An explicit choice, then Manimble's environment, the BioCartoon desktop app's own copy and the login PATH.
    static func find() -> String? {
        let fm = FileManager.default
        var c: [String] = []
        if let e = ProcessInfo.processInfo.environment["MANIMBLE_BIOCARTOON"] { c.append(e) }
        c.append(URL(fileURLWithPath: python).deletingLastPathComponent().appendingPathComponent("biocartoon").path)
        c.append(Workspace.base.appendingPathComponent("python/bin/biocartoon").path)
        let home = fm.homeDirectoryForCurrentUser.path
        for apps in ["/Applications", home + "/Applications"] { c.append(apps + "/BioCartoon.app/Contents/MacOS/biocartoon") }
        c += ["/opt/homebrew/bin/biocartoon", "/usr/local/bin/biocartoon", home + "/.local/bin/biocartoon", home + "/.cargo/bin/biocartoon"]
        if let hit = c.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }
        let out = (try? runSync("/bin/zsh", ["-lc", "command -v biocartoon"], timeout: 10)).flatMap { String(data: $0, encoding: .utf8) }
        let path = out?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    /// Run a program to completion and return its stdout (stderr becomes the error on failure).
    static func runSync(_ exe: String, _ args: [String], timeout: TimeInterval) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw Failure(description: msg.isEmpty ? "\(URL(fileURLWithPath: exe).lastPathComponent) exited with status \(p.terminationStatus)" : msg)
        }
        return data
    }

    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 120) async throws -> Data {
        try await Task.detached(priority: .userInitiated) { try runSync(exe, args, timeout: timeout) }.value
    }

    /// The first version whose `search` takes the author, category, DB-category and license filters and counts their
    /// choices (`--facets`).
    static let filtersSince = "0.3.1"

    /// `biocartoon --version --json`: the program's version ("0.3.0").
    static func version(_ exe: String) async throws -> String {
        struct V: Decodable { var version: String }
        return try JSONDecoder().decode(V.self, from: try await run(exe, ["--version", "--json"])).version
    }

    /// One page of `biocartoon search` keeping what passes `filter` (each option repeated per value; 0.3.0+).
    static func search(_ exe: String, query: String, filter: BCFilter, sort: String, offset: Int, limit: Int) async throws -> [BCIcon] {
        var args = ["search"]
        if !query.isEmpty { args.append(query) }
        args += ["--icons", "--no-sql", "--json", "--limit", String(limit), "--offset", String(offset), "--sort", sort]
        struct Hits: Decodable { var icons: [BCIcon]? }
        // the first search downloads the catalog, so it may take a while
        return try JSONDecoder().decode(Hits.self, from: try await run(exe, args + filterArgs(filter), timeout: 300)).icons ?? []
    }

    /// `search`'s options for what passes `filter`.
    private static func filterArgs(_ filter: BCFilter) -> [String] {
        var args: [String] = []
        for s in filter.sources.sorted() { args += ["--source", s] }
        for a in filter.authorParts { args += ["--author", a] }
        for c in filter.categories.sorted() { args += ["--category", c] }
        for s in filter.subcategories.sorted() { args += ["--subcategory", s] }
        for k in filter.dbCats.sorted() { let d = BCFilter.split(k); args += ["--db-category", "\(d.database):\(d.category)"] }
        for l in filter.licenses.sorted() { args += ["--license", l] }
        return args
    }

    /// How many icons each dropdown's choices find under `query` and the other filters (`search --facets`, 0.3.1+).
    static func facets(_ exe: String, query: String, filter: BCFilter) async throws -> BCFacets {
        var args = ["search"]
        if !query.isEmpty { args.append(query) }
        args += ["--facets", "--icons", "--no-sql", "--json"]
        return try JSONDecoder().decode(BCFacets.self, from: try await run(exe, args + filterArgs(filter)))
    }

    static func categories(_ exe: String) async throws -> [BCCategory] {
        try JSONDecoder().decode([BCCategory].self, from: try await run(exe, ["--categories", "--json"]))
    }

    /// Each database's own categories with their icon counts (`biocartoon --db-categories --json`).
    static func dbCategories(_ exe: String) async throws -> [(database: String, category: String, count: Int)] {
        struct Row: Decodable { var source: String; var category: String; var icons: Int? }
        return try JSONDecoder().decode([Row].self, from: try await run(exe, ["--db-categories", "--json"]))
            .map { ($0.source, $0.category, $0.icons ?? 0) }
    }

    /// A value of a `search --sql` row.
    enum SQLValue: Decodable {
        case string(String), number(Double), null
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else if let b = try? c.decode(Bool.self) { self = .number(b ? 1 : 0) }
            else { self = .string(try c.decode(String.self)) }
        }
        var string: String {
            switch self { case .string(let s): return s; case .number(let n): return String(Int(n)); case .null: return "" }
        }
        var int: Int { if case .number(let n) = self { return Int(n) }; return 0 }
    }

    /// One read-only statement on the catalog (`search --sql`): its rows.
    static func sql(_ exe: String, _ statement: String, maxRows: Int = 4000) async throws -> [[SQLValue]] {
        struct Result: Decodable { var rows: [[SQLValue]] }
        return try JSONDecoder().decode(Result.self, from: try await run(exe, ["search", statement, "--sql", "--json", "--max-rows", String(maxRows)])).rows
    }

    /// The licenses in the catalog with their icon counts (one per drawing: colour variants count once), for the License dropdown.
    static func licenseCounts(_ exe: String) async throws -> [(String, Int)] {
        try await sql(exe, "SELECT a.license, count(DISTINCT coalesce(a.grp, a.source || '/' || a.title)) FROM assets a WHERE a.png_key IS NOT NULL GROUP BY a.license ORDER BY a.license")
            .compactMap { r in r.count == 2 && !r[0].string.isEmpty ? (r[0].string, r[1].int) : nil }
    }

    static func sources(_ exe: String) async throws -> [BCSource] {
        try JSONDecoder().decode([BCSource].self, from: try await run(exe, ["--sources", "--json"]))
    }

    /// Download the icon's PNG to `dest` (longest side at most `maxSide` px).
    static func fetch(_ exe: String, id: String, to dest: URL, maxSide: Int = 1600) async throws {
        _ = try await run(exe, ["fetch", id, "--out", dest.path, "--max-side", String(maxSide), "--json"])
    }

    /// Crop the fully transparent border many catalog PNGs carry, so the picture's box hugs the drawing.
    /// Returns the picture's size afterwards.
    static func trimTransparentMargins(_ url: URL) -> CGSize {
        guard let img = try? ImageExtractor.load(path: url.path) else { return CGSize(width: 1, height: 1) }
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return CGSize(width: w, height: h) }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w where px[(y * w + x) * 4 + 3] > 8 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        guard x1 >= x0, y1 >= y0 else { return CGSize(width: w, height: h) }
        let pad = 2
        let r = CGRect(x: max(0, x0 - pad), y: max(0, y0 - pad), width: min(w, x1 + pad + 1) - max(0, x0 - pad),
                       height: min(h, y1 + pad + 1) - max(0, y0 - pad))
        guard r.width * r.height < 0.95 * Double(w * h), let cropped = img.cropping(to: r),     // rows top-down in both
              let data = ImageExtractor.png(cropped), (try? data.write(to: url)) != nil else { return CGSize(width: w, height: h) }
        return r.size
    }

    /// `pip install --upgrade biocartoon` into Manimble's Python environment.
    static func install() async throws {
        _ = try await run(python, ["-m", "pip", "install", "--upgrade", "--disable-pip-version-check", "biocartoon"], timeout: 600)
    }

    /// Badge colours of the BioCartoon app, one per collection.
    static func badgeColor(_ source: String) -> NSColor {
        switch source {
        case "bioart": return NSColor(hex: "#2F80ED")
        case "bioicons": return NSColor(hex: "#27AE60")
        case "servier": return NSColor(hex: "#8E44AD")
        case "scidraw": return NSColor(hex: "#E67E22")
        case "healthicons": return NSColor(hex: "#16A085")
        case "reactome": return NSColor(hex: "#C0392B")
        case "openmoji": return NSColor(hex: "#F1C40F")
        case "biocartoon": return Theme.warm
        case "user": return NSColor(hex: "#607D8B")
        default: return NSColor(hex: "#9E9E9E")
        }
    }

    /// The palette logo used for the toolbar button and the panel.
    static let logo: NSImage = {
        if let u = Bundle.main.url(forResource: "biocartoon", withExtension: "png"), let img = NSImage(contentsOf: u) { return img }
        return NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "BioCartoon") ?? NSImage()
    }()
}

/// Thumbnails, downsampled from the icons' PNGs and kept in memory.
@MainActor
final class BCThumbs {
    static let shared = BCThumbs()
    private let cache = NSCache<NSString, NSImage>()
    private var waiting: [String: [(NSImage?) -> Void]] = [:]

    func image(for icon: BCIcon, _ done: @escaping (NSImage?) -> Void) {
        if let img = cache.object(forKey: icon.id as NSString) { done(img); return }
        if waiting[icon.id] != nil { waiting[icon.id]!.append(done); return }
        waiting[icon.id] = [done]
        let id = icon.id
        let local = icon.png_local ?? (icon.url?.hasPrefix("/") == true ? icon.url : nil)
        Task.detached(priority: .utility) {
            var data: Data?
            if let p = local { data = FileManager.default.contents(atPath: p) }
            else if let s = icon.url, let u = URL(string: s) { data = try? await URLSession.shared.data(from: u).0 }
            let cg = data.flatMap { Self.downsample($0, maxSide: 240) }
            await MainActor.run {
                let img = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                if let img = img { self.cache.setObject(img, forKey: id as NSString) }
                for f in self.waiting.removeValue(forKey: id) ?? [] { f(img) }
            }
        }
    }

    nonisolated static func downsample(_ data: Data, maxSide: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxSide]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// A result tile: white card, thumbnail, collection badge. Click inserts the icon; dragging it onto the slide places it there.
final class BCTile: NSCollectionViewItem, NSDraggingSource {
    static let id = NSUserInterfaceItemIdentifier("bctile")
    var icon: BCIcon?
    var onClick: ((BCIcon) -> Void)?
    private let thumb = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private var downAt: NSPoint?

    override func loadView() {
        let v = TileView()
        v.owner = self
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.cgColor
        v.layer?.cornerRadius = 8
        v.layer?.borderWidth = 1
        v.layer?.borderColor = NSColor.separatorColor.cgColor
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        badge.font = Theme.font(9, .semibold); badge.textColor = .white; badge.alignment = .center
        badge.wantsLayer = true; badge.layer?.cornerRadius = 4; badge.drawsBackground = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(thumb); v.addSubview(badge)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8), thumb.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            thumb.topAnchor.constraint(equalTo: v.topAnchor, constant: 8), thumb.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
            badge.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 5), badge.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -5),
            badge.widthAnchor.constraint(equalToConstant: 22), badge.heightAnchor.constraint(equalToConstant: 14),
        ])
        view = v
    }

    func show(_ icon: BCIcon, code: String) {
        self.icon = icon
        badge.stringValue = code
        badge.backgroundColor = BioCartoonCLI.badgeColor(icon.database)
        badge.isHidden = code.isEmpty
        var tip = icon.title
        if let c = icon.category, !c.isEmpty { tip += "\n" + c }
        if let c = icon.credit { tip += "\n\n" + c }
        view.toolTip = tip + "\n\nClick to insert, or drag onto the slide."
        thumb.image = nil
        BCThumbs.shared.image(for: icon) { [weak self] img in
            if self?.icon?.id == icon.id { self?.thumb.image = img }
        }
    }

    final class TileView: NSView {
        weak var owner: BCTile?
        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        }
        override func mouseEntered(with e: NSEvent) { layer?.borderColor = Theme.accent.cgColor; layer?.borderWidth = 2 }
        override func mouseExited(with e: NSEvent) { layer?.borderColor = NSColor.separatorColor.cgColor; layer?.borderWidth = 1 }
        override func mouseDown(with e: NSEvent) { owner?.downAt = e.locationInWindow }
        override func mouseDragged(with e: NSEvent) {
            guard let o = owner, let start = o.downAt, let icon = o.icon,
                  hypot(e.locationInWindow.x - start.x, e.locationInWindow.y - start.y) > 4 else { return }
            o.downAt = nil
            let item = NSPasteboardItem()
            item.setData((try? JSONEncoder().encode(icon)) ?? Data(), forType: BioCartoonPane.dragType)
            let drag = NSDraggingItem(pasteboardWriter: item)
            let img = o.thumb.image ?? BioCartoonCLI.logo
            let side: CGFloat = 96
            let s = side / max(img.size.width, img.size.height, 1)
            let size = NSSize(width: img.size.width * s, height: img.size.height * s)
            let p = convert(e.locationInWindow, from: nil)
            drag.setDraggingFrame(NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2, width: size.width, height: size.height), contents: img)
            beginDraggingSession(with: [drag], event: e, source: o)
        }
        override func mouseUp(with e: NSEvent) {
            if owner?.downAt != nil, let o = owner, let icon = o.icon { o.onClick?(icon) }
            owner?.downAt = nil
        }
    }

    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .copy : []
    }
}

/// What the filter dropdowns keep (the funnel of the BioCartoon editor's search), as `biocartoon search` takes them: each
/// one keeps what matches any of its entries (none keeps everything), and an icon has to pass all of them.
struct BCFilter: Equatable {
    var sources: Set<String> = []        // databases, by key ("bioart")
    var authors = ""                      // parts of names, commas between
    var categories: Set<String> = []     // taxonomy slugs ("cells")
    var subcategories: Set<String> = []  // subcategory slugs ("cells.cell_types")
    var dbCats: Set<String> = []          // a database's own categories, as `key(_:_:)` makes them
    var licenses: Set<String> = []

    var authorParts: [String] {
        authors.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
    var isEmpty: Bool {
        sources.isEmpty && authorParts.isEmpty && categories.isEmpty && subcategories.isEmpty && dbCats.isEmpty && licenses.isEmpty
    }

    static func key(_ database: String, _ category: String) -> String { database + "\t" + category }
    static func split(_ key: String) -> (database: String, category: String) {
        let p = key.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(p[0]), p.count > 1 ? String(p[1]) : "")
    }
}

/// A dropdown whose entries tick on and off, titled with what is picked ("Any" when nothing is).
final class BCMultiPopup: NSPopUpButton {
    private(set) var picked: Set<String> = []
    private var names: [String: String] = [:]
    var onChange: (() -> Void)?

    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: true)
        controlSize = .small
        font = Theme.font(11)
        menu?.autoenablesItems = false
        target = self; action = #selector(toggled)
        setChoices([])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// (key, name, icon count) in display order; picks of keys no longer offered are dropped.
    func setChoices(_ choices: [(key: String, name: String, count: Int?)]) {
        removeAllItems()
        addItem(withTitle: "Any")          // the pull-down's title slot
        names = [:]
        for c in choices {
            let item = NSMenuItem(title: c.count.map { "\(c.name) (\(NumberFormatter.localizedString(from: NSNumber(value: $0), number: .decimal)))" } ?? c.name,
                                  action: nil, keyEquivalent: "")
            item.representedObject = c.key
            menu?.addItem(item)
            names[c.key] = c.name
        }
        picked = picked.filter { names[$0] != nil }
        refreshTitle()
    }

    func clear() { picked = []; refreshTitle() }
    func pick(_ keys: Set<String>) { picked = keys.filter { names[$0] != nil }; refreshTitle() }

    @objc private func toggled() {
        guard let k = selectedItem?.representedObject as? String else { return }
        if picked.contains(k) { picked.remove(k) } else { picked.insert(k) }
        refreshTitle()
        onChange?()
    }

    private func refreshTitle() {
        var shown: [String] = []
        for item in itemArray.dropFirst() {
            let k = item.representedObject as? String ?? ""
            item.state = picked.contains(k) ? .on : .off
            if picked.contains(k) { shown.append(names[k] ?? k) }
        }
        item(at: 0)?.title = shown.isEmpty ? "Any" : shown.joined(separator: ", ")
        synchronizeTitleAndSelectedItem()
    }
}

/// A view painted in the window's background colour: the pane sits where the inspector's scroll view, which paints its own, was.
final class BCBackdrop: NSView {
    override func draw(_ r: NSRect) { NSColor.windowBackgroundColor.setFill(); r.fill() }
}

/// The BioCartoon icon search (Insert ▸ BioCartoon Icons…), shown in the inspector's place: the BioCartoon
/// editor's search sidebar, backed by the `biocartoon` command line.
@MainActor
final class BioCartoonPane: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSSearchFieldDelegate {
    static let dragType = NSPasteboard.PasteboardType("com.manimble.biocartoon-icon")
    let view: NSView = BCBackdrop()
    /// Insert an icon at the slide's centre (a click on its tile).
    var onInsert: ((BCIcon) -> Void)?
    /// The × in the corner: back to the inspector.
    var onClose: (() -> Void)?

    private let search = NSSearchField()
    private let funnel = NSButton()
    private let filterBox = NSBox()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let dbPopup = BCMultiPopup(frame: .zero, pullsDown: true)
    private let authorField = NSTextField()
    private let catPopup = BCMultiPopup(frame: .zero, pullsDown: true)
    private let subPopup = BCMultiPopup(frame: .zero, pullsDown: true)
    private let dbCatPopup = BCMultiPopup(frame: .zero, pullsDown: true)
    private let licensePopup = BCMultiPopup(frame: .zero, pullsDown: true)
    private let clearButton = NSButton(title: "Clear filters", target: nil, action: nil)
    private let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(labelWithString: "")
    private let installButton = NSButton(title: "Install BioCartoon", target: nil, action: nil)
    private let grid = NSCollectionView()
    private let scroll = NSScrollView()
    private let creditLabel = NSTextField(wrappingLabelWithString: "")
    private let copyCredit = NSButton(title: "Copy credit", target: nil, action: nil)
    private var creditBox: NSStackView!

    private(set) var exe: String?
    private var filtersSupported = true     // a `biocartoon` from before 0.3.1 has no filter options (or their counts)
    private var sources: [BCSource] = []
    private var categories: [BCCategory] = []
    private var dbCategories: [(database: String, category: String, count: Int)] = []
    private var licenses: [(String, Int)] = []
    /// The dropdowns' counts under the search and the filters (nil until they come: the whole catalog's counts then),
    /// and the search and filters they are for (or loading for).
    private(set) var facets: BCFacets?
    private var facetsFor: (query: String, filter: BCFilter)?
    private var facetsRequest = 0, facetsAnswered = 0
    private(set) var filter = BCFilter()
    private var results: [BCIcon] = []
    private var more = false
    private var loading = false
    private var generation = 0
    private var typing: DispatchWorkItem?
    private static let pageSize = 60
    private static let sorts = [("Relevance", "relevance"), ("Popular", "popular"), ("A–Z", "az"), ("Z–A", "za")]

    override init() {
        super.init()
        let logo = NSImageView(image: BioCartoonCLI.logo)
        logo.widthAnchor.constraint(equalToConstant: 20).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let heading = NSTextField(labelWithString: "BioCartoon")
        heading.font = Theme.font(14, .semibold)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close") ?? NSImage(),
                             target: self, action: #selector(closePressed))
        close.isBordered = false
        close.contentTintColor = .tertiaryLabelColor
        close.toolTip = "Back to the inspector"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let head = NSStackView(views: [logo, heading, spacer, close]); head.spacing = 7

        search.placeholderString = "Search icons (cell, neuron, mouse…)"
        search.delegate = self
        search.sendsSearchStringImmediately = false
        search.target = self; search.action = #selector(searchSubmitted)
        search.setContentHuggingPriority(.init(1), for: .horizontal)
        funnel.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Filters")
        funnel.isBordered = false
        funnel.imageScaling = .scaleProportionallyDown
        funnel.target = self; funnel.action = #selector(funnelPressed)
        funnel.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let searchRow = NSStackView(views: [search, funnel]); searchRow.spacing = 2

        summary.font = Theme.font(10); summary.textColor = .secondaryLabelColor
        summary.maximumNumberOfLines = 2
        summary.isHidden = true

        // the filters, laid out like the BioCartoon editor's: a label and a dropdown per row
        for p in [dbPopup, subPopup, dbCatPopup, licensePopup] { p.onChange = { [weak self] in self?.filtersEdited() } }
        catPopup.onChange = { [weak self] in self?.categoriesEdited() }
        authorField.placeholderString = "Any (commas for several)"
        authorField.font = Theme.font(11); authorField.controlSize = .small
        authorField.delegate = self
        let dbCatLabel = fieldLabel("DB category")
        dbCatLabel.toolTip = "A database's own categories, by its code (BA: NIAID NIH BioArt, …)"
        let rows: [[NSView]] = [[fieldLabel("Database"), dbPopup], [fieldLabel("Author"), authorField], [fieldLabel("Category"), catPopup],
                                [fieldLabel("Subcategory"), subPopup], [dbCatLabel, dbCatPopup], [fieldLabel("License"), licensePopup]]
        for r in rows { r[1].setContentHuggingPriority(.init(1), for: .horizontal) }
        let table = NSGridView(views: rows)
        table.rowSpacing = 6; table.columnSpacing = 8
        table.column(at: 0).width = 78
        table.column(at: 1).xPlacement = .fill
        table.rowAlignment = .none
        for r in 0..<table.numberOfRows { table.row(at: r).yPlacement = .center }
        table.translatesAutoresizingMaskIntoConstraints = false
        clearButton.controlSize = .small; clearButton.bezelStyle = .rounded
        clearButton.target = self; clearButton.action = #selector(clearFilters)
        clearButton.isHidden = true
        let filterStack = NSStackView(views: [table, clearButton])
        filterStack.orientation = .vertical; filterStack.alignment = .leading; filterStack.spacing = 8
        filterStack.translatesAutoresizingMaskIntoConstraints = false
        filterBox.boxType = .custom; filterBox.cornerRadius = 8; filterBox.borderWidth = 0
        filterBox.fillColor = .quaternaryLabelColor
        filterBox.contentViewMargins = .zero
        if let cv = filterBox.contentView {
            cv.addSubview(filterStack)
            NSLayoutConstraint.activate([
                filterStack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 10), filterStack.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -10),
                filterStack.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8), filterStack.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
                table.widthAnchor.constraint(equalTo: filterStack.widthAnchor),
            ])
        }
        filterBox.isHidden = true
        setSources([]); setCategories([]); setLicenses([]); setDbCategories([])

        sortPopup.controlSize = .small
        sortPopup.font = Theme.font(11)
        sortPopup.addItems(withTitles: Self.sorts.map { $0.0 })
        sortPopup.selectItem(at: max(0, Self.sorts.firstIndex { $0.1 == UserDefaults.standard.string(forKey: "biocartoonSort") } ?? 0))
        sortPopup.target = self; sortPopup.action = #selector(sortChanged)
        status.font = Theme.font(11); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sortRow = NSStackView(views: [fieldLabel("Sort"), sortPopup, status]); sortRow.spacing = 6

        installButton.target = self; installButton.action = #selector(installPressed)
        installButton.bezelColor = Theme.accent
        installButton.isHidden = true

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 96, height: 96)
        layout.minimumInteritemSpacing = 6; layout.minimumLineSpacing = 6
        layout.sectionInset = NSEdgeInsets(top: 2, left: 0, bottom: 12, right: 0)
        grid.collectionViewLayout = layout
        grid.dataSource = self
        grid.delegate = self
        grid.isSelectable = false
        grid.backgroundColors = [.clear]
        grid.register(BCTile.self, forItemWithIdentifier: BCTile.id)
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: scroll)

        creditLabel.font = Theme.font(10); creditLabel.textColor = .secondaryLabelColor
        creditLabel.maximumNumberOfLines = 3
        creditLabel.isSelectable = true
        copyCredit.controlSize = .small; copyCredit.bezelStyle = .rounded
        copyCredit.target = self; copyCredit.action = #selector(copyCreditPressed)
        let creditBox = NSStackView(views: [creditLabel, copyCredit])
        creditBox.orientation = .vertical; creditBox.alignment = .leading; creditBox.spacing = 4
        creditBox.isHidden = true
        self.creditBox = creditBox

        let stack = NSStackView(views: [head, searchRow, summary, filterBox, sortRow, installButton, scroll, creditBox])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [head, searchRow, summary, filterBox, sortRow, scroll, creditBox] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        creditLabel.preferredMaxLayoutWidth = 300
        summary.preferredMaxLayoutWidth = 300
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// The pane came into view: focus the search box and get the command line ready.
    func activate(in window: NSWindow?) {
        window?.makeFirstResponder(search)
        if exe == nil { locate() }
    }

    private func locate() {
        status.stringValue = "Looking for biocartoon…"
        Task {
            let found = await Task.detached { BioCartoonCLI.find() }.value
            exe = found
            facets = nil; facetsFor = nil
            installButton.isHidden = found != nil
            guard let exe = found else {
                status.stringValue = ""
                setMessage("The BioCartoon command line is not installed. Install it into Manimble's Python environment (pip install biocartoon) to search 15,000+ open-licensed science icons.")
                return
            }
            // the first call downloads the catalog, so it goes alone; the dropdowns fill in behind the results
            if let s = try? await BioCartoonCLI.sources(exe) { setSources(s) }
            let version = (try? await BioCartoonCLI.version(exe)) ?? "0"
            filtersSupported = version.compare(BioCartoonCLI.filtersSince, options: .numeric) != .orderedAscending
            funnel.isEnabled = filtersSupported
            if !filtersSupported {
                filter = BCFilter()
                filterBox.isHidden = true
                refreshFilterChrome()
                installButton.title = "Update BioCartoon"
                installButton.isHidden = false
                creditLabel.stringValue = "biocartoon \(version) is installed; the filters need \(BioCartoonCLI.filtersSince) or newer (pip install --upgrade biocartoon)."
                creditBox.isHidden = false
                copyCredit.isHidden = true
            }
            reload()
            async let cats = BioCartoonCLI.categories(exe)
            async let lics = BioCartoonCLI.licenseCounts(exe)
            async let own = BioCartoonCLI.dbCategories(exe)
            if let c = try? await cats { setCategories(c) }
            if let l = try? await lics { setLicenses(l) }
            if let d = try? await own { setDbCategories(d) }
        }
    }

    private func setMessage(_ s: String) {
        results = []; grid.reloadData()
        status.stringValue = ""
        creditLabel.stringValue = s
        creditBox.isHidden = false
        copyCredit.isHidden = true
    }

    // MARK: filter choices

    // Each dropdown lists the choices that find icons under the search and the other filters, with how many (as the
    // BioCartoon editor's do); picked ones stay listed so they can be taken out. Until the counts come, all of them.

    /// A choice's count: under the search when the counts have come, else the catalog's; nil to leave it out.
    private func shown(_ n: Int?, catalog: Int?, picked: Bool) -> (Int?)? {
        guard let n = n else { return .some(catalog) }
        return n > 0 || picked ? .some(n) : nil
    }

    private func setSources(_ list: [BCSource]) {
        sources = list
        refreshSources()
        refreshDbCategories()
    }

    private func refreshSources() {
        dbPopup.setChoices(sources.filter { ($0.icons ?? 0) > 0 }.compactMap { s in
            shown(facets?.source(s.source), catalog: s.icons, picked: dbPopup.picked.contains(s.source)).map { (s.source, s.name, $0) }
        })
    }

    private func setCategories(_ list: [BCCategory]) {
        categories = list
        refreshCategories()
        refreshSubcategories()
    }

    private func refreshCategories() {
        catPopup.setChoices(categories.filter { !$0.slug.contains(".") }.compactMap { c in
            shown(facets?.taxon(c.slug), catalog: c.icons, picked: catPopup.picked.contains(c.slug)).map { (c.slug, c.name, $0) }
        })
    }

    /// The subcategories of the picked categories (of all of them, "Cells: Cell types", when none is).
    private func refreshSubcategories() {
        let picked = filter.categories
        var choices: [(key: String, name: String, count: Int?)] = []
        for c in categories where c.slug.contains(".") {
            let top = String(c.slug.prefix { $0 != "." })
            if !picked.isEmpty, !picked.contains(top) { continue }
            guard let n = shown(facets?.taxon(c.slug), catalog: c.icons, picked: subPopup.picked.contains(c.slug)) else { continue }
            let name = picked.count == 1 ? c.name : "\(categories.first { $0.slug == top }?.name ?? top): \(c.name)"
            choices.append((c.slug, name, n))
        }
        subPopup.setChoices(choices)
    }

    private func setLicenses(_ list: [(String, Int)]) {
        licenses = list
        refreshLicenses()
    }

    private func refreshLicenses() {
        guard let fc = facets else { licensePopup.setChoices(licenses.map { ($0.0, $0.0, $0.1) }); return }
        var counts: [String: Int] = [:]
        for r in fc.licenses { if let l = r.license { counts[l] = r.icons } }
        for l in licensePopup.picked where counts[l] == nil { counts[l] = 0 }
        licensePopup.setChoices(counts.keys.sorted().map { ($0, $0, counts[$0]) })
    }

    private func setDbCategories(_ list: [(database: String, category: String, count: Int)]) {
        dbCategories = list
        refreshDbCategories()
    }

    /// Each database's own categories, "BA: Viruses", in the order of the databases (of the picked ones when any are).
    private func refreshDbCategories() {
        var all = dbCategories
        if let fc = facets {
            all = fc.db_categories.compactMap { r in r.source.flatMap { s in r.category.map { (s, $0, r.icons) } } }
            for k in dbCatPopup.picked where !all.contains(where: { BCFilter.key($0.database, $0.category) == k }) {
                let d = BCFilter.split(k)
                all.append((d.database, d.category, 0))
            }
        }
        let order = sources.map(\.source)
        let rows = all.filter { filter.sources.isEmpty || filter.sources.contains($0.database) }.sorted { a, b in
            let (ia, ib) = (order.firstIndex(of: a.database) ?? order.count, order.firstIndex(of: b.database) ?? order.count)
            return ia != ib ? ia < ib : a.category.localizedCaseInsensitiveCompare(b.category) == .orderedAscending
        }
        dbCatPopup.setChoices(rows.map { (BCFilter.key($0.database, $0.category), "\(code(forDatabase: $0.database)): \($0.category)", $0.count) })
    }

    /// Count the dropdowns' choices under the search and the filters, unless they are counted for these already.
    private func requestFacets() {
        guard let exe = exe, filtersSupported else { return }
        let query = search.stringValue.trimmingCharacters(in: .whitespaces), f = filter
        if let done = facetsFor, done.query == query, done.filter == f { return }
        facetsFor = (query, f)
        facetsRequest += 1
        let req = facetsRequest
        Task {
            do {
                let fc = try await BioCartoonCLI.facets(exe, query: query, filter: f)
                guard req == facetsRequest else { return }
                facets = fc; facetsAnswered = req
                refreshSources(); refreshCategories(); refreshSubcategories(); refreshLicenses(); refreshDbCategories()
            } catch {
                if req == facetsRequest { facetsFor = nil }      // ask again with the next search
            }
        }
    }

    private static func label(_ name: String, _ n: Int?) -> String {
        guard let n = n else { return name }
        return "\(name) (\(NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)))"
    }
    private func code(forDatabase db: String) -> String { sources.first { $0.source == db }?.code ?? db.prefix(2).uppercased() }

    // MARK: filter changes

    @objc private func closePressed() { onClose?() }
    @objc private func funnelPressed() { filterBox.isHidden.toggle(); refreshFilterChrome() }

    @objc private func clearFilters() {
        filter = BCFilter()
        for p in [dbPopup, catPopup, subPopup, dbCatPopup, licensePopup] { p.clear() }
        authorField.stringValue = ""
        refreshSubcategories()
        refreshDbCategories()
        refreshFilterChrome()
        reload()
    }

    /// A category was ticked on or off: the subcategory list follows it (taking one out takes its subcategories with it).
    private func categoriesEdited() {
        filter.categories = catPopup.picked
        refreshSubcategories()
        filtersEdited()
    }

    private func filtersEdited() {
        filter.sources = dbPopup.picked
        refreshDbCategories()           // another database's own categories would find nothing
        filter.categories = catPopup.picked
        filter.subcategories = subPopup.picked
        filter.dbCats = dbCatPopup.picked
        filter.licenses = licensePopup.picked
        filter.authors = authorField.stringValue
        refreshFilterChrome()
        reload()
    }

    /// Set the filters from code (the headless check).
    func apply(_ f: BCFilter) {
        filter = f
        dbPopup.pick(f.sources); catPopup.pick(f.categories)
        refreshSubcategories()
        subPopup.pick(f.subcategories)
        refreshDbCategories()
        dbCatPopup.pick(f.dbCats); licensePopup.pick(f.licenses)
        authorField.stringValue = f.authors
        filterBox.isHidden = false
        refreshFilterChrome()
        reload()
    }

    /// The funnel lights up while filters are set or shown; set ones are summed up in a line while hidden.
    private func refreshFilterChrome() {
        let active = !filter.isEmpty
        funnel.contentTintColor = active || !filterBox.isHidden ? Theme.accent : .secondaryLabelColor
        funnel.toolTip = filterBox.isHidden ? "Filter by database, author, category or license" : "Hide the filters"
        clearButton.isHidden = !active
        summary.stringValue = summaryText()
        summary.isHidden = !(active && filterBox.isHidden)
    }

    /// The set filters in a line: "Bioicons, OpenMoji · by Ann · Cells · CC0-1.0".
    private func summaryText() -> String {
        var parts: [String] = []
        if !filter.sources.isEmpty { parts.append(sources.filter { filter.sources.contains($0.source) }.map(\.name).joined(separator: ", ")) }
        let authors = filter.authors.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !authors.isEmpty { parts.append("by " + authors.joined(separator: ", ")) }
        let taxa = filter.categories.sorted() + filter.subcategories.sorted()
        if !taxa.isEmpty { parts.append(taxa.map { s in categories.first { $0.slug == s }?.name ?? s }.joined(separator: ", ")) }
        if !filter.dbCats.isEmpty {
            parts.append(filter.dbCats.sorted().map { let k = BCFilter.split($0); return "\(code(forDatabase: k.database)): \(k.category)" }.joined(separator: ", "))
        }
        if !filter.licenses.isEmpty { parts.append(filter.licenses.sorted().joined(separator: ", ")) }
        return parts.joined(separator: "  ·  ")
    }

    @objc private func sortChanged() {
        UserDefaults.standard.set(Self.sorts[sortPopup.indexOfSelectedItem].1, forKey: "biocartoonSort")
        reload()
    }
    @objc private func searchSubmitted() { typing?.cancel(); reload() }
    func controlTextDidChange(_ n: Notification) {
        typing?.cancel()
        let author = (n.object as? NSTextField) === authorField
        let w = DispatchWorkItem { [weak self] in author ? self?.filtersEdited() : self?.reload() }
        typing = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    // MARK: results

    /// Start a new search from the first page.
    func reload() {
        requestFacets()
        generation += 1
        results = []; more = false; loading = false
        grid.reloadData()
        scroll.contentView.scroll(to: .zero)
        loadPage()
    }

    private func loadPage() {
        guard let exe = exe, !loading else { return }
        loading = true
        let gen = generation
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        let f = filter, sort = Self.sorts[sortPopup.indexOfSelectedItem].1
        status.stringValue = results.isEmpty ? "Searching…" : "Loading more…"
        Task {
            do {
                let page = try await BioCartoonCLI.search(exe, query: query, filter: f, sort: sort, offset: results.count, limit: Self.pageSize)
                guard gen == generation else { return }
                loading = false
                more = page.count == Self.pageSize
                let start = results.count
                results += page
                if start == 0 { grid.reloadData() }
                else if !page.isEmpty { grid.insertItems(at: Set((start..<results.count).map { IndexPath(item: $0, section: 0) })) }
                status.stringValue = results.isEmpty ? "No results" : "\(results.count)\(more ? "+" : "") icon\(results.count == 1 && !more ? "" : "s")"
            } catch {
                guard gen == generation else { return }
                loading = false
                status.stringValue = "Search failed"
                setMessage("\(error)")
            }
        }
    }

    @objc private func scrolled() {
        guard more, !loading, let doc = scroll.documentView else { return }
        if scroll.contentView.bounds.maxY > doc.frame.height - 3 * 102 { loadPage() }
    }
    @objc private func resized() { grid.collectionViewLayout?.invalidateLayout() }

    @objc private func installPressed() {
        installButton.isEnabled = false
        status.stringValue = "Installing biocartoon…"
        Task {
            do {
                try await BioCartoonCLI.install()
                installButton.isEnabled = true
                installButton.title = "Install BioCartoon"
                creditBox.isHidden = true
                exe = nil
                locate()
            } catch {
                installButton.isEnabled = true
                setMessage("Could not install biocartoon: \(error)")
            }
        }
    }

    /// Show the credit line of the icon just inserted (BioCartoon's "Copy caption").
    func showCredit(_ icon: BCIcon) {
        creditLabel.stringValue = icon.credit ?? icon.title
        copyCredit.isHidden = false
        creditBox.isHidden = false
    }

    // for the headless check
    var resultCount: Int { results.count }
    var firstResult: BCIcon? { results.first }
    var allResults: [BCIcon] { results }
    var isLoading: Bool { loading }
    var facetsSettled: Bool { facetsAnswered == facetsRequest }
    func type(_ query: String) { search.stringValue = query; reload() }

    @objc private func copyCreditPressed() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(creditLabel.stringValue, forType: .string)
        copyCredit.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.copyCredit.title = "Copy credit" }
    }

    // MARK: grid

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { results.count }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: BCTile.id, for: ip) as! BCTile
        let icon = results[ip.item]
        item.show(icon, code: code(forDatabase: icon.database))
        item.onClick = { [weak self] icon in self?.onInsert?(icon) }
        return item
    }

    /// Square tiles, as many across as fit at about 96 px, stretched to fill the pane's width.
    func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt ip: IndexPath) -> NSSize {
        let w = scroll.contentSize.width
        let n = max(2, Int((w + 6) / 102))
        let side = max(40, floor((w - 6 * CGFloat(n - 1)) / CGFloat(n)))
        return NSSize(width: side, height: side)
    }
}

extension MainController {
    /// Insert ▸ BioCartoon Icons… (and the toolbar palette): the search takes the inspector's place; again puts it away.
    @objc func showBioCartoon() {
        if let p = biocartoonPane, !p.view.isHidden { hideBioCartoon(); return }
        let p = biocartoonPane ?? BioCartoonPane()
        if biocartoonPane == nil {
            p.onInsert = { [weak self] icon in self?.insertBioCartoon(icon, at: nil) }
            p.onClose = { [weak self] in self?.hideBioCartoon() }
            p.view.translatesAutoresizingMaskIntoConstraints = false
            inspectorHost.addSubview(p.view)
            NSLayoutConstraint.activate([
                p.view.leadingAnchor.constraint(equalTo: inspectorHost.leadingAnchor), p.view.trailingAnchor.constraint(equalTo: inspectorHost.trailingAnchor),
                p.view.topAnchor.constraint(equalTo: inspectorHost.topAnchor), p.view.bottomAnchor.constraint(equalTo: inspectorHost.bottomAnchor),
            ])
            biocartoonPane = p
        }
        p.view.isHidden = false
        inspectorScroll?.isHidden = true
        if let right = mainSplit?.subviews.last, right.isHidden { right.isHidden = false; mainSplit?.adjustSubviews() }
        p.activate(in: window)
    }

    /// Back to the inspector.
    func hideBioCartoon() {
        biocartoonPane?.view.isHidden = true
        inspectorScroll?.isHidden = false
    }

    func biocartoonDropped(_ data: Data, at p: CGPoint) -> Bool {
        guard sceneName != nil, player == nil, let icon = try? JSONDecoder().decode(BCIcon.self, from: data) else { return false }
        insertBioCartoon(icon, at: p)
        return true
    }

    /// Download the icon's PNG into the deck folder and insert it as a picture, centred on `point`
    /// (frame px; nil = the slide's centre), its longer side 3 manim units.
    func insertBioCartoon(_ icon: BCIcon, at point: CGPoint?) {
        guard let ws = workspace, sceneName != nil, player == nil, let exe = biocartoonPane?.exe else { return }
        let slug = icon.title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            .prefix(6).joined(separator: "_")
        let stem = slug.isEmpty ? "biocartoon" : slug
        var name = stem + ".png", n = 1
        while FileManager.default.fileExists(atPath: ws.work.appendingPathComponent(name).path) { name = "\(stem)_\(n).png"; n += 1 }
        let dest = ws.work.appendingPathComponent(name)
        let c = point ?? CGPoint(x: canvas.frameSize.width / 2, y: canvas.frameSize.height / 2)
        busyPill.show("Downloading \(icon.title)…", symbol: nil, tint: nil, spinning: true)
        Task { @MainActor in
            let size: CGSize
            do {
                try await BioCartoonCLI.fetch(exe, id: icon.id, to: dest)
                size = await Task.detached { BioCartoonCLI.trimTransparentMargins(dest) }.value
            } catch { busyPill.hide(); toast("Could not download \(icon.title): \(error)", error: true); return }
            busyPill.hide()
            let half = 1.5 * canvas.unitPx * min(1, size.width / max(size.height, 1))
            insert(kind: "image", extra: ["file": name, "path": dest.path,
                                          "sx": Double(c.x) - half, "sy": Double(c.y), "ex": Double(c.x) + half, "ey": Double(c.y)])
            biocartoonPane?.showCredit(icon)
        }
    }
}

extension MainController {
    // MARK: headless check (MANIMBLE_TEST_BIOCARTOON=deck)

    func biocartoonTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "biocartoon.log") }
        func shot(_ v: NSView?, _ name: String) {
            guard let v = v, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
        }
        func images() -> [String] { (scene?.objects?.values.compactMap { $0.kind == "image" ? $0.image : nil } ?? []).sorted() }
        func counts(_ rows: [BCFacets.Row], _ name: KeyPath<BCFacets.Row, String?>) -> String {
            rows.map { "\($0[keyPath: name] ?? "?") \($0.icons)" }.joined(separator: ", ")
        }
        func wait(_ what: String, _ ok: () -> Bool) async {
            for _ in 0..<600 where !ok() { try? await Task.sleep(nanoseconds: 100_000_000) }
            log("\(what): \(ok() ? "ok" : "TIMED OUT")")
        }
        Task { @MainActor in
            log("biocartoon at \(BioCartoonCLI.find() ?? "-")")
            showBioCartoon()
            guard let p = biocartoonPane else { log("no pane"); return }
            log("pane shown: \(!p.view.isHidden), inspector hidden: \(inspectorScroll?.isHidden == true)")
            await wait("first page") { p.resultCount > 0 }
            p.type("mitochondria")
            try? await Task.sleep(nanoseconds: 300_000_000)
            await wait("search") { p.resultCount > 0 && p.firstResult?.title.lowercased().contains("mito") == true }
            let plain = p.resultCount
            // the dropdowns count what the search finds
            await wait("facets") { p.facetsSettled && p.facets != nil }
            log("facets for mitochondria: databases \(counts(p.facets?.sources ?? [], \.source))")
            // the filters go to the command line
            var f = BCFilter(); f.licenses = ["CC0-1.0"]; f.sources = ["bioicons", "healthicons", "scidraw"]; f.categories = ["cells"]
            p.apply(f)
            try? await Task.sleep(nanoseconds: 300_000_000)
            await wait("filtered") { !p.isLoading && p.resultCount > 0 }
            let bad = p.allResults.filter { $0.license != "CC0-1.0" || !f.sources.contains($0.database) }
            log("filtered: \(p.resultCount) of \(plain), off: \(bad.count)")
            await wait("filtered facets") { p.facetsSettled }
            log("filtered facets: databases \(counts(p.facets?.sources ?? [], \.source)); licenses \(counts(p.facets?.licenses ?? [], \.license))")
            try? await Task.sleep(nanoseconds: 2_000_000_000)      // thumbnails
            shot(p.view, "biocartoon_pane.png")
            shot(window.contentView, "biocartoon_filters_window.png")
            p.apply(BCFilter())
            try? await Task.sleep(nanoseconds: 300_000_000)
            await wait("unfiltered") { !p.isLoading && p.resultCount > 0 }
            guard let icon = p.firstResult, let data = try? JSONEncoder().encode(icon) else { log("no result"); return }
            log("first: \(icon.id) \(icon.title) \(Int(icon.width ?? 0))x\(Int(icon.height ?? 0))")
            let before = images()
            // as if dropped on the slide's upper-left quarter
            let taken = biocartoonDropped(data, at: CGPoint(x: canvas.frameSize.width / 4, y: canvas.frameSize.height / 4))
            log("drop taken: \(taken)")
            await wait("inserted") { images().count > before.count }
            await queueTail?.value
            log("images: \(images())")
            if let o = scene?.objects?.values.first(where: { $0.kind == "image" && !before.contains($0.image ?? "") }) {
                log("placed: \(o.loc)")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            shot(window.contentView, "biocartoon_window.png")
            hideBioCartoon()
            log("closed: pane hidden \(p.view.isHidden), inspector shown \(inspectorScroll?.isHidden == false)")
            log("done")
        }
    }
}

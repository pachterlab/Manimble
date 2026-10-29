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
    var thumb_url: String?      // a small preview for the tile, when the catalog has one (biocartoon 0.4.2+)
    var width: Double?
    var height: Double?
    var svg_key: String?        // set when the icon is published as SVG
    var variant: String?
    var taxa: [BCTaxon]?        // its place in BioCartoon's taxonomy (biocartoon 0.3.4+)
    var stars: Int?             // how many people starred it, as of the catalog and the last sync (see BCStars)
    var starred: Bool?          // this install starred it

    /// The database the icon is listed under: BioCartoon's own drawings are uploads (source `user`) by "BioCartoon".
    var database: String { source == "user" && author == "BioCartoon" ? "biocartoon" : source }

    /// What the BioCartoon editor shows on hovering a tile: the title, its categories, the database's own category,
    /// "Reactome Icon Library  ·  CC-BY-4.0  ·  SVG  ·  1024 × 569 px", and the credit line.
    var info: NSAttributedString {
        let out = NSMutableAttributedString()
        func line(_ s: String, _ font: NSFont, _ color: NSColor = .labelColor, after: CGFloat = 3) {
            let para = NSMutableParagraphStyle(); para.paragraphSpacing = after
            out.append(NSAttributedString(string: (out.length == 0 ? "" : "\n") + s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para]))
        }
        line(title, Theme.font(13, .semibold))
        if let v = variant, !v.isEmpty { line("Variant: \(v)", Theme.font(12)) }
        let taxa = (taxa ?? []).map { $0.subcategory.isEmpty ? $0.category : "\($0.category) › \($0.subcategory)" }
        if !taxa.isEmpty { line("Category: " + taxa.joined(separator: ", "), Theme.font(12)) }
        if let c = category, !c.isEmpty { line("Database category: \(c)", Theme.font(12)) }
        var last = [database == "biocartoon" ? "BioCartoon" : source_name ?? source]
        if let l = license, !l.isEmpty { last.append(l) }
        last.append(svg_key != nil ? "SVG" : "PNG")
        if let w = width, let h = height, w > 0, h > 0 { last.append("\(Int(w)) × \(Int(h)) px") }
        line(last.joined(separator: "  ·  "), Theme.font(12), after: 5)
        if let c = credit, !c.isEmpty { line(c, Theme.font(10), .secondaryLabelColor) }
        return out
    }
}

/// A category and subcategory of BioCartoon's taxonomy ("Cells", "Organelles and cell components").
struct BCTaxon: Codable, Equatable {
    var category: String
    var subcategory: String
    var slug: String?
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
        var file_type: String?
        var icons: Int
    }
    var sources: [Row]
    var licenses: [Row]
    var categories: [Row]
    var source_categories: [Row]       // the databases' own categories
    var file_types: [Row]

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

    /// The oldest `biocartoon` Manimble works with: it lists icons' taxonomy (`taxa`) and calls the databases' own
    /// categories source categories (`--source-category`, `source_categories`), and filters by tag (`--tags`). Keep in step
    /// with engine/requirements.txt.
    static let minimumVersion = "0.4.0"

    static func supported(_ version: String) -> Bool {
        version.compare(minimumVersion, options: .numeric) != .orderedAscending
    }

    /// `biocartoon --version --json`: the program's version ("0.3.0").
    static func version(_ exe: String) async throws -> String {
        struct V: Decodable { var version: String }
        return try JSONDecoder().decode(V.self, from: try await run(exe, ["--version", "--json"])).version
    }

    /// The catalog file searches read (`--version --json`), nil before the first download.
    static func catalogPath(_ exe: String) async -> String? {
        struct V: Decodable { struct C: Decodable { var path: String? }; var catalog: C? }
        return (try? JSONDecoder().decode(V.self, from: try await run(exe, ["--version", "--json"])))?.catalog?.path
    }

    /// `biocartoon sync`: download the published catalog when it is newer than the copy searches read (they never
    /// check on their own, so new uploads would not show up). True when a newer one came in; with no copy yet it does
    /// nothing, since the first search downloads it.
    static func sync(_ exe: String) async throws -> Bool {
        guard let before = await catalogPath(exe) else { return false }
        _ = try await run(exe, ["sync"], timeout: 600)
        return await catalogPath(exe) != before
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
        for k in filter.dbCats.sorted() { let d = BCFilter.split(k); args += ["--source-category", "\(d.database):\(d.category)"] }
        for l in filter.licenses.sorted() { args += ["--license", l] }
        for t in filter.fileTypes.sorted() { args += ["--file-type", t] }
        if !filter.tagList.isEmpty { args += ["--tags", filter.tagList.joined(separator: ",")] }
        return args
    }

    /// How many icons each dropdown's choices find under `query` and the other filters (`search --facets`).
    static func facets(_ exe: String, query: String, filter: BCFilter) async throws -> BCFacets {
        var args = ["search"]
        if !query.isEmpty { args.append(query) }
        args += ["--facets", "--icons", "--no-sql", "--json"]
        return try JSONDecoder().decode(BCFacets.self, from: try await run(exe, args + filterArgs(filter)))
    }

    static func categories(_ exe: String) async throws -> [BCCategory] {
        try JSONDecoder().decode([BCCategory].self, from: try await run(exe, ["--categories", "--json"]))
    }

    /// Each database's own categories with their icon counts (`biocartoon --source-categories --json`).
    static func sourceCategories(_ exe: String) async throws -> [(database: String, category: String, count: Int)] {
        struct Row: Decodable { var source: String; var category: String; var icons: Int? }
        return try JSONDecoder().decode([Row].self, from: try await run(exe, ["--source-categories", "--json"]))
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

    /// Download the icon's SVG as published (fails when it has none).
    static func fetchSVG(_ exe: String, id: String, to dest: URL) async throws {
        _ = try await run(exe, ["fetch", id, "--svg", "--out", dest.path, "--json"])
    }

    /// Write the icon into the PNG's metadata (its title, author, license and credit, and the whole record in the
    /// comment), so a picture placed from the catalog keeps its credit wherever the file goes.
    static func tag(_ url: URL, with icon: BCIcon) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let json = try? JSONEncoder().encode(icon), let record = String(data: json, encoding: .utf8) else { return }
        var png: [CFString: Any] = [kCGImagePropertyPNGTitle: icon.title, kCGImagePropertyPNGComment: tagPrefix + record]
        if let c = icon.credit { png[kCGImagePropertyPNGDescription] = c }
        if let a = icon.author { png[kCGImagePropertyPNGAuthor] = a }
        if let l = icon.license { png[kCGImagePropertyPNGCopyright] = l }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tagging")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, [kCGImagePropertyPNGDictionary: png] as CFDictionary)
        if CGImageDestinationFinalize(dest) { _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp) }
        try? FileManager.default.removeItem(at: tmp)
    }
    private static let tagPrefix = "biocartoon:"

    /// `tag` for a vector picture: the record in a comment at the end of the SVG (base64, as a comment cannot hold "--").
    static func tagSVG(_ url: URL, with icon: BCIcon) {
        guard let json = try? JSONEncoder().encode(icon), let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data("<!-- \(svgTagPrefix)\(json.base64EncodedString()) -->\n".utf8))
    }
    private static let svgTagPrefix = "biocartoon64:"

    /// The catalog icon a picture file was placed from (what `tag` wrote), nil for any other picture.
    static func origin(ofImageAt path: String) -> BCIcon? {
        if path.lowercased().hasSuffix(".svg") {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let r = text.range(of: "<!-- " + svgTagPrefix, options: .backwards),
                  let end = text.range(of: " -->", range: r.upperBound..<text.endIndex),
                  let data = Data(base64Encoded: String(text[r.upperBound..<end.lowerBound])) else { return nil }
            return try? JSONDecoder().decode(BCIcon.self, from: data)
        }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        // ImageIO keeps the PNG comment as the EXIF user comment
        let comments = [(props[kCGImagePropertyPNGDictionary] as? [CFString: Any])?[kCGImagePropertyPNGComment],
                        (props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment]]
        for case let c as String in comments where c.hasPrefix(tagPrefix) {
            if let icon = try? JSONDecoder().decode(BCIcon.self, from: Data(c.dropFirst(tagPrefix.count).utf8)) { return icon }
        }
        return nil
    }

    /// Submit a picture to the shared library (`biocartoon upload`); it waits for review before joining the catalog.
    static func upload(_ exe: String, file: String, title: String, credit: String, license: String, category: String,
                       description: String, dryRun: Bool = false) async throws {
        var args = ["upload", file, "--license", license, "--title", title]
        if !credit.isEmpty { args += ["--credit", credit] }
        if !category.isEmpty { args += ["--category", category] }
        if !description.isEmpty { args += ["--description", description] }
        if dryRun { args.append("--dry-run") }
        _ = try await run(exe, args)
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

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// `pip install --upgrade "biocartoon>=minimumVersion"` into Manimble's Python environment.
    static func install() async throws {
        _ = try await run(python, ["-m", "pip", "install", "--upgrade", "--disable-pip-version-check", "biocartoon>=\(minimumVersion)"], timeout: 600)
    }

    /// The command line when it is installed and new enough, else why not (for the user).
    static func usable() async -> Result<String, Failure> {
        guard let exe = await Task.detached(operation: { find() }).value else {
            return .failure(Failure(description: "The BioCartoon command line is not installed. Install it into Manimble's Python environment (pip install \"biocartoon>=\(minimumVersion)\") to search 15,000+ open-licensed science icons."))
        }
        let version = (try? await BioCartoonCLI.version(exe)) ?? "an unknown version"
        guard supported(version) else {
            return .failure(Failure(description: "biocartoon \(version) is installed; Manimble needs \(minimumVersion) or newer (pip install --upgrade \"biocartoon>=\(minimumVersion)\")."))
        }
        return .success(exe)
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

    /// The same logo as black-and-white line art (a template image, so it follows the toolbar's tint like the SF Symbols).
    static let monoLogo: NSImage = {
        if let u = Bundle.main.url(forResource: "biocartoon-mono", withExtension: "png"), let img = NSImage(contentsOf: u) {
            img.isTemplate = true
            return img
        }
        return NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "BioCartoon") ?? NSImage()
    }()
}

/// Thumbnails, kept in memory: the catalog's small previews, else downsampled from the icons' PNGs.
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
            if data == nil, let s = icon.thumb_url, let u = URL(string: s) { data = try? await Self.download(u) }
            if data == nil, local == nil, let s = icon.url, let u = URL(string: s) { data = try? await Self.download(u) }
            let cg = data.flatMap { Self.downsample($0, maxSide: 240) }
            await MainActor.run {
                let img = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                if let img = img { self.cache.setObject(img, forKey: id as NSString) }
                for f in self.waiting.removeValue(forKey: id) ?? [] { f(img) }
            }
        }
    }

    /// The body of a successful GET (a missing thumbnail is a 404, not an image).
    nonisolated static func download(_ u: URL) async throws -> Data? {
        let (data, response) = try await URLSession.shared.data(from: u)
        return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == false ? nil : data
    }

    nonisolated static func downsample(_ data: Data, maxSide: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxSide]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Stars on catalog icons, shared with the BioCartoon editor. The counts live on BioCartoon's submissions Worker, which
/// tells installs apart by a random client id; Manimble uses the editor's own id when the editor is installed, so a star
/// given in either app is the same star. The latest counts go into the editor's usage file (`usage.sqlite`, table `stars`),
/// which `biocartoon search --sort popular` orders by.
///
///   GET  <server>/stars/all                  -> {id: n} for every icon with a star
///   GET  <server>/stars?ids=a,b&client=<id>  -> {"stars": {id: n}, "mine": [id]}
///   POST <server>/star {"id", "client", "on"} -> {"id", "stars", "starred"}
@MainActor
final class BCStars {
    static let shared = BCStars()
    /// Posted when counts or this install's stars change (the object is nil).
    static let changed = Notification.Name("BCStarsChanged")

    private(set) var counts: [String: Int] = [:]
    private(set) var mine: Set<String> = []
    /// Star changes the Worker has not confirmed yet (id -> starred), sent again on the next sync.
    private var pending: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: "biocartoonPendingStars") as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "biocartoonPendingStars") }
    }
    private var inFlight: Set<String> = []
    private var lastSync: Date?
    private var syncing = false
    /// Why the last star could not be counted, for the pane's status line.
    var onProblem: ((String) -> Void)?

    var server: String {
        let env = ProcessInfo.processInfo.environment["BIOCARTOON_SUBMIT_URL"] ?? ""
        return (env.isEmpty ? "https://api.biocartoon.com" : env).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    private static var appSupport: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    static var usageFile: URL { appSupport.appendingPathComponent("biocartoon/usage.sqlite") }

    /// The BioCartoon editor's client id (kept in its settings), else Manimble's own, made once.
    lazy var client: String = {
        let ron = Self.appSupport.appendingPathComponent("com.biocartoon.app/app.ron")
        if let s = try? String(contentsOf: ron, encoding: .utf8),
           let r = s.range(of: #"client_id\\?":\s*\\?"[0-9a-f]{32}"#, options: .regularExpression) {
            return String(s[r].suffix(32))
        }
        if let saved = UserDefaults.standard.string(forKey: "biocartoonClientId"), saved.count == 32 { return saved }
        let id = (0..<4).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max)) }.joined()
        UserDefaults.standard.set(id, forKey: "biocartoonClientId")
        return id
    }()

    func count(_ icon: BCIcon) -> Int { counts[icon.id] ?? icon.stars ?? 0 }
    func isStarred(_ icon: BCIcon) -> Bool { pending[icon.id] ?? (mine.contains(icon.id) || (counts[icon.id] == nil && icon.starred == true)) }

    /// "7", "1k", "1.1k", "10k", "1M": as the editor's tiles show counts.
    static func format(_ n: Int) -> String {
        let n = max(0, n)
        for (unit, size) in [("B", 1_000_000_000), ("M", 1_000_000), ("k", 1000)] where n >= size {
            let whole = n / size, tenth = (n % size) / (size / 10)
            return whole < 10 && tenth > 0 ? "\(whole).\(tenth)\(unit)" : "\(whole)\(unit)"
        }
        return String(n)
    }

    /// Fetch every count and which of them are this install's, keep them in the usage file, and send the star changes
    /// still waiting. At most once every few minutes unless `force`; true when a count or star changed.
    @discardableResult
    func sync(force: Bool = false) async -> Bool {
        if syncing || (!force && lastSync.map { Date().timeIntervalSince($0) < 300 } == true) { return false }
        syncing = true
        defer { syncing = false }
        guard let all = try? await getJSON("\(server)/stars/all") as? [String: Any] else { return false }
        lastSync = Date()
        var fresh: [String: Int] = [:]
        for (id, n) in all { if let n = n as? Int { fresh[id] = n } }
        var mineNow: Set<String> = []
        let ids = Array(fresh.keys).sorted()
        // D1 binds at most 100 values a query and the Worker binds the client with the ids: 100 or more ids is a 500
        for start in stride(from: 0, to: ids.count, by: 90) {
            let chunk = ids[start..<min(start + 90, ids.count)].joined(separator: ",")
            guard let v = try? await getJSON("\(server)/stars?ids=\(Self.escape(chunk))&client=\(client)") as? [String: Any] else { return false }
            mineNow.formUnion((v["mine"] as? [String]) ?? [])
        }
        let changed = fresh != counts || mineNow != mine
        counts = fresh; mine = mineNow
        // what this install changed and the Worker hasn't counted yet wins over its answer
        for (id, on) in pending {
            if on { mine.insert(id) } else { mine.remove(id) }
            let base = fresh[id] ?? 0
            counts[id] = mineNow.contains(id) == on ? base : max(0, base + (on ? 1 : -1))
        }
        await writeUsage(full: true)
        if changed { NotificationCenter.default.post(name: Self.changed, object: nil) }
        sendPending()
        return changed
    }

    /// Star `icon` or take the star back. Shown at once and kept in the usage file; the Worker's count follows now, or
    /// on a later sync when it can't be reached.
    func toggle(_ icon: BCIcon) {
        let id = icon.id
        guard !id.isEmpty else { return }
        let on = !isStarred(icon)
        counts[id] = max(0, count(icon) + (on ? 1 : -1))
        if on { mine.insert(id) } else { mine.remove(id) }
        var p = pending; p[id] = on; pending = p
        NotificationCenter.default.post(name: Self.changed, object: nil)
        Task { await writeUsage(ids: [id]) }
        sendPending()
    }

    private func sendPending() {
        for (id, on) in pending where !inFlight.contains(id) {
            inFlight.insert(id)
            Task { await send(id, on) }
        }
    }

    private func send(_ id: String, _ on: Bool) async {
        var req = URLRequest(url: URL(string: "\(server)/star")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id, "client": client, "on": on])
        req.timeoutInterval = 20
        let answer = try? await URLSession.shared.data(for: req)
        inFlight.remove(id)
        guard let data = answer?.0, let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }  // offline: stays pending
        if let e = v["error"] as? String {
            if e.hasPrefix("Limit reached") { onProblem?("Your star will be counted later. \(e)"); return }
            // not on the server (one of your own uploads) or refused: the star stays here, uncounted
            var p = pending; p[id] = nil; pending = p
            return
        }
        guard let n = v["stars"] as? Int else { return }
        let starred = v["starred"] as? Bool ?? on
        var p = pending
        if p[id] == on { p[id] = nil; pending = p }
        else if p[id] != nil { sendPending(); return }  // changed again while this one was on its way
        counts[id] = n
        if starred { mine.insert(id) } else { mine.remove(id) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
        await writeUsage(ids: [id])
    }

    /// Keep the counts in the editor's usage file (for its tiles and the CLI's Popular order): all of them (`full`, rows the
    /// Worker no longer counts go to 0) or just `ids`.
    private func writeUsage(full: Bool = false, ids: [String] = []) async {
        let file = Self.usageFile
        guard FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) else { return }
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
        var sql = "BEGIN;\nCREATE TABLE IF NOT EXISTS stars (id TEXT PRIMARY KEY, n INTEGER NOT NULL, mine INTEGER NOT NULL DEFAULT 0);\n"
        let rows = full ? Array(counts.keys) : ids
        if full {
            let keep = rows.isEmpty ? "''" : rows.map(q).joined(separator: ",")
            // a star of your own the Worker doesn't know (an upload of yours) stays
            sql += "UPDATE stars SET n = 0 WHERE n <> 0 AND mine = 0 AND id NOT IN (\(keep));\n"
        }
        for id in rows {
            sql += "INSERT INTO stars (id, n, mine) VALUES (\(q(id)), \(counts[id] ?? 0), \(mine.contains(id) ? 1 : 0)) "
                + "ON CONFLICT (id) DO UPDATE SET n = excluded.n, mine = excluded.mine;\n"
        }
        sql += "COMMIT;\n"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("manimble-stars-\(UUID().uuidString).sql")
        guard (try? sql.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return }
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { _ = try await BioCartoonCLI.run("/usr/bin/sqlite3", ["-cmd", ".timeout 5000", file.path, ".read \(tmp.path)"], timeout: 30) }
        catch { NSLog("BioCartoon stars: could not update \(file.path): \(error)") }
    }

    private func getJSON(_ url: String) async throws -> Any {
        guard let u = URL(string: url) else { throw URLError(.badURL) }
        var req = URLRequest(url: u); req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.,"))) ?? s
    }
}

/// A result tile: white card, thumbnail, collection badge. Click inserts the icon; dragging it onto the slide places it there.
final class BCTile: NSCollectionViewItem, NSDraggingSource {
    static let id = NSUserInterfaceItemIdentifier("bctile")
    var icon: BCIcon?
    var onClick: ((BCIcon) -> Void)?
    private let thumb = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let star = NSButton(title: "", target: nil, action: nil)
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
        // upper right: the star and how many starred the icon (gold when you did); a click stars it or takes it back
        star.isBordered = false; star.imagePosition = .imageTrailing; star.imageHugsTitle = true
        star.font = Theme.font(9, .semibold); star.contentTintColor = .systemGray
        star.target = self; star.action = #selector(starPressed)
        star.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(thumb); v.addSubview(badge); v.addSubview(star)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8), thumb.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            thumb.topAnchor.constraint(equalTo: v.topAnchor, constant: 8), thumb.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
            badge.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 5), badge.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -5),
            badge.widthAnchor.constraint(equalToConstant: 22), badge.heightAnchor.constraint(equalToConstant: 14),
            star.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4), star.topAnchor.constraint(equalTo: v.topAnchor, constant: 3),
        ])
        view = v
    }

    @objc private func starPressed() {
        guard let icon = icon else { return }
        BCInfoTip.shared.hide()
        BCStars.shared.toggle(icon)
    }

    /// Show the icon's latest star count and whether you starred it.
    func refreshStar() {
        guard let icon = icon else { return }
        let stars = BCStars.shared, on = stars.isStarred(icon), n = stars.count(icon)
        star.image = NSImage(systemSymbolName: on ? "star.fill" : "star", accessibilityDescription: on ? "Unstar" : "Star")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        star.contentTintColor = on ? .systemYellow : .systemGray
        star.attributedTitle = NSAttributedString(string: n > 0 ? BCStars.format(n) : "",
                                                  attributes: [.font: Theme.font(9, .semibold), .foregroundColor: NSColor.darkGray])
        star.toolTip = on ? "Starred: click to take your star back" : "Star this icon (shared with the BioCartoon editor)"
    }

    func show(_ icon: BCIcon, code: String) {
        self.icon = icon
        badge.stringValue = code
        badge.backgroundColor = BioCartoonCLI.badgeColor(icon.database)
        badge.isHidden = code.isEmpty
        refreshStar()
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
        override func mouseEntered(with e: NSEvent) {
            layer?.borderColor = Theme.accent.cgColor; layer?.borderWidth = 2
            if let icon = owner?.icon { BCInfoTip.shared.schedule(icon, beside: self) }
        }
        override func mouseExited(with e: NSEvent) {
            layer?.borderColor = NSColor.separatorColor.cgColor; layer?.borderWidth = 1
            BCInfoTip.shared.hide()
        }
        override func viewDidMoveToWindow() { if window == nil { BCInfoTip.shared.hide() } }
        override func mouseDown(with e: NSEvent) { BCInfoTip.shared.hide(); owner?.downAt = e.locationInWindow }

        /// Right-click: insert it, or copy its name or credit (as the BioCartoon editor's tile menu).
        override func menu(for event: NSEvent) -> NSMenu? {
            BCInfoTip.shared.hide()
            guard let o = owner, let icon = o.icon else { return nil }
            let m = NSMenu()
            m.addItem(BCMenuItem("Insert on Slide") { [weak o] in o?.onClick?(icon) })
            m.addItem(BCMenuItem(BCStars.shared.isStarred(icon) ? "Unstar" : "Star") { BCStars.shared.toggle(icon) })
            m.addItem(.separator())
            m.addItem(BCMenuItem("Copy Name") { BioCartoonCLI.copy(icon.title) })
            if let c = icon.credit, !c.isEmpty { m.addItem(BCMenuItem("Copy Credit") { BioCartoonCLI.copy(c) }) }
            return m
        }
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

/// A menu item that runs a closure.
final class BCMenuItem: NSMenuItem {
    private let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func fire() { run() }
}

/// The card shown on hovering a result tile (the BioCartoon editor's hover info): a borderless panel beside the tile.
@MainActor
final class BCInfoTip {
    static let shared = BCInfoTip()
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?
    private static let maxWidth: CGFloat = 420, pad: CGFloat = 10

    func schedule(_ icon: BCIcon, beside view: NSView) {
        hide()
        let w = DispatchWorkItem { [weak self, weak view] in
            guard let v = view, v.window?.isVisible == true else { return }
            self?.show(icon, beside: v)
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func hide() { pending?.cancel(); pending = nil; panel?.orderOut(nil) }

    /// The card's content for `icon` (the headless check's picture of it).
    var contentView: NSView? { panel?.contentView }

    func show(_ icon: BCIcon, beside view: NSView) {
        guard let win = view.window else { return }
        let p = panel ?? make()
        label.attributedStringValue = icon.info
        let text = icon.info.boundingRect(with: NSSize(width: Self.maxWidth, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = NSSize(width: ceil(text.width) + 2 * Self.pad + 6, height: ceil(text.height) + 2 * Self.pad + 2)
        label.frame = NSRect(x: Self.pad, y: Self.pad, width: size.width - 2 * Self.pad, height: size.height - 2 * Self.pad)
        // beside the tile, on the slide's side (the pane is at the window's right), top edges level
        let tile = win.convertToScreen(view.convert(view.bounds, to: nil))
        let screen = (win.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        var x = tile.minX - size.width - 8
        if x < screen.minX { x = tile.maxX + 8 }
        let y = min(max(tile.maxY - size.height, screen.minY), screen.maxY - size.height)
        p.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        p.orderFront(nil)
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = true
        let bg = NSVisualEffectView()
        bg.material = .toolTip; bg.state = .active
        bg.wantsLayer = true; bg.layer?.cornerRadius = 7; bg.layer?.masksToBounds = true
        label.cell?.wraps = true
        label.maximumNumberOfLines = 0
        bg.addSubview(label)
        p.contentView = bg
        panel = p
        return p
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
    var fileTypes: Set<String> = []       // "svg" (published as SVG), "png" (a PNG only)
    var tags = ""                         // whole tags, any case, commas between

    var authorParts: [String] {
        authors.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }
    var tagList: [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var isEmpty: Bool {
        sources.isEmpty && authorParts.isEmpty && categories.isEmpty && subcategories.isEmpty && dbCats.isEmpty && licenses.isEmpty
            && fileTypes.isEmpty && tagList.isEmpty
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
    private let fileTypePopup = BCMultiPopup(frame: .zero, pullsDown: true)
    private let tagsField = NSTextField()
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
    /// The sort was picked by hand since the pane opened; until then it follows the search (Popular with
    /// nothing typed, Relevance once something is).
    private var sortPicked = false

    override init() {
        super.init()
        let logo = NSImageView(image: BioCartoonCLI.monoLogo)
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
        for p in [dbPopup, subPopup, dbCatPopup, licensePopup, fileTypePopup] { p.onChange = { [weak self] in self?.filtersEdited() } }
        catPopup.onChange = { [weak self] in self?.categoriesEdited() }
        authorField.placeholderString = "Any (commas for several)"
        authorField.font = Theme.font(11); authorField.controlSize = .small
        authorField.delegate = self
        tagsField.placeholderString = "Any (commas for several)"
        tagsField.font = Theme.font(11); tagsField.controlSize = .small
        tagsField.delegate = self
        let tagsLabel = fieldLabel("Tags")
        tagsLabel.toolTip = "Icons with one of these as a whole tag, any case"
        let dbCatLabel = fieldLabel("Database category")
        dbCatLabel.toolTip = "A database's own categories, by its code (BA: NIAID NIH BioArt, …)"
        let rows: [[NSView]] = [[fieldLabel("Database"), dbPopup], [fieldLabel("Author"), authorField], [fieldLabel("Category"), catPopup],
                                [fieldLabel("Subcategory"), subPopup], [dbCatLabel, dbCatPopup], [fieldLabel("License"), licensePopup],
                                [fieldLabel("File type"), fileTypePopup], [tagsLabel, tagsField]]
        for r in rows { r[1].setContentHuggingPriority(.init(1), for: .horizontal) }
        let table = NSGridView(views: rows)
        table.rowSpacing = 6; table.columnSpacing = 8
        table.column(at: 0).width = 104
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
        setSources([]); setCategories([]); setLicenses([]); setDbCategories([]); refreshFileTypes()

        sortPopup.controlSize = .small
        sortPopup.font = Theme.font(11)
        sortPopup.addItems(withTitles: Self.sorts.map { $0.0 })
        followSearch()
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
        NotificationCenter.default.addObserver(self, selector: #selector(starsChanged), name: BCStars.changed, object: nil)
        BCStars.shared.onProblem = { [weak self] why in self?.status.stringValue = why }

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
        sortPicked = false
        if followSearch(), exe != nil { reload() }
        if exe == nil { locate() } else { syncStars() }
    }

    /// Bring the star counts up to date (shared with the BioCartoon editor); Popular results are put in the new order.
    private func syncStars() {
        Task {
            if await BCStars.shared.sync(), exe != nil, Self.sorts[sortPopup.indexOfSelectedItem].1 == "popular" { reload() }
        }
    }

    @objc private func starsChanged() {
        for case let tile as BCTile in grid.visibleItems() { tile.refreshStar() }
    }

    private func locate() {
        status.stringValue = "Looking for biocartoon…"
        Task {
            let found = await BioCartoonCLI.usable()
            facets = nil; facetsFor = nil
            guard case .success(let exe) = found else {
                if case .failure(let why) = found {
                    // missing, or too old: offer to install it (or update it) into Manimble's environment
                    let missing = await Task.detached { BioCartoonCLI.find() == nil }.value
                    installButton.title = missing ? "Install BioCartoon" : "Update BioCartoon"
                    installButton.isHidden = false
                    setMessage(why.description)
                }
                return
            }
            self.exe = exe
            installButton.isHidden = true
            syncCatalog(exe)
            // the first call downloads the catalog, so it goes alone; the dropdowns fill in behind the results
            if let s = try? await BioCartoonCLI.sources(exe) { setSources(s) }
            reload()
            syncStars()
            await loadChoices(exe)
        }
    }

    /// Whether this run of Manimble has checked for a newer catalog.
    private static var catalogSynced = false

    /// Once per run, bring the downloaded catalog up to the published one in the background; searches use the copy
    /// they have meanwhile, and start over on the new one when it comes in.
    private func syncCatalog(_ exe: String) {
        guard !Self.catalogSynced else { return }
        Self.catalogSynced = true
        Task {
            do {
                guard try await BioCartoonCLI.sync(exe), self.exe == exe else { return }
                if let s = try? await BioCartoonCLI.sources(exe) { setSources(s) }
                reload()
                await loadChoices(exe)
            } catch {
                NSLog("BioCartoon catalog sync failed: \(error)")  // offline: keep the copy we have
            }
        }
    }

    /// The Category, License and database-category dropdowns' choices.
    private func loadChoices(_ exe: String) async {
        async let cats = BioCartoonCLI.categories(exe)
        async let lics = BioCartoonCLI.licenseCounts(exe)
        async let own = BioCartoonCLI.sourceCategories(exe)
        if let c = try? await cats { setCategories(c) }
        if let l = try? await lics { setLicenses(l) }
        if let d = try? await own { setDbCategories(d) }
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

    /// SVG (the database publishes an SVG) and PNG (a PNG only), counted once the search's counts come.
    private func refreshFileTypes() {
        var counts: [String: Int] = [:]
        for r in facets?.file_types ?? [] { if let t = r.file_type?.lowercased() { counts[t] = r.icons } }
        fileTypePopup.setChoices([("svg", "SVG"), ("png", "PNG")].compactMap { key, name in
            shown(facets == nil ? nil : counts[key] ?? 0, catalog: nil, picked: fileTypePopup.picked.contains(key)).map { (key, name, $0) }
        })
    }

    private func setDbCategories(_ list: [(database: String, category: String, count: Int)]) {
        dbCategories = list
        refreshDbCategories()
    }

    /// Each database's own categories, "BA: Viruses", in the order of the databases (of the picked ones when any are).
    private func refreshDbCategories() {
        var all = dbCategories
        if let fc = facets {
            all = fc.source_categories.compactMap { r in r.source.flatMap { s in r.category.map { (s, $0, r.icons) } } }
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
        guard let exe = exe else { return }
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
                refreshSources(); refreshCategories(); refreshSubcategories(); refreshLicenses(); refreshDbCategories(); refreshFileTypes()
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
        for p in [dbPopup, catPopup, subPopup, dbCatPopup, licensePopup, fileTypePopup] { p.clear() }
        authorField.stringValue = ""
        tagsField.stringValue = ""
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
        filter.fileTypes = fileTypePopup.picked
        filter.authors = authorField.stringValue
        filter.tags = tagsField.stringValue
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
        dbCatPopup.pick(f.dbCats); licensePopup.pick(f.licenses); fileTypePopup.pick(f.fileTypes)
        authorField.stringValue = f.authors
        tagsField.stringValue = f.tags
        filterBox.isHidden = false
        refreshFilterChrome()
        reload()
    }

    /// The funnel lights up while filters are set or shown; set ones are summed up in a line while hidden.
    private func refreshFilterChrome() {
        let active = !filter.isEmpty
        funnel.contentTintColor = active || !filterBox.isHidden ? Theme.accent : .secondaryLabelColor
        funnel.toolTip = filterBox.isHidden ? "Filter by database, author, category, license, file type or tags" : "Hide the filters"
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
        if !filter.fileTypes.isEmpty { parts.append(filter.fileTypes.sorted().map { $0.uppercased() }.joined(separator: ", ")) }
        if !filter.tagList.isEmpty { parts.append("tagged " + filter.tagList.joined(separator: ", ")) }
        return parts.joined(separator: "  ·  ")
    }

    @objc private func sortChanged() {
        sortPicked = true
        reload()
    }

    /// Unless the sort was picked by hand, set it for what's typed; true if that changed it. Relevance
    /// is offered only once something is typed.
    @discardableResult private func followSearch() -> Bool {
        let empty = search.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        let relevance = Self.sorts.firstIndex { $0.1 == "relevance" }!
        sortPopup.item(at: relevance)?.isHidden = empty
        guard !sortPicked || (empty && sortPopup.indexOfSelectedItem == relevance) else { return false }
        let key = empty ? "popular" : "relevance"
        let i = Self.sorts.firstIndex { $0.1 == key }!
        guard sortPopup.indexOfSelectedItem != i else { return false }
        sortPopup.selectItem(at: i)
        return true
    }
    @objc private func searchSubmitted() { typing?.cancel(); reload() }
    func controlTextDidChange(_ n: Notification) {
        typing?.cancel()
        let field = n.object as? NSTextField
        let edited = field === authorField || field === tagsField
        let w = DispatchWorkItem { [weak self] in edited ? self?.filtersEdited() : self?.reload() }
        typing = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    // MARK: results

    /// Start a new search from the first page.
    func reload() {
        followSearch()
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
        BCInfoTip.shared.hide()
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
    var message: String { creditBox.isHidden ? "" : creditLabel.stringValue }
    var offersInstall: String? { installButton.isHidden ? nil : installButton.title }
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
        hideFeedbackPane()
        hideScriptPane()
        p.view.isHidden = false
        inspectorScroll?.isHidden = true
        if let right = mainSplit?.subviews.last, right.isHidden { right.isHidden = false; mainSplit?.adjustSubviews() }
        p.activate(in: window)
    }

    /// Back to the inspector.
    func hideBioCartoon() {
        BCInfoTip.shared.hide()
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
        var base = stem, n = 1
        while ["png", "svg"].contains(where: { FileManager.default.fileExists(atPath: ws.work.appendingPathComponent("\(base).\($0)").path) }) {
            base = "\(stem)_\(n)"; n += 1
        }
        let png = ws.work.appendingPathComponent(base + ".png"), svg = ws.work.appendingPathComponent(base + ".svg")
        let c = point ?? CGPoint(x: canvas.frameSize.width / 2, y: canvas.frameSize.height / 2)
        busyPill.show("Downloading \(icon.title)…", symbol: nil, tint: nil, spinning: true, cancellable: false)
        Task { @MainActor in
            var size: CGSize
            let dest: URL
            do {
                try await BioCartoonCLI.fetch(exe, id: icon.id, to: png)
                // a vector picture when the icon is published as SVG and manim draws it like the PNG, else the PNG
                if icon.svg_key != nil, let v = await vectorCopy(exe, icon, png: png, to: svg) {
                    try? FileManager.default.removeItem(at: png)
                    BioCartoonCLI.tagSVG(svg, with: icon)
                    dest = svg; size = v
                } else {
                    dest = png
                    size = await Task.detached { () -> CGSize in
                        let s = BioCartoonCLI.trimTransparentMargins(png)
                        BioCartoonCLI.tag(png, with: icon)
                        return s
                    }.value
                }
            } catch { busyPill.hide(); toast("Could not download \(icon.title): \(error)", error: true); return }
            busyPill.hide()
            let half = 1.5 * canvas.unitPx * min(1, size.width / max(size.height, 1))
            insert(kind: "image", extra: ["file": dest.lastPathComponent, "path": dest.path,
                                          "sx": Double(c.x) - half, "sy": Double(c.y), "ex": Double(c.x) + half, "ey": Double(c.y)])
            biocartoonPane?.showCredit(icon)
        }
    }

    /// The icon's SVG made ready for manim at `dest` (the engine's svg_icon: flattened, even-odd holes kept, strokes
    /// scaled with the picture), when manim draws it like the catalog's PNG; its size, or nil to keep the PNG.
    private func vectorCopy(_ exe: String, _ icon: BCIcon, png: URL, to dest: URL) async -> CGSize? {
        struct Prepared: Decodable { var ok: Bool; var width: Double?; var height: Double?; var why: String? }
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("biocartoon-\(UUID().uuidString).svg")
        defer { try? FileManager.default.removeItem(at: raw) }
        guard (try? await BioCartoonCLI.fetchSVG(exe, id: icon.id, to: raw)) != nil,
              let r = try? await engine.call("svg_icon", ["svg": raw.path, "png": png.path, "out": dest.path], as: Prepared.self)
        else { return nil }
        guard r.ok, let w = r.width, let h = r.height, w > 0, h > 0 else {
            NSLog("BioCartoon %@ stays a PNG: %@", icon.id, r.why ?? "?")
            return nil
        }
        return CGSize(width: w, height: h)
    }
}

extension MainController {
    // MARK: right-click on a picture

    /// The right-click menu's BioCartoon item for the selected picture: its credit when it came from the catalog,
    /// otherwise an offer to submit it to the shared library (as the BioCartoon editor's canvas menu).
    func bioCartoonMenuItem() -> NSMenuItem? {
        guard let o = objInfo, o.kind == "image", let path = o.imagePath, FileManager.default.fileExists(atPath: path) else { return nil }
        if let icon = BioCartoonCLI.origin(ofImageAt: path) {
            return BCMenuItem("Show Credit…") { [weak self] in self?.showBioCartoonCredit(icon) }
        }
        let item = BCMenuItem("Add to BioCartoon Library…") { [weak self] in self?.addToBioCartoon(path) }
        item.toolTip = "Submit this picture to the shared BioCartoon library"
        return item
    }

    /// Right-click ▸ Show Credit…: who made the artwork, ready to copy.
    func showBioCartoonCredit(_ icon: BCIcon) {
        let a = NSAlert()
        a.messageText = icon.title
        a.informativeText = icon.credit ?? icon.title
        a.icon = BioCartoonCLI.logo
        a.addButton(withTitle: "Copy Credit")
        a.addButton(withTitle: "Done")
        a.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            BioCartoonCLI.copy(icon.credit ?? icon.title)
            self?.toast("Copied the credit")
        }
    }

    /// Right-click ▸ Add to BioCartoon Library…: title, credit, license and category, then `biocartoon upload`.
    func addToBioCartoon(_ path: String) {
        Task { @MainActor in
            let found = await BioCartoonCLI.usable()
            guard case .success(let exe) = found else {
                toast("BioCartoon needs installing or updating: open Insert ▸ BioCartoon Icons…", error: true)
                return
            }
            let cats = (try? await BioCartoonCLI.categories(exe)) ?? []
            let form = BCSubmitForm(file: path, categories: cats)
            let a = NSAlert()
            a.messageText = "Add to BioCartoon Library"
            a.informativeText = "Submit this picture to the shared library, where everyone can find it. Submissions are reviewed before they are published (up to 20 a day)."
            a.icon = BioCartoonCLI.logo
            a.accessoryView = form.view
            let submit = a.addButton(withTitle: "Submit for Review")
            a.addButton(withTitle: "Cancel")
            form.onValidity = { submit.isEnabled = $0 }
            form.refresh()
            a.beginSheetModal(for: window) { [weak self] r in
                guard r == .alertFirstButtonReturn, let self = self else { return }
                let v = form.values
                UserDefaults.standard.set(v.credit, forKey: "biocartoonCredit")
                self.busyPill.show("Submitting \(v.title)…", symbol: nil, tint: nil, spinning: true, cancellable: false)
                Task { @MainActor in
                    do {
                        try await BioCartoonCLI.upload(exe, file: path, title: v.title, credit: v.credit, license: v.license,
                                                       category: v.category, description: v.description)
                        self.busyPill.hide()
                        self.toast("Submitted \(v.title) for review: it joins the BioCartoon library once approved")
                    } catch {
                        self.busyPill.hide()
                        self.toast("Could not submit \(v.title): \(error)", error: true)
                    }
                }
            }
            window.makeFirstResponder(form.titleField)
        }
    }
}

/// The fields of Add to BioCartoon Library: what `biocartoon upload` takes.
@MainActor
final class BCSubmitForm: NSObject, NSTextFieldDelegate {
    let view: NSView
    let titleField = NSTextField()
    private let creditField = NSTextField()
    private let license = NSPopUpButton(frame: .zero, pullsDown: false)
    private let category = NSPopUpButton(frame: .zero, pullsDown: false)
    private let descriptionField = NSTextField()
    private let confirm = NSButton(checkboxWithTitle: "I made this picture, or may share it under this license", target: nil, action: nil)
    var onValidity: ((Bool) -> Void)?
    private static let licenses = [("CC-BY-4.0", "CC BY 4.0 (users credit you)"), ("CC0-1.0", "CC0 (no credit needed)")]

    init(file: String, categories: [BCCategory]) {
        let stem = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        titleField.stringValue = stem.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        creditField.stringValue = UserDefaults.standard.string(forKey: "biocartoonCredit") ?? NSFullUserName()
        creditField.placeholderString = "Anonymous"
        descriptionField.placeholderString = "Optional"
        for (key, name) in Self.licenses { license.addItem(withTitle: name); license.lastItem?.representedObject = key }
        category.addItem(withTitle: "None")
        let tops = Dictionary(categories.filter { !$0.slug.contains(".") }.map { ($0.slug, $0.name) }, uniquingKeysWith: { a, _ in a })
        for c in categories {
            let top = String(c.slug.prefix { $0 != "." })
            category.addItem(withTitle: c.slug.contains(".") ? "\(tops[top] ?? top) › \(c.name)" : c.name)
            category.lastItem?.representedObject = c.slug
        }
        let rows: [[NSView]] = [[Self.label("Title"), titleField], [Self.label("Credit"), creditField], [Self.label("License"), license],
                                [Self.label("Category"), category], [Self.label("Description"), descriptionField]]
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8; grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for f in [titleField, creditField, descriptionField] { f.widthAnchor.constraint(equalToConstant: 280).isActive = true }
        let stack = NSStackView(views: [grid, confirm])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        view = stack
        super.init()
        titleField.delegate = self
        confirm.target = self; confirm.action = #selector(changed)
    }

    private static func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }

    var values: (title: String, credit: String, license: String, category: String, description: String) {
        let t = { (f: NSTextField) in f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (t(titleField), t(creditField), license.selectedItem?.representedObject as? String ?? "CC-BY-4.0",
                category.selectedItem?.representedObject as? String ?? "", t(descriptionField))
    }

    func refresh() { onValidity?(confirm.state == .on && !values.title.isEmpty) }
    @objc private func changed() { refresh() }
    func controlTextDidChange(_ n: Notification) { refresh() }
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
            await wait("first page") { p.resultCount > 0 || p.offersInstall != nil }
            if let b = p.offersInstall { log("offers \(b): \(p.message)"); log("done"); return }
            // the star counts come from the Worker and land in the editor's usage file; Popular puts the starred first
            let stars = BCStars.shared
            await wait("star sync") { !stars.counts.isEmpty }
            log("stars: \(stars.counts.count) counted, \(stars.mine.count) mine, client \(stars.client.prefix(6))…")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await wait("popular") { !p.isLoading && p.resultCount > 0 }
            log("popular: " + p.allResults.prefix(8).map { "\($0.id) \(stars.count($0))\(stars.isStarred($0) ? "*" : "")" }.joined(separator: ", "))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            shot(p.view, "biocartoon_stars.png")
            p.type("mitochondria")
            try? await Task.sleep(nanoseconds: 300_000_000)
            await wait("search") { p.resultCount > 0 && p.firstResult?.title.lowercased().contains("mito") == true }
            let plain = p.resultCount
            // the dropdowns count what the search finds
            await wait("facets") { p.facetsSettled && p.facets != nil }
            log("facets for mitochondria: databases \(counts(p.facets?.sources ?? [], \.source))")
            log("source categories for mitochondria: \(p.facets?.source_categories.count ?? 0)")
            // the filters go to the command line
            var f = BCFilter(); f.licenses = ["CC0-1.0"]; f.sources = ["bioicons", "healthicons", "scidraw"]; f.categories = ["cells"]
            f.fileTypes = ["svg"]
            p.apply(f)
            try? await Task.sleep(nanoseconds: 300_000_000)
            await wait("filtered") { !p.isLoading && p.resultCount > 0 }
            let bad = p.allResults.filter { $0.license != "CC0-1.0" || !f.sources.contains($0.database) || $0.svg_key == nil }
            log("filtered: \(p.resultCount) of \(plain), off: \(bad.count)")
            await wait("filtered facets") { p.facetsSettled }
            log("filtered facets: databases \(counts(p.facets?.sources ?? [], \.source)); licenses \(counts(p.facets?.licenses ?? [], \.license)); file types \(counts(p.facets?.file_types ?? [], \.file_type))")
            try? await Task.sleep(nanoseconds: 2_000_000_000)      // thumbnails
            shot(p.view, "biocartoon_pane.png")
            shot(window.contentView, "biocartoon_filters_window.png")
            p.apply(BCFilter())
            try? await Task.sleep(nanoseconds: 300_000_000)
            await wait("unfiltered") { !p.isLoading && p.resultCount > 0 }
            guard let icon = p.firstResult, let data = try? JSONEncoder().encode(icon) else { log("no result"); return }
            log("first: \(icon.id) \(icon.title) \(Int(icon.width ?? 0))x\(Int(icon.height ?? 0))")
            log("info: \(icon.info.string.replacingOccurrences(of: "\n", with: " | "))")
            BCInfoTip.shared.show(icon, beside: p.view)
            try? await Task.sleep(nanoseconds: 300_000_000)
            shot(BCInfoTip.shared.contentView, "biocartoon_info.png")
            BCInfoTip.shared.hide()
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
            // right-click on the placed picture: its credit; on a picture of one's own: the library offer
            if let (k, o) = scene?.objects?.first(where: { $0.value.kind == "image" && !before.contains($0.value.image ?? "") }),
               let path = o.imagePath {
                log("origin: \(BioCartoonCLI.origin(ofImageAt: path)?.id ?? "-")")
                selection = Int(k)
                log("menu: \(canvasMenu()?.items.map(\.title) ?? [])")
                let plain = URL(fileURLWithPath: dir + "plain.png")
                if let img = try? ImageExtractor.load(path: path), let data = ImageExtractor.png(img) { try? data.write(to: plain) }
                log("plain origin: \(BioCartoonCLI.origin(ofImageAt: plain.path)?.id ?? "-")")
                do {
                    try await BioCartoonCLI.upload(BioCartoonCLI.find() ?? "", file: plain.path, title: "Test picture", credit: "Tester",
                                                   license: "CC0-1.0", category: "cells", description: "", dryRun: true)
                    log("upload dry run: ok")
                } catch { log("upload dry run: \(error)") }
            }
            // an icon published as SVG that manim draws as it looks (even-odd holes) goes in as a vector picture
            var vf = BCFilter(); vf.sources = ["healthicons"]; vf.fileTypes = ["svg"]
            if let exe = p.exe, let vec = try? await BioCartoonCLI.search(exe, query: "ambulance", filter: vf, sort: "relevance", offset: 0, limit: 1).first {
                let had = images()
                insertBioCartoon(vec, at: CGPoint(x: canvas.frameSize.width * 0.75, y: canvas.frameSize.height * 0.7))
                await wait("vector inserted") { images().count > had.count }
                await queueTail?.value
                log("vector: \(vec.id) -> \(images().filter { !had.contains($0) })")
                if let o = scene?.objects?.values.first(where: { $0.kind == "image" && !had.contains($0.image ?? "") }), let path = o.imagePath {
                    log("vector origin: \(BioCartoonCLI.origin(ofImageAt: path)?.id ?? "-"), placed: \(o.loc)")
                }
            } else { log("vector: no SVG icon found") }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            shot(window.contentView, "biocartoon_window.png")
            hideBioCartoon()
            log("closed: pane hidden \(p.view.isHidden), inspector shown \(inspectorScroll?.isHidden == false)")
            log("done")
        }
    }
}

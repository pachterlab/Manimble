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
    var category: String?
    var url: String?            // a web URL, or a local path for the user's own uploads
    var png_local: String?
    var width: Double?
    var height: Double?
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

    static func search(_ exe: String, query: String, source: String?, sort: String, offset: Int, limit: Int) async throws -> [BCIcon] {
        var args = ["search"]
        if !query.isEmpty { args.append(query) }
        args += ["--icons", "--no-sql", "--json", "--limit", String(limit), "--offset", String(offset), "--sort", sort]
        if let s = source { args += ["--source", s] }
        struct Hits: Decodable { var icons: [BCIcon]? }
        // the first search downloads the catalog, so it may take a while
        return try JSONDecoder().decode(Hits.self, from: try await run(exe, args, timeout: 300)).icons ?? []
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

    /// `pip install biocartoon` into Manimble's Python environment.
    static func install() async throws {
        _ = try await run(python, ["-m", "pip", "install", "--disable-pip-version-check", "biocartoon"], timeout: 600)
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
        badge.backgroundColor = BioCartoonCLI.badgeColor(icon.source)
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
            item.setData((try? JSONEncoder().encode(icon)) ?? Data(), forType: BioCartoonPanel.dragType)
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

/// The BioCartoon icon search (Insert ▸ BioCartoon Icons…): a floating panel laid out like the BioCartoon editor's
/// search sidebar, backed by the `biocartoon` command line.
@MainActor
final class BioCartoonPanel: NSObject, NSCollectionViewDataSource, NSSearchFieldDelegate, NSWindowDelegate {
    static let dragType = NSPasteboard.PasteboardType("com.manimble.biocartoon-icon")
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 352, height: 640),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
    /// Insert an icon at the slide's centre (a click on its tile).
    var onInsert: ((BCIcon) -> Void)?

    private let search = NSSearchField()
    private let sourceBar = NSSegmentedControl()
    private let sortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(labelWithString: "")
    private let installButton = NSButton(title: "Install BioCartoon", target: nil, action: nil)
    private let grid = NSCollectionView()
    private let scroll = NSScrollView()
    private let creditLabel = NSTextField(wrappingLabelWithString: "")
    private let copyCredit = NSButton(title: "Copy credit", target: nil, action: nil)

    private(set) var exe: String?
    private var sources: [BCSource] = []
    private var results: [BCIcon] = []
    private var more = false
    private var loading = false
    private var generation = 0
    private var typing: DispatchWorkItem?
    private static let pageSize = 60
    private static let sorts = [("Relevance", "relevance"), ("Popular", "popular"), ("A–Z", "az"), ("Z–A", "za")]

    override init() {
        super.init()
        panel.title = "BioCartoon"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 300, height: 360)
        panel.setFrameAutosaveName("manimble.biocartoon")
        panel.delegate = self

        let logo = NSImageView(image: BioCartoonCLI.logo)
        logo.widthAnchor.constraint(equalToConstant: 22).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let heading = NSTextField(labelWithString: "Search BioCartoon")
        heading.font = Theme.font(13, .semibold)
        let head = NSStackView(views: [logo, heading]); head.spacing = 7

        search.placeholderString = "Search icons (cell, neuron, mouse…)"
        search.delegate = self
        search.sendsSearchStringImmediately = false
        search.target = self; search.action = #selector(searchSubmitted)

        sourceBar.segmentStyle = .roundRect
        sourceBar.controlSize = .small
        sourceBar.trackingMode = .selectOne
        sourceBar.target = self; sourceBar.action = #selector(filterChanged)
        setSources([])

        sortPopup.controlSize = .small
        sortPopup.font = Theme.font(11)
        sortPopup.addItems(withTitles: Self.sorts.map { $0.0 })
        sortPopup.selectItem(at: max(0, Self.sorts.firstIndex { $0.1 == UserDefaults.standard.string(forKey: "biocartoonSort") } ?? 0))
        sortPopup.target = self; sortPopup.action = #selector(filterChanged)
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
        grid.isSelectable = false
        grid.backgroundColors = [.clear]
        grid.register(BCTile.self, forItemWithIdentifier: BCTile.id)
        scroll.documentView = grid
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        creditLabel.font = Theme.font(10); creditLabel.textColor = .secondaryLabelColor
        creditLabel.maximumNumberOfLines = 3
        creditLabel.isSelectable = true
        copyCredit.controlSize = .small; copyCredit.bezelStyle = .rounded
        copyCredit.target = self; copyCredit.action = #selector(copyCreditPressed)
        let creditBox = NSStackView(views: [creditLabel, copyCredit])
        creditBox.orientation = .vertical; creditBox.alignment = .leading; creditBox.spacing = 4
        creditBox.isHidden = true
        self.creditBox = creditBox

        let stack = NSStackView(views: [head, search, sourceBar, sortRow, installButton, scroll, creditBox])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 36, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [search, sourceBar, sortRow, scroll, creditBox] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        creditLabel.preferredMaxLayoutWidth = 320
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
    }
    private var creditBox: NSStackView!

    /// Show the panel next to `window` and get the command line ready.
    func show(beside window: NSWindow?) {
        if !panel.isVisible, let w = window, UserDefaults.standard.string(forKey: "NSWindow Frame manimble.biocartoon") == nil {
            let f = w.frame
            panel.setFrame(NSRect(x: f.minX + 12, y: f.maxY - 80 - 640, width: 352, height: 640), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
        if exe == nil { locate() }
    }

    private func locate() {
        status.stringValue = "Looking for biocartoon…"
        Task {
            let found = await Task.detached { BioCartoonCLI.find() }.value
            exe = found
            installButton.isHidden = found != nil
            guard let exe = found else {
                status.stringValue = ""
                setMessage("The BioCartoon command line is not installed. Install it into Manimble's Python environment (pip install biocartoon) to search 15,000+ open-licensed science icons.")
                return
            }
            if let s = try? await BioCartoonCLI.sources(exe) { setSources(s) }
            reload()
        }
    }

    private func setMessage(_ s: String) {
        results = []; grid.reloadData()
        status.stringValue = ""
        creditLabel.stringValue = s
        creditBox.isHidden = false
        copyCredit.isHidden = true
    }

    private func setSources(_ list: [BCSource]) {
        sources = list.filter { ($0.icons ?? 1) > 0 }
        sourceBar.segmentCount = sources.count + 1
        sourceBar.setLabel("All", forSegment: 0)
        sourceBar.setWidth(0, forSegment: 0)
        for (i, s) in sources.enumerated() {
            sourceBar.setLabel(s.code, forSegment: i + 1)
            sourceBar.setToolTip(s.name + (s.icons.map { " (\($0) icons)" } ?? ""), forSegment: i + 1)
        }
        sourceBar.selectedSegment = 0
    }

    private var sourceCode: String? { sourceBar.selectedSegment > 0 ? sources[sourceBar.selectedSegment - 1].code : nil }
    private func code(for source: String) -> String { sources.first { $0.source == source }?.code ?? "" }

    @objc private func filterChanged() {
        UserDefaults.standard.set(Self.sorts[sortPopup.indexOfSelectedItem].1, forKey: "biocartoonSort")
        reload()
    }
    @objc private func searchSubmitted() { typing?.cancel(); reload() }
    func controlTextDidChange(_ n: Notification) {
        typing?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reload() }
        typing = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    /// Start a new search from the first page.
    func reload() {
        generation += 1
        results = []; more = false; loading = false
        grid.reloadData()
        scroll.contentView.scroll(to: .zero)
        loadPage()
    }

    private func loadPage() {
        guard let exe = exe, !loading else { return }
        loading = true
        let gen = generation, offset = results.count
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        status.stringValue = offset == 0 ? "Searching…" : "Loading more…"
        Task {
            do {
                let page = try await BioCartoonCLI.search(exe, query: query, source: sourceCode,
                                                          sort: Self.sorts[sortPopup.indexOfSelectedItem].1, offset: offset, limit: Self.pageSize)
                guard gen == generation else { return }
                loading = false
                more = page.count == Self.pageSize
                let start = results.count
                results += page
                if start == 0 { grid.reloadData() }
                else { grid.insertItems(at: Set((start..<results.count).map { IndexPath(item: $0, section: 0) })) }
                status.stringValue = results.isEmpty ? "No results" : "\(results.count)\(more ? "+" : "") icons"
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

    @objc private func installPressed() {
        installButton.isEnabled = false
        status.stringValue = "Installing biocartoon…"
        Task {
            do {
                try await BioCartoonCLI.install()
                installButton.isEnabled = true
                creditBox.isHidden = true
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
        item.show(icon, code: code(for: icon.source))
        item.onClick = { [weak self] icon in self?.onInsert?(icon) }
        return item
    }
}

extension MainController {
    @objc func showBioCartoon() {
        let p = biocartoonPanel ?? BioCartoonPanel()
        p.onInsert = { [weak self] icon in self?.insertBioCartoon(icon, at: nil) }
        biocartoonPanel = p
        p.show(beside: window)
    }

    func biocartoonDropped(_ data: Data, at p: CGPoint) -> Bool {
        guard sceneName != nil, player == nil, let icon = try? JSONDecoder().decode(BCIcon.self, from: data) else { return false }
        insertBioCartoon(icon, at: p)
        return true
    }

    /// Download the icon's PNG into the deck folder and insert it as a picture, centred on `point`
    /// (frame px; nil = the slide's centre), its longer side 3 manim units.
    func insertBioCartoon(_ icon: BCIcon, at point: CGPoint?) {
        guard let ws = workspace, sceneName != nil, player == nil, let exe = biocartoonPanel?.exe else { return }
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
            biocartoonPanel?.showCredit(icon)
        }
    }
}

extension MainController {
    // MARK: headless check (MANIMBLE_TEST_BIOCARTOON=deck)

    func biocartoonTest() {
        let dir = (ProcessInfo.processInfo.environment["MANIMBLE_TEST_OUT"] ?? "/tmp") + "/"
        func log(_ s: String) { try? (s + "\n").appendLine(to: dir + "biocartoon.log") }
        func shot(_ w: NSWindow, _ name: String) {
            guard let v = w.contentView?.superview, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + name))
        }
        func images() -> [String] { (scene?.objects?.values.compactMap { $0.kind == "image" ? $0.image : nil } ?? []).sorted() }
        func wait(_ what: String, _ ok: () -> Bool) async {
            for _ in 0..<600 where !ok() { try? await Task.sleep(nanoseconds: 100_000_000) }
            log("\(what): \(ok() ? "ok" : "TIMED OUT")")
        }
        Task { @MainActor in
            log("biocartoon at \(BioCartoonCLI.find() ?? "-")")
            showBioCartoon()
            guard let p = biocartoonPanel else { log("no panel"); return }
            await wait("first page") { p.resultCount > 0 }
            p.type("mitochondria")
            try? await Task.sleep(nanoseconds: 300_000_000)
            await wait("search") { p.resultCount > 0 && p.firstResult?.title.lowercased().contains("mito") == true }
            try? await Task.sleep(nanoseconds: 2_000_000_000)      // thumbnails
            shot(p.panel, "biocartoon_panel.png")
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
            shot(window, "biocartoon_window.png")
            log("done")
        }
    }
}

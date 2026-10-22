import AppKit

/// The Extract Elements sheet: the picture with every element that will be cut out tinted on top, like PowerPoint's
/// Remove Background. Drag a box around something to add it (the subject-lifting model finds the thing inside the
/// box), paint with Keep / Remove to fix an element's edges, and choose whether the picture behind gets filled in.
@MainActor final class ExtractEditor: NSObject {
    enum Tool: Int { case box, keep, remove }
    struct Result {
        let masks: [[UInt8]]
        let fill: Bool
        let filled: CGImage?        // the background preview, when it was computed for exactly these masks
    }

    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.49, green: 0.36, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.60, blue: 0.18, alpha: 1), NSColor(srgbRed: 0.30, green: 0.70, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 1.0, green: 0.27, blue: 0.55, alpha: 1), NSColor(srgbRed: 0.95, green: 0.85, blue: 0.10, alpha: 1),
    ]

    struct Element {
        var mask: [UInt8]
        var region: CGRect?             // the box it was drawn from
        var bounds: CGRect?
        var overlay: CGImage?
        let color: NSColor
    }

    let image: CGImage
    let w: Int, h: Int
    private(set) var elements: [Element] = []
    var selected: Int? { didSet { canvas.needsDisplay = true; refreshControls() } }
    var tool: Tool = .box { didSet { toolControl.selectedSegment = tool.rawValue; refreshControls(); canvas.window?.invalidateCursorRects(for: canvas) } }
    var brush: CGFloat { CGFloat(brushSlider.doubleValue) }       // radius in view points
    private var colorIndex = 0
    private var undoStack: [([Element], Int?)] = []
    private var redoStack: [([Element], Int?)] = []
    private var busyCount = 0 { didSet { busyCount > 0 ? spinner.startAnimation(nil) : spinner.stopAnimation(nil) } }

    // background preview
    private(set) var filled: CGImage?
    private var filledFor = -1                 // `generation` the preview was made for
    private var generation = 0                 // bumps on every change to the masks

    let window: NSWindow
    private let canvas: ExtractCanvas
    private let toolControl = NSSegmentedControl()
    private let brushSlider = NSSlider(value: 14, minValue: 3, maxValue: 60, target: nil, action: nil)
    private let brushLabel = NSTextField(labelWithString: "Brush")
    private let wholeBox = NSButton(title: "Whole Box", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear All", target: nil, action: nil)
    private let detectButton = NSButton(title: "Find Elements", target: nil, action: nil)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let fillBox = NSButton(checkboxWithTitle: "Fill in the background behind them", target: nil, action: nil)
    private let previewBox = NSButton(checkboxWithTitle: "Preview background", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let insertButton = NSButton(title: "Insert", target: nil, action: nil)
    private var finish: ((Result?) -> Void)?

    init(image: CGImage, masks: [[UInt8]], source: String) {
        self.image = image
        w = image.width; h = image.height
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        canvas = ExtractCanvas()
        super.init()
        canvas.editor = self
        window.title = "Extract Elements"
        window.minSize = NSSize(width: 720, height: 520)
        for m in masks { elements.append(makeElement(mask: m, region: nil)) }

        let heading = NSTextField(labelWithString: "Extract elements from \(source)"); heading.font = Theme.font(13, .semibold)
        toolControl.segmentCount = 3
        for (i, (label, symbol, tip)) in [("Box", "rectangle.dashed", "Drag a box around something to add it as an element (B)"),
                                          ("Keep", "plus.circle", "Paint over parts the selected element should include (K)"),
                                          ("Remove", "minus.circle", "Paint over parts the selected element should leave out (R)")].enumerated() {
            toolControl.setLabel(label, forSegment: i)
            toolControl.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label), forSegment: i)
            toolControl.setImageScaling(.scaleProportionallyDown, forSegment: i)
            toolControl.setToolTip(tip, forSegment: i)
        }
        toolControl.trackingMode = .selectOne
        toolControl.selectedSegment = 0
        toolControl.target = self; toolControl.action = #selector(toolChanged)
        brushSlider.target = self; brushSlider.action = #selector(brushChanged)
        brushLabel.textColor = .secondaryLabelColor
        wholeBox.toolTip = "Cut out the selected element's whole box instead of the shape found inside it"
        for (b, sel) in [(wholeBox, #selector(wholeBoxPressed)), (deleteButton, #selector(deletePressed)),
                         (clearButton, #selector(clearPressed)), (detectButton, #selector(detectPressed))] {
            b.target = self; b.action = sel; b.bezelStyle = .rounded; b.controlSize = .small
        }
        detectButton.toolTip = "Add every separate subject the picture's model finds"
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let tools = NSStackView(views: [toolControl, brushLabel, brushSlider, spacer, spinner, detectButton, wholeBox, deleteButton, clearButton])
        tools.spacing = 8
        brushSlider.widthAnchor.constraint(equalToConstant: 110).isActive = true

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.wantsLayer = true
        canvas.layer?.cornerRadius = 6; canvas.layer?.masksToBounds = true
        Theme.layerColors(canvas) { $0.layer?.backgroundColor = Theme.canvasBottom.cgColor }

        hint.textColor = .secondaryLabelColor; hint.font = Theme.font(11.5)
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fillBox.state = .on
        fillBox.toolTip = "Replace the picture with a copy where a best guess of what is behind each element is painted in, so the elements can be moved away"
        fillBox.target = self; fillBox.action = #selector(fillChanged)
        previewBox.target = self; previewBox.action = #selector(previewChanged)
        let options = NSStackView(views: [fillBox, previewBox]); options.spacing = 16

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed)); cancel.keyEquivalent = "\u{1b}"
        insertButton.target = self; insertButton.action = #selector(insertPressed); insertButton.keyEquivalent = "\r"
        let spacer2 = NSView(); spacer2.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [options, spacer2, cancel, insertButton]); buttons.spacing = 8

        let stack = NSStackView(views: [heading, tools, canvas, hint, hairline(), buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            tools.widthAnchor.constraint(equalTo: stack.widthAnchor), canvas.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        canvas.setContentHuggingPriority(.init(1), for: .vertical)
        selected = elements.isEmpty ? nil : 0
        refreshControls()
    }

    /// Show the sheet on `parent`; `done` gets the chosen masks, or nil when cancelled.
    func run(on parent: NSWindow, done: @escaping (Result?) -> Void) {
        finish = done
        // as large as the parent allows, keeping the picture's shape
        let room = parent.contentLayoutRect.size
        let chrome = NSSize(width: 36, height: 190)
        let fit = min((room.width - 40 - chrome.width) / CGFloat(w), (room.height - 40 - chrome.height) / CGFloat(h), 1.5)
        let size = NSSize(width: max(720, CGFloat(w) * fit + chrome.width), height: max(520, CGFloat(h) * fit + chrome.height))
        window.setContentSize(NSSize(width: min(size.width, room.width - 20), height: min(size.height, room.height - 20)))
        parent.beginSheet(window) { _ in }
        window.makeFirstResponder(canvas)
    }

    private func close(_ r: Result?) {
        window.sheetParent?.endSheet(window)
        let f = finish; finish = nil
        DispatchQueue.main.async { f?(r) }
    }

    // MARK: elements

    private func makeElement(mask: [UInt8], region: CGRect?) -> Element {
        let c = Self.colors[colorIndex % Self.colors.count]; colorIndex += 1
        var e = Element(mask: mask, region: region, bounds: nil, overlay: nil, color: c)
        refresh(&e)
        return e
    }

    /// Recompute an element's box and its tinted overlay after its mask changed.
    private func refresh(_ e: inout Element, bounds: Bool = true) {
        if bounds { e.bounds = ImageExtractor.bounds(of: e.mask, w: w, h: h) }
        e.overlay = Self.overlay(e.mask, color: e.color, w: w, h: h)
    }

    private static func overlay(_ mask: [UInt8], color: NSColor, w: Int, h: Int) -> CGImage? {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255), b = Int(c.blueComponent * 255)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) where mask[i] > 0 {
            let a = Int(mask[i]) * 140 / 255           // premultiplied
            px[i * 4] = UInt8(r * a / 255); px[i * 4 + 1] = UInt8(g * a / 255); px[i * 4 + 2] = UInt8(b * a / 255); px[i * 4 + 3] = UInt8(a)
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return px.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }

    private func changed() {
        generation += 1
        canvas.needsDisplay = true
        refreshControls()
        if previewBox.state == .on { computePreview() }
    }

    func checkpoint() {
        undoStack.append((elements, selected))
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let (els, sel) = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append((elements, selected))
        elements = els; selected = sel; changed()
    }

    func redo() {
        guard let (els, sel) = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append((elements, selected))
        elements = els; selected = sel; changed()
    }

    /// A new element from the box drawn on the picture (picture pixels, origin top-left).
    func addRegion(_ box: CGRect, wholeBox: Bool) {
        let cg = image, w = self.w, h = self.h
        busyCount += 1
        Task { @MainActor in
            let mask = await Task.detached(priority: .userInitiated) { () -> [UInt8] in
                wholeBox ? ImageExtractor.rectangle(w: w, h: h, box: box)
                         : ((try? ImageExtractor.subject(in: cg, box: box)) ?? ImageExtractor.rectangle(w: w, h: h, box: box))
            }.value
            self.busyCount -= 1
            self.checkpoint()
            self.elements.append(self.makeElement(mask: mask, region: box))
            self.selected = self.elements.count - 1
            self.changed()
        }
    }

    /// Element under a picture point: the topmost whose shape covers it, else the smallest box around it.
    func element(at p: CGPoint) -> Int? {
        let x = Int(p.x), y = Int(p.y)
        if x >= 0, y >= 0, x < w, y < h {
            for i in elements.indices.reversed() where elements[i].mask[y * w + x] > 127 { return i }
        }
        return elements.indices.filter { elements[$0].bounds?.contains(p) == true }
            .min { (elements[$0].bounds!.width * elements[$0].bounds!.height) < (elements[$1].bounds!.width * elements[$1].bounds!.height) }
    }

    /// Start a brush stroke: Keep with nothing selected starts a new element.
    func beginStroke() {
        checkpoint()
        if tool == .keep && selected == nil {
            elements.append(makeElement(mask: [UInt8](repeating: 0, count: w * h), region: nil))
            selected = elements.count - 1
        }
    }

    /// Paint a round dab of `radius` picture pixels along a segment: Keep adds it to the selected element, Remove
    /// takes it away from the selected element (or from every element when none is selected).
    func paint(from a: CGPoint, to b: CGPoint, radius: CGFloat) {
        let value: UInt8 = tool == .keep ? 255 : 0
        let targets = selected.map { [$0] } ?? (tool == .remove ? Array(elements.indices) : [])
        guard !targets.isEmpty else { return }
        let rr = max(1, radius), r2 = rr * rr
        let x0 = max(0, Int(min(a.x, b.x) - rr)), x1 = min(w - 1, Int(max(a.x, b.x) + rr))
        let y0 = max(0, Int(min(a.y, b.y) - rr)), y1 = min(h - 1, Int(max(a.y, b.y) + rr))
        guard x0 <= x1, y0 <= y1 else { return }
        let dx = b.x - a.x, dy = b.y - a.y, len2 = max(dx * dx + dy * dy, 1e-6)
        for i in targets {
            elements[i].mask.withUnsafeMutableBufferPointer { m in
                for y in y0...y1 {
                    for x in x0...x1 {
                        let px = CGFloat(x) + 0.5, py = CGFloat(y) + 0.5
                        let t = max(0, min(1, ((px - a.x) * dx + (py - a.y) * dy) / len2))
                        let ex = px - (a.x + t * dx), ey = py - (a.y + t * dy)
                        if ex * ex + ey * ey <= r2 { m[y * w + x] = value }
                    }
                }
            }
            refresh(&elements[i], bounds: false)
        }
        canvas.needsDisplay = true
    }

    func endStroke() {
        for i in elements.indices { elements[i].bounds = ImageExtractor.bounds(of: elements[i].mask, w: w, h: h) }
        // an element painted away entirely is gone
        let empty = elements.indices.filter { elements[$0].bounds == nil }
        if !empty.isEmpty {
            for i in empty.reversed() { elements.remove(at: i) }
            selected = nil
        }
        changed()
    }

    func deleteSelected() {
        guard let i = selected else { NSSound.beep(); return }
        checkpoint()
        elements.remove(at: i)
        selected = elements.isEmpty ? nil : min(i, elements.count - 1)
        changed()
    }

    // MARK: background preview

    private func computePreview() {
        guard filledFor != generation else { canvas.needsDisplay = true; return }
        let gen = generation, cg = image, w = self.w, h = self.h, masks = elements.map { $0.mask }
        guard !masks.isEmpty else { filled = nil; filledFor = gen; canvas.needsDisplay = true; return }
        busyCount += 1
        Task { @MainActor in
            let out = await Task.detached(priority: .userInitiated) {
                ImageFill.inpaint(cg, hole: ImageExtractor.hole(for: masks, w: w, h: h))
            }.value
            self.busyCount -= 1
            guard gen == self.generation else { return }        // the masks changed meanwhile; a newer run follows
            self.filled = out; self.filledFor = gen
            self.canvas.needsDisplay = true
        }
    }

    var showingPreview: Bool { previewBox.state == .on && filledFor == generation && filled != nil }

    // MARK: controls

    private func refreshControls() {
        let n = elements.count
        insertButton.title = n == 0 ? "Insert" : "Insert \(n) Element\(n == 1 ? "" : "s")"
        insertButton.isEnabled = n > 0
        wholeBox.isEnabled = selected != nil
        deleteButton.isEnabled = selected != nil
        clearButton.isEnabled = n > 0
        let painting = tool != .box
        brushSlider.isEnabled = painting; brushLabel.textColor = painting ? .secondaryLabelColor : .tertiaryLabelColor
        previewBox.isEnabled = fillBox.state == .on
        switch tool {
        case .box:
            hint.stringValue = "Drag a box around something to add it. Click an element to select it, ⌫ deletes it. ⇧-drag cuts out the whole box. B / K / R switch tools, ⌘Z undoes."
        case .keep:
            hint.stringValue = selected == nil ? "Paint over something to make it a new element."
                : "Paint over parts element \(selected! + 1) should include. ⌘-click another element to select it."
        case .remove:
            hint.stringValue = selected == nil ? "Paint over parts that no element should include."
                : "Paint over parts element \(selected! + 1) should leave out (they stay in the picture). ⌘-click another element to select it."
        }
    }

    func nudgeBrush(_ d: Double) {
        brushSlider.doubleValue = max(brushSlider.minValue, min(brushSlider.maxValue, brushSlider.doubleValue + d))
    }

    @objc private func toolChanged() { tool = Tool(rawValue: toolControl.selectedSegment) ?? .box }
    @objc private func brushChanged() { canvas.needsDisplay = true }
    @objc private func fillChanged() {
        if fillBox.state == .off { previewBox.state = .off }
        refreshControls(); canvas.needsDisplay = true
    }
    @objc private func previewChanged() {
        if previewBox.state == .on { computePreview() } else { canvas.needsDisplay = true }
    }

    @objc private func wholeBoxPressed() {
        guard let i = selected, let box = elements[i].region ?? elements[i].bounds else { return }
        checkpoint()
        elements[i].mask = ImageExtractor.rectangle(w: w, h: h, box: box)
        refresh(&elements[i])
        changed()
    }

    @objc private func deletePressed() { deleteSelected() }

    @objc private func clearPressed() {
        checkpoint()
        elements.removeAll(); selected = nil
        changed()
    }

    @objc private func detectPressed() {
        let cg = image
        busyCount += 1
        Task { @MainActor in
            let found = await Task.detached(priority: .userInitiated) { (try? ImageExtractor.subjects(in: cg)) ?? [] }.value
            self.busyCount -= 1
            // skip what is already an element
            let fresh = found.filter { m in !self.elements.contains { Self.overlap(m, $0.mask) > 0.5 } }
            guard !fresh.isEmpty else { NSSound.beep(); return }
            self.checkpoint()
            for m in fresh { self.elements.append(self.makeElement(mask: m, region: nil)) }
            self.selected = self.elements.count - 1
            self.changed()
        }
    }

    /// Share of the smaller shape that the two masks have in common.
    private static func overlap(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var both = 0, na = 0, nb = 0
        for i in a.indices {
            let x = a[i] > 127, y = b[i] > 127
            if x { na += 1 }; if y { nb += 1 }; if x && y { both += 1 }
        }
        return Double(both) / Double(max(1, min(na, nb)))
    }

    @objc private func cancelPressed() { close(nil) }

    @objc private func insertPressed() {
        guard !elements.isEmpty else { return }
        let fill = fillBox.state == .on
        close(Result(masks: elements.map { $0.mask }, fill: fill, filled: fill && filledFor == generation ? filled : nil))
    }
}

/// The picture, the elements' tints and boxes, and the box / brush interaction. Flipped, so y grows downwards
/// like picture pixels.
final class ExtractCanvas: NSView {
    weak var editor: ExtractEditor?
    private var dragStart: CGPoint?            // view points
    private var dragNow: CGPoint?
    private var lastPaint: CGPoint?            // picture pixels
    private var hover: CGPoint?
    private var painting = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Where the picture sits in the view.
    var pictureRect: CGRect {
        guard let e = editor else { return .zero }
        let inset = bounds.insetBy(dx: 10, dy: 10)
        let s = min(inset.width / CGFloat(e.w), inset.height / CGFloat(e.h))
        let size = CGSize(width: CGFloat(e.w) * s, height: CGFloat(e.h) * s)
        return CGRect(x: inset.midX - size.width / 2, y: inset.midY - size.height / 2, width: size.width, height: size.height)
    }
    private var scale: CGFloat { guard let e = editor, e.w > 0 else { return 1 }; return pictureRect.width / CGFloat(e.w) }

    private func toPicture(_ p: CGPoint) -> CGPoint {
        let r = pictureRect, s = scale
        return CGPoint(x: (p.x - r.minX) / s, y: (p.y - r.minY) / s)
    }
    private func toView(_ r: CGRect) -> CGRect {
        let pr = pictureRect, s = scale
        return CGRect(x: pr.minX + r.minX * s, y: pr.minY + r.minY * s, width: r.width * s, height: r.height * s)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let e = editor, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pr = pictureRect
        // checkerboard for transparent pictures
        ctx.setFillColor(NSColor(white: 0.32, alpha: 1).cgColor); ctx.fill(pr)
        ctx.setFillColor(NSColor(white: 0.40, alpha: 1).cgColor)
        let cell: CGFloat = 10
        var y = pr.minY, row = 0
        while y < pr.maxY {
            var x = pr.minX + (row % 2 == 0 ? 0 : cell)
            while x < pr.maxX { ctx.fill(CGRect(x: x, y: y, width: min(cell, pr.maxX - x), height: min(cell, pr.maxY - y))); x += 2 * cell }
            y += cell; row += 1
        }
        func drawImage(_ img: CGImage, alpha: CGFloat = 1) {
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.interpolationQuality = .high
            // the view is flipped: draw the CGImage upside up
            ctx.translateBy(x: pr.minX, y: pr.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(origin: .zero, size: pr.size))
            ctx.restoreGState()
        }
        let preview = e.showingPreview
        drawImage(preview ? e.filled! : e.image)
        for (i, el) in e.elements.enumerated() {
            if !preview, let o = el.overlay { drawImage(o, alpha: i == e.selected ? 1 : 0.55) }
            guard let b = el.bounds else { continue }
            let r = toView(b).insetBy(dx: -1, dy: -1)
            ctx.setStrokeColor(el.color.withAlphaComponent(i == e.selected ? 1 : 0.8).cgColor)
            ctx.setLineWidth(i == e.selected ? 2 : 1)
            ctx.setLineDash(phase: 0, lengths: i == e.selected ? [] : [5, 3])
            ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [])
            // number badge
            let label = "\(i + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
            let sz = label.size(withAttributes: attrs)
            let badge = CGRect(x: r.minX, y: r.minY, width: sz.width + 10, height: sz.height + 2)
            ctx.setFillColor(el.color.cgColor)
            ctx.addPath(CGPath(roundedRect: badge, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
            label.draw(at: CGPoint(x: badge.minX + 5, y: badge.minY + 1), withAttributes: attrs)
        }
        // the box being drawn
        if let a = dragStart, let b = dragNow, e.tool == .box, !painting {
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5); ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor); ctx.fill(r)
        }
        // brush outline
        if e.tool != .box, let p = hover {
            let c = e.tool == .keep ? NSColor.systemGreen : NSColor.systemRed
            let r = e.brush
            ctx.setStrokeColor(c.cgColor); ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hover = convert(event.locationInWindow, from: nil); if editor?.tool != .box { needsDisplay = true } }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard let e = editor else { return }
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p; dragNow = p
        // ⌘-click selects, whatever the tool
        if e.tool != .box && event.modifierFlags.contains(.command) {
            e.selected = e.element(at: toPicture(p)); dragStart = nil; return
        }
        if e.tool != .box {
            painting = true
            e.beginStroke()
            let q = toPicture(p)
            e.paint(from: q, to: q, radius: e.brush / scale)
            lastPaint = q
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let e = editor, dragStart != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragNow = p; hover = p
        if painting, let last = lastPaint {
            let q = toPicture(p)
            e.paint(from: last, to: q, radius: e.brush / scale)
            lastPaint = q
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let e = editor, let a = dragStart else { return }
        let b = convert(event.locationInWindow, from: nil)
        dragStart = nil; dragNow = nil
        if painting {
            painting = false; lastPaint = nil
            e.endStroke()
            return
        }
        if abs(a.x - b.x) < 4 && abs(a.y - b.y) < 4 {
            e.selected = e.element(at: toPicture(b))
        } else {
            let pa = toPicture(a), pb = toPicture(b)
            let r = CGRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y), width: abs(pa.x - pb.x), height: abs(pa.y - pb.y))
                .intersection(CGRect(x: 0, y: 0, width: e.w, height: e.h))
            if !r.isNull, r.width >= 3, r.height >= 3 { e.addRegion(r, wholeBox: event.modifierFlags.contains(.shift)) }
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard let e = editor else { return }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "\u{7f}", "\u{f728}": e.deleteSelected()
        case "b": e.tool = .box
        case "k": e.tool = .keep
        case "r": e.tool = .remove
        case "[": adjustBrush(-3)
        case "]": adjustBrush(3)
        default:
            if event.keyCode == 53 { e.selected = nil } else { super.keyDown(with: event) }
        }
        needsDisplay = true
    }

    private func adjustBrush(_ d: Double) { editor?.nudgeBrush(d) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "z" else { return super.performKeyEquivalent(with: event) }
        event.modifierFlags.contains(.shift) ? editor?.redo() : editor?.undo()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(pictureRect, cursor: editor?.tool == .box ? .crosshair : .arrow)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }
}

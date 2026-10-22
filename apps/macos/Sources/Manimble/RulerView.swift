import AppKit

/// PowerPoint-style ruler along the top (horizontal) or left (vertical) edge of the stage.
///
/// Graduated in manim units with 0 at the slide's centre (negative left/below, positive right/above, as in
/// `move_to([x, y, 0])`), it shows the slide's extent, the selection's extent, the user's guides and the
/// cursor position, and follows the canvas's zoom and pan. Drag from the ruler onto the slide to add a guide;
/// drag a guide's marker to move it.
final class RulerView: NSView {
    enum Orientation { case horizontal, vertical }
    let orientation: Orientation
    weak var canvas: CanvasView?
    /// Cursor position in frame pixels (nil = pointer not over the slide).
    var cursor: CGPoint? { didSet { needsDisplay = true } }
    static let thickness: CGFloat = 20

    private let bg = Theme.canvasBottom
    private let guideColor = Theme.dynamic(light: NSColor(srgbRed: 0.0, green: 0.55, blue: 0.75, alpha: 1),
                                           dark: NSColor(srgbRed: 0.25, green: 0.85, blue: 1.0, alpha: 1))
    private var tracking: NSTrackingArea?
    private var dragging = false

    init(_ orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = orientation == .horizontal ? "Drag down onto the slide to add a horizontal guide" : "Drag right onto the slide to add a vertical guide"
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    var horizontal: Bool { orientation == .horizontal }

    // MARK: geometry

    /// Points per manim unit at the current zoom.
    private var ptsPerUnit: CGFloat {
        guard let c = canvas else { return 90 }
        return CGFloat(c.unitPx) * c.slideRect.width / c.frameSize.width
    }

    /// Where a frame-pixel coordinate along this ruler's axis lands in the view, in points.
    private func viewPos(framePx v: Double) -> CGFloat {
        guard let c = canvas else { return 0 }
        let r = c.slideRect
        let p: CGPoint
        if horizontal { p = CGPoint(x: r.minX + CGFloat(v) * r.width / c.frameSize.width, y: r.midY) }
        else { p = CGPoint(x: r.midX, y: r.maxY - CGFloat(v) * r.height / c.frameSize.height) }
        let q = convert(p, from: c)
        return horizontal ? q.x : q.y
    }

    /// Frame-pixel coordinate (along this ruler's axis) of the slide centre, mapped into the view.
    private var centerPos: CGFloat {
        guard let c = canvas else { return 0 }
        return viewPos(framePx: Double(horizontal ? c.frameSize.width : c.frameSize.height) / 2)
    }

    /// Major step in units so labels are at least ~44 pt apart, and how many minor ticks it is divided into.
    private var step: (major: CGFloat, minor: Int) {
        let ppu = ptsPerUnit
        for s in [0.1, 0.2, 0.25, 0.5, 1, 2, 5, 10, 20] as [CGFloat] where s * ppu >= 44 {
            return (s, [0.1, 0.5, 5, 10, 20].contains(s) ? 5 : 4)
        }
        return (50, 5)
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let b = bounds
        bg.setFill(); b.fill()
        guard let c = canvas else { return }
        let length = horizontal ? b.width : b.height
        let thick = horizontal ? b.height : b.width

        // the slide's extent, a little lighter than the surroundings
        let s0 = viewPos(framePx: 0)
        let s1 = viewPos(framePx: Double(horizontal ? c.frameSize.width : c.frameSize.height))
        let slideLo = min(s0, s1), slideHi = max(s0, s1)
        Theme.ink(0.075).setFill()
        along(from: slideLo, to: slideHi, thickness: thick).fill()

        // selection extent
        if let box = c.selectedBox {
            let a = viewPos(framePx: horizontal ? box.x0 : box.y0), z = viewPos(framePx: horizontal ? box.x1 : box.y1)
            Theme.accent.withAlphaComponent(0.28).setFill()
            along(from: min(a, z), to: max(a, z), thickness: thick).fill()
        }

        // ticks and labels
        let (major, minorN) = step
        let ppu = ptsPerUnit
        let center = centerPos
        let minorStep = major / CGFloat(minorN)
        let firstUnit = floor((0 - center) / ppu / minorStep) * minorStep
        let lastUnit = ceil((length - center) / ppu / minorStep) * minorStep
        let minorColor = Theme.ink(0.28), majorColor = Theme.ink(0.6)
        let font = Theme.mono(8.5)
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.ink(0.72)]
        let decimals = major >= 1 ? 0 : (major == 0.25 ? 2 : 1)
        var u = firstUnit
        let eps = minorStep / 1000
        while u <= lastUnit + eps {
            defer { u += minorStep }
            let pos = center + u * ppu
            if pos < -1 || pos > length + 1 { continue }
            let k = Int((u / minorStep).rounded())
            let isMajor = k % minorN == 0
            let isHalf = !isMajor && minorN % 2 == 0 && k % (minorN / 2) == 0
            let len: CGFloat = isMajor ? thick : (isHalf ? thick * 0.42 : thick * 0.26)
            (isMajor ? majorColor : minorColor).setFill()
            tick(at: pos, length: len, thickness: thick).fill()
            if isMajor {
                var v = u
                if abs(v) < eps { v = 0 }
                let text = String(format: "%.\(decimals)f", Double(v))
                let size = text.size(withAttributes: labelAttrs)
                if horizontal {
                    text.draw(at: CGPoint(x: pos + 3, y: thick - size.height - 1), withAttributes: labelAttrs)
                } else {
                    // rotated so it reads bottom-to-top, as on PowerPoint's vertical ruler
                    ctx.saveGState()
                    ctx.translateBy(x: thick - size.height - 1, y: pos + 3)
                    ctx.rotate(by: .pi / 2)
                    text.draw(at: CGPoint(x: 0, y: -size.height), withAttributes: labelAttrs)
                    ctx.restoreGState()
                }
            }
        }

        // guide markers (the horizontal ruler shows vertical guides and vice versa)
        for g in c.userGuides where g.vertical == horizontal {
            let pos = viewPos(framePx: g.pos)
            let path = NSBezierPath()
            let h: CGFloat = 6
            if horizontal {
                path.move(to: CGPoint(x: pos - h / 2, y: 0)); path.line(to: CGPoint(x: pos + h / 2, y: 0)); path.line(to: CGPoint(x: pos, y: h))
            } else {
                path.move(to: CGPoint(x: thick, y: pos - h / 2)); path.line(to: CGPoint(x: thick, y: pos + h / 2)); path.line(to: CGPoint(x: thick - h, y: pos))
            }
            path.close()
            guideColor.setFill(); path.fill()
        }

        // cursor position
        if let cur = cursor {
            let pos = viewPos(framePx: Double(horizontal ? cur.x : cur.y))
            Theme.ink(0.85).setFill()
            tick(at: pos, length: thick, thickness: thick).fill()
        }

        // edge next to the canvas
        Theme.ink(0.14).setFill()
        if horizontal { NSRect(x: 0, y: 0, width: b.width, height: 1).fill() }
        else { NSRect(x: b.width - 1, y: 0, width: 1, height: b.height).fill() }
    }

    /// A band covering [lo, hi] along the ruler's axis.
    private func along(from lo: CGFloat, to hi: CGFloat, thickness: CGFloat) -> NSRect {
        horizontal ? NSRect(x: lo, y: 0, width: hi - lo, height: thickness) : NSRect(x: 0, y: lo, width: thickness, height: hi - lo)
    }

    /// A 1 pt tick rising from the canvas-side edge.
    private func tick(at pos: CGFloat, length: CGFloat, thickness: CGFloat) -> NSRect {
        let p = pos.rounded() - 0.5
        return horizontal ? NSRect(x: p, y: 0, width: 1, height: length) : NSRect(x: thickness - length, y: p, width: length, height: 1)
    }

    // MARK: guides by dragging

    /// Index of the user guide whose marker sits under a point in this view, if any.
    private func guideMarker(at p: CGPoint) -> Int? {
        guard let c = canvas else { return nil }
        let v = horizontal ? p.x : p.y
        for (i, g) in c.userGuides.enumerated() where g.vertical == horizontal && abs(viewPos(framePx: g.pos) - v) <= 5 { return i }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(tracking!)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if guideMarker(at: p) != nil { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set() }
        else { (horizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set() }
    }

    override func mouseDown(with event: NSEvent) {
        guard let c = canvas, c.frameSize.width > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let fp = c.framePoint(window: event.locationInWindow)
        if let i = guideMarker(at: p) {
            c.continueGuideDrag(index: i)
        } else {
            // the top ruler pulls down a horizontal guide; the left ruler pulls out a vertical one
            c.beginGuideDrag(vertical: !horizontal, pos: Double(horizontal ? fp.y : fp.x))
        }
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let c = canvas else { return }
        let fp = c.framePoint(window: event.locationInWindow)
        c.updateGuideDrag(pos: Double(horizontal ? fp.y : fp.x))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        canvas?.endGuideDrag()
    }
}

// MARK: - controller glue

extension MainController {
    /// Rulers on (View ▸ Ruler); remembered across launches, on by default.
    var showRuler: Bool { UserDefaults.standard.object(forKey: "showRuler") as? Bool ?? true }

    func applyRulerVisibility() {
        let on = showRuler
        for v in [hRuler, vRuler, rulerCorner] { v.isHidden = !on }
        for k in rulerThickness { k.constant = on ? RulerView.thickness : 0 }
    }

    @objc func toggleRuler() {
        UserDefaults.standard.set(!showRuler, forKey: "showRuler")
        applyRulerVisibility()
    }

    func redrawRulers() { hRuler.needsDisplay = true; vRuler.needsDisplay = true }
}

import AppKit

private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

/// An alternate view for the PYTHON card, toggled with ⌃⌥⌘T.
/// ← → move, ↑ or X rotate, Z rotates back, ↓ soft drop, space hard drop, P pause, Esc returns to the code.
final class AuxPaneView: NSView {
    private static let cols = 10, rows = 20
    private struct Kind { let cells: [(Int, Int)]; let box: Int; let color: NSColor }
    // cells in a box×box square, y down; rotating turns the square
    private static let kinds: [Kind] = [
        Kind(cells: [(0, 1), (1, 1), (2, 1), (3, 1)], box: 4, color: rgb(0.30, 0.82, 0.95)),   // I
        Kind(cells: [(0, 0), (1, 0), (0, 1), (1, 1)], box: 2, color: rgb(1.0, 0.80, 0.25)),    // O
        Kind(cells: [(1, 0), (0, 1), (1, 1), (2, 1)], box: 3, color: Theme.accent),             // T
        Kind(cells: [(1, 0), (2, 0), (0, 1), (1, 1)], box: 3, color: rgb(0.40, 0.85, 0.48)),   // S
        Kind(cells: [(0, 0), (1, 0), (1, 1), (2, 1)], box: 3, color: rgb(1.0, 0.38, 0.45)),    // Z
        Kind(cells: [(0, 0), (0, 1), (1, 1), (2, 1)], box: 3, color: rgb(0.35, 0.55, 1.0)),    // J
        Kind(cells: [(2, 0), (0, 1), (1, 1), (2, 1)], box: 3, color: Theme.warm),               // L
    ]
    private struct Piece { var kind: Int; var rot = 0; var x = 0; var y = 0 }

    private var board = [[Int?]](repeating: [Int?](repeating: nil, count: AuxPaneView.cols), count: AuxPaneView.rows)
    private var piece = Piece(kind: 0)
    private var next = 0
    private var bag: [Int] = []
    private var score = 0, lines = 0
    private var level: Int { lines / 10 + 1 }
    private var best = UserDefaults.standard.integer(forKey: "auxPaneBest")
    private var over = false
    private var paused = false
    private var timer: Timer?
    private var resignObserver: NSObjectProtocol?
    var onExit: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = rgb(0.098, 0.102, 0.125).cgColor
        newGame()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // stop on a click elsewhere or when the window goes to the background
    override func resignFirstResponder() -> Bool { pause(); return super.resignFirstResponder() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
        guard let w = window else { stop(); return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
            self?.pause()
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    // MARK: game

    private func newGame() {
        board = board.map { $0.map { _ in nil } }
        score = 0; lines = 0; over = false; paused = false; bag = []
        next = draw()
        spawn()
        schedule()
    }

    /// 7-bag: every piece once per seven, in random order.
    private func draw() -> Int {
        if bag.isEmpty { bag = Array(0..<Self.kinds.count).shuffled() }
        return bag.removeLast()
    }

    private func spawn() {
        let k = Self.kinds[next]
        piece = Piece(kind: next, x: (Self.cols - k.box) / 2, y: k.box == 4 ? -1 : 0)
        next = draw()
        if !fits(piece) { over = true; stop(); saveBest() }
    }

    private func cells(_ p: Piece) -> [(Int, Int)] {
        let k = Self.kinds[p.kind]
        return k.cells.map { c in
            var (x, y) = c
            for _ in 0..<(p.rot % 4) where k.box > 2 { (x, y) = (k.box - 1 - y, x) }
            return (x + p.x, y + p.y)
        }
    }

    private func fits(_ p: Piece) -> Bool {
        cells(p).allSatisfy { x, y in x >= 0 && x < Self.cols && y < Self.rows && (y < 0 || board[y][x] == nil) }
    }

    @discardableResult private func shift(_ dx: Int, _ dy: Int) -> Bool {
        var p = piece; p.x += dx; p.y += dy
        guard fits(p) else { return false }
        piece = p
        return true
    }

    /// Rotate, nudging sideways (then up) off a wall or stack when the turned piece doesn't fit where it is.
    private func rotate(_ dir: Int) {
        var p = piece; p.rot = (p.rot + dir + 4) % 4
        for (dx, dy) in [(0, 0), (-1, 0), (1, 0), (-2, 0), (2, 0), (0, -1)] {
            var q = p; q.x += dx; q.y += dy
            if fits(q) { piece = q; return }
        }
    }

    private func ghost() -> Piece {
        var g = piece
        while true { var q = g; q.y += 1; if fits(q) { g = q } else { return g } }
    }

    private func lock() {
        for (x, y) in cells(piece) where y >= 0 { board[y][x] = piece.kind }
        let kept = board.filter { $0.contains(where: { $0 == nil }) }
        let cleared = Self.rows - kept.count
        board = [[Int?]](repeating: [Int?](repeating: nil, count: Self.cols), count: cleared) + kept
        if cleared > 0 {
            let before = level
            score += [0, 100, 300, 500, 800][cleared] * level
            lines += cleared
            if level != before { schedule() }
        }
        spawn()
    }

    private func tick() {
        guard !over, !paused else { return }
        if !shift(0, 1) { lock() }
        needsDisplay = true
    }

    private func schedule() {
        stop()
        guard !over, !paused else { return }
        let t = Timer(timeInterval: max(0.06, 0.8 * pow(0.85, Double(level - 1))), repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func pause() {
        guard !over, !paused else { return }
        paused = true; stop(); needsDisplay = true
    }

    private func resume() {
        guard !over, paused else { return }
        paused = false; schedule(); needsDisplay = true
    }

    private func saveBest() {
        if score > best { best = score; UserDefaults.standard.set(best, forKey: "auxPaneBest") }
    }

    // MARK: input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        resume()
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 { onExit?(); return }                                  // esc
        if over { if event.keyCode == 36 || key == " " { newGame(); needsDisplay = true }; return }
        if key == "p" { paused ? resume() : pause(); return }
        if paused { resume(); return }
        switch event.keyCode {
        case 123: shift(-1, 0)
        case 124: shift(1, 0)
        case 125: if shift(0, 1) { score += 1 } else { lock() }
        case 126: rotate(1)
        case 49:
            let g = ghost()
            score += 2 * (g.y - piece.y)
            piece = g; lock()
        default:
            if key == "x" { rotate(1) } else if key == "z" { rotate(-1) } else { super.keyDown(with: event); return }
        }
        if over { saveBest() }
        needsDisplay = true
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        let pad: CGFloat = 14
        let c = floor(min((bounds.width - 3 * pad) / CGFloat(Self.cols + 6), (bounds.height - 2 * pad) / CGFloat(Self.rows)))
        guard c >= 4 else { return }
        let bw = c * CGFloat(Self.cols), bh = c * CGFloat(Self.rows), panel = c * 5
        let ox = floor((bounds.width - bw - pad - panel) / 2), oy = floor((bounds.height - bh) / 2)
        let well = NSRect(x: ox, y: oy, width: bw, height: bh)

        rgb(0.07, 0.072, 0.09).setFill()
        NSBezierPath(roundedRect: well.insetBy(dx: -3, dy: -3), xRadius: 6, yRadius: 6).fill()
        NSColor(white: 1, alpha: 0.04).setFill()
        for i in 1..<Self.cols { NSRect(x: ox + CGFloat(i) * c, y: oy, width: 1, height: bh).fill() }
        for j in 1..<Self.rows { NSRect(x: ox, y: oy + CGFloat(j) * c, width: bw, height: 1).fill() }

        func block(_ x: Int, _ y: Int, _ color: NSColor, at o: NSPoint, size s: CGFloat, ghost: Bool = false) {
            let r = NSRect(x: o.x + CGFloat(x) * s, y: o.y + CGFloat(y) * s, width: s, height: s).insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: r, xRadius: s * 0.18, yRadius: s * 0.18)
            if ghost {
                color.withAlphaComponent(0.35).setStroke(); path.lineWidth = 1.5; path.stroke()
            } else {
                color.setFill(); path.fill()
                NSColor(white: 1, alpha: 0.18).setFill()
                NSRect(x: r.minX + 2, y: r.minY + 2, width: r.width - 4, height: max(1, s * 0.12)).fill()
            }
        }
        let origin = NSPoint(x: ox, y: oy)
        for (y, row) in board.enumerated() { for (x, k) in row.enumerated() { if let k = k { block(x, y, Self.kinds[k].color, at: origin, size: c) } } }
        if !over {
            let color = Self.kinds[piece.kind].color
            for (x, y) in cells(ghost()) where y >= 0 { block(x, y, color, at: origin, size: c, ghost: true) }
            for (x, y) in cells(piece) where y >= 0 { block(x, y, color, at: origin, size: c) }
        }

        // side panel: next piece, numbers, keys
        let px = ox + bw + pad
        var y = oy
        func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, alpha: CGFloat = 0.85, mono: Bool = false) {
            let font = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : Theme.font(size, weight)
            let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(white: 1, alpha: alpha)])
            str.draw(at: NSPoint(x: px, y: y))
            y += str.size().height
        }
        let small = max(9, c * 0.42), big = max(11, c * 0.7)
        text("NEXT", small, .semibold, alpha: 0.5)
        y += c * 0.3
        let nk = Self.kinds[next], s = c * 0.8
        let nxs = nk.cells.map(\.0), nys = nk.cells.map(\.1)
        let nw = CGFloat(nxs.max()! - nxs.min()! + 1) * s
        let no = NSPoint(x: px + (panel - nw) / 2 - CGFloat(nxs.min()!) * s, y: y - CGFloat(nys.min()!) * s)
        for (x, yy) in nk.cells { block(x, yy, nk.color, at: no, size: s) }
        y += s * 2 + c
        for (label, value) in [("SCORE", score), ("LINES", lines), ("LEVEL", level), ("BEST", max(best, score))] {
            text(label, small, .semibold, alpha: 0.5)
            text("\(value)", big, .semibold, mono: true)
            y += c * 0.4
        }
        y = max(y, oy + bh - small * 1.35 * 7)
        for line in ["← →  move", "↑ X  rotate", "Z  rotate back", "↓  drop", "space  slam", "P  pause", "esc  back to code"] {
            text(line, small, alpha: 0.4)
        }

        if over || paused {
            NSColor(white: 0, alpha: 0.55).setFill()
            NSBezierPath(roundedRect: well, xRadius: 4, yRadius: 4).fill()
            let title = over ? "GAME OVER" : "PAUSED"
            let hint = over ? "return to play again" : "P or click to resume"
            let t = NSAttributedString(string: title, attributes: [.font: Theme.font(big * 1.3, .bold), .foregroundColor: NSColor.white])
            let h = NSAttributedString(string: hint, attributes: [.font: Theme.font(small), .foregroundColor: NSColor(white: 1, alpha: 0.7)])
            t.draw(at: NSPoint(x: well.midX - t.size().width / 2, y: well.midY - t.size().height))
            h.draw(at: NSPoint(x: well.midX - h.size().width / 2, y: well.midY + 4))
        }
    }
}

extension MainController {
    /// ⌃⌥⌘T in the main window: swap the PYTHON card for the alternate view, or back.
    func installPaneShortcut() {
        paneOverlayMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, e.window === self.window,
                  e.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command, .option, .control],
                  e.keyCode == 17 || e.charactersIgnoringModifiers?.lowercased() == "t" else { return e }
            self.togglePaneOverlay()
            return nil
        }
    }

    func togglePaneOverlay() {
        guard let box = sourceBox, let card = box.superview else { return }
        if let t = paneOverlay {
            t.stop(); t.removeFromSuperview(); paneOverlay = nil
            box.isHidden = false
            window.makeFirstResponder(canvas)
            return
        }
        // leaving the editor commits any draft, as clicking elsewhere does
        if window.firstResponder === sourceView { window.makeFirstResponder(canvas) }
        let t = AuxPaneView()
        t.onExit = { [weak self] in self?.togglePaneOverlay() }
        t.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(t)
        NSLayoutConstraint.activate([
            t.leadingAnchor.constraint(equalTo: card.leadingAnchor), t.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            t.topAnchor.constraint(equalTo: card.topAnchor), t.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        box.isHidden = true
        paneOverlay = t
        window.makeFirstResponder(t)
    }
}

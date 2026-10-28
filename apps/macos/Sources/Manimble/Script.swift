import AppKit
import AVFoundation

/// One action of a slide's presentation script: words to speak, a pointer move, or a pause. Steps belong to one
/// build of one slide and run in order when the show reaches that build (Play ▸ Automatic Presentation). Like
/// feedback notes they live in `script.json` beside the deck, not in the Python, so nothing renders.
struct ScriptStep: Codable, Equatable {
    enum Kind: String, Codable { case speak, move, pause }
    var id: String
    var scene: String
    var build: Int
    var kind: Kind
    var text = ""                    // speak: the words
    var seconds = 1.0                // pause
    /// move: [x, y] as fractions of the slide (y from the top). One point: go straight there from wherever the
    /// pointer is; more: a traced track, joined from the pointer's position.
    var path: [[Double]] = []
    var speed = 0.5                  // move: slide widths per second
    var noise = 0.0                  // move: 0 (steady) … 1 (a shaky hand)

    init(id: String, scene: String, build: Int, kind: Kind) {
        self.id = id; self.scene = scene; self.build = build; self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        scene = try c.decode(String.self, forKey: .scene)
        build = try c.decodeIfPresent(Int.self, forKey: .build) ?? 0
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 1
        path = try c.decodeIfPresent([[Double]].self, forKey: .path) ?? []
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 0.5
        noise = try c.decodeIfPresent(Double.self, forKey: .noise) ?? 0
    }

    var points: [CGPoint] { path.compactMap { $0.count >= 2 ? CGPoint(x: $0[0], y: $0[1]) : nil } }

    static let speeds: [(String, Double)] = [("Slow", 0.25), ("Medium", 0.5), ("Fast", 1.0), ("Very fast", 2.0)]
}

/// The deck's script, read from and written to `script.json` in the working copy (Save carries it to the
/// original, like feedback). Also holds the voice settings the whole deck shares.
@MainActor
final class ScriptStore {
    let url: URL
    private let keepEmptyFile: Bool
    private(set) var steps: [ScriptStep] = []
    /// AVSpeechSynthesisVoice identifier (nil: the system voice).
    private(set) var voice: String?
    private(set) var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    /// How long a build with no script stays up in an automatic presentation.
    private(set) var hold = 3.0
    var onChange: (() -> Void)?

    private struct File: Codable {
        var version: Int
        var voice: String?
        var rate: Float?
        var hold: Double?
        var steps: [ScriptStep]
    }

    init(url: URL, originalHasFile: Bool) {
        self.url = url
        keepEmptyFile = originalHasFile
        if let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data) {
            steps = f.steps; voice = f.voice; rate = f.rate ?? rate; hold = f.hold ?? hold
        }
    }

    private func save() {
        if steps.isEmpty && voice == nil && rate == AVSpeechUtteranceDefaultSpeechRate && hold == 3 && !keepEmptyFile {
            try? FileManager.default.removeItem(at: url)
        } else {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(File(version: 1, voice: voice, rate: rate, hold: hold, steps: steps)) {
                try? data.write(to: url, options: .atomic)
            }
        }
        onChange?()
    }

    var isEmpty: Bool { steps.isEmpty }
    func steps(scene: String, build: Int) -> [ScriptStep] { steps.filter { $0.scene == scene && $0.build == build } }
    func step(_ id: String) -> ScriptStep? { steps.first { $0.id == id } }

    /// A new step at the end of the build's script, or right after `after`.
    @discardableResult
    func add(_ kind: ScriptStep.Kind, scene: String, build: Int, after: String? = nil) -> ScriptStep {
        var s = ScriptStep(id: UUID().uuidString, scene: scene, build: build, kind: kind)
        // a new move keeps the speed and wobble of the build's last one
        if kind == .move, let last = steps(scene: scene, build: build).last(where: { $0.kind == .move }) {
            s.speed = last.speed; s.noise = last.noise
        }
        if let after, let i = steps.firstIndex(where: { $0.id == after }) { steps.insert(s, at: i + 1) }
        else if let i = steps.lastIndex(where: { $0.scene == scene && $0.build == build }) { steps.insert(s, at: i + 1) }
        else { steps.append(s) }
        save()
        return s
    }

    func update(_ id: String, _ change: (inout ScriptStep) -> Void) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        var s = steps[i]
        change(&s)
        guard s != steps[i] else { return }
        steps[i] = s
        save()
    }

    func remove(_ id: String) {
        guard steps.contains(where: { $0.id == id }) else { return }
        steps.removeAll { $0.id == id }
        save()
    }

    /// Swap a step with its neighbour in the same build's script (`by` -1: earlier, 1: later).
    func shift(_ id: String, by d: Int) {
        guard let s = step(id) else { return }
        let ids = steps(scene: s.scene, build: s.build).map(\.id)
        guard let k = ids.firstIndex(of: id), ids.indices.contains(k + d),
              let a = steps.firstIndex(where: { $0.id == id }), let b = steps.firstIndex(where: { $0.id == ids[k + d] }) else { return }
        steps.swapAt(a, b)
        save()
    }

    func removeAll() { guard !steps.isEmpty else { return }; steps = []; save() }

    func setVoice(_ v: String?) { guard v != voice else { return }; voice = v; save() }
    func setRate(_ r: Float) { guard r != rate else { return }; rate = r; save() }
    func setHold(_ h: Double) { guard h != hold else { return }; hold = h; save() }

    /// Where the pointer is before a step runs: the end of the last move before it in its build (nil: none yet).
    func pointer(before id: String) -> CGPoint? {
        guard let s = step(id) else { return nil }
        var p: CGPoint?
        for t in steps(scene: s.scene, build: s.build) {
            if t.id == id { break }
            if t.kind == .move, let last = t.points.last { p = last }
        }
        return p
    }
}

/// The pointer drawn over the slide: a classic arrow, sized from the slide's height, with its tip at the point.
final class ScriptPointer {
    let layer = CAShapeLayer()
    private var drawnFor: CGFloat = 0

    init() {
        layer.fillColor = NSColor.white.cgColor
        layer.strokeColor = NSColor.black.cgColor
        layer.lineJoin = .round
        layer.shadowColor = NSColor.black.cgColor; layer.shadowOpacity = 0.35
        layer.shadowRadius = 2; layer.shadowOffset = CGSize(width: 1, height: -1)
        layer.isHidden = true
        layer.zPosition = 100
    }

    /// Put the tip at `p` (fractions of `rect`, y from the top) in a y-up layer space; nil hides it.
    func place(_ p: CGPoint?, in rect: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let p, rect.width > 0 else { layer.isHidden = true; return }
        let h = max(14, rect.height * 0.045)
        if h != drawnFor {
            drawnFor = h
            let k = h / 20                             // the arrow is drawn in a 12 × 20 box, tip at the origin
            let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, -17), (4, -13.2), (7, -19.6), (9.4, -18.6), (6.5, -12.2), (12, -12.2)]
            let path = CGMutablePath()
            path.addLines(between: pts.map { CGPoint(x: $0.0 * k, y: $0.1 * k) })
            path.closeSubpath()
            layer.path = path
            layer.lineWidth = max(1, 1.1 * k)
        }
        layer.position = CGPoint(x: rect.minX + rect.width * p.x, y: rect.maxY - rect.height * p.y)
        layer.isHidden = false
    }
}

/// Runs steps: speaks with the system's text to speech, glides the pointer, waits. Shared by the editor (a click
/// on a step plays it) and the automatic presentation. Everything waits a frame at a time so it can be paused
/// and stopped at any moment.
@MainActor
final class ScriptPerformer: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?
    private var speaking = false
    /// A cloud voice's speech (see CloudVoice) plays from an mp3 instead of the synthesizer.
    private var player: AVAudioPlayer?
    var voice: String?
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    /// Where the pointer is (fractions of the slide), and how it is drawn (nil hides it).
    var pointer: CGPoint?
    var draw: (CGPoint?) -> Void = { _ in }
    /// The slide on screen (for the speed of a move, which counts in slide widths).
    var slideSize: () -> CGSize = { CGSize(width: 16, height: 9) }
    var paused = false {
        didSet {
            guard paused != oldValue, speaking else { return }
            if let player { if paused { player.pause() } else { player.play() }; return }
            if paused { synth.pauseSpeaking(at: .word) } else { synth.continueSpeaking() }
        }
    }
    private(set) var stopped = false
    /// Checked every frame: true ends the step at once (the presenter went to another page).
    var interrupt: () -> Bool = { false }

    override init() {
        super.init()
        synth.delegate = self
    }

    func stop() {
        stopped = true
        synth.stopSpeaking(at: .immediate)
        player?.stop(); player = nil
        speaking = false
    }

    private var halted: Bool { stopped || interrupt() }

    /// One frame (1/60 s); false once stopped or interrupted.
    private func frame() async -> Bool {
        try? await Task.sleep(nanoseconds: 16_666_667)
        return !halted
    }

    /// Wait `seconds` of unpaused time.
    func wait(_ seconds: Double) async {
        var left = seconds, last = Date()
        while left > 0 {
            guard await frame() else { return }
            let now = Date()
            if !paused { left -= now.timeIntervalSince(last) }
            last = now
        }
    }

    func perform(_ s: ScriptStep) async {
        guard !halted else { return }
        switch s.kind {
        case .pause: await wait(s.seconds)
        case .speak: await speak(s.text)
        case .move: await move(s)
        }
    }

    /// Fetch a cloud voice's speech for these steps one after another, in the background, so the show rarely
    /// waits on the service (no-op for the system voice).
    func prefetch(_ steps: [ScriptStep]) {
        guard let cloud = CloudVoice(voice) else { return }
        let r = rate
        let texts = steps.filter { $0.kind == .speak }.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        Task { @MainActor [weak self] in
            for t in texts {
                guard let self, !self.stopped else { return }
                _ = try? await cloud.audio(t, rate: r)
            }
        }
    }

    func speak(_ text: String) async {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let cloud = CloudVoice(voice) {
            // a cloud voice: fetch (or reuse) the mp3 and play it; the system voice reads it if that fails
            if let file = try? await cloud.audio(t, rate: rate), !halted, let p = try? AVAudioPlayer(contentsOf: file) {
                player = p
                if !paused { p.play() }
                while p.isPlaying || paused {
                    guard await frame() else { p.stop(); player = nil; return }
                }
                player = nil
                return
            }
            guard !halted else { return }
        }
        let u = AVSpeechUtterance(string: t)
        u.rate = rate
        if CloudVoice(voice) == nil, let v = voice.flatMap({ AVSpeechSynthesisVoice(identifier: $0) }) { u.voice = v }
        utterance = u; speaking = true
        synth.speak(u)
        if paused { synth.pauseSpeaking(at: .immediate) }
        while speaking {
            guard await frame() else { synth.stopSpeaking(at: .immediate); speaking = false; return }
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { finished(ObjectIdentifier(u)) }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { finished(ObjectIdentifier(u)) }
    nonisolated private func finished(_ id: ObjectIdentifier) {
        Task { @MainActor in if let u = self.utterance, ObjectIdentifier(u) == id { self.speaking = false } }
    }

    /// Glide along the step's track from where the pointer is, easing in and out, with the step's wobble.
    func move(_ s: ScriptStep) async {
        let target = s.points
        guard !target.isEmpty else { return }
        let start = pointer ?? CGPoint(x: 0.5, y: 0.5)
        let track = ScriptMotion(points: [start] + target, size: slideSize(), speed: s.speed, noise: s.noise, seed: s.id)
        pointer = start; draw(start)
        var t = 0.0, last = Date()
        while t < track.duration {
            guard await frame() else { break }
            let now = Date()
            if !paused { t += now.timeIntervalSince(last) }
            last = now
            pointer = track.point(at: min(t, track.duration))
            draw(pointer)
        }
        if !halted { pointer = target.last; draw(pointer) }
    }
}

/// The path of one move: a polyline in slide fractions, walked by arc length (in slide widths, so x and y count
/// the same on screen) with a sinusoidal ease, plus a smooth wobble that fades in and out.
struct ScriptMotion {
    let points: [CGPoint]
    private let lengths: [Double]          // cumulative, in slide widths
    private let aspect: Double             // height / width
    let duration: Double
    private let noise: Double
    private let phases: [Double]

    init(points: [CGPoint], size: CGSize, speed: Double, noise: Double, seed: String) {
        self.points = points
        aspect = size.width > 0 ? Double(size.height / size.width) : 9.0 / 16
        var acc = [0.0]
        for i in 1..<max(1, points.count) {
            let dx = Double(points[i].x - points[i - 1].x), dy = Double(points[i].y - points[i - 1].y) * aspect
            acc.append(acc[i - 1] + (dx * dx + dy * dy).squareRoot())
        }
        lengths = acc
        duration = (acc.last ?? 0) > 0 ? max(0.2, acc.last! / max(0.02, speed)) : 0
        self.noise = noise
        // phases from the step's id, so a move wobbles the same way every time it plays
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        var ph: [Double] = []
        for k in 0..<4 {
            let bits = Double((h >> UInt64(k * 16)) & 0xFFFF)
            ph.append(bits / 65536.0 * 2.0 * Double.pi)
        }
        phases = ph
    }

    var length: Double { lengths.last ?? 0 }

    func point(at t: Double) -> CGPoint {
        guard duration > 0, points.count > 1 else { return points.last ?? .zero }
        let u = min(1, max(0, t / duration))
        let eased = u - sin(2 * .pi * u) / (2 * .pi)          // zero speed at both ends
        let d = eased * length
        var i = 1
        while i < lengths.count - 1 && lengths[i] < d { i += 1 }
        let seg = lengths[i] - lengths[i - 1]
        let f = seg > 0 ? (d - lengths[i - 1]) / seg : 1
        var p = CGPoint(x: points[i - 1].x + (points[i].x - points[i - 1].x) * f,
                        y: points[i - 1].y + (points[i].y - points[i - 1].y) * f)
        if noise > 0 {
            let secs = t, env = sin(.pi * u)
            let amp = noise * 0.012 * env
            let nx = 0.6 * sin(2 * .pi * 1.3 * secs + phases[0]) + 0.4 * sin(2 * .pi * 3.1 * secs + phases[1])
            let ny = 0.6 * sin(2 * .pi * 1.7 * secs + phases[2]) + 0.4 * sin(2 * .pi * 2.6 * secs + phases[3])
            p.x += amp * nx
            p.y += amp * ny / aspect
        }
        return p
    }
}

// MARK: - the editor's overlay

/// Over the canvas while the Script panel is up: the build's pointer tracks (dashed, numbered; only the selected one
/// or the one being set) and the pointer when a step plays. With `capturing` set, a click on the slide sets that move's target and
/// a drag traces its track; otherwise clicks go through to the canvas.
@MainActor
final class ScriptLayer: NSView {
    var slideRect: () -> CGRect = { .zero }
    var steps: [ScriptStep] = [] { didSet { needsDisplay = true } }
    var selected: String? { didSet { needsDisplay = true } }
    var capturing: String? { didSet { window?.invalidateCursorRects(for: self); needsDisplay = true } }
    /// A track was set on the slide for the capturing step.
    var onCaptured: ((String, [CGPoint]) -> Void)?
    let pointer = ScriptPointer()
    private var trace: [CGPoint] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(pointer.layer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    func showPointer(_ p: CGPoint?) { pointer.place(p, in: slideRect()) }

    private func toView(_ p: CGPoint, _ r: CGRect) -> CGPoint { CGPoint(x: r.minX + r.width * p.x, y: r.maxY - r.height * p.y) }
    private func toSlide(_ p: CGPoint, _ r: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (p.x - r.minX) / r.width)), y: min(1, max(0, (r.maxY - p.y) / r.height)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = slideRect()
        guard r.width > 0 else { return }
        var from: CGPoint?
        var n = 0
        for s in steps where s.kind == .move {
            n += 1
            let pts = s.points
            guard let end = pts.last else { continue }
            let sel = s.id == selected
            defer { from = end }
            // a track shows only while its step is picked or being set
            guard sel || s.id == capturing else { continue }
            let c = (sel ? Theme.accent : Theme.accent.withAlphaComponent(0.6))
            let path = NSBezierPath()
            path.lineWidth = sel ? 2.5 : 1.5
            path.setLineDash([5, 4], count: 2, phase: 0)
            path.lineJoinStyle = .round; path.lineCapStyle = .round
            path.move(to: toView(from ?? pts[0], r))
            for p in pts { path.line(to: toView(p, r)) }
            c.setStroke(); path.stroke()
            // the target: a ring with the move's number
            let e = toView(end, r), rad: CGFloat = sel ? 9 : 8
            let ring = NSBezierPath(ovalIn: CGRect(x: e.x - rad, y: e.y - rad, width: 2 * rad, height: 2 * rad))
            c.setFill(); ring.fill()
            let label = NSAttributedString(string: "\(n)", attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white])
            let sz = label.size()
            label.draw(at: CGPoint(x: e.x - sz.width / 2, y: e.y - sz.height / 2))
        }
        if capturing != nil {
            Theme.accent.withAlphaComponent(0.9).setStroke()
            let frameP = NSBezierPath(rect: r.insetBy(dx: 1.5, dy: 1.5)); frameP.lineWidth = 3; frameP.stroke()
            if trace.count > 1 {
                let p = NSBezierPath(); p.lineWidth = 2.5; p.lineJoinStyle = .round
                p.move(to: toView(trace[0], r)); for q in trace.dropFirst() { p.line(to: toView(q, r)) }
                p.stroke()
            }
            let hint = NSAttributedString(string: "  Click to set where the pointer goes, or drag to trace its track  ",
                                          attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
                                                       .backgroundColor: Theme.accent.withAlphaComponent(0.9)])
            let sz = hint.size()
            hint.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.maxY - sz.height - 8))
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard capturing != nil else { return nil }
        let p = convert(point, from: superview)
        return slideRect().contains(p) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let r = slideRect()
        trace = [toSlide(convert(event.locationInWindow, from: nil), r)]
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !trace.isEmpty else { return }
        let r = slideRect()
        let p = toSlide(convert(event.locationInWindow, from: nil), r)
        if let l = trace.last, hypot((p.x - l.x) * r.width, (p.y - l.y) * r.height) >= 3 { trace.append(p); needsDisplay = true }
    }
    override func mouseUp(with event: NSEvent) {
        guard let id = capturing, let first = trace.first else { return }
        let r = slideRect()
        let span = trace.map { hypot(($0.x - first.x) * r.width, ($0.y - first.y) * r.height) }.max() ?? 0
        // a press that hardly moved sets a target; a drag keeps every point of the track
        let pts = Self.thin(span < 6 ? [first] : trace)
        trace = []
        onCaptured?(id, pts)
    }

    /// Fewer points for a traced track: drop those within a hair of the line through their neighbours.
    static func thin(_ pts: [CGPoint], tolerance: CGFloat = 0.002) -> [CGPoint] {
        guard pts.count > 2 else { return pts.map { CGPoint(x: ($0.x * 10000).rounded() / 10000, y: ($0.y * 10000).rounded() / 10000) } }
        var out = [pts[0]]
        for i in 1..<(pts.count - 1) {
            let a = out.last!, b = pts[i], c = pts[i + 1]
            let len = hypot(c.x - a.x, c.y - a.y)
            let dist = len > 0 ? abs((c.x - a.x) * (a.y - b.y) - (a.x - b.x) * (c.y - a.y)) / len : hypot(b.x - a.x, b.y - a.y)
            if dist > tolerance { out.append(b) }
        }
        out.append(pts.last!)
        return out.map { CGPoint(x: ($0.x * 10000).rounded() / 10000, y: ($0.y * 10000).rounded() / 10000) }
    }

    override func resetCursorRects() { if capturing != nil { addCursorRect(slideRect(), cursor: .crosshair) } }
}

// MARK: - automatic presentation

/// A show the automatic presentation can drive: the stills slideshow or the animated show.
@MainActor
protocol ScriptShow: AnyObject {
    var window: PlayerWindow { get }
    var onExit: (() -> Void)? { get set }
    var pageCount: Int { get }
    var pageIndex: Int { get }
    /// The scene and build of the page on screen.
    var scriptPage: (scene: String, build: Int)? { get }
    /// The page is up and still (its picture loaded, its clip played).
    var scriptPageReady: Bool { get }
    /// Where the slide is drawn in the window's content view.
    var scriptSlideRect: CGRect { get }
    func next()
    func exit()
}

extension SlidePlayer: ScriptShow {
    var scriptPage: (scene: String, build: Int)? {
        guard pages.indices.contains(index), scenes.indices.contains(pages[index].slide) else { return nil }
        return (scenes[pages[index].slide], pages[index].build)
    }
    var scriptPageReady: Bool { pages.indices.contains(index) && !pages[index].path.isEmpty }
    var scriptSlideRect: CGRect { slideRectOnScreen }
}

extension AnimatedPlayer: ScriptShow {
    var scriptPage: (scene: String, build: Int)? {
        guard let s = currentSlide else { return nil }
        return (s.scene, s.index)
    }
    var scriptPageReady: Bool { isSettled }
    var scriptSlideRect: CGRect { slideRectOnScreen }
}

/// Plays the deck by itself: on every page, the build's script (or a hold of a few seconds when it has none),
/// then on to the next page; the end of the deck ends the show. Space (or K) pauses and resumes; the arrows and
/// clicks still move through the show, and the script picks up on the page they reach.
@MainActor
final class ScriptRunner {
    private let store: ScriptStore
    private weak var show: ScriptShow?
    private let performer = ScriptPerformer()
    private let pointer = ScriptPointer()
    private let badge = CATextLayer()
    private var task: Task<Void, Never>?
    var onEnd: (() -> Void)?

    init(store: ScriptStore, show: ScriptShow) {
        self.store = store
        self.show = show
        performer.voice = store.voice
        performer.rate = store.rate
    }

    func start() {
        guard let show, let root = show.window.contentView?.layer else { return }
        root.addSublayer(pointer.layer)
        badge.string = "❚❚  Paused · space to resume"
        badge.fontSize = 14; badge.foregroundColor = NSColor.white.cgColor
        badge.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor; badge.cornerRadius = 6
        badge.alignmentMode = .center; badge.contentsScale = show.window.backingScaleFactor
        badge.frame = CGRect(x: 16, y: root.bounds.height - 44, width: 230, height: 26)
        badge.autoresizingMask = [.layerMinYMargin]
        badge.isHidden = true; badge.zPosition = 101
        root.addSublayer(badge)
        performer.draw = { [weak self] p in
            guard let self, let s = self.show else { return }
            self.pointer.place(p, in: s.scriptSlideRect)
        }
        performer.slideSize = { [weak self] in self?.show?.scriptSlideRect.size ?? CGSize(width: 16, height: 9) }
        // space pauses instead of advancing; every other key and click works as in the show
        let keys = show.window.onKey
        show.window.onKey = { [weak self] e in
            let pause = e.keyCode == 49 || e.charactersIgnoringModifiers?.lowercased() == "k"
            if pause { self?.togglePause() } else { keys?(e) }
        }
        let exit = show.onExit
        show.onExit = { [weak self] in self?.stop(); exit?() }
        performer.prefetch(store.steps)
        task = Task { @MainActor [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel(); task = nil
        performer.stop()
        pointer.layer.removeFromSuperlayer(); badge.removeFromSuperlayer()
        onEnd?(); onEnd = nil
    }

    private func togglePause() {
        performer.paused.toggle()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        badge.isHidden = !performer.paused
        CATransaction.commit()
    }

    private func sleep(_ s: Double) async { await performer.wait(s) }

    private func run() async {
        var lastScene: String?
        while !Task.isCancelled, !performer.stopped, let show {
            // the page's picture or clip first
            while !show.scriptPageReady {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if Task.isCancelled || performer.stopped { return }
            }
            let i = show.pageIndex
            guard let page = show.scriptPage else { return }
            if page.scene != lastScene { performer.draw(nil); lastScene = page.scene }     // a new slide: the pointer waits for its first move
            performer.interrupt = { [weak show] in show?.pageIndex != i }
            let steps = store.steps(scene: page.scene, build: page.build)
            if steps.isEmpty { await sleep(store.hold) }
            for s in steps {
                await performer.perform(s)
                if performer.stopped || show.pageIndex != i { break }
            }
            performer.interrupt = { false }
            if Task.isCancelled || performer.stopped { return }
            if show.pageIndex != i { continue }                      // the presenter went elsewhere: script from there
            await sleep(0.4)
            if Task.isCancelled || performer.stopped { return }
            if show.pageIndex != i { continue }
            if i >= show.pageCount - 1 { show.exit(); return }
            show.next()
            // wait for the page to change (an animated show may hold a moment)
            while show.pageIndex == i, !Task.isCancelled, !performer.stopped { try? await Task.sleep(nanoseconds: 30_000_000) }
        }
    }
}

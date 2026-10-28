import AppKit

/// Manimble's look: quiet neutral surfaces, one electric-violet accent, soft depth.
enum Theme {
    static let accent = NSColor(srgbRed: 0.486, green: 0.361, blue: 1.0, alpha: 1)          // #7C5CFF
    static let accentSoft = NSColor(srgbRed: 0.486, green: 0.361, blue: 1.0, alpha: 0.18)
    static let warm = NSColor(srgbRed: 1.0, green: 0.424, blue: 0.047, alpha: 1)             // manim-orange, used sparingly
    static let canvasTop = dynamic(light: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.972, alpha: 1),
                                   dark: NSColor(srgbRed: 0.145, green: 0.150, blue: 0.178, alpha: 1))
    /// The stage around the slide, the rulers and the drawer.
    static let canvasBottom = dynamic(light: NSColor(srgbRed: 0.918, green: 0.918, blue: 0.929, alpha: 1),
                                      dark: NSColor(srgbRed: 0.075, green: 0.078, blue: 0.098, alpha: 1))
    /// The code card and the terminals.
    static let codeBackground = dynamic(light: NSColor(srgbRed: 0.988, green: 0.988, blue: 0.992, alpha: 1),
                                        dark: NSColor(srgbRed: 0.098, green: 0.102, blue: 0.125, alpha: 1))
    /// Header strips above the code and in the drawer.
    static let barBackground = dynamic(light: NSColor(srgbRed: 0.945, green: 0.945, blue: 0.955, alpha: 1),
                                       dark: NSColor(srgbRed: 0.125, green: 0.13, blue: 0.158, alpha: 1))

    /// A colour that follows the window's light/dark appearance.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    /// Foreground ink on the dark/light chrome: white at `alpha` in dark mode, black in light mode.
    static func ink(_ alpha: CGFloat) -> NSColor { dynamic(light: NSColor(white: 0, alpha: alpha), dark: NSColor(white: 1, alpha: alpha)) }

    /// Layer colours are CGColors fixed when they are set; `apply` sets them now and again whenever light/dark changes.
    /// The view is handed back to `apply`, so the closure need not (and must not) capture it.
    static func layerColors<V: NSView>(_ view: V, _ apply: @escaping (V) -> Void) {
        AppearanceWatch.shared.add(view) { [weak view] in if let v = view { apply(v) } }
    }

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
    static func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
}

private final class AppearanceWatch {
    static let shared = AppearanceWatch()
    private struct Entry { weak var view: NSView?; let apply: () -> Void }
    private var entries: [Entry] = []
    private var observation: NSKeyValueObservation?

    func add(_ view: NSView, _ apply: @escaping () -> Void) {
        entries.removeAll { $0.view == nil }
        entries.append(Entry(view: view, apply: apply))
        view.effectiveAppearance.performAsCurrentDrawingAppearance(apply)
        if observation == nil {
            observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                // the views' own effective appearance updates after the app's
                DispatchQueue.main.async { self?.refresh() }
            }
        }
    }

    private func refresh() {
        entries.removeAll { $0.view == nil }
        for e in entries { e.view?.effectiveAppearance.performAsCurrentDrawingAppearance(e.apply) }
    }
}

/// Small uppercase section label used in the inspector.
func sectionLabel(_ s: String) -> NSTextField {
    let l = NSTextField(labelWithString: s.uppercased())
    l.font = Theme.font(10, .semibold)
    l.textColor = .tertiaryLabelColor
    return l
}

/// Field caption (sentence case, secondary).
func fieldLabel(_ s: String) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.font = Theme.font(11)
    l.textColor = .secondaryLabelColor
    return l
}

/// A thin separator line.
func hairline() -> NSView {
    let v = NSBox(); v.boxType = .separator
    return v
}

/// A thin accent progress bar. `set` fills it to a known fraction; `run` drives it on a time estimate: it reaches
/// 90% when the estimated time is up, then creeps on toward 99% while the work overruns. It never moves backwards.
final class ProgressBar: NSView {
    private let fill = CALayer()
    private(set) var running = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 1.5; layer?.masksToBounds = true
        fill.cornerRadius = 1.5; fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(fill)
        Theme.layerColors(self) { v in
            v.layer?.backgroundColor = Theme.ink(0.14).cgColor
            v.fill.backgroundColor = Theme.accent.cgColor
        }
        heightAnchor.constraint(equalToConstant: 3).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The fraction on screen right now (mid-animation included).
    var current: Double {
        guard bounds.width > 0 else { return 0 }
        return Double((fill.presentation() ?? fill).bounds.width / bounds.width)
    }

    override func layout() {
        super.layout()
        fill.position = CGPoint(x: 0, y: bounds.height / 2)
        if !running { place(current, animated: false) }
    }

    func reset() { running = false; fill.removeAllAnimations(); place(0, animated: false) }

    /// Fill to `fraction` (0…1) with a short animation.
    func set(_ fraction: Double) { running = false; place(min(max(fraction, 0), 1), animated: true) }

    /// Estimate mode: 90% in `remaining` seconds (from wherever the bar is), then ease toward 99% over `tail` seconds.
    func run(remaining: Double, tail: Double = 4) {
        let w = bounds.width, h = bounds.height
        guard w > 0 else { return }
        running = true
        let from = current
        let ahead = max(remaining, 0.05), tailTime = max(tail, 1)
        let a = CAKeyframeAnimation(keyPath: "bounds.size.width")
        if from < 0.9 {
            a.values = [from * w, 0.9 * w, 0.99 * w]
            a.keyTimes = [0, NSNumber(value: ahead / (ahead + tailTime)), 1]
            a.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeOut)]
            a.duration = ahead + tailTime
        } else {
            a.values = [from * w, 0.99 * w]
            a.timingFunctions = [CAMediaTimingFunction(name: .easeOut)]
            a.duration = tailTime
        }
        a.fillMode = .forwards; a.isRemovedOnCompletion = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.bounds = CGRect(x: 0, y: 0, width: 0.99 * w, height: h)
        fill.removeAnimation(forKey: "run")
        CATransaction.commit()
        fill.add(a, forKey: "run")
    }

    private func place(_ fraction: Double, animated: Bool) {
        fill.removeAnimation(forKey: "run")
        CATransaction.begin()
        if animated { CATransaction.setAnimationDuration(0.2) } else { CATransaction.setDisableActions(true) }
        fill.bounds = CGRect(x: 0, y: 0, width: bounds.width * CGFloat(fraction), height: bounds.height)
        CATransaction.commit()
    }
}

/// Translucent rounded "pill" used for toasts and the busy indicator (text with a progress bar beneath).
final class Pill: NSVisualEffectView {
    let label = NSTextField(labelWithString: "")
    let icon = NSImageView()
    let bar = ProgressBar()
    /// The X at the right of a spinning pill; set on the busy pill to let the user stop what is rendering.
    let cancelButton = NSButton()
    var onCancel: (() -> Void)?

    init() {
        super.init(frame: .zero)
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 15; layer?.masksToBounds = true
        label.font = Theme.font(12, .medium); label.textColor = .labelColor
        label.maximumNumberOfLines = 3; label.lineBreakMode = .byWordWrapping
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        cancelButton.isBordered = false; cancelButton.bezelStyle = .inline; cancelButton.imagePosition = .imageOnly
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")
        cancelButton.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.toolTip = "Stop rendering"
        cancelButton.setAccessibilityLabel("Stop rendering")
        cancelButton.target = self; cancelButton.action = #selector(cancelPressed)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.isHidden = true
        let row = NSStackView(views: [icon, label, cancelButton]); row.spacing = 7; row.alignment = .centerY
        bar.isHidden = true
        let column = NSStackView(views: [row, bar]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 6
        column.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 14)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor), column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor), column.bottomAnchor.constraint(equalTo: bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: row.leadingAnchor), bar.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
        isHidden = true; alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `spinning`: the pill reports work in progress and shows the bar. `progress` 0…1 fills it by count; otherwise
    /// `remaining` seconds drive it as a time estimate; with neither, a running estimate keeps going or a default
    /// (`defaultEstimate` seconds) starts. `cancellable`: a spinning pill with an `onCancel` shows the X.
    func show(_ text: String, symbol: String?, tint: NSColor?, spinning: Bool = false, progress: Double? = nil,
              remaining: Double? = nil, cancellable: Bool = true) {
        label.stringValue = text
        icon.isHidden = symbol == nil || spinning
        cancelButton.isHidden = !(spinning && cancellable && onCancel != nil)
        cancelButton.isEnabled = true
        if let s = symbol { icon.image = NSImage(systemSymbolName: s, accessibilityDescription: nil); icon.contentTintColor = tint }
        let wasHidden = isHidden || alphaValue == 0
        bar.isHidden = !spinning
        if spinning {
            if wasHidden { bar.reset() }
            layoutSubtreeIfNeeded()                          // the bar needs its width before it can animate
            if let p = progress { bar.set(p) }
            else if let r = remaining { bar.run(remaining: r) }
            else if !bar.running { bar.run(remaining: defaultEstimate) }
        }
        isHidden = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().alphaValue = 1 }
    }
    var defaultEstimate = 3.0

    @objc private func cancelPressed() {
        cancelButton.isEnabled = false                   // one request is enough; the pill goes when the job stops
        onCancel?()
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; animator().alphaValue = 0 }, completionHandler: { [weak self] in
            if self?.alphaValue == 0 { self?.isHidden = true; self?.bar.reset() }
        })
    }
}

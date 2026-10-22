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

/// Translucent rounded "pill" used for toasts and the busy indicator.
final class Pill: NSVisualEffectView {
    let label = NSTextField(labelWithString: "")
    let icon = NSImageView()
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        material = .hudWindow; blendingMode = .withinWindow; state = .active
        wantsLayer = true; layer?.cornerRadius = 15; layer?.masksToBounds = true
        label.font = Theme.font(12, .medium); label.textColor = .labelColor
        label.maximumNumberOfLines = 3; label.lineBreakMode = .byWordWrapping
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isHidden = true
        let row = NSStackView(views: [icon, spinner, label]); row.spacing = 7; row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 7, left: 12, bottom: 7, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true; alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ text: String, symbol: String?, tint: NSColor?, spinning: Bool = false) {
        label.stringValue = text
        icon.isHidden = symbol == nil || spinning
        if let s = symbol { icon.image = NSImage(systemSymbolName: s, accessibilityDescription: nil); icon.contentTintColor = tint }
        spinner.isHidden = !spinning
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        isHidden = false
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; animator().alphaValue = 1 }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; animator().alphaValue = 0 }, completionHandler: { [weak self] in
            if self?.alphaValue == 0 { self?.isHidden = true }
        })
    }
}

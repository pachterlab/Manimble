import AppKit
import AVKit

struct AnimationClip {
    let url: URL
    let kind: String
    let playbackRate: Float
}

/// Advances the build when the slide is clicked, leaving the player's control strip usable.
final class PreviewClickArea: NSView {
    var onClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) && local.y > 60 ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        addCursorRect(NSRect(x: 0, y: 60, width: bounds.width, height: max(0, bounds.height - 60)),
                      cursor: .pointingHand)
    }
}

@MainActor
final class AnimationPreviewView: NSView {
    var onClose: (() -> Void)?
    var onError: ((String) -> Void)?
    private let clips: [AnimationClip]
    private var index = 0
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var keyMonitor: Any?
    private let video = AVPlayerView()
    private let image = NSImageView()
    private let clickArea = PreviewClickArea()
    private let title = NSTextField(labelWithString: "")
    private let counter = NSTextField(labelWithString: "")
    private let previous = NSButton(title: "Previous build", target: nil, action: nil)
    private let next = NSButton(title: "Next build", target: nil, action: nil)
    private let replay = NSButton(title: "Replay", target: nil, action: nil)

    init(scene: String, clips: [AnimationClip]) {
        self.clips = clips
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        title.stringValue = scene
        title.font = .boldSystemFont(ofSize: 14)
        title.textColor = .white
        counter.textColor = .secondaryLabelColor
        image.imageScaling = .scaleProportionallyUpOrDown
        image.isHidden = true
        video.controlsStyle = .inline
        video.showsFullScreenToggleButton = false
        video.showsSharingServiceButton = false
        let close = NSButton(title: "Close", target: self, action: #selector(closePreview))
        close.bezelStyle = .rounded
        previous.target = self; previous.action = #selector(previousBuild)
        next.target = self; next.action = #selector(nextBuild)
        replay.target = self; replay.action = #selector(replayBuild)
        let header = NSStackView(views: [title, close]); header.orientation = .horizontal
        header.distribution = .fill; header.spacing = 12
        let footer = NSStackView(views: [previous, counter, next, replay]); footer.orientation = .horizontal
        footer.alignment = .centerY; footer.spacing = 12
        for view in [header, video, image, clickArea, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            header.heightAnchor.constraint(equalToConstant: 30),
            video.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            video.leadingAnchor.constraint(equalTo: leadingAnchor),
            video.trailingAnchor.constraint(equalTo: trailingAnchor),
            video.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            image.topAnchor.constraint(equalTo: video.topAnchor),
            image.leadingAnchor.constraint(equalTo: video.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: video.trailingAnchor),
            image.bottomAnchor.constraint(equalTo: video.bottomAnchor),
            clickArea.topAnchor.constraint(equalTo: video.topAnchor),
            clickArea.leadingAnchor.constraint(equalTo: video.leadingAnchor),
            clickArea.trailingAnchor.constraint(equalTo: video.trailingAnchor),
            clickArea.bottomAnchor.constraint(equalTo: video.bottomAnchor),
            footer.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            footer.centerXAnchor.constraint(equalTo: centerXAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 32),
        ])
        clickArea.onClick = { [weak self] in
            guard let self else { return }
            self.nextBuild()
            self.window?.makeFirstResponder(self)
        }
        playBuild(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        guard window != nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window,
                  let focused = self.window?.firstResponder as? NSView,
                  (focused === self || focused.isDescendant(of: self)),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            switch event.keyCode {
            case 53: self.onClose?(); return nil
            case 123: self.previousBuild(); return nil
            case 124: self.nextBuild(); return nil
            case 49: self.togglePause(); return nil
            default: return event
            }
        }
    }

    private func playBuild(_ newIndex: Int) {
        guard clips.indices.contains(newIndex) else { return }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        statusObserver = nil
        video.player?.pause()
        video.player = nil
        index = newIndex
        let clip = clips[index]
        counter.stringValue = "Build \(index + 1) of \(clips.count)"
        previous.isEnabled = index > 0
        next.isEnabled = index < clips.count - 1
        if clip.kind == "image" {
            image.image = NSImage(contentsOf: clip.url)
            if image.image == nil { onError?("Could not open animation image: \(clip.url.lastPathComponent)") }
            image.isHidden = false
            video.isHidden = true
        } else {
            image.isHidden = true
            video.isHidden = false
            let item = AVPlayerItem(url: clip.url)
            statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let message = item.error?.localizedDescription ?? "Could not play this animation clip"
                Task { @MainActor in self?.onError?(message) }
            }
            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            video.player = player
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.video.player?.currentItem === item else { return }
                    self.counter.stringValue = self.index + 1 < self.clips.count
                        ? "Build \(self.index + 1) of \(self.clips.count) · Next →"
                        : "Build \(self.clips.count) of \(self.clips.count) · End"
                }
            }
            player.playImmediately(atRate: clip.playbackRate > 0 ? clip.playbackRate : 1)
        }
    }

    @objc private func previousBuild() { playBuild(index - 1); window?.makeFirstResponder(self) }
    @objc private func nextBuild() { playBuild(index + 1); window?.makeFirstResponder(self) }
    @objc private func replayBuild() { playBuild(index); window?.makeFirstResponder(self) }
    @objc private func closePreview() { onClose?() }

    private func togglePause() {
        guard let player = video.player else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
    }

    func stop() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        statusObserver = nil
        video.player?.pause()
        video.player = nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: closePreview()
        case 123: previousBuild()
        case 124: nextBuild()
        case 49: togglePause()
        default: super.keyDown(with: event)
        }
    }
}

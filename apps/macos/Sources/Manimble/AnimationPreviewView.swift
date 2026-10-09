import AppKit
import AVKit

struct AnimationClip {
    let url: URL
    let kind: String
    let playbackRate: Float
}

@MainActor
final class AnimationPreviewView: NSView {
    var onClose: (() -> Void)?
    var onError: ((String) -> Void)?
    private let clips: [AnimationClip]
    private var index = 0
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private let video = AVPlayerView()
    private let image = NSImageView()
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
        for view in [header, video, image, footer] {
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
            footer.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            footer.centerXAnchor.constraint(equalTo: centerXAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 32),
        ])
        playBuild(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

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
            video.player = player
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.index + 1 < self.clips.count { self.playBuild(self.index + 1) }
                }
            }
            player.playImmediately(atRate: clip.playbackRate > 0 ? clip.playbackRate : 1)
        }
    }

    @objc private func previousBuild() { playBuild(index - 1) }
    @objc private func nextBuild() { playBuild(index + 1) }
    @objc private func replayBuild() { playBuild(index) }
    @objc private func closePreview() { onClose?() }

    func stop() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        statusObserver = nil
        video.player?.pause()
        video.player = nil
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: closePreview()
        case 123: previousBuild()
        case 124: nextBuild()
        case 49:
            if let player = video.player {
                if player.rate == 0 { player.play() } else { player.pause() }
            }
        default: super.keyDown(with: event)
        }
    }
}

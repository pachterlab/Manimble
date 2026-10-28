import AppKit
import AVFoundation

/// File ▸ Export To ▸ Movie with "Export with script": the movie a scripted presentation would make. Each build's
/// clip plays, then its last frame is held while the build's script runs (its words spoken, its pointer moves
/// drawn) and 0.4 s more; a build with no script is held the script's hold, as in the show. The narration is spoken
/// to files first so every hold is known, the engine encodes the movie with those holds (`export_movie`, `holds`),
/// and the narration and pointer are then laid over it with AVFoundation.
@MainActor
final class ScriptMovieExport {
    /// What happens over one build's hold, in seconds from the end of its clip.
    enum Event {
        case audio(at: Double, url: URL, length: Double)
        case move(at: Double, motion: ScriptMotion)
    }
    struct Build { var duration: Double; var events: [Event] }

    /// The pause between a build's script and the next build (ScriptRunner's).
    static let gap = 0.4

    let destination: URL
    let work: URL
    let frame: CGSize
    /// Where the slide sits in the frame (y up): clips of another shape are letterboxed.
    let slide: CGRect
    let fps: Int
    private(set) var builds: [String: [Int: Build]] = [:]
    /// The hold of a build with no script.
    let unscripted: Double

    var base: URL { work.appendingPathComponent("show.mp4") }

    /// The engine's `holds`: {slide: {build: seconds}} for the builds that have a script.
    var holds: [String: [String: Double]] {
        builds.mapValues { per in Dictionary(uniqueKeysWithValues: per.map { (String($0.key), $0.value.duration + Self.gap) }) }
    }

    private init(destination: URL, frame: CGSize, aspect: CGFloat, fps: Int, hold: Double) throws {
        self.destination = destination
        self.frame = frame
        self.fps = fps
        unscripted = hold + Self.gap
        let w = min(frame.width, frame.height * aspect), h = w / aspect
        slide = CGRect(x: (frame.width - w) / 2, y: (frame.height - h) / 2, width: w, height: h)
        work = FileManager.default.temporaryDirectory.appendingPathComponent("manimble-script-movie-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    func discard() { try? FileManager.default.removeItem(at: work) }

    /// Speak the script of these slides (in show order) to files and lay out every build's events, walking the
    /// pointer as the show does: it keeps its place from build to build (and slide to slide), and a move starts
    /// from it, or from the middle of the slide before the first.
    static func prepare(store: ScriptStore, scenes: [String], frame: CGSize, aspect: CGFloat, fps: Int, destination: URL,
                        progress: (Int, Int) -> Void) async throws -> ScriptMovieExport {
        let x = try ScriptMovieExport(destination: destination, frame: frame, aspect: aspect, fps: fps, hold: store.hold)
        do {
            let speaking = scenes.flatMap { s in store.steps.filter { $0.scene == s && $0.kind == .speak } }.count
            var spoken = 0
            var pointer: CGPoint?
            for scene in scenes {
                let mine = store.steps.filter { $0.scene == scene }
                for build in Set(mine.map(\.build)).sorted() {
                    var t = 0.0, events: [Event] = []
                    for s in mine where s.build == build {
                        switch s.kind {
                        case .pause:
                            t += s.seconds
                        case .speak:
                            spoken += 1; progress(spoken, speaking)
                            let file = x.work.appendingPathComponent("speech-\(spoken).caf")
                            if let (url, length) = try await speech(s.text, voice: store.voice, rate: store.rate, to: file), length > 0 {
                                events.append(.audio(at: t, url: url, length: length))
                                t += length
                            }
                        case .move:
                            guard !s.points.isEmpty else { continue }
                            let start = pointer ?? CGPoint(x: 0.5, y: 0.5)
                            let m = ScriptMotion(points: [start] + s.points, size: x.slide.size, speed: s.speed, noise: s.noise, seed: s.id)
                            events.append(.move(at: t, motion: m))
                            t += m.duration
                            pointer = s.points.last
                        }
                    }
                    x.builds[scene, default: [:]][build] = Build(duration: t, events: events)
                }
            }
        } catch {
            x.discard(); throw error
        }
        return x
    }

    /// The words as an audio file and its length (nil: nothing to say). A cloud voice's mp3 when it can be had,
    /// else the system voice, as the show reads them.
    private static func speech(_ text: String, voice: String?, rate: Float, to file: URL) async throws -> (URL, Double)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let cloud = CloudVoice(voice), let mp3 = try? await cloud.audio(t, rate: rate) {
            let d = try await AVURLAsset(url: mp3).load(.duration).seconds
            if d.isFinite, d > 0 { return (mp3, d) }
        }
        let u = AVSpeechUtterance(string: t)
        u.rate = rate
        if CloudVoice(voice) == nil, let v = voice.flatMap({ AVSpeechSynthesisVoice(identifier: $0) }) { u.voice = v }
        guard try await SpeechFile().write(u, to: file) else { return nil }
        let f = try AVAudioFile(forReading: file)
        return (file, Double(f.length) / f.fileFormat.sampleRate)
    }

    /// Lay the narration and the pointer over the engine's movie and write it to the destination. `segments`: the
    /// `done` event's, where each build sits in the movie.
    func finish(segments: [[String: Any]]) async throws {
        defer { discard() }
        let movie = AVURLAsset(url: base)
        guard let video = try await movie.loadTracks(withMediaType: .video).first else {
            throw CloudVoice.Failure(message: "the encoded movie has no video")
        }
        let length = try await movie.load(.duration)
        let total = length.seconds
        let comp = AVMutableComposition()
        guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CloudVoice.Failure(message: "could not make the movie's tracks")
        }
        let whole = CMTimeRange(start: .zero, duration: length)
        try vt.insertTimeRange(whole, of: video, at: .zero)

        // the pointer's keyframes, in seconds and frame points (y up); opacity 0 hides it
        var keys: [(t: Double, p: CGPoint, a: Float)] = [(0, CGPoint(x: slide.midX, y: slide.midY), 0)]
        func place(_ p: CGPoint) -> CGPoint { CGPoint(x: slide.minX + slide.width * p.x, y: slide.maxY - slide.height * p.y) }
        func jump(_ t: Double, _ p: CGPoint, _ a: Float) {
            let last = keys[keys.count - 1], at = max(t, last.t)
            keys.append((at, last.p, last.a)); keys.append((at + 0.0005, p, a))
        }
        func glide(_ t: Double, _ p: CGPoint) { keys.append((max(t, keys[keys.count - 1].t), p, 1)) }

        var lastScene: String?
        var cursor = CMTime.zero                                     // audio goes in in time order
        for seg in segments {
            guard let scene = seg["scene"] as? String, let build = seg["build"] as? Int,
                  let end = (seg["end"] as? NSNumber)?.doubleValue, let hold = (seg["hold"] as? NSNumber)?.doubleValue,
                  let start = (seg["start"] as? NSNumber)?.doubleValue else { continue }
            if scene != lastScene {                                  // a new slide: the pointer waits for its first move
                if keys[keys.count - 1].a > 0 { jump(start, keys[keys.count - 1].p, 0) }
                lastScene = scene
            }
            guard let b = builds[scene]?[build] else { continue }
            let t0 = max(start, end - hold)
            for e in b.events {
                switch e {
                case let .audio(when, url, len):
                    let asset = AVURLAsset(url: url)
                    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                    var at0 = CMTime(seconds: t0 + when, preferredTimescale: 48_000)
                    if at0 < cursor { at0 = cursor }
                    let room = total - at0.seconds
                    guard room > 0 else { continue }
                    let span = CMTimeRange(start: .zero, duration: CMTime(seconds: min(len, room), preferredTimescale: 48_000))
                    try at.insertTimeRange(span, of: track, at: at0)
                    cursor = at0 + span.duration
                case let .move(when, motion):
                    let s = t0 + when
                    jump(s, place(motion.points[0]), 1)
                    let step = 1 / Double(fps)
                    var k = step
                    while k < motion.duration { glide(s + k, place(motion.point(at: k))); k += step }
                    glide(s + motion.duration, place(motion.points[motion.points.count - 1]))
                }
            }
        }
        keys.append((max(total, keys[keys.count - 1].t), keys[keys.count - 1].p, keys[keys.count - 1].a))
        if at.segments.isEmpty { comp.removeTrack(at) }

        let size = try await video.load(.naturalSize)
        let pointer = ScriptPointer()
        pointer.place(CGPoint(x: 0.5, y: 0.5), in: slide)
        pointer.layer.opacity = 0
        let span = max(keys[keys.count - 1].t, 0.001)
        let times = keys.map { NSNumber(value: min(1, $0.t / span)) }
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = keys.map { NSValue(point: $0.p) }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = keys.map { NSNumber(value: $0.a) }
        for a in [move, fade] {
            a.keyTimes = times; a.calculationMode = .linear
            a.beginTime = AVCoreAnimationBeginTimeAtZero; a.duration = span
            a.isRemovedOnCompletion = false; a.fillMode = .both
        }
        pointer.layer.add(move, forKey: "move"); pointer.layer.add(fade, forKey: "fade")
        let parent = CALayer(), videoLayer = CALayer()
        parent.frame = CGRect(origin: .zero, size: size); videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer); parent.addSublayer(pointer.layer)

        let vc = AVMutableVideoComposition()
        vc.renderSize = size
        vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = whole
        instruction.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: vt)]
        vc.instructions = [instruction]
        vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)

        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw CloudVoice.Failure(message: "could not start writing the movie")
        }
        let out = work.appendingPathComponent("scripted.mp4")
        session.outputURL = out
        session.outputFileType = .mp4
        session.videoComposition = vc
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        guard session.status == .completed else {
            throw CloudVoice.Failure(message: session.error?.localizedDescription ?? "the movie could not be written")
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: out)
        } else {
            try FileManager.default.moveItem(at: out, to: destination)
        }
    }
}

/// The system voice's reading of an utterance, written to an audio file instead of played.
private final class SpeechFile: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var done: CheckedContinuation<Bool, Error>?

    /// True once something was written; false when the voice said nothing.
    func write(_ u: AVSpeechUtterance, to url: URL) async throws -> Bool {
        synth.delegate = self
        return try await withCheckedThrowingContinuation { c in
            lock.lock(); done = c; lock.unlock()
            synth.write(u) { [self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 { end(nil); return }
                do {
                    lock.lock(); defer { lock.unlock() }
                    if file == nil {
                        file = try AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                               commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
                    }
                    try file?.write(from: pcm)
                } catch {
                    end(error)
                }
            }
        }
    }

    private func end(_ error: Error?) {
        lock.lock()
        let c = done; done = nil
        let wrote = file != nil
        file = nil                                   // closes it
        lock.unlock()
        if let error { c?.resume(throwing: error) } else { c?.resume(returning: wrote) }
    }

    // some voices finish without the empty last buffer
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in end(nil) }
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { end(nil) }
}

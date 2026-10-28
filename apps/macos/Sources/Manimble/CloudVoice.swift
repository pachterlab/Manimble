import AppKit
import AVFoundation
import CryptoKit
import Security

/// Text-to-speech services that need an account. Their voices sit in the Script panel's voice menu beside the
/// system's, marked with a sparkle; a script voice for one of them is stored as `cloud:<service>:<voice>` in
/// `script.json`. The account's API key lives in the login keychain, never in the deck.
enum CloudVoiceService: String, CaseIterable {
    case elevenlabs, openai

    var name: String { self == .elevenlabs ? "ElevenLabs" : "OpenAI" }
    /// Where to make a key.
    var keyPage: URL {
        URL(string: self == .elevenlabs ? "https://elevenlabs.io/app/settings/api-keys" : "https://platform.openai.com/api-keys")!
    }

    /// The voices offered before the account is connected (ElevenLabs lists the account's own voices once it is).
    var builtinVoices: [(id: String, name: String)] {
        switch self {
        case .elevenlabs:
            return [("21m00Tcm4TlvDq8ikWAM", "Rachel"), ("pNInz6obpgDQGcFmaJgB", "Adam"), ("EXAVITQu4vr4xnSDxMaL", "Sarah"),
                    ("ErXwobaYiN019PkySvjV", "Antoni"), ("TxGEqnHWrfWFTfGW9XjX", "Josh"), ("XrExE9yKIg1WjnnlVkGX", "Matilda")]
        case .openai:
            return ["alloy", "ash", "coral", "echo", "fable", "nova", "onyx", "sage", "shimmer"].map { ($0, $0.capitalized) }
        }
    }

    // MARK: key

    private static let keychainService = "org.pachterlab.Manimble.voice"

    var apiKey: String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    var connected: Bool { apiKey?.isEmpty == false }

    func setKey(_ key: String?) {
        SecItemDelete(baseQuery as CFDictionary)
        if let key, !key.isEmpty {
            var q = baseQuery
            q[kSecValueData as String] = Data(key.utf8)
            SecItemAdd(q as CFDictionary, nil)
        }
        UserDefaults.standard.removeObject(forKey: voicesDefaultsKey)
        NotificationCenter.default.post(name: CloudVoice.accountsChanged, object: nil)
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.keychainService, kSecAttrAccount as String: rawValue]
    }

    // MARK: voices of the account

    private var voicesDefaultsKey: String { "cloudVoices.\(rawValue)" }

    /// The account's voices from the last fetch (ElevenLabs), else the built-in list.
    var voices: [(id: String, name: String)] {
        if let saved = UserDefaults.standard.array(forKey: voicesDefaultsKey) as? [[String]], !saved.isEmpty {
            return saved.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
        }
        return builtinVoices
    }

    /// Fetch the account's voice list (ElevenLabs only; OpenAI's voices are fixed). Throws when the key is refused.
    func refreshVoices() async throws {
        guard self == .elevenlabs, let key = apiKey else { return }
        var r = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        r.setValue(key, forHTTPHeaderField: "xi-api-key")
        let (data, resp) = try await URLSession.shared.data(for: r)
        try CloudVoice.check(resp, data)
        struct List: Decodable { struct V: Decodable { let voice_id: String; let name: String }; let voices: [V] }
        let list = try JSONDecoder().decode(List.self, from: data)
        let rows = list.voices.map { [$0.voice_id, $0.name] }.sorted { $0[1] < $1[1] }
        if !rows.isEmpty { UserDefaults.standard.set(rows, forKey: voicesDefaultsKey) }
        NotificationCenter.default.post(name: CloudVoice.accountsChanged, object: nil)
    }

    /// Check a key with a cheap call before keeping it.
    func verify(_ key: String) async throws {
        var r: URLRequest
        switch self {
        case .elevenlabs:
            r = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
            r.setValue(key, forHTTPHeaderField: "xi-api-key")
        case .openai:
            r = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await URLSession.shared.data(for: r)
        try CloudVoice.check(resp, data)
    }
}

/// A script voice read from its stored identifier.
struct CloudVoice {
    static let accountsChanged = Notification.Name("ManimbleCloudVoiceAccountsChanged")
    let service: CloudVoiceService
    let voice: String

    init?(_ identifier: String?) {
        guard let parts = identifier?.split(separator: ":", maxSplits: 2), parts.count == 3, parts[0] == "cloud",
              let s = CloudVoiceService(rawValue: String(parts[1])) else { return nil }
        service = s; voice = String(parts[2])
    }
    init(service: CloudVoiceService, voice: String) { self.service = service; self.voice = voice }

    var identifier: String { "cloud:\(service.rawValue):\(voice)" }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
        throw Failure(message: http.statusCode == 401 ? "The key was refused (401)." : "HTTP \(http.statusCode): \(body)")
    }

    /// The service's speed for the script's rate (AVSpeech's 0.3…0.7, 0.5 normal).
    private func speed(_ rate: Float) -> Double {
        let s = Double(rate / AVSpeechUtteranceDefaultSpeechRate)
        return service == .elevenlabs ? min(1.2, max(0.7, s)) : min(4, max(0.25, s))
    }

    private static let cacheDir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Manimble/voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private func cacheFile(_ text: String, _ rate: Float) -> URL {
        let key = "\(identifier)|\(String(format: "%.3f", speed(rate)))|\(text)"
        let h = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self.cacheDir.appendingPathComponent("\(h).mp3")
    }

    /// The spoken words as an mp3, from the cache when they were made before (so a show replays without
    /// calling the service, or paying for it, again).
    @MainActor
    func audio(_ text: String, rate: Float) async throws -> URL {
        let file = cacheFile(text, rate)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        // one request per text, however many callers (the show's prefetch and the step itself) ask at once
        if let t = Self.inFlight[file] { return try await t.value }
        let t = Task { @MainActor in try await fetch(text, rate: rate, to: file) }
        Self.inFlight[file] = t
        defer { Self.inFlight[file] = nil }
        return try await t.value
    }

    @MainActor private static var inFlight: [URL: Task<URL, Error>] = [:]

    private func fetch(_ text: String, rate: Float, to file: URL) async throws -> URL {
        guard let key = service.apiKey, !key.isEmpty else { throw Failure(message: "\(service.name) is not connected.") }
        var r: URLRequest
        var body: [String: Any]
        switch service {
        case .elevenlabs:
            r = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)?output_format=mp3_44100_128")!)
            r.setValue(key, forHTTPHeaderField: "xi-api-key")
            body = ["text": text, "model_id": "eleven_multilingual_v2", "voice_settings": ["speed": speed(rate)]]
        case .openai:
            r = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = ["model": "tts-1-hd", "voice": voice, "input": text, "speed": speed(rate), "response_format": "mp3"]
        }
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        r.timeoutInterval = 60
        let (data, resp) = try await URLSession.shared.data(for: r)
        try Self.check(resp, data)
        try data.write(to: file, options: .atomic)
        return file
    }
}

/// The sheet that connects an account: paste an API key (with a link to where to make one), checked before it
/// is kept; or disconnect.
@MainActor
enum CloudVoiceAccount {
    static func connect(_ service: CloudVoiceService, from window: NSWindow?, done: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = service.connected ? "\(service.name) is connected" : "Connect \(service.name)"
        a.informativeText = "Paste an API key from your \(service.name) account. It is kept in your login keychain, and the "
            + "words of the script are sent to \(service.name) to be spoken (billed to that account). Speech is cached, so a "
            + "show replays without calling it again."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        field.placeholderString = service.connected ? "Paste a new key to replace it" : "API key"
        let link = NSButton(title: "Get a key at \(service.keyPage.host ?? "")…", target: nil, action: nil)
        link.bezelStyle = .inline; link.isBordered = false; link.contentTintColor = .linkColor; link.font = Theme.font(11)
        let opener = LinkTarget(service.keyPage); link.target = opener; link.action = #selector(LinkTarget.open)
        let stack = NSStackView(views: [field, link])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 50)
        a.accessoryView = stack
        a.addButton(withTitle: "Connect")
        a.addButton(withTitle: "Cancel")
        if service.connected { a.addButton(withTitle: "Disconnect") }
        a.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { r in
            _ = opener
            switch r {
            case .alertFirstButtonReturn:
                let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { done(service.connected); return }
                Task { @MainActor in
                    do {
                        try await service.verify(key)
                        service.setKey(key)
                        try? await service.refreshVoices()
                        done(true)
                    } catch {
                        let e = NSAlert()
                        e.messageText = "\(service.name) did not accept the key"
                        e.informativeText = error.localizedDescription
                        e.runModal()
                        done(service.connected)
                    }
                }
            case .alertThirdButtonReturn:
                service.setKey(nil); done(false)
            default: done(service.connected)
            }
        }
        if let window { a.beginSheetModal(for: window, completionHandler: finish) } else { finish(a.runModal()) }
    }

    private final class LinkTarget: NSObject {
        let url: URL
        init(_ url: URL) { self.url = url }
        @objc func open() { NSWorkspace.shared.open(url) }
    }
}

import AVFoundation
import NaturalLanguage
import PhononTTS

enum Voices {
    struct Voice {
        let name: String
        let identifier: String
        let languages: [String]

        var providerVoice: AVSpeechSynthesisProviderVoice {
            let v = AVSpeechSynthesisProviderVoice(
                name: name, identifier: identifier, primaryLanguages: languages, supportedLanguages: languages)
            v.gender = .female
            v.version = "1.0"
            return v
        }
    }

    static let auto = Voice(
        name: "Phonon", identifier: "com.mauriciabad.phonon.auto",
        languages: ["en-US", "es-ES", "ca-ES", "fr-FR", "de-DE", "pt-BR"])
    static let all = [auto]

    /// How each detected language is spoken: Phonon's text normalization and the bundled voice,
    /// as `voices.json` lists them. Languages missing there go to an Apple voice.
    static let phonon: [NLLanguage: (Language, String)] = {
        struct Entry: Decodable { let name: String }
        guard let url = Bundle.main.url(forResource: "voices", withExtension: "json"),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: url))
        else { return [.english: (.english, "default")] }
        var map: [NLLanguage: (Language, String)] = [:]
        for (code, entry) in entries {
            if let language = Language(rawValue: code), language != .none {
                map[NLLanguage(code)] = (language, entry.name)
            }
        }
        return map
    }()
}

actor Engine {
    static let shared = Engine()

    private var loading: Task<Phonon, Error>?

    private func tts() async throws -> Phonon {
        if let loading { return try await loading.value }
        let task = Task {
            guard let bundled = Bundle.main.url(forResource: "Models", withExtension: nil) else {
                throw PhononError(description: "the extension has no Models folder")
            }
            let dir = try PhononModels.install(bundled: bundled)
            return try await Phonon.load(models: dir, language: .english)
        }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil
            throw error
        }
    }

    func warmUp() async throws {
        _ = try await tts()
    }

    /// Speak `text`, paragraph by paragraph, each in the voice for its language.
    func speak(_ text: String, voice: String, onAudio: @escaping @Sendable ([Float]) -> Void) async throws {
        for (language, part) in Self.split(text) {
            try Task.checkCancellation()
            if let (normalization, name) = Voices.phonon[language] {
                let tts = try await tts()
                if tts.language != normalization { try await tts.setLanguage(normalization) }
                if tts.voice != name, tts.voices.contains(name) { try await tts.setVoice(name) }
                try await tts.speak(part, onAudio: onAudio)
            } else {
                do {
                    try await AppleVoice.speak(part, language: language, onAudio: onAudio)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The closest Phonon voice beats silence.
                    NSLog("PhononVoice: Apple voice for %@ failed (%@), using Spanish", language.rawValue, String(describing: error))
                    let tts = try await tts()
                    if tts.language != .spanish { try await tts.setLanguage(.spanish) }
                    if tts.voice != "Nerea" { try await tts.setVoice("Nerea") }
                    try await tts.speak(part, onAudio: onAudio)
                }
            }
        }
    }

    /// The text as runs of paragraphs in one language. Short paragraphs, which detect poorly,
    /// take the language of the whole text.
    static func split(_ text: String) -> [(NLLanguage, String)] {
        let whole = detect(text)
        var runs: [(NLLanguage, String)] = []
        for paragraph in text.components(separatedBy: .newlines) {
            let p = paragraph.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            let language = p.count >= 40 ? detect(p) : whole
            if let last = runs.last, last.0 == language {
                runs[runs.count - 1].1 += "\n" + p
            } else {
                runs.append((language, p))
            }
        }
        return runs
    }

    static func detect(_ text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .spanish, .catalan, .french, .german, .portuguese]
        recognizer.processString(text)
        return recognizer.dominantLanguage ?? .english
    }
}

/// Languages Phonon has no model for (Catalan), read by the Mac's own voice for that language
/// and resampled to Phonon's format so they come out of the same audio unit.
enum AppleVoice {
    static func speak(_ text: String, language: NLLanguage, onAudio: @escaping @Sendable ([Float]) -> Void) async throws {
        let voice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language.rawValue) && !$0.identifier.hasPrefix("com.mauriciabad.") }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let synthesizer = AVSpeechSynthesizer()
        let target = AVAudioFormat(standardFormatWithSampleRate: Phonon.sampleRate, channels: 1)!
        let state = WriteState()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.continuation = continuation
                synthesizer.write(utterance) { buffer in
                    guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                        state.resume()
                        return
                    }
                    state.started = true
                    if let samples = state.convert(pcm, to: target) { onAudio(samples) }
                }
                // A voice that fails to load never calls back at all.
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    guard !state.started else { return }
                    synthesizer.stopSpeaking(at: .immediate)
                    state.resume(throwing: PhononError(description: "no audio from \(voice?.identifier ?? "the default voice")"))
                }
            }
        } onCancel: {
            synthesizer.stopSpeaking(at: .immediate)
            state.resume(throwing: CancellationError())
        }
    }

    private final class WriteState: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<Void, Error>?
        var started: Bool {
            get { lock.withLock { _started } }
            set { lock.withLock { _started = newValue } }
        }
        private var _started = false
        private var converter: AVAudioConverter?

        func resume(throwing error: Error? = nil) {
            lock.withLock {
                if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
                continuation = nil
            }
        }

        func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) -> [Float]? {
            if converter?.inputFormat != input.format {
                converter = AVAudioConverter(from: input.format, to: format)
            }
            guard let converter else { return nil }
            let ratio = format.sampleRate / input.format.sampleRate
            let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
            var given = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return input
            }
            guard error == nil, let data = out.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
        }
    }
}

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

    /// Speak a request sentence by sentence, each in the voice for its paragraph's language, at
    /// the requested speed. Before each sentence it reports a sentence marker, and after it word
    /// markers spread over the sentence's audio by word length (Phonon gives no word timings).
    func speak(
        _ speech: SSML.Speech,
        audio: @escaping @Sendable ([Float]) -> Void,
        markers: @escaping @Sendable ([AVSpeechSynthesisMarker]) -> Void
    ) async throws {
        let sink = try AudioSink(rate: speech.rate, audio: audio)
        let text = speech.text as NSString
        for sentence in Self.sentences(in: speech.text) {
            try Task.checkCancellation()
            let start = sink.position
            var first = [AVSpeechSynthesisMarker(
                markerType: .sentence, forTextRange: speech.ssmlRange(sentence.range),
                atByteSampleOffset: sink.byteOffset(start))]
            if sentence.startsParagraph {
                first.insert(AVSpeechSynthesisMarker(
                    markerType: .paragraph, forTextRange: speech.ssmlRange(sentence.paragraph),
                    atByteSampleOffset: sink.byteOffset(start)), at: 0)
            }
            markers(first)

            try await say(text.substring(with: sentence.range), in: sentence.language, to: sink)

            let words = Self.words(in: text.substring(with: sentence.range), at: sentence.range.location)
            let total = Double(words.reduce(0) { $0 + $1.length + 1 })
            var done = 0.0
            let length = Double(sink.position - start)
            markers(words.map { word in
                defer { done += Double(word.length + 1) }
                return AVSpeechSynthesisMarker(
                    markerType: .word, forTextRange: speech.ssmlRange(word),
                    atByteSampleOffset: sink.byteOffset(start + Int(length * done / max(total, 1))))
            })
        }
        sink.finish()
    }

    private func say(_ text: String, in language: NLLanguage, to sink: AudioSink) async throws {
        if let (normalization, name) = Voices.phonon[language] {
            try await phonon(text, normalization, name, to: sink)
            return
        }
        do {
            try await AppleVoice.speak(text, language: language, onAudio: sink.write)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The closest Phonon voice beats silence.
            NSLog("PhononVoice: Apple voice for %@ failed (%@), using Spanish", language.rawValue, String(describing: error))
            try await phonon(text, .spanish, Voices.phonon[.spanish]?.1 ?? "default", to: sink)
        }
    }

    private func phonon(_ text: String, _ normalization: Language, _ name: String, to sink: AudioSink) async throws {
        let tts = try await tts()
        if tts.language != normalization { try await tts.setLanguage(normalization) }
        if tts.voice != name, tts.voices.contains(name) { try await tts.setVoice(name) }
        try await tts.speak(text, onAudio: sink.write)
    }

    struct Sentence {
        let range: NSRange
        let paragraph: NSRange
        let language: NLLanguage
        let startsParagraph: Bool
    }

    /// The sentences of `text`, with the language of their paragraph. Short paragraphs, which
    /// detect poorly, take the language of the whole text.
    static func sentences(in text: String) -> [Sentence] {
        let ns = text as NSString
        let whole = detect(text)
        var result: [Sentence] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { paragraph, range, _, _ in
            guard let paragraph, !paragraph.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let language = paragraph.count >= 40 ? detect(paragraph) : whole
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = paragraph
            var first = true
            tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { r, _ in
                if !paragraph[r].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let local = NSRange(r, in: paragraph)
                    result.append(Sentence(
                        range: NSRange(location: range.location + local.location, length: local.length),
                        paragraph: range, language: language, startsParagraph: first))
                    first = false
                }
                return true
            }
        }
        return result
    }

    /// The words of `sentence`, as ranges in the whole text (`sentence` starts at `offset`).
    static func words(in sentence: String, at offset: Int) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = sentence
        return tokenizer.tokens(for: sentence.startIndex..<sentence.endIndex).map {
            let r = NSRange($0, in: sentence)
            return NSRange(location: offset + r.location, length: r.length)
        }
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

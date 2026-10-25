import AVFoundation
import PhononTTS

/// The system voice. macOS hands it one request at a time as SSML and pulls the audio through
/// the render block, offline and as fast as it can, so the render block waits for generation
/// instead of padding with silence. Sentence and word markers tell macOS where each part of the
/// text is in the audio, which its skip buttons and highlighting rely on.
final class PhononAudioUnit: AVSpeechSynthesisProviderAudioUnit {
    private let format = AVAudioFormat(standardFormatWithSampleRate: Phonon.sampleRate, channels: 1)!
    private var busses: AUAudioUnitBusArray!
    private let output = SampleQueue()
    private var task: Task<Void, Never>?

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        busses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
        // Load (and on first use compile) the models now, so the first request does not wait as long.
        Task.detached { try? await Engine.shared.warmUp() }
    }

    override var outputBusses: AUAudioUnitBusArray { busses }

    override var speechVoices: [AVSpeechSynthesisProviderVoice] {
        get { Voices.all.map(\.providerVoice) }
        set {}
    }

    override func synthesizeSpeechRequest(_ request: AVSpeechSynthesisProviderRequest) {
        task?.cancel()
        let generation = output.start()
        let speech = SSML.parse(request.ssmlRepresentation)
        let output = output
        let report = speechSynthesisOutputMetadataBlock
        task = Task.detached {
            do {
                try await Engine.shared.speak(
                    speech,
                    audio: { output.append($0, generation: generation) },
                    markers: { report?($0, request) })
            } catch {
                NSLog("PhononVoice: %@", String(describing: error))
            }
            output.finish(generation: generation)
        }
    }

    override func cancelSpeechRequest() {
        task?.cancel()
        output.cancel()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let output = output
        return { actionFlags, _, frameCount, _, bufferList, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let frames = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let count = Int(frameCount)
            let (written, done) = output.read(into: frames, count: count)
            if written < count { (frames + written).update(repeating: 0, count: count - written) }
            buffers[0].mDataByteSize = UInt32(count * MemoryLayout<Float>.size)
            if done { actionFlags.pointee = .offlineUnitRenderAction_Complete }
            return noErr
        }
    }
}

/// Samples between the generating task and the render block.
final class SampleQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var samples: [Float] = []
    private var head = 0
    private var finished = true
    private var generation = 0

    /// Begin a new utterance, dropping whatever the last one left. Returns its generation, so
    /// a cancelled task's late chunks are ignored.
    func start() -> Int {
        condition.withLock {
            generation += 1
            samples.removeAll(keepingCapacity: true)
            head = 0
            finished = false
            return generation
        }
    }

    func append(_ chunk: [Float], generation g: Int) {
        condition.withLock {
            guard g == generation, !finished else { return }
            samples += chunk
            condition.broadcast()
        }
    }

    func finish(generation g: Int) {
        condition.withLock {
            guard g == generation else { return }
            finished = true
            condition.broadcast()
        }
    }

    func cancel() {
        condition.withLock {
            generation += 1
            samples.removeAll(keepingCapacity: true)
            head = 0
            finished = true
            condition.broadcast()
        }
    }

    /// Copy up to `count` samples, waiting until that many are ready or the utterance has ended.
    /// Returns how many were written and whether the utterance is now fully read.
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> (Int, Bool) {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 60)
        while !finished, samples.count - head < count, condition.wait(until: deadline) {}
        let n = min(count, samples.count - head)
        samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress! + head, count: n) }
        head += n
        if head > 1 << 16, head * 2 > samples.count {
            samples.removeFirst(head)
            head = 0
        }
        return (n, finished && head == samples.count)
    }
}

enum SSML {
    /// What a request asks to say: its text without tags and with entities decoded, where each
    /// UTF-16 unit of that text came from in the SSML (markers point into the SSML), and the speed.
    struct Speech: Sendable {
        var text = ""
        var rate = 1.0
        fileprivate var starts: [Int] = []
        fileprivate var ends: [Int] = []

        /// The SSML range a range of `text` came from.
        func ssmlRange(_ range: NSRange) -> NSRange {
            guard range.length > 0, range.location < starts.count else { return NSRange(location: 0, length: 0) }
            let start = starts[range.location]
            let end = ends[min(range.location + range.length, ends.count) - 1]
            return NSRange(location: start, length: end - start)
        }
    }

    static func parse(_ ssml: String) -> Speech {
        let u = Array(ssml.utf16)
        var speech = Speech()
        var text: [UInt16] = []
        func add(_ s: String, from start: Int, to end: Int) {
            for unit in s.utf16 {
                text.append(unit)
                speech.starts.append(start)
                speech.ends.append(end)
            }
        }
        var i = 0
        while i < u.count {
            switch u[i] {
            case 0x3C: // <
                let end = u[i...].firstIndex(of: 0x3E) ?? u.count - 1
                let tag = String(decoding: u[i...end], as: UTF16.self)
                if tag.hasPrefix("<break") { add(" ", from: i, to: end + 1) }
                if tag.hasPrefix("<prosody"), speech.rate == 1, let rate = rate(tag) { speech.rate = rate }
                i = end + 1
            case 0x26: // &
                if let end = u[i...].prefix(10).firstIndex(of: 0x3B) {
                    let entity = String(decoding: u[i...end], as: UTF16.self)
                    let names = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&amp;": "&"]
                    if let char = names[entity] ?? numeric(entity) {
                        add(char, from: i, to: end + 1)
                        i = end + 1
                        continue
                    }
                }
                add("&", from: i, to: i + 1)
                i += 1
            default:
                text.append(u[i])
                speech.starts.append(i)
                speech.ends.append(i + 1)
                i += 1
            }
        }
        speech.text = String(decoding: text, as: UTF16.self)
        return speech
    }

    private static func numeric(_ entity: String) -> String? {
        guard entity.hasPrefix("&#") else { return nil }
        let body = entity.dropFirst(2).dropLast()
        let value = body.hasPrefix("x") ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
        return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }

    /// The speed multiplier for a `<prosody rate="…">` tag. macOS sends percentages that grow
    /// with the square of the speed it means: its "2×" button sends 400%, the slowest setting 12.5%.
    private static func rate(_ tag: String) -> Double? {
        guard let open = tag.range(of: "rate=\""),
              let close = tag[open.upperBound...].firstIndex(of: "\"")
        else { return nil }
        let value = tag[open.upperBound..<close].trimmingCharacters(in: .whitespaces)
        let named = ["x-slow": 0.5, "slow": 0.75, "medium": 1, "default": 1, "fast": 1.5, "x-fast": 2]
        let speed: Double?
        if let n = named[value] {
            speed = n
        } else if value.hasSuffix("%"), let percent = Double(value.dropLast()) {
            speed = (percent / 100).squareRoot()
        } else {
            speed = Double(value)
        }
        return speed.map { min(max($0, 0.25), 4) }
    }
}

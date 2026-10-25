import AVFoundation
import PhononTTS

/// The system voice. macOS hands it one request at a time as SSML and pulls the audio through
/// the render block, offline and as fast as it can, so the render block waits for generation
/// instead of padding with silence.
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
        let text = SSML.plainText(request.ssmlRepresentation)
        let voice = request.voice.identifier
        let output = output
        task = Task.detached {
            do {
                try await Engine.shared.speak(text, voice: voice) { output.append($0, generation: generation) }
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
    /// The text inside the SSML macOS sends, without tags and with entities decoded.
    static func plainText(_ ssml: String) -> String {
        var text = ssml.replacingOccurrences(of: "<break[^>]*>", with: ". ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&amp;": "&"] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

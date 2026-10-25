import AVFoundation
import PhononTTS

/// Where one request's audio goes: through a time stretcher when macOS asks for another speed,
/// then on to the render queue. Positions are counted in samples as generated, before stretching,
/// and converted to the byte offsets markers use.
final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private let stretcher: Stretcher?
    private let audio: @Sendable ([Float]) -> Void
    private let rate: Double
    private var generated = 0

    init(rate: Double, audio: @escaping @Sendable ([Float]) -> Void) throws {
        self.rate = rate
        self.audio = audio
        stretcher = abs(rate - 1) < 0.01 ? nil : try Stretcher(rate: rate)
    }

    /// Samples generated so far.
    var position: Int { lock.withLock { generated } }

    /// Where the audio generated up to `position` ends up in the output, in bytes of Float32 mono.
    func byteOffset(_ position: Int) -> Int {
        Int(Double(position) / rate) * MemoryLayout<Float>.size
    }

    @Sendable func write(_ samples: [Float]) {
        lock.withLock {
            generated += samples.count
            let out = stretcher?.process(samples) ?? samples
            if !out.isEmpty { audio(out) }
        }
    }

    func finish() {
        lock.withLock {
            if let out = stretcher?.flush(), !out.isEmpty { audio(out) }
        }
    }
}

/// Changes the speed of a stream of samples without changing its pitch, with Apple's time-pitch
/// unit in an offline engine. It only renders output its input already covers: rendering past
/// that would make the player insert silence.
final class Stretcher {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Phonon.sampleRate, channels: 1)!
    private let buffer: AVAudioPCMBuffer
    private let rate: Double
    private let latency: Int
    private var scheduled = 0
    private var rendered = 0
    private var skip: Int

    init(rate: Double) throws {
        self.rate = rate
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        timePitch.rate = Float(rate)
        try engine.start()
        player.play()
        buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        latency = Int((timePitch.latency + timePitch.outputPresentationLatency) * format.sampleRate)
        // The unit's own delay comes out first, as silence: drop it so markers line up.
        skip = latency
    }

    deinit { engine.stop() }

    func process(_ samples: [Float]) -> [Float] {
        schedule(samples)
        return render(until: Int(Double(scheduled) / rate) - latency - 4096)
    }

    /// Everything left, once the input has ended.
    func flush() -> [Float] {
        let total = Int(Double(scheduled) / rate)
        schedule([Float](repeating: 0, count: latency * 2 + 8192))
        return render(until: total + latency)
    }

    private func schedule(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        player.scheduleBuffer(buf)
        scheduled += samples.count
    }

    private func render(until target: Int) -> [Float] {
        var out: [Float] = []
        while rendered < target {
            let frames = AVAudioFrameCount(min(4096, target - rendered))
            guard (try? engine.renderOffline(frames, to: buffer)) == .success, buffer.frameLength > 0 else { break }
            let n = Int(buffer.frameLength)
            rendered += n
            let drop = min(skip, n)
            skip -= drop
            out += UnsafeBufferPointer(start: buffer.floatChannelData![0] + drop, count: n - drop)
        }
        return out
    }
}

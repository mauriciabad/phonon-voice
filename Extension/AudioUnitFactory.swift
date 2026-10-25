import AudioToolbox
import CoreAudioKit

/// The extension's principal class: macOS asks it for the audio unit when a voice is used.
public final class AudioUnitFactory: NSObject, AUAudioUnitFactory {
    private var unit: AUAudioUnit?

    public func beginRequest(with context: NSExtensionContext) {}

    @objc public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try PhononAudioUnit(componentDescription: componentDescription, options: [])
        self.unit = unit
        return unit
    }
}

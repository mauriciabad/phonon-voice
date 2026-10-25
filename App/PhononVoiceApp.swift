import AVFoundation
import SwiftUI

/// Host app for the voice extension. Opening it once registers the voice with macOS; it also
/// has a box to try the voice, which loads (and the first time, compiles) the models.
@main
struct PhononVoiceApp: App {
    var body: some Scene {
        Window("Phonon Voice", id: "main") {
            ContentView()
                .frame(minWidth: 460, minHeight: 320)
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @State private var text = "Hello! This is Phonon, speaking as a system voice.\n\nHola, ¿qué tal? Ahora también hablo en castellano.\n\nBon dia! I en català, amb la veu de la Montse."
    @State private var synthesizer = AVSpeechSynthesizer()

    private var voice: AVSpeechSynthesisVoice? {
        // macOS prefixes provider voice identifiers with the extension's bundle identifier.
        AVSpeechSynthesisVoice.speechVoices().first { $0.identifier.hasSuffix("com.mauriciabad.phonon.auto") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("To use Phonon everywhere, open System Settings → Accessibility → Read & Speak, set **System voice** to Phonon Voice → **Phonon** (under English (United States)), and turn off **Detect languages**. Then select text in any app and press ⌥Esc.")
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.body)
                .border(.separator)
            HStack {
                Button("Speak") {
                    synthesizer.stopSpeaking(at: .immediate)
                    let utterance = AVSpeechUtterance(string: text)
                    utterance.voice = voice
                    synthesizer.speak(utterance)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(voice == nil)
                Button("Stop") { synthesizer.stopSpeaking(at: .immediate) }
                Spacer()
                Button("Open Spoken Content Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                }
            }
            if voice == nil {
                Text("macOS hasn't picked up the voice yet. Quit and reopen this app.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear { AVSpeechSynthesisProviderVoice.updateSpeechVoices() }
    }
}

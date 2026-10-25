<p align="center"><img src="design/icon-1024.png" width="160" alt="Phonon Voice icon"></p>

# Phonon Voice

Use [Phonon](https://github.com/gradium-ai/xn-ptts), Gradium's on-device text-to-speech model, as a **macOS system voice**. Select text in any app, press **⌥Esc**, and Phonon reads it, the same way Apple's built-in voices do (Speak Selection, Read & Speak, `say -v Phonon`, and any app that uses the system speech API).

- **Runs entirely on your Mac.** The model runs on the Apple Neural Engine; nothing is sent anywhere. A sentence is ready in a fraction of a second.
- **Picks the voice per language.** Each paragraph's language is detected, then read in a native voice:

  | Language | Voice |
  |---|---|
  | English | Phonon default |
  | Spanish | Nerea |
  | French | Tiphaine |
  | German | Josefine |
  | Portuguese | Débora |
  | Catalan | Apple's Montse (Phonon has no Catalan model) |

> [!NOTE]
> This is an unofficial community project. It is not made or endorsed by Gradium.

## Install

You need a Mac with Apple silicon on macOS 15 or later (tested on macOS 27), [Xcode](https://apps.apple.com/app/xcode/id497799835), and [Homebrew](https://brew.sh). No Apple developer account is needed.

1. Run this in Terminal:
   ```sh
   zsh -c "$(curl -fsSL https://raw.githubusercontent.com/mauriciabad/phonon-voice/main/install.sh)"
   ```
   It installs the tools it needs, asks you to log in to [Hugging Face](https://huggingface.co) and accept the Phonon model's terms (free, in your browser), then builds the app into `/Applications`. The first run takes a few minutes.
2. In the **Read & Speak** settings it opens at the end (System Settings → Accessibility; called *Spoken Content* before macOS 27):
   - Set **System voice** to **Phonon Voice → Phonon**, under English (United States).
   - Turn off **Detect languages**. Phonon detects the language itself; with this on, macOS sends non-English text to its own voices.

Then select text anywhere and press **⌥Esc**.

The first time you read **Catalan**, macOS asks whether to "lower the security settings" for PhononVoiceExtension. That prompt is about loading Apple's own Catalan voice from inside the sandboxed extension. Allow it to hear Montse; if you cancel, Catalan is read by the Spanish voice instead.

## Customize the voices

Phonon's [voice catalog](https://huggingface.co/gradium/phonon-voices) has dozens of voices per language. To see them (needs the [`ptts` CLI](https://github.com/gradium-ai/xn-ptts#command-line), `brew install gradium-ai/tap/ptts`):

```sh
ptts --list-voices
```

Clone this repository, edit [`voices.json`](voices.json) with the name and ID of the voice you want for each language, and run `./install.sh` from the clone. An entry without an `id` uses the model's default voice. Languages Phonon supports: `en`, `es`, `fr`, `de`, `pt`.

## How it works

The app is a small host for an **Audio Unit speech synthesizer extension** (`AVSpeechSynthesisProviderAudioUnit`), the mechanism macOS uses for third-party system voices. macOS sends the extension each utterance as SSML and pulls the audio through its render block.

- `install.sh` exports Phonon 40m multilingual to Core ML with the voices from `voices.json`, using the exporter in [xn-ptts](https://github.com/gradium-ai/xn-ptts) (pinned to `v0.4.1`), and bundles it in the extension.
- On first use, the extension compiles the models for your Mac, which takes about 10 s once. After that, loading takes well under a second.
- [`Extension/Engine.swift`](Extension/Engine.swift) splits text into paragraphs, detects each one's language with Apple's NaturalLanguage framework, and switches Phonon's voice and text normalization to match. Text in a language Phonon doesn't speak goes to the best Apple voice for it.
- [`Extension/PhononAudioUnit.swift`](Extension/PhononAudioUnit.swift) streams the generated audio to macOS as it is produced, with sentence and word markers so the Speak Selection controller's skip buttons and word highlighting work.
- [`Extension/AudioSink.swift`](Extension/AudioSink.swift) applies the speed macOS asks for (the controller's 1×/2× button and the speaking rate) by time-stretching the audio without changing its pitch.

The Xcode project is generated from [`project.yml`](project.yml) by XcodeGen. To sign with your own certificate instead of ad hoc:

```sh
SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=YOURTEAMID ./install.sh
```

## Uninstall

```sh
zsh -c "$(curl -fsSL https://raw.githubusercontent.com/mauriciabad/phonon-voice/main/uninstall.sh)"
```

Then pick another System voice in Read & Speak. To update, run the install command again.

## License

The code in this repository is under the [MIT license](LICENSE).

The Phonon model is **not** included. `install.sh` downloads it with your own Hugging Face account. Phonon 40m multilingual is licensed [CC BY-NC 4.0](https://huggingface.co/gradium/phonon-40m-multilingual) (**non-commercial use only**), and the voice catalog is Apache 2.0. Phonon and xn-ptts are by [Gradium](https://gradium.ai). The app icon is drawn after the Phonon mark in the xn-ptts README.

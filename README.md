# VoiceInk (fork)

A fork of [Beingpax/VoiceInk](https://github.com/Beingpax/VoiceInk), a macOS voice-to-text app.

The full project README is kept at [UPSTREAM-README.md](UPSTREAM-README.md). It covers what the
app does, its features, its dependencies, and the upstream acknowledgments. This file only
describes what this fork changes.

## Build

```shell
make build              # development build
make local              # unsigned app copied to ~/Downloads
```

No Apple Developer account is needed. See [BUILDING.md](BUILDING.md) and
[LOCAL_BUILD_SETUP.md](LOCAL_BUILD_SETUP.md) for requirements and troubleshooting.

## Added transcription models

- **SenseVoice Small**, local and offline through transcribe.cpp. 241 MB, supports English,
  Mandarin, Cantonese, Japanese, and Korean. Runs after recording stops, no streaming.
- **Orukeet**, local and offline. A Parakeet V3 finetune from
  [oruk/orukeet](https://huggingface.co/oruk/orukeet) covering 25 European languages, 705 MB.
- **Cohere Transcribe 03-2026**, local, running on Apple silicon through FluidAudio. 2.1 GB,
  14 languages, batch only.
- **OpenRouter**, cloud. Currently `microsoft/mai-transcribe-2`. The key is read from the
  Keychain, or from `OPENROUTER_API_KEY` when the app inherits a shell environment. Your
  custom dictionary is sent as a phrase list.

## Audio input

- A configurable microphone equalizer with a high-pass filter, seven peaking bands, and a
  low-pass filter. It is applied to live audio, so streaming models hear the same signal that
  gets recorded. Defaults are flat: 0.0 dB on every band, 300 Hz high-pass, 3 kHz low-pass.
- Adaptive speech leveling that raises quiet speech without amplifying isolated peaks, with a
  strength slider in Audio settings. Default is 50%.

## Dictation control

- **Spoken actions**: configurable phrases that trigger an action instead of being transcribed,
  including inserting saved text. Configured in their own sidebar section.
- **Continuous dictation**: recording stays open across spoken commands, which are processed in
  order rather than ending the session.
- **Spoken phrase submission**: when a transcript ends with a configured phrase, the default
  being "press enter", VoiceInk strips the phrase, pastes the rest, and presses Return.
- **FluidAudio vocabulary boosting**: dictionary terms bias recognition in the FluidAudio
  models, in both batch and streaming modes.

## Removed

- Licensing and activation, including the onboarding license screen. The app builds and runs
  unsigned.
- Stored transcription history, session metrics, and CSV export.
- Announcements, the Sparkle updater, and the release and notarization scripts.

## License

GPL v3, unchanged from upstream. See [LICENSE](LICENSE).

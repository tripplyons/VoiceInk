# VoiceInk agent notes

## Project

- VoiceInk is a macOS Swift app built with `VoiceInk.xcodeproj` and the `VoiceInk` scheme.
- App code is in `VoiceInk/`. Unit tests are in `VoiceInkTests/`.
- The Xcode project uses file-system-synchronized groups. New Swift files inside those directories normally do not need manual `project.pbxproj` entries.
- Preserve unrelated working-tree changes. Do not commit unless the user asks.

## Build

Run the ordinary development build with:

```sh
make build
```

Use `make local` only when the user wants a runnable unsigned app copied to `~/Downloads`. It deletes `.local-build` and writes outside the repository.

The first build may resolve Swift packages and build the external Whisper framework under `~/VoiceInk-Dependencies`.

## Tests

Do not start with plain `xcodebuild test`. This project requires package validation overrides and ad-hoc signing on machines without the maintainer's certificate. Use:

```sh
DERIVED_DATA="${TMPDIR:-/tmp}/VoiceInk-agent-derived-data"

xcodebuild test \
  -project VoiceInk.xcodeproj \
  -scheme VoiceInk \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  CODE_SIGN_IDENTITY='-' \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM='' \
  CODE_SIGN_ENTITLEMENTS='' \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_BUILD' \
  -only-testing:VoiceInkTests/VoiceInkTests \
  -skip-testing:VoiceInkUITests
```

Notes:

- `-skipPackagePluginValidation` is required for MLX's `CudaBuild` plugin.
- `-skipMacroValidation` is required for `MLXHuggingFaceMacros`.
- The signing overrides avoid missing `Mac Development` certificates and provisioning profiles.
- Xcode may still build the UI-test runner even when UI tests are skipped.
- If the dedicated derived-data directory develops a stale linker or permission error, remove only `$DERIVED_DATA` and retry once. Do not clear the user's global DerivedData.
- Read the final `** TEST SUCCEEDED **` or `** TEST FAILED **` marker. Xcode's output can list test cases after the marker.

For a compile-only check, replace `test` with `build` and omit the two testing selectors.

## Audio processing ownership

- `CoreAudioRecorder` applies microphone EQ and `StreamingSpeechLeveler` before writing recorded PCM and before sending streaming chunks.
- Do not normalize that recording again when it stops. A second adaptive pass changes gain based on audio that was already leveled.
- `AudioProcessor` normalization remains appropriate for imported audio that did not pass through `CoreAudioRecorder`.
- Keep meter display scaling separate from recorded-audio gain. `Recorder.audioMeterSnapshot()` and `AudioVisualizer` affect UI only.

## Verification

- Match checks to the change. Run focused unit tests for isolated logic and the full `VoiceInkTests` suite for shared audio or recorder changes.
- Review `git diff --check` and `git status --short` before reporting completion.
- Report test or build failures with the actual blocker. Do not claim success from compilation alone when behavior changed.

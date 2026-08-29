# VoiceInk local source build

This checkout builds an ad-hoc-signed VoiceInk app for personal use without an Apple Developer certificate.

## Requirements

- macOS 14.4 or newer
- Full Xcode installation, opened once to finish first-launch setup
- Git
- CMake
- Several gigabytes of free disk space for Swift packages, DerivedData, and the Whisper XCFramework

With Homebrew:

```sh
brew install git cmake
xcodebuild -version
swift --version
```

If command-line tools point at the wrong Xcode installation:

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

## Build

```sh
cd VoiceInk
make check
make local
open ~/Downloads/VoiceInk.app
```

`make local`:

1. Clones `whisper.cpp` into `~/VoiceInk-Dependencies/`.
2. Builds `whisper.xcframework`.
3. Resolves Swift Package Manager dependencies.
4. Builds VoiceInk with ad-hoc signing.
5. Replaces `~/Downloads/VoiceInk.app` with the new bundle.
6. Clears downloaded-file quarantine attributes from that bundle.

The first build is slow because it compiles Whisper and downloads Swift dependencies. Later builds reuse `~/VoiceInk-Dependencies/whisper.cpp/build-apple/whisper.xcframework`.

macOS will request microphone, Accessibility, and possibly screen-recording permissions. Grant only the permissions needed for the features you use.

## Verify

Verify the installed bundle and executable:

```sh
codesign --verify --deep --strict --verbose=2 ~/Downloads/VoiceInk.app
file ~/Downloads/VoiceInk.app/Contents/MacOS/VoiceInk
```

The first command should report `valid on disk`. The second should report a Mach-O executable for your Mac's architecture.

Run the test target against the local configuration:

```sh
xcodebuild \
  -project VoiceInk.xcodeproj \
  -scheme VoiceInk \
  -configuration Debug \
  -derivedDataPath .local-build \
  -xcconfig LocalBuild.xcconfig \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM= \
  CODE_SIGN_ENTITLEMENTS="$PWD/VoiceInk/VoiceInk.local.entitlements" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) LOCAL_BUILD' \
  test
```

## Update

```sh
cd VoiceInk
git pull --rebase
make local
```

Review dependency changes before rebuilding. `-skipPackagePluginValidation` and `-skipMacroValidation` allow package plugins and macros to execute without Xcode's interactive approval, so build only revisions and dependencies you trust.

## Local-build limitations

- No iCloud dictionary synchronization
- No automatic application updates
- Ad-hoc signature rather than Developer ID notarization
- Rebuilding may require granting macOS permissions again if the app's code identity changes

# SimpleMediaPlayer

**English** | [日本語](README.ja.md)

A media player packed with my personal interests.
It supports importing audio and video files, browsing a local library, playlist management, playback controls, lyrics display, and audio visualization.

## Requirements

- Xcode 27+ (with Swift 6+ and the Music Understanding SDK)
- Apple platform SDKs supported by the Xcode project
- Music analysis using [Music Understanding](https://developer.apple.com/documentation/musicunderstanding) requires macOS 27+, iOS 27+, or iPadOS 27+. Music analysis is unavailable on earlier OS versions.

The [embedded audio metadata support matrix](docs/embedded-audio-metadata.md) ([日本語](docs/embedded-audio-metadata.ja.md)) describes supported fields and formats.

## Localization

The app supports English and Japanese and follows the system's language preference.
UI text is maintained in `SimpleMediaPlayer/Localizable.xcstrings`; the Music
permission explanation is maintained in `SimpleMediaPlayer/InfoPlist.xcstrings`.
Keep LED faceplate legends (`EQ`, `KEY`, `SPEED`, `VOLUME`, `ON`/`OFF`), `BPM`,
and numeric displays unchanged in both languages. Localize accessibility
descriptions separately. Language-independent catalog entries use
`shouldTranslate: false`.

## Build and Test

The build runs SwiftLint automatically. Before the first build (including
`start.sh`), open the project in Xcode, let it resolve packages, and choose
**Trust & Enable** for the plugin. See the [SwiftLint guide](docs/swiftlint.md)
for lint commands and configuration.

```sh
xcodebuild -project SimpleMediaPlayer.xcodeproj -scheme SimpleMediaPlayer build
xcodebuild -project SimpleMediaPlayer.xcodeproj -scheme SimpleMediaPlayer test
```

## Run Outside Xcode Debugging

Use the repository-local launch script to build and run a normal macOS app
bundle without Xcode's debug run:

```sh
./start.sh
```

With no arguments, the script launches an existing Release build, or builds it
first when it does not exist. Build artifacts are kept under the repository's
gitignored `.build/` directory. The following options are also available and
can be combined:

```sh
./start.sh rebuild       # Clean, rebuild, and launch Release
./start.sh debug         # Build and launch Debug
./start.sh rebuild debug # Clean, rebuild, and launch Debug
```

The app bundle contains the executable at:

```text
.build/DerivedData/Build/Products/Release/SimpleMediaPlayer.app/Contents/MacOS/SimpleMediaPlayer
```

For a distributable macOS build, use Xcode's Product > Archive flow with the
`SimpleMediaPlayer` scheme and export the archived app. iPhone and iPad builds
must be signed and installed through Xcode, Finder, Apple Configurator, or an
equivalent deployment workflow; they are not launched as standalone executable
files like a macOS app.

## Media Storage

Imported media files are copied into the app's own media directory and managed
there instead of being referenced directly from their original locations.

For the sandboxed macOS app, the media directory is based on the app's bundle
identifier:

```text
~/Library/Containers/<Bundle ID>/Data/Library/Application Support/<Bundle ID>/Media
```

Files are stored with UUID-based names while preserving their original file
extensions, such as `2E3102B4-4359-4180-A481-C7EAB1DE9E49.mp3`.

## Code Signing

Simulator builds work out of the box. To build for a physical device, create
`Configs/Signing.local.xcconfig` (gitignored) with your own Apple Developer
Team ID:

```
DEVELOPMENT_TEAM = XXXXXXXXXX
```

## License

The source code is licensed under the [MIT License](LICENSE).

The bundled fonts are licensed under the SIL Open Font License (OFL), not MIT:

- DSEG7 Classic Mini — [OFL-DSEG.txt](SimpleMediaPlayer/Resources/Fonts/OFL-DSEG.txt)
- DotGothic16 — [OFL-DotGothic16.txt](SimpleMediaPlayer/Resources/Fonts/OFL-DotGothic16.txt)
- Dotrice — [OFL-Dotrice.txt](SimpleMediaPlayer/Resources/Fonts/OFL-Dotrice.txt)

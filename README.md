# SimpleMediaPlayer

**English** | [日本語](README.ja.md)

A media player packed with my personal interests.
It supports importing audio and video files, browsing a local library, playlist management, playback controls, lyrics display, and audio visualization.

## Requirements

- Xcode 27.1+ (with Swift 6+ and the Music Understanding SDK; Xcode 27.1 Beta is supported)
- Apple platform SDKs supported by the Xcode project
- Music analysis using [Music Understanding](https://developer.apple.com/documentation/musicunderstanding) requires macOS 27+, iOS 27+, or iPadOS 27+. Music analysis is unavailable on earlier OS versions.

The [embedded audio metadata support matrix](docs/embedded-audio-metadata.md) ([日本語](docs/embedded-audio-metadata.ja.md)) describes supported fields and formats.
See [extended audio formats](docs/extended-audio-formats.md) ([日本語](docs/extended-audio-formats.ja.md)) for WMA, WavPack, Monkey's Audio, and Musepack playback, caching, and limitations.

## iPhone Duo

On the open inner display, the app uses the sidebar, media list, details panel, and LED playback panel. Smaller windows and the closed outer display use the iPhone tabs and deck. Playback and library navigation continue across layout changes. [Layout and verification](docs/iphone-duo.md) describe the supported behavior and Simulator checks.

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

## Music Library on iPhone and iPad

On iPhone and iPad, the library menu offers **Play from Music…** and
**Import from Music…**. Both open the system media picker for songs that are
downloaded to the device and have no DRM; Apple Music subscription songs and
protected or cloud-only items are not available.

- **Play from Music…** exports one song to a temporary copy and plays it with
  the app's own player, so the equalizer, key and speed controls, visualizers,
  and music analysis work as usual. Nothing is added to the library; the
  temporary copy is removed when playback moves to other media or is cleared.
  Editing, copying, and AAC conversion are disabled for such songs.
- **Import from Music…** exports the selected songs into the app's media
  directory and registers them as regular library items. AAC, Apple Lossless,
  MP3, AIFF, and WAV keep their encoding; other encodings are converted to AAC
  and the result message says so. The song's Music metadata and artwork take
  precedence over tags embedded in the file. Songs already imported from Music
  are skipped. The original in the Music library is never changed.

The feature requires Music library access (`NSAppleMusicUsageDescription`); the
app explains the reason and offers to open Settings when access was denied.

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

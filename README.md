# SimpleMediaPlayer

**English** | [日本語](README.ja.md)

A media player packed with my personal interests.
It supports importing audio and video files, browsing a local library, playlist management, playback controls, lyrics display, and audio visualization.

## Requirements

- Xcode 26+ (with Swift 6+)
- Apple platform SDKs supported by the Xcode project

## Localization

The app supports English and Japanese and follows the system's language preference.
UI text is maintained in `SimpleMediaPlayer/Localizable.xcstrings`; the Music
permission explanation is maintained in `SimpleMediaPlayer/InfoPlist.xcstrings`.
Keep LED faceplate legends (`EQ`, `KEY`, `SPEED`, `VOLUME`, `ON`/`OFF`), `BPM`,
and numeric displays unchanged in both languages. Localize accessibility
descriptions separately. Language-independent catalog entries use
`shouldTranslate: false`.

## Build and Test

```sh
xcodebuild -project SimpleMediaPlayer.xcodeproj -scheme SimpleMediaPlayer build
xcodebuild -project SimpleMediaPlayer.xcodeproj -scheme SimpleMediaPlayer test
```

## SwiftLint

SwiftLint **0.65.1** is pinned through the
[SwiftLintPlugins package](https://github.com/SimplyDanny/SwiftLintPlugins).
Xcode runs `SwiftLintBuildToolPlugin` when building the app, unit-test, and UI-test
targets. No Homebrew installation is required. On the first build, allow Xcode
to resolve the package, then choose **Trust & Enable** when it asks to enable
the plugin. Command-line builds (including `start.sh`) also need this initial
trust step. Package resolution requires network access on a fresh checkout.

Run lint for all three source directories without building or running tests:

```sh
./scripts/lint.sh
./scripts/lint.sh --strict # Fail on new warnings as well as errors
```

The script downloads the same pinned binary using Xcode package resolution on
first use and keeps packages and caches in `.build/`. It can be called from any
working directory. Additional arguments are passed to `swiftlint lint`.

`.swiftlint.yml` uses SwiftLint's default rules and severities. The initial scan
of 98 files found 413 violations. Formatting, local-name, and equivalent syntax
cleanup resolved 308 of those findings; line wrapping introduced three additional
function-length findings. The remaining 108 are recorded in
`.swiftlint-baseline.json` so existing violations do not block adoption.
New warnings appear in Xcode, and new error-level violations fail the build.
Linting does not change source files
unless explicitly invoked with an option such as `--fix`.

The retained findings require separate review: file/type/function size,
complexity, parameter counts, tuple/type structure, explicit `nil` defaults in
SwiftData models and migration fixtures, forced AVFoundation casts, and a test
parser's intentionally non-failing UTF-8 decoding. Removing defaults, changing
cast failures, or replacing lossy decoding can affect behavior. Avoid broad
automatic correction of those findings. The cleanup preserves persistence
schemas, external argument labels, localized text, and numeric expressions.

The baseline postpones existing issues; it does not fix them. To inspect all
violations, including those in the baseline:

```sh
mkdir -p .build
printf '[]\n' > .build/swiftlint-empty-baseline.json
./scripts/lint.sh --baseline .build/swiftlint-empty-baseline.json
```

Only regenerate the baseline after reviewing the full report: regeneration
also accepts any new violations. SwiftLint writes all detected violations even
when an existing baseline is configured:

```sh
./scripts/lint.sh --write-baseline .swiftlint-baseline.json
python3 -m json.tool --no-ensure-ascii --sort-keys --indent 2 \
  .swiftlint-baseline.json .build/swiftlint-baseline-formatted.json
mv .build/swiftlint-baseline-formatted.json .swiftlint-baseline.json
```

Baseline matching includes the diagnostic text, so edits to an existing long
function or file can cause length or complexity violations to reappear. Review
those changes before refreshing the baseline. A version upgrade can also change
rules or parsing behavior; update the exact package version in the Xcode project,
`SWIFTLINT_VERSION` in `scripts/lint.sh`, and the resolved package lockfile
together, then review lint results and verify the build.

Build-time linting adds work to each target, with per-target caches limiting
repeat work. The integration preserves `ENABLE_USER_SCRIPT_SANDBOXING = YES`
and adds no library to the shipped app. For unattended builds, Xcode provides
`-skipPackagePluginValidation`; use it only after reviewing the pinned plugin,
because it skips plugin trust checks for that invocation. See the
[official setup documentation](https://github.com/realm/SwiftLint#xcode-projects).

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


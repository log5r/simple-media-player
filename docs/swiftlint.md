# SwiftLint

**English** | [日本語](swiftlint.ja.md)

[Back to README](../README.md)

Run the commands below from the repository root.

## Setup

SwiftLint **0.65.1** is pinned through the
[SwiftLintPlugins package](https://github.com/SimplyDanny/SwiftLintPlugins).
Xcode runs `SwiftLintBuildToolPlugin` when building the app, unit-test, and UI-test
targets. No Homebrew installation is required. On the first build, allow Xcode
to resolve the package, then choose **Trust & Enable** when it asks to enable
the plugin. Command-line builds (including `start.sh`) also need this initial
trust step. Package resolution requires network access on a fresh checkout.

## Running Lint

Run lint for all three source directories without building or running tests:

```sh
./scripts/lint.sh
./scripts/lint.sh --strict # Fail on new warnings as well as errors
```

The script downloads the same pinned binary using Xcode package resolution on
first use and keeps packages and caches in `.build/`. It can be called from any
working directory. Additional arguments are passed to `swiftlint lint`.

## Rules and Baseline

`.swiftlint.yml` uses SwiftLint's default rules and severities. Existing
violations are recorded in `.swiftlint-baseline.json`.
New warnings appear in Xcode, and new error-level violations fail the build.
Linting does not change source files
unless explicitly invoked with an option such as `--fix`.

The retained findings require separate review: file/type/function size,
complexity, parameter counts, tuple/type structure, explicit `nil` defaults in
SwiftData models and migration fixtures, forced AVFoundation casts, and a test
parser's intentionally non-failing UTF-8 decoding. Removing defaults, changing
cast failures, or replacing lossy decoding can affect behavior. Avoid broad
automatic correction of those findings.
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

## Build Integration

Build-time linting adds work to each target, with per-target caches limiting
repeat work. The integration preserves `ENABLE_USER_SCRIPT_SANDBOXING = YES`
and adds no library to the shipped app. For unattended builds, Xcode provides
`-skipPackagePluginValidation`; use it only after reviewing the pinned plugin,
because it skips plugin trust checks for that invocation. See the
[official setup documentation](https://github.com/realm/SwiftLint#xcode-projects).

#!/usr/bin/env zsh

set -euo pipefail

readonly PROJECT_ROOT="${0:A:h:h}"
readonly PACKAGE_DIRECTORY="${PROJECT_ROOT}/.build/SourcePackages"
readonly SWIFTLINT_BINARY="${PACKAGE_DIRECTORY}/artifacts/swiftlintplugins/SwiftLintBinary/SwiftLintBinary.artifactbundle/macos/swiftlint"
readonly SWIFTLINT_VERSION="0.65.1"

cd "${PROJECT_ROOT}"

if [[ ! -x "${SWIFTLINT_BINARY}" ]]; then
  xcodebuild \
    -resolvePackageDependencies \
    -project "${PROJECT_ROOT}/SimpleMediaPlayer.xcodeproj" \
    -scheme SimpleMediaPlayer \
    -derivedDataPath "${PROJECT_ROOT}/.build/DerivedData" \
    -clonedSourcePackagesDirPath "${PACKAGE_DIRECTORY}" >&2
fi

if [[ "$("${SWIFTLINT_BINARY}" version)" != "${SWIFTLINT_VERSION}" ]]; then
  print -u2 "Expected SwiftLint ${SWIFTLINT_VERSION}. Resolve the project's package dependencies again."
  exit 1
fi

exec "${SWIFTLINT_BINARY}" lint \
  --config "${PROJECT_ROOT}/.swiftlint.yml" \
  --cache-path "${PROJECT_ROOT}/.build/SwiftLintCache" \
  "$@"

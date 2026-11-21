#!/usr/bin/env bash
# Runs the iOS Simulator unit tests that pull request and main push CI runs skip.
# Uses an existing iPhone simulator for IOS_TEST_RUNTIME_VERSION (default 27.1) and leaves it booted.

set -o pipefail
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit "$?"

runtime_version="${IOS_TEST_RUNTIME_VERSION:-27.1}"
# The selector also exits with 2 on an invalid version, so reject one here.
if [[ ! "$runtime_version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "IOS_TEST_RUNTIME_VERSION must be a version such as 27.1: ${runtime_version}" >&2
  exit 1
fi

devices_json="$(xcrun simctl list devices --json)" || exit "$?"
selection_exit=0
udid="$(printf '%s' "$devices_json" \
  | python3 scripts/select-ios-test-device.py --mode device --version "$runtime_version")" \
  || selection_exit=$?
if (( selection_exit == 2 )); then
  cat >&2 <<EOF
No available iPhone simulator was found for iOS ${runtime_version}.
Install the iOS ${runtime_version} simulator runtime (Xcode Settings > Components, or
xcodebuild -downloadPlatform iOS -buildVersion ${runtime_version}) and create an iPhone simulator for it,
or set IOS_TEST_RUNTIME_VERSION to the version of an installed runtime.
EOF
  exit 2
elif (( selection_exit != 0 )); then
  echo "Selecting an iOS ${runtime_version} simulator failed." >&2
  exit "$selection_exit"
fi

# A simulator that stays booted between runs has settled, which keeps the tests fast.
xcrun simctl bootstatus "$udid" -b || exit "$?"

common_args=(
  -project SimpleMediaPlayer.xcodeproj
  -scheme SimpleMediaPlayer
  -derivedDataPath .build/DerivedData-ios
  -clonedSourcePackagesDirPath .build/SourcePackages
  -skipPackagePluginValidation
)

build_args=(
  "${common_args[@]}"
  -destination 'generic/platform=iOS Simulator'
  ARCHS=arm64
  -enableCodeCoverage YES
  CODE_SIGNING_ALLOWED=NO build-for-testing
)
./scripts/ci-xcodebuild.sh iOS-build-for-testing "${build_args[@]}" || exit "$?"

result_directory=".build-logs/test-results"
mkdir -p "$result_directory" || exit "$?"
result_bundle="${result_directory}/iOSUnitTests-$(date +%Y%m%d-%H%M%S)-$$.xcresult"
if [[ -e "$result_bundle" ]]; then
  echo "The result bundle path already exists: ${result_bundle}" >&2
  exit 1
fi

test_args=(
  "${common_args[@]}"
  -destination "platform=iOS Simulator,id=${udid}"
  -only-testing:SimpleMediaPlayerTests
  -parallel-testing-enabled NO
  -resultBundlePath "$result_bundle"
  -enableCodeCoverage YES
  CODE_SIGNING_ALLOWED=NO test-without-building
)
test_exit=0
./scripts/ci-xcodebuild.sh iOS-unit-tests "${test_args[@]}" || test_exit=$?

printf 'Test result bundle: %s\n' "$result_bundle"
exit "$test_exit"

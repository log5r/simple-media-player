#!/usr/bin/env zsh

set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly SCRIPT_NAME="${0:t}"
readonly PROJECT_PATH="${SCRIPT_DIR}/SimpleMediaPlayer.xcodeproj"
readonly SCHEME="SimpleMediaPlayer"
readonly DERIVED_DATA_PATH="${SCRIPT_DIR}/.build/DerivedData"

configuration="Release"
should_rebuild=false
should_build=false

usage() {
  print -u2 "Usage: ${SCRIPT_NAME} [rebuild] [debug]"
  print -u2 "  rebuild  Clean and rebuild before launching"
  print -u2 "  debug    Build and launch the Debug configuration"
}

for argument in "$@"; do
  case "${argument}" in
    rebuild)
      should_rebuild=true
      should_build=true
      ;;
    debug)
      configuration="Debug"
      should_build=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print -u2 "Unknown argument: ${argument}"
      usage
      exit 2
      ;;
  esac
done

readonly APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${configuration}/${SCHEME}.app"
readonly BINARY_PATH="${APP_PATH}/Contents/MacOS/${SCHEME}"

if [[ ! -x "${BINARY_PATH}" ]]; then
  should_build=true
fi

if [[ "${should_build}" == true ]]; then
  build_actions=(build)
  if [[ "${should_rebuild}" == true ]]; then
    build_actions=(clean build)
  fi

  pkill -x "${SCHEME}" 2>/dev/null || true

  xcodebuild \
    -project "${PROJECT_PATH}" \
    -scheme "${SCHEME}" \
    -configuration "${configuration}" \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    "${build_actions[@]}"
fi

open "${APP_PATH}"

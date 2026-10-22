#!/usr/bin/env bash

set -o pipefail
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit "$?"

if (( $# < 2 )); then
  echo "Usage: ci-xcodebuild.sh <log-name> <xcodebuild arguments...>" >&2
  exit 2
fi
run_name="$1"
shift
if [[ ! "$run_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "The log name must contain only letters, numbers, dots, underscores, or hyphens." >&2
  exit 2
fi

command -v xcsift >/dev/null 2>&1 || {
  echo "xcsift is required for CI builds. Install it on the xcode-27 runner." >&2
  exit 1
}
mkdir -p .build-logs || exit "$?"
build_log=".build-logs/${run_name}-$(date +%Y%m%d-%H%M%S)-$$.log"

build_status=0
xcodebuild "$@" 2>&1 | tee "$build_log" | xcsift -f toon -w || build_status=$?

printf 'Full build log: %s\n' "$build_log"
exit "$build_status"

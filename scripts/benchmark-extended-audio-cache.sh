#!/usr/bin/env bash
set -euo pipefail

# Requires a completed macOS Debug build with packages in .build/SourcePackages.
# The 512KiB budget forces the fixture batch to exceed capacity without writing 8GiB.
project_root="$(cd "$(dirname "$0")/.." && pwd)"
baseline="${1:-90557a1f14fbf269ebbee1a0100b620d4737afd8}"
track_count="${TRACK_COUNT:-100}"
run_count="${RUN_COUNT:-3}"
work_dir="${BENCHMARK_DIRECTORY:-$project_root/.build/issue13-benchmark}"
derived_dir="${DERIVED_DATA_DIRECTORY:-$project_root/.build/DerivedData}"
products="$derived_dir/Build/Products/Debug"
modulemaps="$derived_dir/Build/Intermediates.noindex/GeneratedModuleMaps"
mkdir -p "$work_dir/before" "$work_dir/after"

for name in ExtendedAudioSource.swift FFmpegAudioBridge.h FFmpegAudioBridge.m; do
    git -C "$project_root" show "$baseline:SimpleMediaPlayer/Services/$name" > "$work_dir/before/$name"
    cp "$project_root/SimpleMediaPlayer/Services/$name" "$work_dir/after/$name"
done
cp "$project_root/SimpleMediaPlayer/Services/ExtendedAudioCache.swift" "$work_dir/after/ExtendedAudioCache.swift"

python3 - "$work_dir" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
for mode in ("before", "after"):
    path = root / mode / "ExtendedAudioSource.swift"
    source = path.read_text()
    source = source.replace("8 * 1_024 * 1_024 * 1_024", "512 * 1_024")
    replacement = '''private static func cacheDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EXTENDED_AUDIO_BENCH_CACHE"]!, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }'''
    source, count = re.subn(r'private static func cacheDirectory\(\) throws -> URL \{.*?\n    \}', replacement, source, flags=re.S)
    assert count == 1, "Expected production cacheDirectory entry point"
    path.write_text(source)
PY

link_objects=("$products/SFBAudioEngine.o" "$products/CSFBAudioEngine.o"
    "$products/AVFAudioExtensions.o" "$products/MAC.o" "$products/taglib.o"
    "$products/dumb.o" "$products/speex.o" "$products/CXXAudioRingBuffer.o"
    "$products/CXXDispatchSemaphore.o" "$products/CXXMessageQueue.o"
    "$products/CXXQueue.o" "$products/CXXUnfairLock.o")
frameworks=(AetherLibavcodec AetherLibavformat AetherLibavutil AetherLibswresample
    AVFoundation AudioToolbox Accelerate CoreAudio FLAC lame mpc mpg123 ogg opus sndfile tta-cpp vorbis wavpack)
link_frameworks=()
for framework in "${frameworks[@]}"; do link_frameworks+=(-framework "$framework"); done
profile_runtime="$(xcrun clang --print-file-name=libclang_rt.profile_osx.a)"

for mode in before after; do
    xcrun clang -fobjc-arc -mmacosx-version-min=26.5 -fmodules-cache-path="$work_dir/clang-cache" -c \
        "$work_dir/$mode/FFmpegAudioBridge.m" -F "$products" -I "$work_dir/$mode" \
        -o "$work_dir/$mode/bridge.o"
    mode_sources=("$work_dir/$mode/ExtendedAudioSource.swift")
    mode_flags=(-O)
    if [[ "$mode" == after ]]; then
        mode_sources+=("$work_dir/after/ExtendedAudioCache.swift")
        mode_flags+=(-D AFTER)
    fi
    xcrun swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macos26.5" \
        -module-cache-path "$work_dir/module-cache" "${mode_flags[@]}" \
        -import-objc-header "$work_dir/$mode/FFmpegAudioBridge.h" \
        -I "$products" -F "$products" -Xcc "-fmodule-map-file=$modulemaps/CSFBAudioEngine.modulemap" \
        -I "$project_root/.build/SourcePackages/checkouts/SFBAudioEngine/Sources/CSFBAudioEngine/include" \
        "${mode_sources[@]}" \
        "$project_root/scripts/ExtendedAudioCacheBenchmark.swift" "$work_dir/$mode/bridge.o" \
        "${link_objects[@]}" "${link_frameworks[@]}" "$profile_runtime" -lc++ -lz \
        -Xlinker -rpath -Xlinker "$products" -o "$work_dir/$mode/benchmark"
done

results="$work_dir/results.jsonl"
: > "$results"
mkdir -p "$work_dir/runs"
run_root="$(mktemp -d "$work_dir/runs/batch-XXXXXX")"
for ((run = 1; run <= run_count; run++)); do
    for mode in before after; do
        run_dir="$run_root/$run-$mode"
        mkdir -p "$run_dir/cache"
        LLVM_PROFILE_FILE="$run_dir/dependencies.profraw" \
            EXTENDED_AUDIO_BENCH_CACHE="$run_dir/cache" "$work_dir/$mode/benchmark" \
            "$project_root/SimpleMediaPlayerTests/Fixtures" "$run_dir" "$track_count" | tee -a "$results"
    done
done
printf 'Results: %s\n' "$results"

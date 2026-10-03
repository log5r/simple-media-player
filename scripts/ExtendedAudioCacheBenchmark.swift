import AVFoundation
import Darwin
import Foundation
import SFBAudioEngine

// Runs the production decoder entry points; fixture preparation is outside the measurement.
@main
struct ExtendedAudioCacheBenchmark {
    struct Metrics {
        let wall: Double
        let user: Double
        let system: Double
        let diskBytes: UInt64

        init() {
            wall = ProcessInfo.processInfo.systemUptime
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            var process = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &process) { pointer in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4,
                    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self))
            }
            diskBytes = result == 0 ? process.ri_diskio_byteswritten : 0
        }

        func since(_ start: Metrics) -> [String: Any] {
            ["elapsed_seconds": wall - start.wall, "cpu_user_seconds": user - start.user,
             "cpu_system_seconds": system - start.system,
             "process_disk_bytes_written": diskBytes >= start.diskBytes ? diskBytes - start.diskBytes : 0]
        }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 4,
              let trackCount = Int(CommandLine.arguments[3]), trackCount > 0 else {
            fatalError("Usage: benchmark fixtures_directory run_directory track_count")
        }
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let originalDirectory = directory.appendingPathComponent("originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
        let musepack = originalDirectory.appendingPathComponent("fixture.mpc")
        try AudioConverter.convert(fixtures.appendingPathComponent("tag-test.wav"), to: musepack)
        let inputs = ["wma", "wv", "ape", "mpc"]
        var tracks: [URL] = []
        for index in 0..<trackCount {
            let ext = inputs[index % inputs.count]
            let fixture = ext == "mpc" ? musepack : fixtures.appendingPathComponent("extended-test.\(ext)")
            let source = originalDirectory.appendingPathComponent("track-\(index).\(ext)")
            try FileManager.default.copyItem(at: fixture, to: source)
            tracks.append(source)
        }

        var logicalPCMBytes: Int64 = 0
        let started = Metrics()
        for source in tracks {
            try autoreleasepool {
                #if AFTER
                try ExtendedAudioSource.validate(for: source)
                #else
                let cached = try ExtendedAudioSource.readableURL(for: source)
                logicalPCMBytes += try size(of: cached)
                #endif
            }
        }
        var result = Metrics().since(started)
        result["stage"] = "import_validation"
        #if AFTER
        result["mode"] = "after"
        #else
        result["mode"] = "before"
        #endif
        result["track_count"] = tracks.count
        result["logical_pcm_bytes_written"] = logicalPCMBytes
        let cacheDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EXTENDED_AUDIO_BENCH_CACHE"]!)
        result["cache_bytes_after_import"] = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil
        ).reduce(Int64(0)) { total, file in total + (try size(of: file)) }
        emit(result)

        // The first track has been evicted in the baseline because the batch exceeds the cache budget.
        let revisitStarted = Metrics()
        let cached = try ExtendedAudioSource.readableURL(for: tracks[0])
        var revisit = Metrics().since(revisitStarted)
        revisit["stage"] = "first_track_playback_preparation"
        revisit["mode"] = result["mode"]
        revisit["logical_pcm_bytes_written"] = try size(of: cached)
        revisit["decoded_frames"] = try AVAudioFile(forReading: cached).length
        emit(revisit)
    }

    static func size(of url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func emit(_ value: [String: Any]) {
        let encoded = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print(String(decoding: encoded, as: UTF8.self))
    }
}

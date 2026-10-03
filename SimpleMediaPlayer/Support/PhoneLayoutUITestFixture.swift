#if DEBUG && os(iOS)
import AVFoundation
import SwiftData
import SwiftUI

/// Local media keeps the phone navigation tests independent of file-provider dialogs and network access.
@MainActor
enum PhoneLayoutUITestFixture {
    static var dynamicTypeSizeOverride: DynamicTypeSize? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing-phone-layout") else { return nil }
        if arguments.contains("--ui-testing-phone-large-text") { return .accessibility5 }
        if arguments.contains("--ui-testing-phone-extra-large-text") { return .xxxLarge }
        return nil
    }

    static func makeAACVersionExporter() -> TransformedTrackExporter {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing-phone-layout"),
              arguments.contains("--ui-testing-delayed-aac") else { return TransformedTrackExporter() }
        return TransformedTrackExporter(renderer: DelayedUITestAudioRenderer())
    }

    static func insert(into context: ModelContext) throws {
        resetLEDSettingsIfRequested()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000) else { return }
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            buffer.floatChannelData?[channel].initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        let playlist = Playlist(name: "Layout Playlist")
        context.insert(playlist)
        for index in 1...3 {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("phone-layout-\(index).wav")
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            for _ in 0..<60 { try file.write(from: buffer) }
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let usesLongTitle = index == 1
                && ProcessInfo.processInfo.arguments.contains("--ui-testing-phone-long-title")
            let title = usesLongTitle
                ? "とても長い曲名の表示確認 — A Very Long Track Name for Checking the Compact Playback Panel"
                : "Layout Track \(index)"
            let item = MediaItem(
                title: title, artist: "Layout Artist", album: "Layout Album",
                duration: 60, isVideo: false,
                lyricsRaw: "[00:00.00]First lyric\n[00:20.00]Second lyric\n[00:40.00]Third lyric",
                bookmarkData: bookmark, fileName: url.lastPathComponent
            )
            context.insert(item)
            let entry = PlaylistEntry(sortIndex: index - 1, playlist: playlist, item: item)
            playlist.entries.append(entry)
            context.insert(entry)
        }
        try context.save()
    }

    private static func resetLEDSettingsIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing-reset-led-settings") else { return }
        // Launch-argument defaults override writes, so mutable settings need persistent initial values.
        let defaults: [(String, String)] = [
            (AppSettingsKey.bottomPanelLayout, AppSettingsDefault.bottomPanelLayout),
            (AppSettingsKey.ledDisplayStyle, AppSettingsDefault.ledDisplayStyle),
            (AppSettingsKey.ledColorHex, AppSettingsDefault.ledColorHex),
            (AppSettingsKey.timeDisplayStyle, AppSettingsDefault.timeDisplayStyle),
            (AppSettingsKey.mediaInfoDisplayStyle, AppSettingsDefault.mediaInfoDisplayStyle),
            (AppSettingsKey.ledGlassStyle, AppSettingsDefault.ledGlassStyle),
            (AppSettingsKey.visualizerResponseMode, AppSettingsDefault.visualizerResponseMode)
        ]
        for (key, value) in defaults {
            UserDefaults.standard.set(value, forKey: key)
        }
    }
}

/// A slow background renderer makes dismiss-before-completion reproducible without large media files.
private nonisolated struct DelayedUITestAudioRenderer: TransformedAudioRendering {
    // The rendering protocol requires this signature.
    // swiftlint:disable:next function_parameter_count
    func render(
        sourceURL: URL,
        pitchCents: Float,
        rate: Float,
        maxSampleRate: Double?,
        makeEncoder: (AVAudioFormat) throws -> any AudioFileEncoding,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> TransformedAudioRenderer.Result {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            Thread.sleep(forTimeInterval: 0.05)
        }
        return try TransformedAudioRenderer().render(
            sourceURL: sourceURL, pitchCents: pitchCents, rate: rate, maxSampleRate: maxSampleRate,
            makeEncoder: makeEncoder, progress: progress
        )
    }
}
#endif

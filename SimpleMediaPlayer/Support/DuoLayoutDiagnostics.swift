#if DEBUG && os(iOS)
import Darwin
import SwiftUI

/// This overlay measures real scene geometry without changing the layout's proposal or its safe area.
struct DuoLayoutDiagnostics: ViewModifier {
    let layoutName: String
    var player: PlayerViewModel?
    var autoplayItems: [MediaItem] = []
    @State private var hasRequestedPlayback = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-duo-layout") {
                GeometryReader { geometry in
                    let value = metrics(for: geometry)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Layout diagnostics")
                            .accessibilityElement(children: .ignore)
                            .accessibilityIdentifier("duoLayoutMetrics")
                            .accessibilityLabel("Layout diagnostics")
                            .accessibilityValue(value)
                            .onChange(of: value, initial: true) { _, value in
                                print("DuoLayoutMetrics \(value)")
                                fflush(nil)
                            }
                        Text("Safe area diagnostics")
                            .accessibilityElement(children: .ignore)
                            .accessibilityIdentifier("duoSafeAreaMetrics")
                            .accessibilityLabel("Safe area diagnostics")
                            .accessibilityValue(safeAreaMetrics(for: geometry))
                        if let player {
                            Text("Playback diagnostics")
                                .accessibilityElement(children: .ignore)
                                .accessibilityIdentifier("duoPlaybackMetrics")
                                .accessibilityLabel("Playback diagnostics")
                                .accessibilityValue(playbackMetrics(for: player))
                        }
                    }
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
                .allowsHitTesting(false)
            }
        }
        .task(id: autoplayItems.map(\.id)) {
            await runPlaybackProbe()
        }
    }

    private func runPlaybackProbe() async {
        guard PhoneLayoutUITestFixture.autoplayProbeEnabled,
              let player, let firstItem = autoplayItems.first else { return }
        if hasRequestedPlayback == false, player.currentItem == nil {
            hasRequestedPlayback = true
            player.play(item: firstItem, in: autoplayItems)
        }
        do {
            while Task.isCancelled == false {
                print("DuoPlaybackMetrics \(playbackMetrics(for: player))")
                fflush(nil)
                try await Task.sleep(for: .seconds(1))
            }
        } catch { return }
    }

    private func metrics(for geometry: GeometryProxy) -> String {
        let inset = geometry.safeAreaInsets
        var values: [String: Any] = [
            "layout": layoutName,
            "width": geometry.size.width,
            "height": geometry.size.height,
            "displayScale": displayScale,
            "portrait": geometry.size.height > geometry.size.width,
            "horizontalSizeClass": sizeClassName(horizontalSizeClass),
            "verticalSizeClass": sizeClassName(verticalSizeClass),
            "safeArea": [
                "top": inset.top, "leading": inset.leading,
                "bottom": inset.bottom, "trailing": inset.trailing
            ]
        ]
        if #available(iOS 27.1, *) {
            values["division"] = regions(in: geometry, kind: .division)
            values["occlusion"] = regions(in: geometry, kind: .occlusion)
            values["hasActiveDivision"] = geometry.reservedRegions(kind: .division).contains { $0.isActive }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "unavailable" }
        return value
    }

    private func safeAreaMetrics(for geometry: GeometryProxy) -> String {
        let inset = geometry.safeAreaInsets
        return "width=\(geometry.size.width) height=\(geometry.size.height) "
            + "top=\(inset.top) leading=\(inset.leading) bottom=\(inset.bottom) trailing=\(inset.trailing)"
    }

    private func playbackMetrics(for player: PlayerViewModel) -> String {
        let values: [String: Any] = [
            "itemID": player.currentItem?.id.uuidString ?? "",
            "generation": player.playbackGeneration,
            "title": player.currentItem?.title ?? "",
            "time": player.currentTime,
            "playing": player.isPlaying,
            "paused": player.isPaused,
            "volume": player.volume,
            "muted": player.isMuted,
            "pitch": player.pitchSemitones,
            "rate": player.playbackRate,
            "rmsL": player.audioFrame.rmsL,
            "rmsR": player.audioFrame.rmsR,
            "queueIDs": player.queue.map { $0.id.uuidString }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "unavailable" }
        return value
    }

    @available(iOS 27.1, *)
    private func regions(in geometry: GeometryProxy, kind: ReservedRegion.Kind) -> [[String: Any]] {
        geometry.reservedRegions(kind: kind, options: [.includeInactive]).map { region in
            let frame = region.frame
            let margin = region.margins
            return [
                "active": region.isActive,
                "x": frame.minX, "y": frame.minY,
                "width": frame.width, "height": frame.height,
                "margins": [
                    "top": margin.top, "leading": margin.leading,
                    "bottom": margin.bottom, "trailing": margin.trailing
                ]
            ]
        }
    }

    private func sizeClassName(_ sizeClass: UserInterfaceSizeClass?) -> String {
        switch sizeClass {
        case .compact: "compact"
        case .regular: "regular"
        case nil: "unspecified"
        @unknown default: "unknown"
        }
    }
}
#endif

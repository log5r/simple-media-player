import SwiftUI

struct TransportButtonsView: View {
    let player: PlayerViewModel
    let selectedItem: MediaItem?
    let queue: [MediaItem]
    let palette: BottomPanelPalette
    let height: CGFloat
    let playItem: (MediaItem) -> Void

    @State private var flashPrevious = false
    @State private var flashNext = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        player: PlayerViewModel,
        selectedItem: MediaItem?,
        queue: [MediaItem],
        palette: BottomPanelPalette,
        height: CGFloat = BottomPanelMetrics.controlHeight,
        playItem: @escaping (MediaItem) -> Void
    ) {
        self.player = player
        self.selectedItem = selectedItem
        self.queue = queue
        self.palette = palette
        self.height = height
        self.playItem = playItem
    }

    private var isPaused: Bool {
        player.currentItem != nil && player.isPlaying == false && player.currentTime > 0
    }

    var body: some View {
        HStack(spacing: 0) {
            transportButton(
                identifier: "previousTrackButton",
                label: "Previous Track",
                systemName: "backward.end.alt.fill",
                active: flashPrevious,
                isEnabled: canSkipToPrevious
            ) {
                flashPrevious = true
                skipToPrevious()
                clearFlashPrevious()
            }
            Divider().background(palette.buttonDivider)
            transportButton(
                identifier: "playButton",
                label: "Play",
                systemName: "play.fill",
                active: player.isPlaying,
                isEnabled: canPlay
            ) {
                play()
            }
            Divider().background(palette.buttonDivider)
            transportButton(
                identifier: "pauseButton",
                label: "Pause",
                systemName: "pause.fill",
                active: isPaused,
                isEnabled: player.currentItem != nil
            ) {
                player.pause()
            }
            Divider().background(palette.buttonDivider)
            transportButton(
                identifier: "stopButton",
                label: "Stop",
                systemName: "stop.fill",
                active: player.isPlaying == false && player.currentTime == 0,
                isEnabled: player.canStop
            ) {
                player.stop()
            }
            Divider().background(palette.buttonDivider)
            transportButton(
                identifier: "nextTrackButton",
                label: "Next Track",
                systemName: "forward.end.alt.fill",
                active: flashNext,
                isEnabled: canSkipToNext
            ) {
                flashNext = true
                skipToNext()
                clearFlashNext()
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.controlStroke, lineWidth: 1))
        .shadow(color: palette.buttonShadow, radius: 2, y: 1)
        #if os(macOS)
        .focusable()
        .onKeyPress(.space) {
            guard canPlay || player.canPause else { return .ignored }
            if player.canPause {
                player.pause()
            } else {
                play()
            }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard canSkipToPrevious else { return .ignored }
            skipToPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard canSkipToNext else { return .ignored }
            skipToNext()
            return .handled
        }
        #endif
    }

    private var canPlay: Bool {
        player.currentItem != nil || selectedItem != nil
    }

    private var canSkipToNext: Bool {
        if player.currentItem != nil {
            return player.canSkipToNext
        }
        return adjacentSelectedItem(offset: 1) != nil
    }

    private var canSkipToPrevious: Bool {
        if player.currentItem != nil {
            return player.canSkipToPrevious
        }
        return adjacentSelectedItem(offset: -1) != nil
    }

    private func play() {
        if let selectedItem, player.currentItem?.id != selectedItem.id {
            playItem(selectedItem)
        } else {
            player.resume()
        }
    }

    private func skipToNext() {
        if player.currentItem != nil {
            player.next()
        } else if let item = adjacentSelectedItem(offset: 1) {
            playItem(item)
        }
    }

    private func skipToPrevious() {
        if player.currentItem != nil {
            player.previous()
        } else if let item = adjacentSelectedItem(offset: -1) {
            playItem(item)
        }
    }

    private func adjacentSelectedItem(offset: Int) -> MediaItem? {
        guard let selectedItem, let index = queue.firstIndex(where: { $0.id == selectedItem.id }) else {
            return nil
        }
        let targetIndex = index + offset
        guard queue.indices.contains(targetIndex) else { return nil }
        return queue[targetIndex]
    }

    private func transportButton(
        identifier: String,
        label: LocalizedStringKey,
        systemName: String,
        active: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Rectangle()
                    .fill(buttonFill(active: active, isEnabled: isEnabled))
                    .shadow(color: active ? palette.activeButtonShadow : .clear, radius: 9)
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor(active: active, isEnabled: isEnabled))
                    .shadow(color: active ? palette.activeIconShadow : .clear, radius: 3)
            }
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .help(label)
        .zIndex(active ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: active)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isEnabled)
    }

    private func iconColor(active: Bool, isEnabled: Bool) -> Color {
        guard isEnabled else { return palette.disabledIcon }
        return active ? palette.activeIcon : palette.enabledIcon
    }

    private func buttonFill(active: Bool, isEnabled: Bool) -> AnyShapeStyle {
        if isEnabled == false {
            return AnyShapeStyle(palette.disabledButtonFill)
        }

        if active {
            return AnyShapeStyle(palette.activeButtonFill)
        } else {
            return AnyShapeStyle(palette.normalButtonFill)
        }
    }

    private func clearFlashPrevious() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            flashPrevious = false
        }
    }

    private func clearFlashNext() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            flashNext = false
        }
    }
}

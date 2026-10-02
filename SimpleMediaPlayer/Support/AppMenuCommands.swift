import SwiftUI

struct AppMenuAction {
    let isEnabled: Bool
    private let perform: @MainActor () -> Void

    init(isEnabled: Bool = true, perform: @escaping @MainActor () -> Void) {
        self.isEnabled = isEnabled
        self.perform = perform
    }

    @MainActor
    func callAsFunction() {
        guard isEnabled else { return }
        perform()
    }
}

struct AppMenuActions {
    let showSettings: AppMenuAction
    let exportToFinder: AppMenuAction
    let saveAdjustedCopy: AppMenuAction
    let createPlaylist: AppMenuAction
    let addTracksToPlaylist: AppMenuAction
    let beginMultipleEdit: AppMenuAction
    let editSelectedMedia: AppMenuAction
    let cancelMultipleEdit: AppMenuAction
    let toggleLyrics: AppMenuAction
    let toggleEqualizer: AppMenuAction
    let toggleVideoArea: AppMenuAction
    let playPause: AppMenuAction
    let previousTrack: AppMenuAction
    let nextTrack: AppMenuAction

    let lyricsAreVisible: Bool
    let equalizerIsVisible: Bool
    let videoAreaIsVisible: Bool
}

private struct AppMenuActionsKey: FocusedValueKey {
    typealias Value = AppMenuActions
}

extension FocusedValues {
    var appMenuActions: AppMenuActions? {
        get { self[AppMenuActionsKey.self] }
        set { self[AppMenuActionsKey.self] = newValue }
    }
}

struct AppMenuCommands: Commands {
    let player: PlayerViewModel

    @FocusedValue(\.appMenuActions) private var actions

    private var usesPhonePlayback: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    var body: some Commands {
        #if os(macOS)
        CommandGroup(replacing: .appSettings) {
            Button("Settings") {
                actions?.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(actions?.showSettings.isEnabled != true)
        }
        #endif

        CommandGroup(after: .newItem) {
            Divider()

            Button("Export to Finder") {
                actions?.exportToFinder()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(actions?.exportToFinder.isEnabled != true)

            Button("Save adjusted copy") {
                actions?.saveAdjustedCopy()
            }
            .disabled(actions?.saveAdjustedCopy.isEnabled != true)
        }

        CommandMenu("Library") {
            Button("New Playlist") {
                actions?.createPlaylist()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(actions?.createPlaylist.isEnabled != true)

            Button("Add Tracks") {
                actions?.addTracksToPlaylist()
            }
            .disabled(actions?.addTracksToPlaylist.isEnabled != true)

            Divider()

            Button("Multiple Edit") {
                actions?.beginMultipleEdit()
            }
            .disabled(actions?.beginMultipleEdit.isEnabled != true)

            Button("Edit Selected") {
                actions?.editSelectedMedia()
            }
            .disabled(actions?.editSelectedMedia.isEnabled != true)

            Button("Cancel Multiple Edit") {
                actions?.cancelMultipleEdit()
            }
            .disabled(actions?.cancelMultipleEdit.isEnabled != true)
        }

        CommandMenu("Controls") {
            Button(player.isPlaying ? L10n.string("Pause") : L10n.string("Play")) {
                if let actions {
                    actions.playPause()
                } else if usesPhonePlayback {
                    player.togglePlayPause()
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!(actions?.playPause.isEnabled ?? (usesPhonePlayback && player.currentItem != nil)))

            Button("Stop") {
                player.stop()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(player.canStop == false)

            Divider()

            Button("Previous Track") {
                if let actions {
                    actions.previousTrack()
                } else if usesPhonePlayback {
                    player.previous()
                }
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(!(actions?.previousTrack.isEnabled ?? (
                usesPhonePlayback && (player.canSkipToPrevious || player.currentTime >= 3)
            )))

            Button("Next Track") {
                if let actions {
                    actions.nextTrack()
                } else if usesPhonePlayback {
                    player.next()
                }
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(!(actions?.nextTrack.isEnabled ?? (usesPhonePlayback && player.canSkipToNext)))

            Button("Skip Back 10 Seconds") {
                player.seek(to: player.currentTime - 10)
            }
            .keyboardShortcut(.leftArrow, modifiers: .option)
            .disabled(player.currentItem == nil)

            Button("Skip Forward 10 Seconds") {
                player.seek(to: player.currentTime + 10)
            }
            .keyboardShortcut(.rightArrow, modifiers: .option)
            .disabled(player.currentItem == nil)

            Divider()

            Menu("Key") {
                Button("Key Up") {
                    player.setPitchSemitones(player.pitchSemitones + 1)
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(
                    adjustmentsAreEnabled == false ||
                        player.pitchSemitones >= PlayerViewModel.pitchSemitoneRange.upperBound
                )

                Button("Key Down") {
                    player.setPitchSemitones(player.pitchSemitones - 1)
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(
                    adjustmentsAreEnabled == false ||
                        player.pitchSemitones <= PlayerViewModel.pitchSemitoneRange.lowerBound
                )

                Button("Reset Key") {
                    player.setPitchSemitones(0)
                }
                .disabled(adjustmentsAreEnabled == false || player.pitchSemitones == 0)
            }

            Menu("Speed") {
                Button("Faster") {
                    player.setPlaybackRate(player.playbackRate + PlayerViewModel.playbackRateStep)
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(
                    adjustmentsAreEnabled == false ||
                        player.playbackRate >= PlayerViewModel.playbackRateRange.upperBound
                )

                Button("Slower") {
                    player.setPlaybackRate(player.playbackRate - PlayerViewModel.playbackRateStep)
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(
                    adjustmentsAreEnabled == false ||
                        player.playbackRate <= PlayerViewModel.playbackRateRange.lowerBound
                )

                Button("Normal Speed") {
                    player.setPlaybackRate(1)
                }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(adjustmentsAreEnabled == false || abs(player.playbackRate - 1) <= 0.001)
            }

            Button("Reset Key and Speed") {
                player.resetPitchAndRate()
            }
            .disabled(adjustmentsAreEnabled == false || player.hasPitchOrRateAdjustment == false)

            // 速度変更を繰り返した際の周波数欠落バグの切り分け用。エンジンが
            // おかしくなった時にいつでも叩けるよう常に有効にしておく
            Button("Reset Audio Engine") {
                player.resetAudioEngine()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])

            Divider()

            Button(player.isMuted ? L10n.string("Unmute") : L10n.string("Mute")) {
                player.toggleMuted()
            }
            .keyboardShortcut("m", modifiers: .command)

            Button("Volume Up") {
                player.setVolume(player.volume + 0.1)
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(player.volume >= 1)

            Button("Volume Down") {
                player.setVolume(player.volume - 0.1)
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(player.volume <= 0)
        }

        CommandGroup(after: .toolbar) {
            Button(actions?.lyricsAreVisible == true ? L10n.string("Hide Details") : L10n.string("Show Details")) {
                actions?.toggleLyrics()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(actions?.toggleLyrics.isEnabled != true)

            Button(
                actions?.equalizerIsVisible == true ? L10n.string("Hide Equalizer") : L10n.string("Show Equalizer")
            ) {
                actions?.toggleEqualizer()
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(actions?.toggleEqualizer.isEnabled != true)

            Button(actions?.videoAreaIsVisible == true ? L10n.string("Back to List") : L10n.string("Show Video")) {
                actions?.toggleVideoArea()
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
            .disabled(actions?.toggleVideoArea.isEnabled != true)
        }
    }

    private var adjustmentsAreEnabled: Bool {
        player.isVideoMode == false
    }
}

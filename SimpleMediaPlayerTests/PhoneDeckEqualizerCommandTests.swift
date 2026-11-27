#if os(iOS)
import Foundation
import SwiftUI
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct PhoneDeckEqualizerCommandTests {
    @Test(arguments: [false, true], [false, true])
    func deckCommandTakesPriorityOverTheLibraryAndItsVisibility(
        _ libraryIsVisible: Bool, _ deckIsVisible: Bool
    ) throws {
        let state = LibraryBrowsingState()
        state.showsEqualizer = libraryIsVisible
        state.showsDeckEqualizer = deckIsVisible
        let context = makeContext(state: state, presentation: DeckPresentation())
        let library = libraryActions(state: state)
        let command = try #require(EqualizerMenuCommand.current(deck: context.command, library: library))

        #expect(command.isVisible == deckIsVisible)
        #expect(command.toggle.isEnabled)
        command.toggle()

        #expect(state.showsDeckEqualizer == !deckIsVisible)
        #expect(state.showsEqualizer == libraryIsVisible)
        #expect(context.command?.isVisible == !deckIsVisible)
    }

    @Test(arguments: [false, true])
    func deckCommandStillWorksWhenTheExpandedPortraitLayoutHasNoLibraryProvider(
        _ inlinePreference: Bool
    ) throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: AppSettingsKey.showEqualizerPanel)
        defaults.set(inlinePreference, forKey: AppSettingsKey.showEqualizerPanel)
        defer { defaults.set(original, forKey: AppSettingsKey.showEqualizerPanel) }
        let state = LibraryBrowsingState()
        state.showsEqualizer = true
        let context = makeContext(state: state, presentation: DeckPresentation())

        let hidden = try #require(EqualizerMenuCommand.current(deck: context.command, library: nil))
        #expect(!hidden.isVisible)
        hidden.toggle()
        let shown = try #require(EqualizerMenuCommand.current(deck: context.command, library: nil))
        #expect(shown.isVisible)
        shown.toggle()

        #expect(!state.showsDeckEqualizer)
        #expect(state.showsEqualizer)
        #expect(defaults.bool(forKey: AppSettingsKey.showEqualizerPanel) == inlinePreference)
    }

    @Test func dismissingTheDeckRestoresTheLibraryCommandAndItsVisibility() throws {
        let state = LibraryBrowsingState()
        state.showsEqualizer = true
        let presentation = DeckPresentation()
        let context = makeContext(state: state, presentation: presentation)
        let library = libraryActions(state: state)
        let oldDeckCommand = try #require(context.command)
        #expect(!oldDeckCommand.isVisible)

        presentation.isPresented = false
        #expect(context.command == nil)
        let restored = try #require(EqualizerMenuCommand.current(deck: context.command, library: library))
        #expect(restored.isVisible)
        restored.toggle()

        #expect(!state.showsEqualizer)
        #expect(!state.showsDeckEqualizer)
        #expect(EqualizerMenuCommand.current(deck: context.command, library: nil) == nil)
    }

    @Test(arguments: [false, true])
    func aDeckCommandCapturedBeforeDismissalCannotChangeEitherPresentation(_ deckIsVisible: Bool) throws {
        let state = LibraryBrowsingState()
        state.showsEqualizer = true
        state.showsDeckEqualizer = deckIsVisible
        let presentation = DeckPresentation()
        let context = makeContext(state: state, presentation: presentation)
        let captured = try #require(context.command)

        presentation.isPresented = false
        captured.toggle()

        #expect(state.showsEqualizer)
        #expect(state.showsDeckEqualizer == deckIsVisible)
    }

    @Test(arguments: [false, true])
    func presentationChangesDisableNewCommandsAndInvalidateCapturedCommands(_ fullScreenVideo: Bool) throws {
        let state = LibraryBrowsingState()
        let context = makeContext(state: state, presentation: DeckPresentation())
        let captured = try #require(context.command)
        #expect(captured.toggle.isEnabled)
        if fullScreenVideo {
            state.showsVideoFullScreen = true
        } else {
            state.isBulkEditMode = true
        }
        let blocked = try #require(context.command)
        let resolved = try #require(EqualizerMenuCommand.current(deck: blocked, library: libraryActions(state: state)))

        #expect(!blocked.toggle.isEnabled)
        #expect(!resolved.toggle.isEnabled)
        blocked.toggle()
        resolved.toggle()
        captured.toggle()

        #expect(!state.showsDeckEqualizer)
        #expect(!state.showsEqualizer)
        state.showsVideoFullScreen = false
        state.isBulkEditMode = false
        let available = try #require(context.command)
        #expect(available.toggle.isEnabled)
        available.toggle()
        #expect(state.showsDeckEqualizer)
    }

    private func makeContext(
        state: LibraryBrowsingState, presentation: DeckPresentation
    ) -> PhoneDeckEqualizerCommandContext {
        PhoneDeckEqualizerCommandContext(
            browsingState: state,
            showsDeck: Binding(get: { presentation.isPresented }, set: { presentation.isPresented = $0 })
        )
    }

    /// An expanded library provider deliberately has a different target from the deck override.
    private func libraryActions(state: LibraryBrowsingState) -> AppMenuActions {
        let unused = AppMenuAction(isEnabled: false) {}
        return AppMenuActions(
            showSettings: unused, exportToFinder: unused, saveAdjustedCopy: unused,
            createPlaylist: unused, addTracksToPlaylist: unused, beginMultipleEdit: unused,
            editSelectedMedia: unused, cancelMultipleEdit: unused, toggleLyrics: unused,
            toggleEqualizer: AppMenuAction { state.showsEqualizer.toggle() },
            toggleVideoArea: unused, playPause: unused, previousTrack: unused, nextTrack: unused,
            lyricsAreVisible: false, equalizerIsVisible: state.showsEqualizer, videoAreaIsVisible: false
        )
    }
}

@MainActor
private final class DeckPresentation {
    var isPresented = true
}
#endif

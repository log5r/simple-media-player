import SwiftUI

/// The visible presentation can override the library's equalizer command without replacing its other commands.
struct EqualizerMenuCommand {
    let toggle: AppMenuAction
    let isVisible: Bool

    static func current(deck: Self?, library: AppMenuActions?) -> Self? {
        deck ?? library.map { Self(toggle: $0.toggleEqualizer, isVisible: $0.equalizerIsVisible) }
    }
}

private struct DeckEqualizerCommandKey: FocusedValueKey {
    typealias Value = EqualizerMenuCommand
}

extension FocusedValues {
    var deckEqualizerCommand: EqualizerMenuCommand? {
        get { self[DeckEqualizerCommandKey.self] }
        set { self[DeckEqualizerCommandKey.self] = newValue }
    }
}

#if os(iOS)
@MainActor
struct PhoneDeckEqualizerCommandContext {
    let browsingState: LibraryBrowsingState
    let showsDeck: Binding<Bool>

    var command: EqualizerMenuCommand? {
        guard showsDeck.wrappedValue else { return nil }
        return EqualizerMenuCommand(
            toggle: AppMenuAction(isEnabled: canToggle) {
                // A command captured before dismissal must never change a later library presentation.
                guard showsDeck.wrappedValue, canToggle else { return }
                browsingState.showsDeckEqualizer.toggle()
            },
            isVisible: browsingState.showsDeckEqualizer
        )
    }

    private var canToggle: Bool {
        !browsingState.isBulkEditMode && !browsingState.showsVideoFullScreen
    }
}
#endif

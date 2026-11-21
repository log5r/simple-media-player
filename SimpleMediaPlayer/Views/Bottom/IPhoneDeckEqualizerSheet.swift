#if os(iOS)
import SwiftUI

/// The deck's equalizer sheet. Its state lives in the scene so the keyboard command can open it over the deck.
struct IPhoneDeckEqualizerSheet: ViewModifier {
    @Binding var isPresented: Bool
    let player: PlayerViewModel
    /// Another deck presentation is active, so the sheet cannot be presented now.
    let isBlocked: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                NavigationStack {
                    ScrollView { EqualizerPanelView(player: player) }
                        .navigationTitle("Equalizer")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Close") { isPresented = false }
                            }
                        }
                        .disablesVerticalToolbar()
                }
            }
            // A request that cannot be presented is dropped, so it never appears later or reads as shown.
            .onChange(of: isPresented) { _, requested in
                if requested && isBlocked { isPresented = false }
            }
    }
}
#endif

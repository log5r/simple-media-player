#if os(macOS)
import SwiftUI

struct FocusOnTapModifier: ViewModifier {
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        // List and Table can update selection through a click without moving keyboard focus.
        content
            .focused($isFocused)
            .simultaneousGesture(
                TapGesture().onEnded {
                    isFocused = true
                }
            )
    }
}
#endif

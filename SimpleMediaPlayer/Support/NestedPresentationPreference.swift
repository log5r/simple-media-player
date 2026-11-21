import SwiftUI

/// A view reports a modal presentation of its own so an ancestor does not try to present over it.
/// The phone deck reads this before presenting its equalizer sheet for a keyboard command.
nonisolated struct NestedPresentationPreferenceKey: PreferenceKey {
    static var defaultValue: Bool { false }

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    func reportsNestedPresentation(_ isPresented: Bool) -> some View {
        preference(key: NestedPresentationPreferenceKey.self, value: isPresented)
    }
}

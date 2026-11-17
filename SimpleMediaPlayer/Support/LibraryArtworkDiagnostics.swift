#if DEBUG
import SwiftUI

/// macOS exposes each album grid button as one element with its own identifier, which hides the child
/// `libraryArtworkImage` from UI tests. The grid instead reports how many of its artwork views loaded an image.
enum LibraryArtworkDiagnostics {
    nonisolated struct LoadedCount: PreferenceKey {
        static let defaultValue = 0

        static func reduce(value: inout Int, nextValue: () -> Int) {
            value += nextValue()
        }
    }

    struct Report: ViewModifier {
        let identifier: String

        func body(content: Content) -> some View {
            content.overlayPreferenceValue(LoadedCount.self, alignment: .topLeading) { count in
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-artwork") {
                    // macOS exposes the value only on the plain static text, not on a wrapping element.
                    // A clear color keeps the text accessible, unlike zero opacity or hidden().
                    Text("Artwork diagnostics")
                        .foregroundStyle(.clear)
                        .accessibilityIdentifier(identifier)
                        .accessibilityValue("\(count)")
                        .allowsHitTesting(false)
                }
            }
        }
    }
}
#endif

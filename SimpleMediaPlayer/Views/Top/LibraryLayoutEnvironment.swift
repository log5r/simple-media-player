import SwiftUI

extension EnvironmentValues {
    @Entry var usesPhoneLayout = false
    #if os(iOS)
    @Entry var usesTouchControls = true
    #else
    @Entry var usesTouchControls = false
    #endif
}

extension View {
    func platformEditorFrame(width: CGFloat, height: CGFloat? = nil) -> some View {
        #if os(iOS)
        frame(maxWidth: width, maxHeight: height)
        #else
        frame(width: width, height: height)
        #endif
    }
}

enum EditorLayoutMetrics {
    #if os(iOS)
    static let minimumScrollHeight: CGFloat = 0
    #else
    static let minimumScrollHeight: CGFloat = 420
    #endif
}

import SwiftUI

extension ToolbarContent {
    @ToolbarContentBuilder
    func prefersVerticalToolbarPlacement() -> some ToolbarContent {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            self.axisBehavior(.verticalPreferred)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension View {
    /// Single-item sheets keep the horizontal bar so a lone Close button doesn't take a full-height column
    /// on the narrow outer screen.
    @ViewBuilder
    func disablesVerticalToolbar() -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            toolbarVerticalBehavior(.disabled)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

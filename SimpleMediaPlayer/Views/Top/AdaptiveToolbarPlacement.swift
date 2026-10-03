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

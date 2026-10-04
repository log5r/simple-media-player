import SwiftUI

enum LibraryLayoutPolicy {
    static func usesCompactLayout(horizontalSizeClass: UserInterfaceSizeClass?, width: CGFloat) -> Bool {
        if let horizontalSizeClass { return horizontalSizeClass == .compact }
        return width < 600
    }

    static func showsInlineDetails(size: CGSize, accessibilityText: Bool) -> Bool {
        !accessibilityText && size.width >= 620 && size.height >= 300
    }

    static func showsInlineEqualizer(size: CGSize, accessibilityText: Bool) -> Bool {
        !accessibilityText && size.height >= 430
    }
}

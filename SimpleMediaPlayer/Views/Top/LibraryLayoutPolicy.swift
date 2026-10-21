import SwiftUI

enum LibraryLayoutPolicy {
    /// iOS shows Lyrics and Info in a fixed-width column beside the list.
    static let inlineDetailsWidth: CGFloat = 240
    /// Keeps No., Artwork, Title, and the start of Artist visible beside the details column.
    /// iPhone Duo's Open portrait leaves only 429pt, so its details open in a sheet instead.
    static let minimumListWidthBesideDetails: CGFloat = 480

    static func usesCompactLayout(horizontalSizeClass: UserInterfaceSizeClass?, width: CGFloat) -> Bool {
        if let horizontalSizeClass { return horizontalSizeClass == .compact }
        return width < 600
    }

    static func showsInlineDetails(size: CGSize, accessibilityText: Bool) -> Bool {
        !accessibilityText && size.width - inlineDetailsWidth >= minimumListWidthBesideDetails
            && size.height >= 300
    }

    static func showsInlineEqualizer(size: CGSize, accessibilityText: Bool) -> Bool {
        !accessibilityText && size.height >= 430
    }
}

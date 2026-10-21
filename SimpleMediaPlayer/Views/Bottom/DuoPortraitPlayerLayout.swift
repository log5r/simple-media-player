import CoreGraphics

/// Use the current display's division capability, rather than an iPhone model or pixel dimensions.
enum DuoPortraitPlayerLayout {
    /// Below this height, the Library's navigation bar, rows, and Close button do not fit under the fold.
    static let minimumFoldedLibraryHeight: CGFloat = 280

    static func isPreferred(size: CGSize, compact: Bool, hasDisplayDivision: Bool) -> Bool {
        !compact && hasDisplayDivision && size.height > size.width
    }

    /// The lower edge of an active fold that divides the view into upper and lower parts.
    static func foldBottom(in bounds: CGRect, divisionFrames: [CGRect]) -> CGFloat? {
        divisionFrames
            .filter { $0.width > $0.height && $0.intersects(bounds) }
            .map(\.maxY)
            .max()
    }

    /// Place the Library below the fold so the visuals stay above it; the keyboard can leave too little room there.
    static func libraryTop(in bounds: CGRect, foldBottom: CGFloat?) -> CGFloat? {
        guard let foldBottom, bounds.maxY - foldBottom >= minimumFoldedLibraryHeight else { return nil }
        return max(0, foldBottom - bounds.minY)
    }
}

struct DuoPortraitPlayerPlacement: Equatable {
    let visuals: CGRect
    let controls: CGRect
    let meters: CGRect
    let led: CGRect

    /// Keep the portrait player continuous across the fold; only occlusions reserve space.
    /// With `controlsHeight`, the controls keep only that much of the lower half and the LED and meters take the rest.
    static func make(in bounds: CGRect, occlusionFrames: [CGRect], controlsHeight: CGFloat? = nil) -> Self {
        let halfHeight = bounds.height - bounds.height / 2
        let lowerHeight = controlsHeight.map { min(halfHeight, max(0, $0)) } ?? halfHeight
        let upper = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                           height: bounds.height - lowerHeight)
        let lower = CGRect(x: bounds.minX, y: upper.maxY, width: bounds.width, height: lowerHeight)
        let visuals = safeFrame(in: upper, avoiding: occlusionFrames)
        let controls = safeFrame(in: lower, avoiding: occlusionFrames)
        let ledHeight = visuals.height / 2
        return Self(
            visuals: visuals, controls: controls,
            meters: CGRect(x: visuals.minX, y: visuals.minY + ledHeight,
                           width: visuals.width, height: visuals.height - ledHeight),
            led: CGRect(x: visuals.minX, y: visuals.minY, width: visuals.width, height: ledHeight)
        )
    }

    private static func safeFrame(in bounds: CGRect, avoiding frames: [CGRect]) -> CGRect {
        DeckSafeRegions.frames(in: bounds, avoiding: frames)
            .max { $0.width * $0.height < $1.width * $1.height } ?? .zero
    }
}

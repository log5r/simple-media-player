import CoreGraphics

/// Use the current display's division capability, rather than an iPhone model or pixel dimensions.
enum DuoPortraitPlayerLayout {
    static func isPreferred(size: CGSize, compact: Bool, hasDisplayDivision: Bool) -> Bool {
        !compact && hasDisplayDivision && size.height > size.width
    }
}

struct DuoPortraitPlayerPlacement: Equatable {
    let visuals: CGRect
    let controls: CGRect
    let meters: CGRect
    let led: CGRect

    /// Keep the portrait player continuous across the fold; only occlusions reserve space.
    static func make(in bounds: CGRect, occlusionFrames: [CGRect]) -> Self {
        let upper = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                           height: bounds.height / 2)
        let lower = CGRect(x: bounds.minX, y: bounds.midY, width: bounds.width,
                           height: bounds.height - upper.height)
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

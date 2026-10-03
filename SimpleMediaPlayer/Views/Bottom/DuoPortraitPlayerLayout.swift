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

    static func make(in bounds: CGRect, divisionFrames: [CGRect], reservedFrames: [CGRect]) -> Self {
        let horizontalDivision = divisionFrames
            .map { $0.intersection(bounds) }
            .filter { !$0.isNull && !$0.isEmpty && $0.width > $0.height && $0.width >= bounds.width * 0.5 }
            .min { abs($0.midY - bounds.midY) < abs($1.midY - bounds.midY) }
        let upperEnd = horizontalDivision?.minY ?? bounds.midY
        let lowerStart = horizontalDivision?.maxY ?? bounds.midY
        let upper = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                           height: max(0, upperEnd - bounds.minY))
        let lower = CGRect(x: bounds.minX, y: lowerStart, width: bounds.width,
                           height: max(0, bounds.maxY - lowerStart))
        let visuals = safeFrame(in: upper, avoiding: reservedFrames)
        let controls = safeFrame(in: lower, avoiding: reservedFrames)
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

import CoreGraphics

enum FullScreenVideoLayout {
    /// Active divisions include their margins and use the video's local coordinates.
    static func videoFrame(in bounds: CGRect, activeDivisionFrames: [CGRect]) -> CGRect {
        guard let division = portraitDivision(in: bounds, activeDivisionFrames: activeDivisionFrames) else {
            return bounds
        }
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                      height: division.minY - bounds.minY)
    }

    /// Keep playback and close controls below the fold, outside the upper video area.
    static func controlsFrame(in bounds: CGRect, activeDivisionFrames: [CGRect]) -> CGRect {
        guard let division = portraitDivision(in: bounds, activeDivisionFrames: activeDivisionFrames) else {
            return bounds
        }
        return CGRect(x: bounds.minX, y: division.maxY, width: bounds.width,
                      height: bounds.maxY - division.maxY)
    }

    private static func portraitDivision(in bounds: CGRect, activeDivisionFrames: [CGRect]) -> CGRect? {
        guard bounds.height > bounds.width else { return nil }
        let divisions = activeDivisionFrames.map { bounds.intersection($0) }.filter {
            !$0.isNull && !$0.isEmpty && $0.minX == bounds.minX && $0.maxX == bounds.maxX
                && $0.minY > bounds.minY && $0.maxY < bounds.maxY
        }
        return divisions.min(by: { $0.minY < $1.minY })
    }
}

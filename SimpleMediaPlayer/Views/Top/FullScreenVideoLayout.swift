import CoreGraphics

enum FullScreenVideoLayout {
    /// Active divisions include their margins and use the video's local coordinates.
    static func videoFrame(in bounds: CGRect, activeDivisionFrames: [CGRect]) -> CGRect {
        guard bounds.height > bounds.width else { return bounds }
        let divisions = activeDivisionFrames.map { bounds.intersection($0) }.filter {
            !$0.isNull && !$0.isEmpty && $0.minX == bounds.minX && $0.maxX == bounds.maxX
                && $0.minY > bounds.minY && $0.maxY < bounds.maxY
        }
        guard let division = divisions.min(by: { $0.minY < $1.minY }) else { return bounds }
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width,
                      height: division.minY - bounds.minY)
    }
}

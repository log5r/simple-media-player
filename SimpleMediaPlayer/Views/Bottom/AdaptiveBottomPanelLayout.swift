import CoreGraphics

/// Minimum sizes come from the controls' touch targets, not a device model or display resolution.
enum AdaptiveBottomPanelMetrics {
    static let minimumControlWidth: CGFloat = 332
    static let inlineControlWidth: CGFloat = 526
    static let minimumLEDWidth: CGFloat = 300
    static let minimumTransportWidth: CGFloat = 224
    static let combinedButtonsWidth: CGFloat = 382
    static let classicLEDHeight: CGFloat = 117
    static let compactControlsHeight: CGFloat = 112
    static let compactMeterHeight: CGFloat = 96
    static let compactSpacing: CGFloat = 8

    static func controlHeight(
        width: CGFloat, layout: BottomPanelLayout, showsMeters: Bool = true, showsOutputControls: Bool = false
    ) -> CGFloat {
        if layout == .classic { return width >= inlineControlWidth ? 164 : 128 }
        let outputHeight: CGFloat = showsOutputControls && width < combinedButtonsWidth ? 44 + compactSpacing : 0
        return compactControlsHeight + (showsMeters ? compactMeterHeight + compactSpacing : 0) + outputHeight
    }

    static func height(
        width: CGFloat, layout: BottomPanelLayout, dividedControlWidth: CGFloat? = nil,
        showsOutputControls: Bool = false
    ) -> CGFloat {
        let normalHeight = normalHeight(width: width, layout: layout, showsOutputControls: showsOutputControls)
        guard let dividedControlWidth else { return normalHeight }
        return max(normalHeight, controlHeight(
            width: dividedControlWidth, layout: layout, showsOutputControls: showsOutputControls
        ))
    }

    private static func normalHeight(
        width: CGFloat, layout: BottomPanelLayout, showsOutputControls: Bool
    ) -> CGFloat {
        if layout == .classic { return classicLEDHeight + controlHeight(width: width, layout: layout) }
        guard width >= minimumSplitWidth else {
            return 153 + controlHeight(width: width, layout: layout, showsOutputControls: showsOutputControls)
        }
        return controlHeight(width: width / 2, layout: layout, showsOutputControls: showsOutputControls)
    }

    static var minimumSplitWidth: CGFloat { max(minimumControlWidth, minimumLEDWidth) * 2 }
}

struct AdaptiveBottomPanelPlacement: Equatable {
    let controls: CGRect
    let display: CGRect

    /// A full-height vertical division changes the control width independently of the deck's height.
    func controlWidthForVerticalDivision(in bounds: CGRect, divisionFrames: [CGRect]) -> CGFloat? {
        let hasVerticalDivision = divisionFrames.contains { frame in
            let intersection = frame.intersection(bounds)
            return frame.height > frame.width && frame.minY <= bounds.minY && frame.maxY >= bounds.maxY &&
                !intersection.isNull && !intersection.isEmpty
        }
        return hasVerticalDivision ? controls.width : nil
    }

    static func make(
        in bounds: CGRect,
        avoiding reservedFrames: [CGRect],
        side: LEDPanelSide,
        layout: BottomPanelLayout
    ) -> Self {
        let regions = DeckSafeRegions.frames(in: bounds, avoiding: reservedFrames)
        let candidates = regions.filter { $0.width >= 224 && $0.height >= 80 }
            .sorted { $0.width * $0.height > $1.width * $1.height }
        if candidates.count >= 2 {
            let pair = Array(candidates.prefix(2)).sorted {
                abs($0.minY - $1.minY) > 1 ? $0.minY < $1.minY : $0.minX < $1.minX
            }
            let isVertical = abs(pair[0].midY - pair[1].midY) > abs(pair[0].midX - pair[1].midX)
            let displayFirst = isVertical || side == .left
            return Self(controls: pair[displayFirst ? 1 : 0], display: pair[displayFirst ? 0 : 1])
        }
        let region = candidates.first ?? regions.max { $0.width * $0.height < $1.width * $1.height } ?? .zero
        if layout == .classic || region.width < AdaptiveBottomPanelMetrics.minimumSplitWidth {
            let displayHeight = min(layout == .classic ? AdaptiveBottomPanelMetrics.classicLEDHeight : 153,
                                    region.height * 0.5)
            return Self(
                controls: CGRect(x: region.minX, y: region.minY + displayHeight,
                                 width: region.width, height: max(0, region.height - displayHeight)),
                display: CGRect(x: region.minX, y: region.minY, width: region.width, height: displayHeight)
            )
        }
        let controlWidth = region.width / 2
        let displayWidth = controlWidth
        return Self(
            controls: CGRect(x: side == .left ? region.minX + displayWidth : region.minX,
                             y: region.minY, width: controlWidth, height: region.height),
            display: CGRect(x: side == .left ? region.minX : region.minX + controlWidth,
                            y: region.minY, width: displayWidth, height: region.height)
        )
    }
}

enum DeckSafeRegions {
    /// Both division and occlusion margins are included before these local rectangles are supplied.
    static func frames(in bounds: CGRect, avoiding reservedFrames: [CGRect]) -> [CGRect] {
        reservedFrames.reduce([bounds]) { regions, reserved in
            regions.flatMap { subtract(reserved, from: $0) }
        }.filter { $0.width > 0 && $0.height > 0 }
    }

    private static func subtract(_ reserved: CGRect, from region: CGRect) -> [CGRect] {
        let intersection = region.intersection(reserved)
        guard !intersection.isNull, !intersection.isEmpty else { return [region] }
        return [
            CGRect(x: region.minX, y: region.minY, width: region.width, height: intersection.minY - region.minY),
            CGRect(x: region.minX, y: intersection.maxY, width: region.width, height: region.maxY - intersection.maxY),
            CGRect(x: region.minX, y: intersection.minY, width: intersection.minX - region.minX,
                   height: intersection.height),
            CGRect(x: intersection.maxX, y: intersection.minY, width: region.maxX - intersection.maxX,
                   height: intersection.height)
        ].filter { $0.width > 0 && $0.height > 0 }
    }
}

#if os(iOS)
import SwiftUI

enum DeckReservedRegions {
    static func activeFrames(in proxy: GeometryProxy) -> [CGRect] {
        if #available(iOS 27.1, *) {
            return frames(in: proxy, kind: .division) + frames(in: proxy, kind: .occlusion)
        }
        return []
    }

    static func activeDivisionFrames(in proxy: GeometryProxy) -> [CGRect] {
        if #available(iOS 27.1, *) { return frames(in: proxy, kind: .division) }
        return []
    }

    @available(iOS 27.1, *)
    private static func frames(in proxy: GeometryProxy, kind: ReservedRegion.Kind) -> [CGRect] {
        proxy.reservedRegions(kind: kind, options: [.includeInactive], layoutDirectionBehavior: .fixed)
            .filter(\.isActive)
            .map { region in
                CGRect(x: region.frame.minX - region.margins.leading,
                       y: region.frame.minY - region.margins.top,
                       width: region.frame.width + region.margins.leading + region.margins.trailing,
                       height: region.frame.height + region.margins.top + region.margins.bottom)
            }
    }
}
#endif

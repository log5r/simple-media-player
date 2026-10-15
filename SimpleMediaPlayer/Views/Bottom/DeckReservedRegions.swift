#if os(iOS)
import SwiftUI

enum DeckReservedRegions {
    static func activeFrames(in proxy: GeometryProxy, includesDivisions: Bool = true) -> [CGRect] {
        if #available(iOS 27.1, *) {
            let divisions = includesDivisions ? frames(in: proxy, kind: .division) : []
            return divisions + frames(in: proxy, kind: .occlusion)
        }
        return []
    }

    static func activeDivisionFrames(in proxy: GeometryProxy) -> [CGRect] {
        if #available(iOS 27.1, *) { return frames(in: proxy, kind: .division) }
        return []
    }

    static func hasDisplayDivision(in proxy: GeometryProxy) -> Bool {
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division, options: [.includeInactive]).isEmpty == false
        }
        return false
    }

    /// `ReservedRegion.frame` already includes `margins`, so the frame is returned without expansion.
    @available(iOS 27.1, *)
    private static func frames(in proxy: GeometryProxy, kind: ReservedRegion.Kind) -> [CGRect] {
        proxy.reservedRegions(kind: kind, options: [.includeInactive], layoutDirectionBehavior: .fixed)
            .filter(\.isActive)
            .map(\.frame)
    }
}

#endif

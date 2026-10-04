#if os(iOS)
import SwiftUI

/// Keep this layout between the navigation container and each pane's scrolling content.
struct IPhoneDeckArrangementView<Display: View, Controls: View>: View {
    let display: (CGFloat) -> Display
    let controls: () -> Controls
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(@ViewBuilder display: @escaping (CGFloat) -> Display, @ViewBuilder controls: @escaping () -> Controls) {
        self.display = display
        self.controls = controls
    }

    var body: some View {
        GeometryReader { proxy in
            if #available(iOS 27.1, *), shouldArrange(in: proxy) {
                arrangedContent
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        display(300)
                        controls()
                    }
                    .padding(.horizontal, 16).padding(.bottom, 12)
                }
            }
        }
    }

    private func shouldArrange(in proxy: GeometryProxy) -> Bool {
        let bounds = CGRect(origin: .zero, size: proxy.size)
        return horizontalSizeClass == .regular || DeckReservedRegions.activeDivisionFrames(in: proxy).contains {
            let intersection = bounds.intersection($0)
            return !intersection.isNull && !intersection.isEmpty
        }
    }

    @available(iOS 27.1, *)
    private var arrangedContent: some View {
        ArrangementView {
            DeckSafeContentRegion { size in
                display(min(300, max(1, size.height - 10)))
                    .padding(.horizontal, 16)
            }
            .splitArrangementLayoutSize(minWidth: 220, minHeight: 90)
            .accessibilityIdentifier("phoneDeckDisplayRegion")
        } secondary: {
            DeckSafeContentRegion { size in
                ScrollView([.horizontal, .vertical]) {
                    controls()
                        .padding(.horizontal, 16).padding(.bottom, 12)
                        .frame(width: max(324, size.width))
                }
            }
            .splitArrangementLayoutSize(minWidth: 324, minHeight: 44, idealHeight: 310)
            .accessibilityIdentifier("phoneDeckControlsRegion")
        }
        .arrangementViewStyle(.split.axes([.horizontal, .vertical]))
    }
}

struct DeckSafeRow<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        DeckSafeContentRegion { _ in content() }
            .frame(height: height)
    }
}

struct DeckSafeControlsOverlay<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let frames = DeckSafeRegions.frames(in: bounds, avoiding: DeckReservedRegions.activeFrames(in: proxy))
            let preferredFrames = frames.filter { $0.width >= 140 && $0.height >= 140 }.sorted {
                abs($0.minY - $1.minY) > 1 ? $0.minY < $1.minY : $0.maxX > $1.maxX
            }
            let frame = preferredFrames.first ?? frames.max { $0.width * $0.height < $1.width * $1.height } ?? .zero
            content()
                .frame(width: frame.width, height: frame.height, alignment: .topTrailing)
                .clipped()
                .offset(x: frame.minX, y: frame.minY)
        }
    }
}

private struct DeckSafeContentRegion<Content: View>: View {
    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let frames = DeckSafeRegions.frames(in: bounds, avoiding: DeckReservedRegions.activeFrames(in: proxy))
            let frame = frames.max { $0.width * $0.height < $1.width * $1.height } ?? .zero
            content(frame.size)
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
                .clipped()
                .offset(x: frame.minX, y: frame.minY)
        }
    }
}
#endif

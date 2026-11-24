#if os(iOS)
import SwiftUI

/// Keep this layout between the navigation container and each pane's scrolling content.
struct IPhoneDeckArrangementView<Display: View, Controls: View>: View {
    let display: (CGFloat, Bool) -> Display
    let controls: () -> Controls
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var measuredControlsHeight: CGFloat = 0

    init(
        @ViewBuilder display: @escaping (CGFloat, Bool) -> Display,
        @ViewBuilder controls: @escaping () -> Controls
    ) {
        self.display = display
        self.controls = controls
    }

    var body: some View {
        GeometryReader { proxy in
            if #available(iOS 27.1, *), shouldArrange(in: proxy) {
                arrangedContent
            } else if horizontalSizeClass == .compact, IPhoneDeckLayout.usesSideBySide(availableSize: proxy.size) {
                sideBySideContent(in: proxy)
            } else {
                stackedContent(in: proxy)
            }
        }
    }

    /// The LED takes the height the controls leave, and the stack sits on the page switcher without a gap.
    private func stackedContent(in proxy: GeometryProxy) -> some View {
        let horizontalSafeArea = proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
        let compactDisplay = IPhoneDeckLayout.usesCompactDisplay(
            availableSize: proxy.size, horizontalSafeArea: horizontalSafeArea,
            accessibilityText: dynamicTypeSize.isAccessibilitySize
        )
        let height = IPhoneDeckLayout.displayHeight(
            availableSize: proxy.size, controlsHeight: measuredControlsHeight,
            horizontalSafeArea: horizontalSafeArea, accessibilityText: dynamicTypeSize.isAccessibilitySize
        )
        return ScrollView {
            VStack(spacing: IPhoneDeckLayout.groupSpacing) {
                display(height, compactDisplay)
                    #if DEBUG
                    .modifier(DuoPanelRegionDiagnostics(regionID: "phoneDeckCompactDisplay"))
                    #endif
                controls()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredControlsHeight = $0 }
            }
            .padding(.horizontal, IPhoneDeckLayout.gutter)
            .padding(.bottom, IPhoneDeckLayout.groupSpacing)
            .frame(minHeight: proxy.size.height, alignment: .bottom)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// A compact landscape deck places the controls on the left and the LED on the right.
    private func sideBySideContent(in proxy: GeometryProxy) -> some View {
        let widths = IPhoneDeckLayout.sideBySideWidths(availableWidth: proxy.size.width)
        let height = IPhoneDeckLayout.sideBySideDisplayHeight(availableHeight: proxy.size.height)
        return HStack(alignment: .bottom, spacing: IPhoneDeckLayout.groupSpacing) {
            ViewThatFits(in: .vertical) {
                controls()
                ScrollView { controls() }
            }
            .frame(width: widths.controls)
            display(height, height < IPhoneDeckLayout.regularDisplayHeight)
                .frame(width: widths.display)
                #if DEBUG
                .modifier(DuoPanelRegionDiagnostics(regionID: "phoneDeckCompactDisplay"))
                #endif
        }
        .padding(.horizontal, IPhoneDeckLayout.gutter)
        .padding(.bottom, IPhoneDeckLayout.groupSpacing)
        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
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
                display(min(IPhoneDeckLayout.maximumDisplayHeight,
                            max(1, size.height - IPhoneDeckLayout.displayBezelHeight)), false)
                    .padding(.horizontal, IPhoneDeckLayout.gutter)
            }
            .splitArrangementLayoutSize(minWidth: 220, minHeight: 90)
            .accessibilityIdentifier("phoneDeckDisplayRegion")
        } secondary: {
            DeckSafeContentRegion { size in
                ScrollView([.horizontal, .vertical]) {
                    controls()
                        .padding(.horizontal, IPhoneDeckLayout.gutter).padding(.bottom, 12)
                        .frame(width: max(324, size.width))
                }
            }
            .splitArrangementLayoutSize(minWidth: 324, minHeight: 44, idealHeight: 310)
            .accessibilityIdentifier("phoneDeckControlsRegion")
        }
        .arrangementViewStyle(.split.axes([.horizontal, .vertical]))
    }
}

/// Lays out Lyrics, Info, and Up Next above the deck's page switcher.
struct IPhoneDeckPageLayout<Content: View>: View {
    let player: PlayerViewModel
    @ViewBuilder let content: () -> Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var heightClass

    /// In short landscapes, large text needs the height of a column for the page's scrolling content.
    var body: some View {
        let usesColumns = heightClass == .compact && dynamicTypeSize.isAccessibilitySize
        let layout = usesColumns ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            : AnyLayout(VStackLayout(spacing: 0))
        return VStack(spacing: 0) {
            if !usesColumns {
                DeckSafeRow(height: 90) {
                    LEDDisplayView(player: player, height: 90, layout: .phoneStrip)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .clipShape(RoundedRectangle(cornerRadius: IPhoneDeckLayout.displayCornerRadius))
                        .padding(.horizontal, IPhoneDeckLayout.gutter)
                }
            }
            layout {
                DeckSafeContentRegion { _ in
                    content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                        .clipShape(RoundedRectangle(cornerRadius: IPhoneDeckLayout.cardCornerRadius))
                        .padding(.horizontal, IPhoneDeckLayout.gutter)
                }
                .padding(.vertical, IPhoneDeckLayout.groupSpacing)
                if usesColumns {
                    ScrollView { playbackControls }
                        .scrollBounceBehavior(.basedOnSize)
                        .padding(.top, IPhoneDeckLayout.groupSpacing)
                } else {
                    playbackControls
                }
            }
        }
    }

    private var playbackControls: some View {
        VStack(spacing: 0) {
            SeekBarView(player: player, drawsOnPanel: true)
                .padding(.horizontal, IPhoneDeckLayout.gutter)
            DeckSafeRow(height: IPhoneDeckLayout.rowHeight) {
                IPhoneTransportBar(player: player).padding(.horizontal, IPhoneDeckLayout.gutter)
            }
            .padding(.top, IPhoneDeckLayout.rowSpacing)
            .padding(.bottom, IPhoneDeckLayout.groupSpacing)
        }
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

/// Draws the content in the largest part of its frame that avoids active divisions and occlusions.
struct DeckSafeContentRegion<Content: View>: View {
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

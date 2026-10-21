#if os(iOS)
import SwiftUI

/// Library, Equalizer, Details, Show Video, and Settings as equal 44 pt cells in the deck's control style.
struct DuoNavigationButtons: View {
    let isVideoMode: Bool
    let showLibrary: () -> Void
    let showEqualizer: () -> Void
    let showDetails: () -> Void
    let showVideoFullScreen: () -> Void
    let showSettings: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var palette: BottomPanelPalette { BottomPanelPalette(colorScheme: colorScheme) }

    var body: some View {
        // Accessibility sizes cannot fit the short titles side by side, so the cells stack.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: IPhoneDeckLayout.rowSpacing))
            : AnyLayout(IPhoneDeckCellRow(spacing: IPhoneDeckLayout.rowSpacing))
        return layout {
            action("Library", symbol: "music.note.list", identifier: "duoShowLibrary", perform: showLibrary)
            action("Equalizer", symbol: "slider.horizontal.3", identifier: "equalizerButton", perform: showEqualizer)
            action("Details", symbol: "info.circle", identifier: "lyricsButton", perform: showDetails)
            if isVideoMode {
                action("Show Video", symbol: "play.rectangle", identifier: "showVideoButton",
                       perform: showVideoFullScreen)
            }
            action("Settings", symbol: "gearshape", identifier: "settingsButton", perform: showSettings)
        }
    }

    private func action(
        _ title: LocalizedStringKey, symbol: String, identifier: String, perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    Label(title, systemImage: symbol).font(.callout.weight(.semibold))
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                        Text(title).font(.caption2.weight(.semibold))
                    }
                }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(palette.enabledIcon)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: IPhoneDeckLayout.rowHeight)
            .background(palette.normalButtonFill)
            .iPhoneDeckControlFrame(palette)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title)).accessibilityIdentifier(identifier)
    }
}
#endif

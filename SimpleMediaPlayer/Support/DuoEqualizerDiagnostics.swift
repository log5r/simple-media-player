#if DEBUG && os(iOS)
import Darwin
import SwiftUI

struct DuoEqualizerDiagnostics: ViewModifier {
    let context: PhoneDeckEqualizerCommandContext
    @AppStorage(AppSettingsKey.showEqualizerPanel) private var inlinePanel = AppSettingsDefault.showEqualizerPanel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusedValue(\.appMenuActions) private var libraryActions
    @FocusedValue(\.deckEqualizerCommand) private var deckCommand

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-duo-layout") {
                GeometryReader { geometry in
                    Text("duoEqualizerMetrics")
                        .font(.system(size: 8, design: .monospaced))
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("duoEqualizerMetrics")
                        .accessibilityValue(metrics(geometry))
                        .onChange(of: metrics(geometry), initial: true) { _, value in
                            print("DuoEqualizerMetrics \(value)")
                            fflush(nil)
                        }
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func metrics(_ geometry: GeometryProxy) -> String {
        let command = EqualizerMenuCommand.current(deck: deckCommand, library: libraryActions)
        var values: [String: Any] = [
            "librarySheet": context.browsingState.showsEqualizer,
            "deckSheet": context.browsingState.showsDeckEqualizer,
            "inlinePanel": inlinePanel,
            "deckPresented": context.showsDeck.wrappedValue,
            "menuTitle": command?.isVisible == true ? "Hide Equalizer" : "Show Equalizer",
            "commandEnabled": command?.toggle.isEnabled == true,
            "portrait": geometry.size.height > geometry.size.width,
            "layout": horizontalSizeClass == .compact ? "compact" : "expanded"
        ]
        if #available(iOS 27.1, *) {
            values["hasActiveDivision"] = geometry.reservedRegions(kind: .division).contains { $0.isActive }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "unavailable" }
        return value
    }
}
#endif

#if DEBUG && os(iOS)
import SwiftUI

/// Attach before the drawing offset so geometry follows the pane, independently of accessibility child bounds.
struct DuoPanelRegionDiagnostics: ViewModifier {
    let regionID: String

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-duo-layout") {
                GeometryReader { proxy in
                    Text("Panel region diagnostics")
                        .font(.system(size: 1))
                        .foregroundStyle(.clear)
                        .frame(width: 1, height: 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Panel region diagnostics")
                        .accessibilityIdentifier("\(regionID)Metrics")
                        .accessibilityValue(metrics(for: proxy.frame(in: .global)))
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func metrics(for frame: CGRect) -> String {
        let values: [String: CGFloat] = [
            "x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "unavailable" }
        return value
    }
}
#endif

import SwiftUI

struct SevenSegmentTimeView: View {
    let time: TimeInterval
    var color = Color(red: 0.72, green: 0.91, blue: 0.53)
    var scale: CGFloat = 1
    var shadowOpacity = 0.8
    var shadowRadius: CGFloat = 3
    @AppStorage(AppSettingsKey.timeDisplayStyle) private var timeDisplayStyleRaw = AppSettingsDefault.timeDisplayStyle

    private var style: TimeDisplayStyle {
        TimeDisplayStyle(rawValue: timeDisplayStyleRaw) ?? .sevenSegment
    }

    var body: some View {
        ZStack {
            // 7セグスタイルのみ、全点灯("88:88")を薄く敷いて消灯セグメントを表現する。
            // フォントは等幅なので同じ桁数なら正確に重なる
            if style == .sevenSegment {
                Text(ghostText(for: format(time)))
                    .foregroundStyle(color.opacity(0.08))
                    .accessibilityHidden(true)
            }
            Text(format(time))
                .foregroundStyle(color)
                .shadow(color: color.opacity(shadowOpacity), radius: shadowRadius)
        }
        .font(.custom(style.fontName, size: style.fontSize * scale))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(width: style.displayWidth * scale, height: 34 * scale, alignment: .center)
        .monospacedDigit()
        .accessibilityLabel(L10n.format("Playback time %@", format(time)))
        .id(style.id)
        .rotationEffect(.degrees(-1.5))
    }

    private func format(_ value: TimeInterval) -> String {
        let safe = max(0, Int(value))
        return String(format: "%02d:%02d", safe / 60, safe % 60)
    }

    private func ghostText(for text: String) -> String {
        String(text.map { $0.isNumber ? "8" : $0 })
    }
}

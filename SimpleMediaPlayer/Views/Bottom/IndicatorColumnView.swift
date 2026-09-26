import SwiftUI

/// EQ / KEY / SPEED の状態を示す刻印レジェンド列。各行は
/// 「琥珀色 LED ドット + 刻印文字 + ダークグラスの値窓」で構成し、
/// 有効時だけ LED と窓の値が灯る。表示専用(操作はしない)。
struct IndicatorColumnView: View {
    let player: PlayerViewModel
    let palette: BottomPanelPalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pitchSpeedAvailable: Bool {
        player.isVideoMode == false
    }

    var body: some View {
        VStack(spacing: 7) {
            IndicatorRow(
                legend: "EQ",
                value: player.equalizer.isEnabled ? "ON" : "OFF",
                isOn: player.equalizer.isEnabled,
                palette: palette,
                reduceMotion: reduceMotion
            )
            .accessibilityLabel("Equalizer")
            .accessibilityValue(player.equalizer.isEnabled ? L10n.string("On") : L10n.string("Off"))
            .accessibilityIdentifier("indicatorEQ")

            IndicatorRow(
                legend: "KEY",
                value: PitchSpeedTextFormatter.pitch(pitchSpeedAvailable ? player.pitchSemitones : 0),
                isOn: pitchSpeedAvailable && player.pitchSemitones != 0,
                palette: palette,
                reduceMotion: reduceMotion
            )
            .accessibilityLabel("Key")
            .accessibilityValue(L10n.format("%d semitones", pitchSpeedAvailable ? player.pitchSemitones : 0))
            .accessibilityIdentifier("indicatorKey")

            IndicatorRow(
                legend: "SPEED",
                value: PitchSpeedTextFormatter.rate(pitchSpeedAvailable ? player.playbackRate : 1),
                isOn: pitchSpeedAvailable && abs(player.playbackRate - 1) > 0.001,
                palette: palette,
                reduceMotion: reduceMotion
            )
            .accessibilityLabel("Speed")
            .accessibilityValue(PitchSpeedTextFormatter.rate(pitchSpeedAvailable ? player.playbackRate : 1))
            .accessibilityIdentifier("indicatorSpeed")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 168, height: 96)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("indicatorColumn")
    }
}

private struct IndicatorRow: View {
    let legend: String
    let value: String
    let isOn: Bool
    let palette: BottomPanelPalette
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 8) {
            ledDot
                .frame(width: 12)

            Text(verbatim: legend)
                .font(.system(size: 10, weight: .heavy))
                .kerning(1.2)
                .foregroundStyle(isOn ? palette.indicatorLegendOn : palette.indicatorLegendOff)
                .shadow(color: palette.indicatorLegendEmboss, radius: 0, y: 1)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            glassWindow
                .frame(width: 60, height: 20)
        }
        .frame(height: 22)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isOn)
        .accessibilityElement(children: .combine)
    }

    private var ledDot: some View {
        Circle()
            .fill(isOn ? palette.indicatorLEDOn : palette.indicatorLEDOff)
            .frame(width: 6, height: 6)
            .overlay(
                Circle().strokeBorder(isOn ? palette.indicatorLEDOnRing : .black, lineWidth: 1)
            )
            .background(
                // 消灯時のみ、下端に筐体の受光ハイライトを見せる
                Circle()
                    .fill(Color.white.opacity(isOn ? 0 : 0.06))
                    .frame(width: 6, height: 6)
                    .offset(y: 1)
            )
            .shadow(color: isOn ? palette.indicatorLEDGlow : .clear, radius: 7)
    }

    private var glassWindow: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 3)
                .fill(palette.glassWindowFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.black, lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(palette.glassWindowBezel, lineWidth: 2)
                        .padding(1)
                )
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(palette.glassWindowInnerShadow)
                        .frame(height: 5)
                        .padding(.horizontal, 3)
                        .padding(.top, 3)
                }
                .background(alignment: .bottom) {
                    Rectangle()
                        .fill(palette.glassWindowBottomHighlight)
                        .frame(height: 1)
                        .offset(y: 1)
                }

            Text(verbatim: value)
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(isOn ? palette.glassValueOn : palette.glassValueOff)
                .shadow(color: isOn ? palette.glassValueGlow : .clear, radius: 6)
                .lineLimit(1)
                .padding(.trailing, 8)
        }
    }
}

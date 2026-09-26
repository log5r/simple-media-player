import SwiftUI

struct BottomPanelPalette {
    private let isDark: Bool

    init(colorScheme: ColorScheme) {
        isDark = colorScheme == .dark
    }

    var panelBackground: LinearGradient {
        LinearGradient(
            colors: isDark
                ? [
                    Color(red: 0.18, green: 0.19, blue: 0.21),
                    Color(red: 0.12, green: 0.13, blue: 0.15),
                    Color(red: 0.08, green: 0.09, blue: 0.10)
                ]
                : [
                    Color(red: 0.98, green: 0.98, blue: 0.98),
                    Color(red: 0.91, green: 0.91, blue: 0.92),
                    Color(red: 0.85, green: 0.85, blue: 0.86)
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var panelTopStroke: Color {
        isDark ? Color.white.opacity(0.14) : Color(red: 0.77, green: 0.77, blue: 0.79)
    }

    var displayBezelFill: LinearGradient {
        LinearGradient(
            colors: isDark
                ? [
                    Color(red: 0.05, green: 0.05, blue: 0.06),
                    Color(red: 0.16, green: 0.17, blue: 0.18),
                    Color(red: 0.27, green: 0.28, blue: 0.30)
                ]
                : [
                    Color(red: 0.42, green: 0.42, blue: 0.44),
                    Color(red: 0.74, green: 0.74, blue: 0.76),
                    Color(red: 0.96, green: 0.96, blue: 0.97)
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var displayBezelTopLine: Color {
        Color.black.opacity(isDark ? 0.62 : 0.48)
    }

    var displayBezelBottomLine: Color {
        Color.white.opacity(isDark ? 0.24 : 0.75)
    }

    var displayBezelInnerShadow: LinearGradient {
        LinearGradient(
            colors: [Color.black.opacity(isDark ? 0.56 : 0.46), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var labelColor: Color {
        isDark ? Color(red: 0.74, green: 0.75, blue: 0.78) : Color(red: 0.3, green: 0.3, blue: 0.33)
    }

    var controlStroke: Color {
        isDark ? Color.white.opacity(0.24) : Color(red: 0.56, green: 0.56, blue: 0.58)
    }

    var buttonDivider: Color {
        isDark ? Color.white.opacity(0.22) : Color(red: 0.59, green: 0.59, blue: 0.62)
    }

    var buttonShadow: Color {
        Color.black.opacity(isDark ? 0.48 : 0.28)
    }

    var controlShadow: Color {
        Color.black.opacity(isDark ? 0.42 : 0.22)
    }

    var enabledIcon: Color {
        isDark ? Color(red: 0.88, green: 0.90, blue: 0.94) : Color(red: 0.22, green: 0.24, blue: 0.28)
    }

    var activeIcon: Color {
        isDark ? Color(red: 0.03, green: 0.12, blue: 0.18) : Color(red: 0.16, green: 0.18, blue: 0.22)
    }

    var disabledIcon: Color {
        isDark ? Color(red: 0.46, green: 0.48, blue: 0.52) : Color(red: 0.48, green: 0.49, blue: 0.52)
    }

    var activeIconShadow: Color {
        isDark ? Color.white.opacity(0.18) : Color.white.opacity(0.8)
    }

    var activeButtonShadow: Color {
        Color(red: 0.5, green: 0.82, blue: 1.0).opacity(isDark ? 0.65 : 0.9)
    }

    var normalButtonFill: LinearGradient {
        LinearGradient(
            colors: isDark
                ? [
                    Color(red: 0.25, green: 0.26, blue: 0.29),
                    Color(red: 0.17, green: 0.18, blue: 0.20),
                    Color(red: 0.10, green: 0.11, blue: 0.13)
                ]
                : [
                    Color.white,
                    Color(red: 0.86, green: 0.86, blue: 0.88),
                    Color(red: 0.74, green: 0.74, blue: 0.76)
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var disabledButtonFill: LinearGradient {
        LinearGradient(
            colors: isDark
                ? [
                    Color(red: 0.16, green: 0.17, blue: 0.19),
                    Color(red: 0.12, green: 0.13, blue: 0.15),
                    Color(red: 0.09, green: 0.10, blue: 0.12)
                ]
                : [
                    Color(red: 0.82, green: 0.82, blue: 0.84),
                    Color(red: 0.72, green: 0.72, blue: 0.74),
                    Color(red: 0.64, green: 0.64, blue: 0.66)
                ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var activeButtonFill: RadialGradient {
        RadialGradient(
            colors: isDark
                ? [
                    Color(red: 0.83, green: 0.95, blue: 1.0),
                    Color(red: 0.25, green: 0.55, blue: 0.78),
                    Color(red: 0.07, green: 0.19, blue: 0.29)
                ]
                : [
                    Color.white,
                    Color(red: 0.8, green: 0.93, blue: 1.0),
                    Color(red: 0.52, green: 0.8, blue: 0.98)
                ],
            center: .center,
            startRadius: 2,
            endRadius: 48
        )
    }

    var volumeSlotFill: LinearGradient {
        LinearGradient(
            colors: isDark
                ? [Color(red: 0.02, green: 0.02, blue: 0.03), Color(red: 0.10, green: 0.11, blue: 0.13)]
                : [Color(red: 0.05, green: 0.05, blue: 0.06), Color(red: 0.14, green: 0.14, blue: 0.15)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var volumeFilledRib: LinearGradient {
        LinearGradient(
            colors: isDark
                ? [Color(red: 0.78, green: 0.82, blue: 0.88), Color(red: 0.42, green: 0.46, blue: 0.53)]
                : [Color(red: 0.95, green: 0.95, blue: 0.96), Color(red: 0.68, green: 0.68, blue: 0.71)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var volumeEmptyRib: Color {
        Color.white.opacity(isDark ? 0.08 : 0.05)
    }

    var volumeSlotStroke: Color {
        isDark ? Color.white.opacity(0.18) : Color(red: 0.5, green: 0.5, blue: 0.52)
    }

    var volumeSlotBottomHighlight: Color {
        Color.white.opacity(isDark ? 0.18 : 0.7)
    }

    var indicatorLegendOn: Color {
        isDark ? LEDColorValue.resolved("#DFE2E7").color : LEDColorValue.resolved("#2E3035").color
    }

    var indicatorLegendOff: Color {
        isDark ? LEDColorValue.resolved("#6B707A").color : LEDColorValue.resolved("#9A9DA4").color
    }

    var indicatorLegendEmboss: Color {
        Color.white.opacity(isDark ? 0.07 : 0.7)
    }

    var indicatorLEDOn: Color {
        LEDColorValue.resolved("#FFB648").color
    }

    var indicatorLEDOnRing: Color {
        LEDColorValue.resolved("#6A4A1A").color
    }

    var indicatorLEDGlow: Color {
        LEDColorValue.resolved("#FFB648").color.opacity(0.6)
    }

    var indicatorLEDOff: Color {
        LEDColorValue.resolved("#3A2A18").color
    }

    var glassWindowFill: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: LEDColorValue.resolved("#1B1D21").color, location: 0),
                .init(color: LEDColorValue.resolved("#08090B").color, location: 0.45),
                .init(color: LEDColorValue.resolved("#0B0C0E").color, location: 1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var glassWindowBezel: Color {
        LEDColorValue.resolved("#2A2D33").color
    }

    var glassWindowInnerShadow: LinearGradient {
        LinearGradient(
            colors: [Color.black.opacity(0.55), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var glassWindowBottomHighlight: Color {
        Color.white.opacity(0.05)
    }

    var glassValueOn: Color {
        LEDColorValue.resolved("#FFD28A").color
    }

    var glassValueGlow: Color {
        Color(red: 255.0 / 255, green: 190.0 / 255, blue: 90.0 / 255).opacity(0.7)
    }

    var glassValueOff: Color {
        LEDColorValue.resolved("#17181A").color
    }

}

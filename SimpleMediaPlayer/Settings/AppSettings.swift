import SwiftUI

nonisolated enum AppSettingsKey {
    static let appearanceMode = "appearanceMode"
    static let ledGlowIntensity = "ledGlowIntensity"
    static let ledColorHex = "ledColorHex"
    static let vuMeterFaceColorHex = "vuMeterFaceColorHex"
    static let vuMeterLampColorHex = "vuMeterLampColorHex"
    static let vuMeterShadowOpacity = "vuMeterShadowOpacity"
    static let vuMeterShadowExtent = "vuMeterShadowExtent"
    static let ledBacklitForegroundColorHex = "ledBacklitForegroundColorHex"
    static let ledBacklightColorHex = "ledBacklightColorHex"
    static let ledDisplayStyle = "ledDisplayStyle"
    static let timeDisplayStyle = "timeDisplayStyle"
    static let mediaInfoDisplayStyle = "mediaInfoDisplayStyle"
    static let visualizerResponseMode = "visualizerResponseMode"
    static let ledGlassStyle = "ledGlassStyle"
    static let ledBacklitGlassIntensity = "ledBacklitGlassIntensity"
    static let dockIconFollowsLEDColor = "dockIconFollowsLEDColor"
    static let bottomPanelLayout = "bottomPanelLayout"
    static let ledPanelSide = "ledPanelSide"
    static let ledPanelCorner = "ledPanelCorner"
    static let mediaListColumnCustomization = "mediaListColumnCustomization"
    static let mediaListColumnOrder = "mediaListColumnOrder"
    static let mediaListVisibleColumns = "mediaListVisibleColumns"
    static let volumeNormalizationEnabled = "volumeNormalizationEnabled"
    static let equalizerSettings = "equalizerSettings"
    static let equalizerUserPresets = "equalizerUserPresets"
    static let showEqualizerPanel = "showEqualizerPanel"
}

enum AppSettingsDefault {
    static let appearanceMode = AppearanceMode.system.rawValue
    static let ledGlowIntensity = 1.0
    static let ledGlowIntensityRange = 0.0...2.0
    static let ledGlowIntensityStep = 0.05
    static let ledColorHex = "#FFFFFF"
    nonisolated static let vuMeterFaceColorHex = "#E5E89D"
    nonisolated static let vuMeterLampColorHex = "#FFD9A0"
    nonisolated static let vuMeterShadowOpacity = 0.75
    nonisolated static let vuMeterShadowOpacityRange = 0.0...1.0
    nonisolated static let vuMeterShadowOpacityStep = 0.05
    nonisolated static let vuMeterShadowExtent = 1.0
    nonisolated static let vuMeterShadowExtentRange = 0.3...1.0
    nonisolated static let vuMeterShadowExtentStep = 0.05

    nonisolated static func clampedVUMeterShadowOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return vuMeterShadowOpacity }
        return min(max(value, vuMeterShadowOpacityRange.lowerBound), vuMeterShadowOpacityRange.upperBound)
    }

    nonisolated static func clampedVUMeterShadowExtent(_ value: Double) -> Double {
        guard value.isFinite else { return vuMeterShadowExtent }
        return min(max(value, vuMeterShadowExtentRange.lowerBound), vuMeterShadowExtentRange.upperBound)
    }

    static let ledBacklitForegroundColorHex = "#000000"
    static let ledBacklightColorHex = "#E5E89D"
    static let ledDisplayStyle = LEDDisplayStyle.dark.rawValue
    static let timeDisplayStyle = TimeDisplayStyle.sevenSegment.rawValue
    static let mediaInfoDisplayStyle = MediaInfoDisplayStyle.default.rawValue
    static let visualizerResponseMode = VisualizerResponseMode.normal.rawValue
    static let ledGlassStyle = LEDGlassStyle.off.rawValue
    static let ledBacklitGlassIntensity = 0.18
    static let ledBacklitGlassIntensityRange = 0.0...0.5
    static let ledBacklitGlassIntensityStep = 0.02
    static let dockIconFollowsLEDColor = true
    static let bottomPanelLayout = BottomPanelLayout.ledHalf.rawValue
    static let ledPanelSide = LEDPanelSide.right.rawValue
    static let ledPanelCorner = LEDPanelCorner.adaptive.rawValue
    static let mediaListColumnOrder = MediaListColumn.encoded(MediaListColumn.allCases)
    static let mediaListVisibleColumns = MediaListColumn.encoded(MediaListColumn.defaultVisibleColumns)
    static let volumeNormalizationEnabled = false
    static let showEqualizerPanel = false
    static let ledColorPresets = [
        LEDColorPreset(name: L10n.string("Green"), hex: "#B8E887"),
        LEDColorPreset(name: L10n.string("White"), hex: "#FFFFFF"),
        LEDColorPreset(name: L10n.string("Blue"), hex: "#4DA3FF"),
        LEDColorPreset(name: L10n.string("Orange"), hex: "#FF9F2E")
    ]
    static let ledBacklitForegroundColorPresets = [
        LEDColorPreset(name: L10n.string("Black"), hex: "#000000"),
        LEDColorPreset(name: L10n.string("Gray"), hex: "#333333"),
        LEDColorPreset(name: L10n.string("Blue"), hex: "#163A5F"),
        LEDColorPreset(name: L10n.string("Brown"), hex: "#57351F")
    ]
    static let ledBacklightColorPresets = [
        LEDColorPreset(name: L10n.string("Yellow"), hex: "#E5E89D"),
        LEDColorPreset(name: L10n.string("Green"), hex: "#D8EDB8"),
        LEDColorPreset(name: L10n.string("Blue"), hex: "#C9E3F2"),
        LEDColorPreset(name: L10n.string("Orange"), hex: "#F2D39A")
    ]

    static let vuMeterFacePresets: [LEDColorPreset] = [
        LEDColorPreset(name: L10n.string("Ivory"), hex: "#E5E89D"),
        LEDColorPreset(name: L10n.string("White"), hex: "#F4F1E6"),
        LEDColorPreset(name: L10n.string("Amber"), hex: "#F2D39A"),
        LEDColorPreset(name: L10n.string("Mint"), hex: "#D8EDB8"),
        LEDColorPreset(name: L10n.string("Black"), hex: "#1C1D20")
    ]
    static let vuMeterLampPresets: [LEDColorPreset] = [
        LEDColorPreset(name: L10n.string("Warm"), hex: "#FFD9A0"),
        LEDColorPreset(name: L10n.string("White"), hex: "#F4F1E6"),
        LEDColorPreset(name: L10n.string("Green"), hex: "#B8E887"),
        LEDColorPreset(name: L10n.string("Blue"), hex: "#4DA3FF"),
        LEDColorPreset(name: L10n.string("Orange"), hex: "#FF9F2E")
    ]

    static func clampedLEDBacklitGlassIntensity(_ value: Double) -> Double {
        guard value.isFinite else { return ledBacklitGlassIntensity }
        return min(
            max(value, ledBacklitGlassIntensityRange.lowerBound),
            ledBacklitGlassIntensityRange.upperBound
        )
    }
}

enum MediaListColumn: String, CaseIterable, Identifiable {
    case index
    case artwork
    case title
    case artist
    case album
    case genre
    case duration
    case trackNumber
    case year
    case albumArtist
    case composer
    case discNumber
    case kind
    case contentType
    case dateAdded
    case fileName

    static let defaultVisibleColumns: [MediaListColumn] = [
        .index,
        .artwork,
        .title,
        .artist,
        .album,
        .genre,
        .duration
    ]

    var id: String { rawValue }

    var isVisibleByDefault: Bool {
        Self.defaultVisibleColumns.contains(self)
    }

    var title: String {
        switch self {
        case .index: L10n.string("No.")
        case .artwork: ""
        case .title: L10n.string("Title")
        case .artist: L10n.string("Artist")
        case .album: L10n.string("Album")
        case .genre: L10n.string("Genre")
        case .duration: L10n.string("Time")
        case .trackNumber: L10n.string("Track")
        case .year: L10n.string("Year")
        case .albumArtist: L10n.string("Album Artist")
        case .composer: L10n.string("Composer")
        case .discNumber: L10n.string("Disc")
        case .kind: L10n.string("Kind")
        case .contentType: L10n.string("Content Type")
        case .dateAdded: L10n.string("Date Added")
        case .fileName: L10n.string("File Name")
        }
    }

    var settingsTitle: String {
        switch self {
        case .artwork: L10n.string("Artwork")
        default: title
        }
    }

    var settingsIconName: String {
        switch self {
        case .index: "number"
        case .artwork: "photo"
        case .title: "music.note"
        case .artist: "person"
        case .album: "rectangle.stack"
        case .genre: "tag"
        case .duration: "clock"
        case .trackNumber: "list.number"
        case .year: "calendar"
        case .albumArtist: "person.2"
        case .composer: "pencil.and.list.clipboard"
        case .discNumber: "opticaldisc"
        case .kind: "waveform"
        case .contentType: "doc.richtext"
        case .dateAdded: "calendar.badge.plus"
        case .fileName: "doc"
        }
    }

    var minimumWidth: CGFloat {
        switch self {
        case .index: 44
        case .artwork: 36
        case .duration: 58
        case .trackNumber, .year, .discNumber, .kind, .contentType: 70
        case .genre: 90
        case .dateAdded: 120
        case .title: 180
        case .artist, .album, .albumArtist, .composer, .fileName: 140
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .index: 44
        case .artwork: 36
        case .duration: 58
        case .trackNumber, .year, .discNumber, .kind, .contentType: 90
        case .genre: 120
        case .dateAdded: 140
        case .title: 260
        case .artist, .album, .albumArtist, .composer, .fileName: 180
        }
    }

    var defaultVisibility: Visibility {
        isVisibleByDefault ? .visible : .hidden
    }

    static func encoded(_ columns: [MediaListColumn]) -> String {
        columns.map(\.rawValue).joined(separator: ",")
    }

    static func orderedColumns(from rawValue: String) -> [MediaListColumn] {
        let decoded = decodedColumns(from: rawValue)
        let missingColumns = allCases.filter { decoded.contains($0) == false }
        return decoded + missingColumns
    }

    static func visibleColumnSet(from rawValue: String) -> Set<MediaListColumn> {
        let decoded = decodedColumns(from: rawValue)
        return Set(decoded.isEmpty ? defaultVisibleColumns : decoded)
    }

    static func visibleColumns(orderRawValue: String, visibleRawValue: String) -> [MediaListColumn] {
        let visibleColumns = visibleColumnSet(from: visibleRawValue)
        let columns = orderedColumns(from: orderRawValue).filter { visibleColumns.contains($0) }
        return columns.isEmpty ? defaultVisibleColumns : columns
    }

    private static func decodedColumns(from rawValue: String) -> [MediaListColumn] {
        var seenColumns = Set<MediaListColumn>()
        return rawValue
            .split(separator: ",")
            .compactMap { MediaListColumn(rawValue: String($0)) }
            .filter { seenColumns.insert($0).inserted }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: L10n.string("System")
        case .light: L10n.string("Light")
        case .dark: L10n.string("Dark")
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum TimeDisplayStyle: String, CaseIterable, Identifiable {
    case sevenSegment
    case dotted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sevenSegment: L10n.string("7-segment")
        case .dotted: L10n.string("Dot")
        }
    }

    var fontName: String {
        switch self {
        case .sevenSegment: "DSEG7ClassicMini-Regular"
        case .dotted: "Dotrice-Regular"
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .sevenSegment: 31
        case .dotted: 30
        }
    }

    var displayWidth: CGFloat { 112 }
}

enum VisualizerResponseMode: String, CaseIterable, Identifiable {
    case slow
    case normal
    case fast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slow: L10n.string("Slow")
        case .normal: L10n.string("Normal")
        case .fast: L10n.string("Fast")
        }
    }

    nonisolated var framesPerSecond: Double {
        switch self {
        case .slow: 10
        case .normal: 30
        case .fast: 60
        }
    }
}

enum LEDGlassStyle: String, CaseIterable, Identifiable {
    case off
    case cylindrical
    case crtBulge
    case bevel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: L10n.string("Off")
        case .cylindrical: L10n.string("Cylindrical")
        case .crtBulge: L10n.string("CRT Bulge")
        case .bevel: L10n.string("Bevel")
        }
    }
}

enum LEDDisplayStyle: String, CaseIterable, Identifiable {
    case dark
    case backlit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark: L10n.string("Dark")
        case .backlit: L10n.string("Backlit")
        }
    }
}

enum BottomPanelLayout: String, CaseIterable, Identifiable {
    case classic
    case ledHalf

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic: L10n.string("Classic")
        case .ledHalf: L10n.string("LED Half")
        }
    }
}

enum LEDPanelSide: String, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var label: String {
        switch self {
        case .left: L10n.string("Left")
        case .right: L10n.string("Right")
        }
    }
}

enum LEDPanelCorner: String, CaseIterable, Identifiable {
    case rounded
    case adaptive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rounded: L10n.string("Rounded")
        case .adaptive: L10n.string("Adaptive")
        }
    }

    func cornerStyles(side: LEDPanelSide, inset: CGFloat = 0) -> LEDPanelCornerStyles {
        switch self {
        case .rounded:
            let radius = max(0, 9 - inset)
            return LEDPanelCornerStyles(
                topLeading: .fixed(radius),
                topTrailing: .fixed(radius),
                bottomLeading: .fixed(radius),
                bottomTrailing: .fixed(radius)
            )
        case .adaptive:
            let fixedRadius = max(0, 2 - inset)
            let minimumWindowRadius = Edge.Corner.Style.fixed(max(0, 10 - inset))
            return LEDPanelCornerStyles(
                topLeading: .fixed(fixedRadius),
                topTrailing: .fixed(fixedRadius),
                bottomLeading: side == .left ? .concentric(minimum: minimumWindowRadius) : .fixed(fixedRadius),
                bottomTrailing: side == .right ? .concentric(minimum: minimumWindowRadius) : .fixed(fixedRadius)
            )
        }
    }
}

struct LEDPanelCornerStyles: Equatable {
    let topLeading: Edge.Corner.Style
    let topTrailing: Edge.Corner.Style
    let bottomLeading: Edge.Corner.Style
    let bottomTrailing: Edge.Corner.Style

    var shape: ConcentricRectangle {
        ConcentricRectangle(
            topLeadingCorner: topLeading,
            topTrailingCorner: topTrailing,
            bottomLeadingCorner: bottomLeading,
            bottomTrailingCorner: bottomTrailing
        )
    }
}

enum MediaInfoDisplayStyle: String, CaseIterable, Identifiable {
    case `default`
    case dotted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: L10n.string("Default")
        case .dotted: L10n.string("Dot")
        }
    }

    func titleFont(scale: CGFloat = 1, isBold: Bool = false) -> Font {
        let font: Font
        switch self {
        case .default: font = .system(size: 13 * scale, design: .monospaced)
        case .dotted: font = .custom("DotGothic16-Regular", size: 13 * scale)
        }
        return font.weight(isBold ? .bold : .regular)
    }

    func subtitleFont(scale: CGFloat = 1) -> Font {
        switch self {
        case .default: .system(size: 11.5 * scale, design: .monospaced)
        case .dotted: .custom("DotGothic16-Regular", size: 11.5 * scale)
        }
    }

    var textTracking: CGFloat {
        switch self {
        case .default: 0
        case .dotted: 1
        }
    }
}

struct LEDColorPreset: Identifiable {
    let name: String
    let hex: String

    var id: String { hex }
    var value: LEDColorValue { LEDColorValue.resolved(hex) }
}

nonisolated struct LEDColorValue: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }

    var peakColor: Color {
        mixed(toward: .white, amount: 0.36)
    }

    var backgroundColor: Color {
        Color(red: red * 0.07, green: green * 0.07, blue: blue * 0.07)
    }

    var glowColor: Color {
        mixed(toward: .white, amount: 0.2)
    }

    var lowGlowColor: Color {
        Color(red: red * 0.9, green: green * 0.9, blue: blue * 0.9)
    }

    var backlightGlowColor: Color {
        let maximum = max(red, max(green, blue))
        guard maximum > 0 else { return .black }

        let brightness = maximum + (1 - maximum) * 0.9
        let saturationBoost = 1.45
        var highlighted = (
            red: highlightedChannel(red, maximum: maximum, brightness: brightness, saturationBoost: saturationBoost),
            green: highlightedChannel(
                green,
                maximum: maximum,
                brightness: brightness,
                saturationBoost: saturationBoost
            ),
            blue: highlightedChannel(blue, maximum: maximum, brightness: brightness, saturationBoost: saturationBoost)
        )

        let minimumLuminance = min(relativeLuminance + 0.12, 0.92)
        while Self.relativeLuminance(
            red: highlighted.red,
            green: highlighted.green,
            blue: highlighted.blue
        ) < minimumLuminance {
            highlighted.red += (1 - highlighted.red) * 0.08
            highlighted.green += (1 - highlighted.green) * 0.08
            highlighted.blue += (1 - highlighted.blue) * 0.08
        }

        return Color(red: highlighted.red, green: highlighted.green, blue: highlighted.blue)
    }

    static let fallback = LEDColorValue(red: 0.72, green: 0.91, blue: 0.53)

    static func resolved(_ rawHex: String) -> LEDColorValue {
        guard let normalizedHex = normalizedHex(rawHex), let value = LEDColorValue(hex: normalizedHex) else {
            return fallback
        }
        return value
    }

    static func resolved(_ rawHex: String, fallbackHex: String) -> LEDColorValue {
        if let normalizedHex = normalizedHex(rawHex), let value = LEDColorValue(hex: normalizedHex) {
            return value
        }
        guard let normalizedFallback = normalizedHex(fallbackHex),
              let fallbackValue = LEDColorValue(hex: normalizedFallback) else {
            return fallback
        }
        return fallbackValue
    }

    var relativeLuminance: Double {
        Self.relativeLuminance(red: red, green: green, blue: blue)
    }

    private func highlightedChannel(
        _ channel: Double,
        maximum: Double,
        brightness: Double,
        saturationBoost: Double
    ) -> Double {
        let normalized = channel / maximum
        let saturated = 1 - (1 - normalized) * saturationBoost
        return min(max(saturated, 0), 1) * brightness
    }

    private static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linearized(_ channel: Double) -> Double {
            channel <= 0.04045
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(red) + 0.7152 * linearized(green) + 0.0722 * linearized(blue)
    }

    static func normalizedHex(_ rawHex: String) -> String? {
        let trimmed = rawHex.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        let expanded: String

        switch body.count {
        case 3:
            expanded = body.map { "\($0)\($0)" }.joined()
        case 6:
            expanded = body
        default:
            return nil
        }

        guard expanded.allSatisfy(\.isHexDigit) else { return nil }
        return "#\(expanded.uppercased())"
    }

    private init?(hex: String) {
        let body = String(hex.dropFirst())
        guard let value = Int(body, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255.0
        green = Double((value >> 8) & 0xFF) / 255.0
        blue = Double(value & 0xFF) / 255.0
    }

    private init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    private func mixed(toward target: LEDColorValue, amount: Double) -> Color {
        let clampedAmount = min(max(amount, 0), 1)
        return Color(
            red: red + (target.red - red) * clampedAmount,
            green: green + (target.green - green) * clampedAmount,
            blue: blue + (target.blue - blue) * clampedAmount
        )
    }
}

private nonisolated extension LEDColorValue {
    static let white = LEDColorValue(red: 1, green: 1, blue: 1)
}

struct LEDDisplayPalette {
    let foreground: LEDColorValue
    let backlight: LEDColorValue
    let style: LEDDisplayStyle
    let backlitGlassIntensity: Double

    init(
        foreground: LEDColorValue,
        backlight: LEDColorValue,
        style: LEDDisplayStyle,
        backlitGlassIntensity: Double = AppSettingsDefault.ledBacklitGlassIntensity
    ) {
        self.foreground = foreground
        self.backlight = backlight
        self.style = style
        self.backlitGlassIntensity = AppSettingsDefault.clampedLEDBacklitGlassIntensity(
            backlitGlassIntensity
        )
    }

    static func resolved(
        styleRaw: String,
        darkForegroundHex: String,
        backlitForegroundHex: String,
        backlightHex: String,
        backlitGlassIntensity: Double = AppSettingsDefault.ledBacklitGlassIntensity
    ) -> LEDDisplayPalette {
        let style = LEDDisplayStyle(rawValue: styleRaw) ?? .dark
        let foreground: LEDColorValue
        switch style {
        case .dark:
            foreground = LEDColorValue.resolved(
                darkForegroundHex,
                fallbackHex: AppSettingsDefault.ledColorHex
            )
        case .backlit:
            foreground = LEDColorValue.resolved(
                backlitForegroundHex,
                fallbackHex: AppSettingsDefault.ledBacklitForegroundColorHex
            )
        }
        let backlight = LEDColorValue.resolved(
            backlightHex,
            fallbackHex: AppSettingsDefault.ledBacklightColorHex
        )
        return LEDDisplayPalette(
            foreground: foreground,
            backlight: backlight,
            style: style,
            backlitGlassIntensity: backlitGlassIntensity
        )
    }

    var primaryColor: Color {
        foreground.color
    }

    var visualizerOnColor: Color {
        switch style {
        case .dark: foreground.color
        case .backlit: foreground.color.opacity(0.78)
        }
    }

    var visualizerPeakColor: Color {
        switch style {
        case .dark: foreground.peakColor
        case .backlit: foreground.color.opacity(0.96)
        }
    }

    var visualizerOffOpacity: Double {
        style == .dark ? 0.08 : 0.12
    }

    var backgroundColor: Color {
        switch style {
        case .dark: foreground.backgroundColor
        case .backlit: backlight.color
        }
    }

    var backgroundGlowColor: Color {
        switch style {
        case .dark: foreground.glowColor
        case .backlit: backlight.backlightGlowColor
        }
    }

    var textShadowOpacity: Double {
        style == .dark ? 0.75 : 0.10
    }

    var textShadowRadius: CGFloat {
        style == .dark ? 2 : 0.5
    }

    var timeShadowOpacity: Double {
        style == .dark ? 0.8 : 0.12
    }

    var timeShadowRadius: CGFloat {
        style == .dark ? 3 : 0.5
    }

    var symbolShadowOpacity: Double {
        style == .dark ? 0.35 : 0.08
    }

    var symbolShadowRadius: CGFloat {
        style == .dark ? 1.5 : 0.5
    }

    var glassOverlayOpacity: Double {
        style == .dark ? 1 : backlitGlassIntensity
    }
}

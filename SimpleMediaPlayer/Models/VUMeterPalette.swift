import SwiftUI

nonisolated struct VUMeterPalette: Equatable {
    let face: LEDColorValue
    let lamp: LEDColorValue
    let shadowOpacity: Double
    let shadowExtent: Double

    var isDarkFace: Bool { face.relativeLuminance < 0.35 }
    var faceColor: Color { face.color }
    var lampColor: Color { lamp.color }
    var ink: Color { LEDColorValue.resolved(isDarkFace ? "#E9E4CF" : "#2A2A1C").color }
    var red: Color { LEDColorValue.resolved(isDarkFace ? "#FF5A3C" : "#C8412E").color }
    var needle: Color { LEDColorValue.resolved(isDarkFace ? "#F2EEDC" : "#1A1A12").color }
    var lampIntensity: Double { isDarkFace ? 0.36 : 0.55 }
    var glassIntensity: Double { isDarkFace ? 0.30 : 0.70 }
    var wellShadow: WellShadow {
        (isDarkFace ? WellShadow.dark : .light).scaled(opacity: shadowOpacity, extent: shadowExtent)
    }

    static func resolved(
        faceHex: String,
        lampHex: String,
        shadowOpacity: Double = AppSettingsDefault.vuMeterShadowOpacity,
        shadowExtent: Double = AppSettingsDefault.vuMeterShadowExtent
    ) -> VUMeterPalette {
        VUMeterPalette(
            face: .resolved(LEDColorValue.normalizedHex(faceHex) ?? AppSettingsDefault.vuMeterFaceColorHex),
            lamp: .resolved(LEDColorValue.normalizedHex(lampHex) ?? AppSettingsDefault.vuMeterLampColorHex),
            shadowOpacity: AppSettingsDefault.clampedVUMeterShadowOpacity(shadowOpacity),
            shadowExtent: AppSettingsDefault.clampedVUMeterShadowExtent(shadowExtent)
        )
    }
}

nonisolated struct WellShadow: Equatable {
    nonisolated struct Top: Equatable {
        let startOpacity: Double
        let midOpacity: Double
        let midStop: Double
        let endStop: Double
    }

    nonisolated struct Side: Equatable {
        let opacity: Double
        let widthFraction: Double
    }

    let top: Top
    let left: Side
    let right: Side
    let bottom: Side
    let contact: ContactShadow?

    nonisolated struct ContactShadow: Equatable {
        nonisolated struct Stop: Equatable {
            let opacity: Double
            let location: Double
        }

        let linear: [Stop]
        let corner: [Stop]
        let cornerRadiusFraction: Double
    }

    func scaled(opacity opacityScale: Double, extent extentScale: Double) -> WellShadow {
        func scaledSide(_ side: Side) -> Side {
            Side(opacity: side.opacity * opacityScale, widthFraction: side.widthFraction * extentScale)
        }

        return WellShadow(
            top: Top(
                startOpacity: top.startOpacity * opacityScale,
                midOpacity: top.midOpacity * opacityScale,
                midStop: top.midStop * extentScale,
                endStop: top.endStop * extentScale
            ),
            left: scaledSide(left),
            right: scaledSide(right),
            bottom: scaledSide(bottom),
            contact: contact.map { contact in
                ContactShadow(
                    linear: contact.linear.map {
                        .init(opacity: $0.opacity * opacityScale, location: $0.location * extentScale)
                    },
                    corner: contact.corner.map { .init(opacity: $0.opacity * opacityScale, location: $0.location) },
                    cornerRadiusFraction: contact.cornerRadiusFraction * extentScale
                )
            }
        )
    }

    static let light = WellShadow(
        top: Top(startOpacity: 0.72, midOpacity: 0.30, midStop: 0.15, endStop: 0.42),
        left: Side(opacity: 0.46, widthFraction: 0.15),
        right: Side(opacity: 0.46, widthFraction: 0.15),
        bottom: Side(opacity: 0.22, widthFraction: 0.07),
        contact: nil
    )
    static let dark = WellShadow(
        top: Top(startOpacity: 0.90, midOpacity: 0.45, midStop: 0.18, endStop: 0.50),
        left: Side(opacity: 0.92, widthFraction: 0.26),
        right: Side(opacity: 0.60, widthFraction: 0.14),
        bottom: Side(opacity: 0.40, widthFraction: 0.10),
        contact: ContactShadow(
            linear: [
                .init(opacity: 0.96, location: 0),
                .init(opacity: 0.80, location: 0.045),
                .init(opacity: 0.35, location: 0.09),
                .init(opacity: 0, location: 0.30)
            ],
            corner: [
                .init(opacity: 0.90, location: 0),
                .init(opacity: 0.35, location: 0.45),
                .init(opacity: 0, location: 1)
            ],
            cornerRadiusFraction: 0.5
        )
    )
}

import Testing
@testable import SimpleMediaPlayer

struct VUMeterPaletteTests {
    @Test func fullStrengthPreservesOriginalTables() {
        for shadow in [WellShadow.light, .dark] {
            #expect(shadow.scaled(opacity: 1, extent: 1) == shadow)
        }
    }

    @Test func defaultLightShadowMatchesVariantB() {
        let shadow = WellShadow.light.scaled(opacity: 0.75, extent: 1)
        #expect(abs(shadow.top.startOpacity - 0.54) < 1e-6)
        #expect(abs(shadow.top.midOpacity - 0.225) < 1e-6)
        #expect(abs(shadow.left.opacity - 0.345) < 1e-6)
        #expect(abs(shadow.right.opacity - 0.345) < 1e-6)
        #expect(abs(shadow.bottom.opacity - 0.165) < 1e-6)
        #expect(shadow.top.midStop == WellShadow.light.top.midStop)
        #expect(shadow.top.endStop == WellShadow.light.top.endStop)
        #expect(shadow.left.widthFraction == WellShadow.light.left.widthFraction)
        #expect(shadow.right.widthFraction == WellShadow.light.right.widthFraction)
        #expect(shadow.bottom.widthFraction == WellShadow.light.bottom.widthFraction)
        #expect(shadow.contact == nil)
    }

    @Test func darkShadowMatchesVariantD() throws {
        let shadow = WellShadow.dark.scaled(opacity: 0.4, extent: 0.7)
        #expect(abs(shadow.top.startOpacity - 0.36) < 1e-6)
        #expect(abs(shadow.top.midOpacity - 0.18) < 1e-6)
        #expect(abs(shadow.top.midStop - 0.126) < 1e-6)
        #expect(abs(shadow.top.endStop - 0.35) < 1e-6)
        #expect(abs(shadow.left.opacity - 0.368) < 1e-6)
        #expect(abs(shadow.left.widthFraction - 0.182) < 1e-6)
        #expect(abs(shadow.right.opacity - 0.24) < 1e-6)
        #expect(abs(shadow.right.widthFraction - 0.098) < 1e-6)
        #expect(abs(shadow.bottom.opacity - 0.16) < 1e-6)
        #expect(abs(shadow.bottom.widthFraction - 0.07) < 1e-6)
        let contact = try #require(shadow.contact)
        #expect(contact.linear.count == 4)
        for (stop, expected) in zip(contact.linear, [(0.384, 0.0), (0.32, 0.0315), (0.14, 0.063), (0, 0.21)]) {
            #expect(abs(stop.opacity - expected.0) < 1e-6)
            #expect(abs(stop.location - expected.1) < 1e-6)
        }
        #expect(contact.corner.count == 3)
        for (stop, expected) in zip(contact.corner, [(0.36, 0.0), (0.14, 0.45), (0, 1)]) {
            #expect(abs(stop.opacity - expected.0) < 1e-6)
            #expect(stop.location == expected.1)
        }
        #expect(abs(contact.cornerRadiusFraction - 0.35) < 1e-6)
    }

    @Test func zeroOpacityPreservesGeometryAndContactStructure() {
        for base in [WellShadow.light, .dark] {
            let shadow = base.scaled(opacity: 0, extent: 0.3)
            #expect(shadow.top.startOpacity == 0)
            #expect(shadow.top.midOpacity == 0)
            #expect([shadow.left, shadow.right, shadow.bottom].allSatisfy { $0.opacity == 0 })
            #expect(shadow.contact?.linear.count == base.contact?.linear.count)
            #expect(shadow.contact?.corner.count == base.contact?.corner.count)
            if let contact = shadow.contact {
                #expect(contact.linear.allSatisfy { $0.opacity == 0 })
                #expect(contact.corner.allSatisfy { $0.opacity == 0 })
            }
        }
    }

    @Test func gradientStopsRemainOrderedAcrossExtentRange() {
        for extent in stride(from: 0.3, through: 1.0, by: 0.05) {
            for base in [WellShadow.light, .dark] {
                let shadow = base.scaled(opacity: 0.75, extent: extent)
                #expect(shadow.top.midStop > 0)
                #expect(shadow.top.midStop < shadow.top.endStop)
                #expect(shadow.top.endStop <= 1)
                if let contact = shadow.contact {
                    for stops in [contact.linear, contact.corner] {
                        #expect(zip(stops, stops.dropFirst()).allSatisfy { $0.location < $1.location })
                    }
                }
            }
        }
    }

    @Test func invalidSettingsAreClampedBeforeRendering() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            #expect(AppSettingsDefault.clampedVUMeterShadowOpacity(invalid) == 0.75)
            #expect(AppSettingsDefault.clampedVUMeterShadowExtent(invalid) == 1)
        }
        #expect(AppSettingsDefault.clampedVUMeterShadowOpacity(-1) == 0)
        #expect(AppSettingsDefault.clampedVUMeterShadowOpacity(5) == 1)
        let palette = VUMeterPalette.resolved(
            faceHex: "#1C1D20", lampHex: "#FFD9A0", shadowOpacity: .nan, shadowExtent: 5
        )
        #expect(palette.shadowOpacity == 0.75)
        #expect(palette.shadowExtent == 1)
        let minimum = VUMeterPalette.resolved(
            faceHex: "#E5E89D", lampHex: "#FFD9A0", shadowOpacity: -1, shadowExtent: 0
        )
        #expect(minimum.shadowOpacity == 0)
        #expect(minimum.shadowExtent == 0.3)
    }

    @Test func defaultsUseVariantBForBothFaces() {
        #expect(AppSettingsDefault.vuMeterShadowOpacity == 0.75)
        #expect(AppSettingsDefault.vuMeterShadowExtent == 1)
        for face in ["#E5E89D", "#1C1D20"] {
            let palette = VUMeterPalette.resolved(faceHex: face, lampHex: "#FFD9A0")
            let base = palette.isDarkFace ? WellShadow.dark : .light
            #expect(palette.wellShadow == base.scaled(opacity: 0.75, extent: 1))
            let changed = VUMeterPalette.resolved(
                faceHex: face, lampHex: "#FFD9A0", shadowOpacity: 0.4, shadowExtent: 0.7
            )
            #expect(palette != changed)
            #expect(palette.needle == changed.needle)
            #expect(palette.glassIntensity == changed.glassIntensity)
            #expect(palette.lampIntensity == changed.lampIntensity)
        }
    }
}

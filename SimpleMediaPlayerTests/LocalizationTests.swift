import Foundation
import Testing

struct LocalizationTests {
    @Test(arguments: ["en", "ja"])
    func playerAccessibilityLabelsHaveLocalizedResources(language: String) throws {
        let bundle = try localizedBundle(language)
        let expected = language == "ja"
            ? ["Key": "キー", "Speed": "速度", "On": "オン", "Off": "オフ"]
            : ["Key": "Key", "Speed": "Speed", "On": "On", "Off": "Off"]

        for (key, value) in expected {
            #expect(bundle.localizedString(forKey: key, value: nil, table: nil) == value)
        }
        // The LED faceplate uses the same English legends in both languages.
        for legend in ["KEY", "BPM", "EQ"] {
            #expect(bundle.localizedString(forKey: legend, value: nil, table: nil) == legend)
        }
    }

    @Test(arguments: ["en", "ja"])
    func musicPermissionExplanationIsBundledForEachLanguage(language: String) throws {
        let bundle = try localizedBundle(language)
        let strings = try stringTable("InfoPlist", in: bundle)
        let explanation = try #require(strings["NSAppleEventsUsageDescription"])
        let expected = language == "ja"
            ? "Musicライブラリから曲情報を読み取るために使用します。"
            : "Used to read song information from your Music library."

        #expect(explanation == expected)
        #expect(bundle.localizedString(
            forKey: "NSAppleEventsUsageDescription",
            value: nil,
            table: "InfoPlist"
        ) == expected)
    }

    @Test func musicAccessErrorsHaveJapaneseTranslations() throws {
        let bundle = try localizedBundle("ja")
        let strings = try stringTable("Localizable", in: bundle)

        for key in [
            "Could not prepare Music library access.",
            "Music library access failed.",
            "Music library metadata could not be read; embedded metadata was used instead: %@"
        ] {
            let translation = try #require(strings[key], "Missing Japanese translation: \(key)")
            #expect(!translation.isEmpty)
            #expect(translation != key)
        }
    }

    @Test(arguments: ["en", "ja"])
    func musicAnalysisAndImportMessagesPreserveSubstitutedValues(language: String) throws {
        let bundle = try localizedBundle(language)
        let pitchFormat = bundle.localizedString(forKey: "Key%+d", value: nil, table: nil)
        #expect(String(format: pitchFormat, 2) == (language == "ja" ? "キー+2" : "Key+2"))
        #expect(String(format: pitchFormat, -2) == (language == "ja" ? "キー-2" : "Key-2"))

        let analysisFormat = bundle.localizedString(
            forKey: "KEY %@, %@ BPM. %@", value: nil, table: nil
        )
        let analysis = String(format: analysisFormat, "C", "120", "Status")
        #expect(analysis == (language == "ja" ? "キー C、120 BPM。Status" : "KEY C, 120 BPM. Status"))

        let warningFormat = bundle.localizedString(
            forKey: "Music library metadata could not be read; embedded metadata was used instead: %@",
            value: nil,
            table: nil
        )
        let warning = String(format: warningFormat, "Error 123")
        let expectedWarning = language == "ja"
            ? "Musicライブラリから曲情報を読み取れなかったため、埋め込みメタデータを使用しました: Error 123"
            : "Music library metadata could not be read; embedded metadata was used instead: Error 123"
        #expect(warning == expectedWarning)
    }

    @Test func japaneseFormatsPreserveEnglishArgumentPositionsAndTypes() throws {
        let english = try localizedBundle("en")
        let japanese = try stringTable("Localizable", in: localizedBundle("ja"))
        #expect(!japanese.isEmpty)

        for (key, translation) in japanese {
            // English source strings may be omitted from the compiled table and use the key as fallback.
            let source = english.localizedString(forKey: key, value: nil, table: nil)
            #expect(
                try formatArguments(in: translation) == formatArguments(in: source),
                "Format arguments differ for: \(key)"
            )
        }
    }

    private func localizedBundle(_ language: String) throws -> Bundle {
        #expect(Bundle.main.localizations.contains(language))
        let url = try #require(Bundle.main.url(forResource: language, withExtension: "lproj"))
        return try #require(Bundle(url: url))
    }

    private func stringTable(_ name: String, in bundle: Bundle) throws -> [String: String] {
        let url = try #require(bundle.url(forResource: name, withExtension: "strings"))
        let propertyList = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(propertyList as? [String: String])
    }

    private func formatArguments(in format: String) throws -> [String] {
        let pattern = #"%%|%(?:(\d+)\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(hh|ll|h|l|j|z|t|L)?([@diuoxXfFeEgGaAcCsSpn])"#
        let expression = try NSRegularExpression(pattern: pattern)
        let text = format as NSString
        var nextPosition = 1
        var arguments: [String] = []

        for match in expression.matches(in: format, range: NSRange(location: 0, length: text.length)) {
            guard text.substring(with: match.range) != "%%" else { continue }
            let positionRange = match.range(at: 1)
            let position: Int
            if positionRange.location == NSNotFound {
                position = nextPosition
                nextPosition += 1
            } else {
                position = try #require(Int(text.substring(with: positionRange)))
            }
            let lengthRange = match.range(at: 2)
            let length = lengthRange.location == NSNotFound ? "" : text.substring(with: lengthRange)
            let conversion = text.substring(with: match.range(at: 3))
            arguments.append("\(position):\(length)\(conversion)")
        }
        return arguments.sorted()
    }
}

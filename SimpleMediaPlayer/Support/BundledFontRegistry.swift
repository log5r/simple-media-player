import CoreText
import Foundation

enum BundledFontRegistry {
    private static let fontFileNames = [
        "DSEG7ClassicMini-Regular.ttf",
        "Dotrice-Regular.otf",
        "DotGothic16-Regular.ttf"
    ]

    private static var didRegister = false

    static func registerFonts() {
        guard didRegister == false else { return }
        didRegister = true

        for fileName in fontFileNames {
            guard let url = bundledFontURL(fileName: fileName) else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static func bundledFontURL(fileName: String) -> URL? {
        if let url = Bundle.main.url(forResource: fileName, withExtension: nil) {
            return url
        }

        guard let resourceURL = Bundle.main.resourceURL,
              let enumerator = FileManager.default.enumerator(
                at: resourceURL,
                includingPropertiesForKeys: nil
              ) else {
            return nil
        }

        for case let url as URL in enumerator where url.lastPathComponent == fileName {
            return url
        }

        return nil
    }
}

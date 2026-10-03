import SwiftUI

enum PanelContent: CaseIterable, Identifiable {
    case lyrics
    case information

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .lyrics: "Lyrics"
        case .information: "Info"
        }
    }

    var systemImage: String {
        switch self {
        case .lyrics: "text.quote"
        case .information: "info.circle"
        }
    }
}

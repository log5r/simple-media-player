import Foundation

nonisolated extension AppSettingsKey {
    /// When on, the previous and next transport buttons move between the sections found by music analysis.
    static let sectionNavigationEnabled = "sectionNavigationEnabled"
}

nonisolated extension AppSettingsDefault {
    static let sectionNavigationEnabled = false
}

import Foundation

nonisolated enum LibraryListUITestFixture {
    static var searchText: String {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing-multiple-selection"),
              let value = arguments.first(where: { $0.hasPrefix("--ui-testing-library-search=") }) else { return "" }
        // Narrow the visible rows before XCTest snapshots a library containing thousands of models.
        return String(value.dropFirst("--ui-testing-library-search=".count))
        #else
        return ""
        #endif
    }
}

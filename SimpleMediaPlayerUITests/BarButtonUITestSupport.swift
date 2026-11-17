#if os(iOS)
import XCTest

extension XCUIApplication {
    /// The phone layout's tab for `title`.
    /// An ordinary iPhone shows the tabs in the tab bar with only their localized labels. iPhone Duo's outer screen
    /// moves them into the vertical toolbar on the right edge and names them after their SF Symbols, so match the
    /// label. The back button shares that toolbar and its label repeats the previous title on an ordinary iPhone.
    @MainActor func tabButton(_ title: String, timeout: TimeInterval = 10) -> XCUIElement {
        barButton(
            in: [.tabBar, .toolbar],
            matching: NSPredicate(format: "label == %@ AND identifier != %@", title, "BackButton"),
            timeout: timeout
        )
    }

    /// The system back button of the front navigation stack.
    /// An ordinary iPhone keeps it in the navigation bar. iPhone Duo's outer screen leaves only the title there and
    /// moves the button, without a label, into the vertical toolbar. Both keep the `BackButton` identifier.
    @MainActor func navigationBackButton(timeout: TimeInterval = 10) -> XCUIElement {
        barButton(
            in: [.navigationBar, .toolbar],
            matching: NSPredicate(format: "identifier == %@", "BackButton"),
            timeout: timeout
        )
    }

    /// A visible top bar item such as Edit Lyrics, matched by its localized label.
    /// An ordinary iPhone shows it in the navigation bar, and iPhone Duo's outer screen in the vertical toolbar.
    /// This does not open `ToolbarOverflowMenu`, so an item that moved into the menu is not found.
    @MainActor func navigationBarButton(_ label: String, timeout: TimeInterval = 10) -> XCUIElement {
        barButton(in: [.navigationBar, .toolbar], matching: NSPredicate(format: "label == %@", label), timeout: timeout)
    }

    /// Waits until a button matching `predicate` exists in any of `bars`, then returns it from the first bar type
    /// that contains it. A query cannot combine two ancestor types, so one query over every bar type waits, and the
    /// per-type queries decide afterwards. An ordinary iPhone also exposes a full-screen toolbar container, so the
    /// first bar type wins when both contain the button. Without a match, the first bar type's query is returned so
    /// the caller's assertion or tap reports the failure.
    @MainActor private func barButton(
        in bars: [XCUIElement.ElementType], matching predicate: NSPredicate, timeout: TimeInterval
    ) -> XCUIElement {
        let barTypes = NSCompoundPredicate(orPredicateWithSubpredicates: bars.map {
            NSPredicate(format: "elementType == %lu", $0.rawValue)
        })
        let anyBar = descendants(matching: .any).matching(barTypes).buttons.matching(predicate).firstMatch
        let candidates = bars.map { descendants(matching: $0).buttons.matching(predicate).firstMatch }
        guard anyBar.waitForExistence(timeout: timeout) else { return candidates[0] }
        return candidates.first { $0.exists } ?? candidates[0]
    }
}
#endif

import SwiftUI

struct MediaInfoCommandAction {
    private let perform: @MainActor () -> Void

    init(_ perform: @escaping @MainActor () -> Void) {
        self.perform = perform
    }

    @MainActor
    func callAsFunction() {
        perform()
    }
}

private struct MediaInfoCommandActionKey: FocusedValueKey {
    typealias Value = MediaInfoCommandAction
}

extension FocusedValues {
    var mediaInfoCommandAction: MediaInfoCommandAction? {
        get { self[MediaInfoCommandActionKey.self] }
        set { self[MediaInfoCommandActionKey.self] = newValue }
    }
}

struct MediaInfoCommands: Commands {
    @FocusedValue(\.mediaInfoCommandAction) private var mediaInfoCommandAction

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Get Info") {
                mediaInfoCommandAction?()
            }
            .keyboardShortcut("i", modifiers: .command)
            .disabled(mediaInfoCommandAction == nil)
        }
    }
}

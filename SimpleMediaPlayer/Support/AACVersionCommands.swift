import SwiftUI

struct AACVersionCommandAction {
    private let perform: @MainActor () -> Void

    init(_ perform: @escaping @MainActor () -> Void) {
        self.perform = perform
    }

    @MainActor
    func callAsFunction() {
        perform()
    }
}

private struct AACVersionCommandActionKey: FocusedValueKey {
    typealias Value = AACVersionCommandAction
}

extension FocusedValues {
    var aacVersionCommandAction: AACVersionCommandAction? {
        get { self[AACVersionCommandActionKey.self] }
        set { self[AACVersionCommandActionKey.self] = newValue }
    }
}

struct AACVersionCommands: Commands {
    @FocusedValue(\.aacVersionCommandAction) private var aacVersionCommandAction

    var body: some Commands {
        CommandMenu("Convert") {
            Button("Create AAC Version") {
                aacVersionCommandAction?()
            }
            .disabled(aacVersionCommandAction == nil)
        }
    }
}

#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import SimpleMediaPlayer

@MainActor
@Suite(.serialized)
struct TextEditingKeyRoutingTests {
    private static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    private static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
    private static let upArrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    // Hardware arrow keys always carry these flags. The menu ignores them, and so must the routing.
    private static let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]

    private static let collidingKeys: [(String, NSEvent.ModifierFlags)] = [
        (leftArrow, .command),
        (rightArrow, .command),
        (leftArrow, .option),
        (rightArrow, .option),
        (upArrow, .command),
        (downArrow, .command)
    ]
    private static let otherKeys: [(String, NSEvent.ModifierFlags)] = [
        (leftArrow, []),
        (leftArrow, [.command, .shift]),
        (rightArrow, [.option, .shift]),
        (leftArrow, .control),
        (leftArrow, [.command, .option]),
        (upArrow, [.command, .option]),
        (" ", []),
        ("[", .command),
        ("]", .command),
        (".", .command),
        ("m", .command),
        ("a", .command)
    ]

    @Test(arguments: collidingKeys)
    func collidingMenuKeysGoToEditableText(characters: String, modifiers: NSEvent.ModifierFlags) {
        let textView = NSTextView()
        #expect(TextEditingKeyRouting.shouldRouteToText(
            charactersIgnoringModifiers: characters,
            modifierFlags: modifiers.union(Self.arrowFlags),
            responder: textView
        ))
        #expect(TextEditingKeyRouting.shouldRouteToText(
            charactersIgnoringModifiers: characters,
            modifierFlags: modifiers.union(Self.arrowFlags).union(.capsLock),
            responder: textView
        ))
    }

    @Test(arguments: otherKeys)
    func otherKeysAreNotRouted(characters: String, modifiers: NSEvent.ModifierFlags) {
        #expect(TextEditingKeyRouting.shouldRouteToText(
            charactersIgnoringModifiers: characters,
            modifierFlags: modifiers.union(Self.arrowFlags),
            responder: NSTextView()
        ) == false)
    }

    @Test func nonEditableRespondersKeepTheMenuShortcut() {
        let selectableText = NSTextView()
        selectableText.isEditable = false
        selectableText.isSelectable = true
        for responder in [selectableText, NSTextField(), NSView(), nil] as [NSResponder?] {
            #expect(TextEditingKeyRouting.shouldRouteToText(
                charactersIgnoringModifiers: Self.leftArrow,
                modifierFlags: [.command, .function, .numericPad],
                responder: responder
            ) == false)
        }
    }

    @Test func menuShortcutsMatchTheKeysTheEventsCarry() {
        let shortcuts = [
            AppMenuShortcut.previousTrack,
            AppMenuShortcut.nextTrack,
            AppMenuShortcut.skipBack,
            AppMenuShortcut.skipForward,
            AppMenuShortcut.volumeUp,
            AppMenuShortcut.volumeDown
        ]
        #expect(Set(shortcuts) == Set(AppMenuShortcut.textEditingCollisions))
        for (shortcut, (characters, modifiers)) in zip(shortcuts, Self.collidingKeys) {
            #expect(TextEditingKeyRouting.collidingShortcut(
                charactersIgnoringModifiers: characters,
                modifierFlags: modifiers.union(Self.arrowFlags)
            ) == shortcut)
        }
    }

    /// Sends the keys through `NSApplication.sendEvent`, where AppKit matches main-menu key equivalents
    /// before the focused field editor. Without the routing, ⌘← and ⌥← run the menu item instead.
    @Test func focusedFieldEditsTextInsteadOfRunningTheMenuItem() throws {
        let fixture = try MenuFixture()
        defer { fixture.tearDown() }
        let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 200, height: 24))
        field.stringValue = "abc def"
        fixture.window.contentView?.addSubview(field)
        #expect(fixture.window.makeFirstResponder(field))
        let editor = try #require(fixture.window.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        editor.setSelectedRange(NSRange(location: 7, length: 0))

        try fixture.send(Self.leftArrow, .command, keyCode: 123)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
        try fixture.send(Self.rightArrow, .command, keyCode: 124)
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0))
        try fixture.send(Self.leftArrow, .option, keyCode: 123)
        #expect(editor.selectedRange() == NSRange(location: 4, length: 0))
        try fixture.send(Self.upArrow, .command, keyCode: 126)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
        try fixture.send(Self.downArrow, .command, keyCode: 125)
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0))
        try fixture.send(Self.rightArrow, .option, keyCode: 124)
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0))
        // Space is not routed. AppKit already inserts it instead of running the play/pause item.
        try fixture.send(" ", [], keyCode: 49)
        #expect(editor.string == "abc def ")
        #expect(fixture.target.performedTitles.isEmpty)

        // ⇧⌘← does not match the menu item and keeps its text selection behavior.
        try fixture.send(Self.leftArrow, [.command, .shift], keyCode: 123)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 8))
        #expect(fixture.target.performedTitles.isEmpty)
    }

    @Test func menuItemsStillRunWithoutEditableTextFocus() throws {
        let fixture = try MenuFixture()
        defer { fixture.tearDown() }
        let selectableText = NSTextView(frame: NSRect(x: 10, y: 10, width: 200, height: 40))
        selectableText.string = "abc def"
        selectableText.isEditable = false
        selectableText.isSelectable = true
        fixture.window.contentView?.addSubview(selectableText)

        #expect(fixture.window.makeFirstResponder(selectableText))
        try fixture.send(Self.leftArrow, .command, keyCode: 123)
        #expect(fixture.target.performedTitles == ["previousTrack"])

        #expect(fixture.window.makeFirstResponder(nil))
        try fixture.send(Self.rightArrow, .command, keyCode: 124)
        try fixture.send(Self.leftArrow, .option, keyCode: 123)
        try fixture.send(Self.downArrow, .command, keyCode: 125)
        #expect(fixture.target.performedTitles == ["previousTrack", "nextTrack", "skipBack", "volumeDown"])
    }
}

@MainActor
private final class MenuFixture {
    final class Target: NSObject {
        var performedTitles: [String] = []

        @objc func runMenuItem(_ sender: NSMenuItem) {
            performedTitles.append(sender.title)
        }
    }

    let target = Target()
    let window: NSWindow
    private let savedMainMenu: NSMenu?

    init() throws {
        TextEditingKeyRouting.install()
        let submenu = NSMenu(title: "Controls")
        let shortcuts: [(String, KeyboardShortcut)] = [
            ("playPause", KeyboardShortcut(.space, modifiers: [])),
            ("previousTrack", AppMenuShortcut.previousTrack),
            ("nextTrack", AppMenuShortcut.nextTrack),
            ("skipBack", AppMenuShortcut.skipBack),
            ("skipForward", AppMenuShortcut.skipForward),
            ("volumeUp", AppMenuShortcut.volumeUp),
            ("volumeDown", AppMenuShortcut.volumeDown)
        ]
        for (title, shortcut) in shortcuts {
            let item = NSMenuItem(
                title: title,
                action: #selector(Target.runMenuItem(_:)),
                keyEquivalent: String(shortcut.key.character)
            )
            item.keyEquivalentModifierMask = Self.modifierFlags(from: shortcut.modifiers)
            item.target = target
            submenu.addItem(item)
        }
        let controls = NSMenuItem(title: "Controls", action: nil, keyEquivalent: "")
        controls.submenu = submenu
        let mainMenu = NSMenu()
        mainMenu.addItem(controls)
        savedMainMenu = NSApp.mainMenu
        NSApp.mainMenu = mainMenu

        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 260, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }

    func tearDown() {
        window.close()
        NSApp.mainMenu = savedMainMenu
    }

    func send(_ characters: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16) throws {
        let flags = keyCode == 49 ? modifiers : modifiers.union([.function, .numericPad])
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
        NSApp.sendEvent(event)
    }

    private static func modifierFlags(from modifiers: EventModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }
}
#endif

#if os(macOS)
import AppKit
import SwiftUI

/// テキスト編集の標準操作と重なるメニューのキーを、編集中のテキストへ渡す。
///
/// AppKit はメインメニューのキー割り当てを、フォーカス中のテキストの `keyDown(with:)` より先に照合する。
/// そのため ⌘← などをメニューに割り当てると、テキストの編集中でもメニューの操作が実行され、
/// カーソルは移動しない。編集可能なテキストにフォーカスがある間だけ、
/// `AppMenuShortcut.textEditingCollisions` に該当するキーをテキストへ直接渡し、メニューには渡さない。
/// 選択できるだけの編集不可のテキストや、マウスでのメニュー操作は従来どおりメニューが扱う。
@MainActor
enum TextEditingKeyRouting {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            route(event)
        }
    }

    /// テキストへ渡したときは nil を返し、メニューを含む以降の処理には渡さない。
    static func route(_ event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown,
              let textView = (event.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView,
              shouldRouteToText(
                  charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                  modifierFlags: event.modifierFlags,
                  responder: textView
              )
        else { return event }
        // 通常のキー入力と同じく入力メソッドを経由するため、変換中の文字列も入力メソッドが扱う。
        textView.keyDown(with: event)
        return nil
    }

    static func shouldRouteToText(
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags,
        responder: NSResponder?
    ) -> Bool {
        guard let textView = responder as? NSTextView, textView.isEditable else { return false }
        return collidingShortcut(
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifierFlags: modifierFlags
        ) != nil
    }

    /// メニューと同じく、修飾キーが完全に一致するときだけ該当とする。⇧⌘← などはメニューに一致しない。
    static func collidingShortcut(
        charactersIgnoringModifiers: String?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> KeyboardShortcut? {
        guard let characters = charactersIgnoringModifiers, characters.count == 1,
              let character = characters.first
        else { return nil }
        let modifiers = eventModifiers(from: modifierFlags)
        return AppMenuShortcut.textEditingCollisions.first {
            $0.key.character == character && $0.modifiers == modifiers
        }
    }

    // 矢印キーに付く .function / .numericPad と Caps Lock は、メニューの照合でも区別しない。
    private static func eventModifiers(from flags: NSEvent.ModifierFlags) -> EventModifiers {
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}
#endif

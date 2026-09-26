import SwiftUI

#if os(macOS)
import AppKit

// 設定シートの初回表示では SwiftUI の Form / NavigationStack 系機構の
// 遅延ロード(dyld・ページイン)が一度だけ走る。通常起動では問題にならないが、
// デバッガ接続時(Xcodeから実行)はこのロードが大幅に遅くなり、再生中だと
// オーディオIOが数十ms締切を落として「プツッ」というノイズになる。
// 起動直後にオフスクリーンで一度レイアウト・描画させ、ロードを前倒しする。
@MainActor
enum SettingsSheetPrewarmer {
    private static var isDone = false

    static func prewarm() {
        guard isDone == false else { return }
        isDone = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AppSettingsView())
        window.layoutIfNeeded()
        window.displayIfNeeded()
        window.close()
    }
}
#endif

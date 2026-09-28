#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import SimpleMediaPlayer

@MainActor
final class MarqueeTextHitTestingTests: XCTestCase {
    func testClippedTextDoesNotInterceptAdjacentButtonClicks() async throws {
        let appeared = expectation(description: "The hosted view appeared")
        let clicked = expectation(description: "The adjacent button received the click")
        var clickCount = 0
        let hostingView = NSHostingView(rootView: testContent {
            clickCount += 1
            clicked.fulfill()
        }.onAppear { appeared.fulfill() })
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 260, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        await fulfillment(of: [appeared], timeout: 2)
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // Outside the title's 80-point viewport, inside the invisible overflowing text.
        let location = hostingView.convert(NSPoint(x: 140, y: 36), to: nil)
        try click(at: location, in: window)
        await fulfillment(of: [clicked], timeout: 2)
        XCTAssertEqual(clickCount, 1, "Clipped title text must not block an adjacent button")
    }

    private func testContent(action: @escaping () -> Void) -> some View {
        ZStack(alignment: .topLeading) {
            Button(action: action) {
                Rectangle().fill(.blue)
            }
            .buttonStyle(.plain)
            .frame(width: 80, height: 32)
            .offset(x: 100, y: 20)

            // Draw the title last so its clipped overflow lies above the button.
            // A long title overlaps it immediately, without waiting for a scroll cycle.
            MarqueeText(
                text: String(repeating: "Long track title ", count: 8),
                font: .system(size: 20, design: .monospaced)
            )
            .frame(width: 80, height: 32)
            .offset(y: 20)
        }
        .frame(width: 260, height: 80, alignment: .topLeading)
    }

    private func click(at location: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ))
            window.sendEvent(event)
        }
    }
}
#endif

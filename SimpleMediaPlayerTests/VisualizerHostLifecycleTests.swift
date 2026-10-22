import Observation
import SwiftUI
import XCTest
@testable import SimpleMediaPlayer

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class VisualizerHostLifecycleTests: XCTestCase {
    func testVisibleVisualizerTracksReduceMotionChangesAndRemoval() async throws {
        try await exerciseLifecycle(initialReduceMotion: false)
    }

    func testInitiallyReducedMotionDoesNotRegisterAConsumer() async throws {
        try await exerciseLifecycle(initialReduceMotion: true)
    }

    private func exerciseLifecycle(initialReduceMotion: Bool) async throws {
        let player = makePlayerFixture().player
        let state = VisualizerPresentationState(reduceMotion: initialReduceMotion)
        let appeared = expectation(description: "The visualizer is installed in a visible window")
        let host = try HostedVisualizer(player: player, state: state) { appeared.fulfill() }
        defer { host.close() }
        await fulfillment(of: [appeared], timeout: 5)
        try await waitUntil { player.isVisualizationSuspended == initialReduceMotion }

        // Both initial values must support switching the injected motion preference while the same view is installed.
        state.reduceMotion = !initialReduceMotion
        try await waitUntil { player.isVisualizationSuspended == !initialReduceMotion }
        state.reduceMotion = initialReduceMotion
        try await waitUntil { player.isVisualizationSuspended == initialReduceMotion }

        state.reduceMotion = false
        try await waitUntil { !player.isVisualizationSuspended }
        state.isVisible = false
        try await waitUntil { player.isVisualizationSuspended }
        state.isVisible = true
        try await waitUntil { !player.isVisualizationSuspended }

        // Removing the hosting controller must release the reappeared consumer as well.
        host.close()
        try await waitUntil { player.isVisualizationSuspended }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "The hosted visualizer did not update its analysis consumer")
    }
}

@MainActor
@Observable
private final class VisualizerPresentationState {
    var reduceMotion: Bool
    var isVisible = true

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }
}

private struct VisualizerLifecycleContent: View {
    let player: PlayerViewModel
    let state: VisualizerPresentationState
    let appeared: () -> Void

    var body: some View {
        Group {
            if state.isVisible {
                VisualizerHostView(
                    player: player,
                    palette: .resolved(
                        styleRaw: "dark", darkForegroundHex: AppSettingsDefault.ledColorHex,
                        backlitForegroundHex: AppSettingsDefault.ledBacklitForegroundColorHex,
                        backlightHex: AppSettingsDefault.ledBacklightColorHex
                    ),
                    reduceMotionOverride: state.reduceMotion
                )
            } else {
                Color.clear
            }
        }
        .frame(width: 320, height: 120)
        .onAppear(perform: appeared)
    }
}

@MainActor
private final class HostedVisualizer {
    #if os(macOS)
    private let window: NSWindow
    #else
    private let window: UIWindow
    private weak var previousKeyWindow: UIWindow?
    #endif

    init(player: PlayerViewModel, state: VisualizerPresentationState, appeared: @escaping () -> Void) throws {
        let content = VisualizerLifecycleContent(player: player, state: state, appeared: appeared)
        #if os(macOS)
        let hosting = NSHostingView(rootView: content)
        window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 320, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        #else
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        #endif
    }

    func close() {
        #if os(macOS)
        window.contentView = nil
        window.close()
        #else
        window.rootViewController = nil
        window.isHidden = true
        previousKeyWindow?.makeKey()
        #endif
    }
}

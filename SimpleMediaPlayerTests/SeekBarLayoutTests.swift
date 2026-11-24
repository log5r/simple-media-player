#if os(iOS)
import SwiftUI
import UIKit
import XCTest
@testable import SimpleMediaPlayer

@MainActor
final class SeekBarLayoutTests: XCTestCase {
    func testLongSeekTimesUseTwoRowsOnlyWhenTheyCannotShareTheColumn() async throws {
        let player = makePlayerFixture().player
        player.duration = 210 * 60
        player.currentTime = 100 * 60

        let wideHeight = try await seekHeight(player: player, width: 360)
        let narrowHeight = try await seekHeight(player: player, width: 180)
        let sliderHeight: CGFloat = 44
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let lineHeight = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits).lineHeight
        XCTAssertEqual(wideHeight - sliderHeight, lineHeight, accuracy: 2, "100:00 and -110:00 share a row")
        XCTAssertEqual(narrowHeight - sliderHeight, 2 * (wideHeight - sliderHeight), accuracy: 2,
                       "Both times keep their own full-height row")
    }

    private func seekHeight(player: PlayerViewModel, width: CGFloat) async throws -> CGFloat {
        let measured = expectation(description: "Seek bar has laid out its time labels at width \(width)")
        var height: CGFloat?
        let content = SeekBarView(player: player, drawsOnPanel: true)
            .frame(width: width)
            .dynamicTypeSize(.accessibility5)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newHeight in
                // The bar measures its labels after its initial slider-only layout.
                guard newHeight > 44, height == nil else { return }
                height = newHeight
                measured.fulfill()
            }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: content)
        window.isHidden = false
        defer { window.isHidden = true }
        await fulfillment(of: [measured], timeout: 5)
        return try XCTUnwrap(height)
    }
}
#endif

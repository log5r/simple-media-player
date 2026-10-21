import SwiftUI
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LibraryLayoutPolicyTests {
    @Test func sizeClassTakesPrecedenceOverWidth() {
        #expect(LibraryLayoutPolicy.usesCompactLayout(horizontalSizeClass: .compact, width: 900))
        #expect(!LibraryLayoutPolicy.usesCompactLayout(horizontalSizeClass: .regular, width: 550))
        #expect(LibraryLayoutPolicy.usesCompactLayout(horizontalSizeClass: nil, width: 599))
        #expect(!LibraryLayoutPolicy.usesCompactLayout(horizontalSizeClass: nil, width: 600))
    }

    @Test func detailsRequireSpaceBesideTheListAndReadableText() {
        #expect(!LibraryLayoutPolicy.showsInlineDetails(size: CGSize(width: 719, height: 500),
                                                       accessibilityText: false))
        #expect(!LibraryLayoutPolicy.showsInlineDetails(size: CGSize(width: 800, height: 299),
                                                       accessibilityText: false))
        #expect(LibraryLayoutPolicy.showsInlineDetails(size: CGSize(width: 720, height: 300),
                                                      accessibilityText: false))
        // iPhone Duo's Open portrait list would keep only 429pt beside the details column.
        #expect(!LibraryLayoutPolicy.showsInlineDetails(size: CGSize(width: 669, height: 951),
                                                       accessibilityText: false))
        // iPad mini's portrait list keeps 504pt, so it still shows the column.
        #expect(LibraryLayoutPolicy.showsInlineDetails(size: CGSize(width: 744, height: 1133),
                                                      accessibilityText: false))
        #expect(!LibraryLayoutPolicy.showsInlineDetails(size: CGSize(width: 900, height: 500),
                                                       accessibilityText: true))
    }

    @Test func equalizerLeavesRoomForBrowsing() {
        #expect(!LibraryLayoutPolicy.showsInlineEqualizer(size: CGSize(width: 800, height: 429),
                                                         accessibilityText: false))
        #expect(LibraryLayoutPolicy.showsInlineEqualizer(size: CGSize(width: 800, height: 430),
                                                        accessibilityText: false))
        #expect(!LibraryLayoutPolicy.showsInlineEqualizer(size: CGSize(width: 800, height: 700),
                                                         accessibilityText: true))
    }
}

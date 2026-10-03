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
        #expect(!LibraryLayoutPolicy.showsInlineDetails(size: CGSize(width: 619, height: 500),
                                                       accessibilityText: false))
        #expect(!LibraryLayoutPolicy.showsInlineDetails(size: CGSize(width: 700, height: 299),
                                                       accessibilityText: false))
        #expect(LibraryLayoutPolicy.showsInlineDetails(size: CGSize(width: 620, height: 300),
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

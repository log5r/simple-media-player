#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import SimpleMediaPlayer

@MainActor
final class AlbumBrowserAggregationTests: XCTestCase {
    func testLargeAlbumDetailDoesNotRegroupDuringSelectionAndPlaybackChanges() async throws {
        let items = (1...3_000).map { index in
            MediaItem(
                title: "Track \(index)", artist: "Artist", album: "Album \((index - 1) / 30)",
                trackNumber: "\(index)", duration: 120, isVideo: false,
                bookmarkData: Data(), fileName: "song.mp3"
            )
        }
        let probe = AlbumGroupingProbe()
        let projection = LibraryAlbumProjection(group: probe.group)
        let browsing = LibraryBrowsingState()
        let player = makePlayerFixture().player
        browsing.openGroup(section: .albums, name: "Album 0")
        let appeared = expectation(description: "Album detail appeared")
        let view = AlbumBrowserView(
            items: items, player: player,
            selectedItemID: Binding(get: { browsing.selectedItemID }, set: { browsing.selectedItemID = $0 }),
            isBulkEditMode: Binding(get: { browsing.isBulkEditMode }, set: { browsing.isBulkEditMode = $0 }),
            bulkSelection: browsing.bulkSelection, browsingState: browsing,
            itemMenu: { _ in EmptyView() }, albumProjection: projection
        )
        let hosting = NSHostingView(rootView: view.onAppear { appeared.fulfill() })
        let window = makeWindow(content: hosting)
        defer { window.close(); projection.clear() }
        await fulfillment(of: [appeared], timeout: 5)
        try await redraw(hosting)
        XCTAssertEqual(projection.albums.first?.tracks.count, 30)
        XCTAssertEqual(probe.count, 1, "The initial detail must aggregate only once, including its visible rows")

        browsing.closeGroup()
        try await redraw(hosting)
        browsing.openGroup(section: .albums, name: "Album 0")
        try await redraw(hosting)
        XCTAssertEqual(probe.count, 1, "Switching between the grid and detail must reuse the albums")

        for item in items.prefix(5) {
            browsing.selectedItemID = item.id
            player.currentItem = item
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        browsing.isBulkEditMode = true
        browsing.bulkSelection.toggle(items[0].id)
        try await redraw(hosting)
        XCTAssertEqual(probe.count, 1, "Row selection, playback and bulk selection must reuse the albums")

        items[0].albumArtist = "Ensemble"
        try await waitUntil { projection.albums.first?.artist == "Ensemble" }
        try await redraw(hosting)
        XCTAssertEqual(probe.count, 2, "A metadata edit must aggregate once, even while the view redraws")
    }

    private func makeWindow(content: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 900, height: 1_800),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func redraw(_ hosting: NSView) async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while condition() == false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition(), "The album detail did not update")
    }
}
#endif

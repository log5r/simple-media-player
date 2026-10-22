import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct LibraryScrollAnchorTests {
    private let ids = (0..<4).map { _ in UUID() }

    /// Rows 44 points tall, the first starting `offset` points above the viewport top.
    private func frames(scrolledBy offset: CGFloat) -> [UUID: CGRect] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id, CGRect(x: 0, y: CGFloat(index) * 44 - offset, width: 320, height: 44))
        })
    }

    @Test func pinnedHeaderHidesTheRowsBeneathIt() {
        // Row 0 spans -10..<34 and row 1 spans 34..<78; a 44-point header covers 0..<44.
        let rowFrames = frames(scrolledBy: 10)

        #expect(LibraryScrollAnchor.firstVisibleItemID(in: rowFrames, from: 0, to: 400) == ids[0])
        #expect(LibraryScrollAnchor.firstVisibleItemID(in: rowFrames, from: 44, to: 400) == ids[1])
    }

    @Test func rowEndingAtTheHeaderIsNotVisible() {
        // Row 0 spans 0..<44, entirely behind the header.
        let rowFrames = frames(scrolledBy: 0)

        #expect(LibraryScrollAnchor.firstVisibleItemID(in: rowFrames, from: 44, to: 400) == ids[1])
        #expect(LibraryScrollAnchor.firstVisibleItemID(in: rowFrames, from: 44, to: 44) == nil)
    }

    @Test func viewportShorterThanTheHeaderHasNoVisibleRow() {
        // A squeezed or not-yet-measured viewport ends above the header's bottom edge.
        let rowFrames = frames(scrolledBy: 10)

        #expect(LibraryScrollAnchor.firstVisibleItemID(in: rowFrames, from: 44, to: 30) == nil)
        #expect(LibraryScrollAnchor.firstVisibleItemID(in: rowFrames, from: 44, to: 0) == nil)

        // Row 1 spans 10..<54, reaching past both ends of the inverted interval.
        let straddling = frames(scrolledBy: 34)

        #expect(LibraryScrollAnchor.firstVisibleItemID(in: straddling, from: 44, to: 30) == nil)
    }

    @Test func sectionHeaderPinnedBelowTheInsetHidesRows() {
        // A navigation bar covers 0..<86, and a header's content sits in its cell's padding at 96..<140.
        let pinned = CGRect(x: 0, y: 96, width: 320, height: 44)

        #expect(LibraryScrollAnchor.visibleTop(belowInset: 86, sectionHeaders: [pinned]) == 140)
        #expect(LibraryScrollAnchor.visibleTop(belowInset: 86, sectionHeaders: []) == 86)
    }

    @Test func outgoingHeaderAndLowerHeadersDoNotRaiseTheTop() {
        // The next section's header pushes the pinned one up, and a later header is further down.
        let outgoing = CGRect(x: 0, y: 70, width: 320, height: 44)
        let incoming = CGRect(x: 0, y: 114, width: 320, height: 44)
        let later = CGRect(x: 0, y: 400, width: 320, height: 44)

        #expect(LibraryScrollAnchor.visibleTop(belowInset: 86, sectionHeaders: [outgoing, later]) == 114)
        #expect(LibraryScrollAnchor.visibleTop(belowInset: 86, sectionHeaders: [later]) == 86)
        #expect(LibraryScrollAnchor.visibleTop(belowInset: 86, sectionHeaders: [outgoing, incoming]) == 158)
    }

    @Test func tallUpcomingHeaderIsNotPinnedUntilItPushes() {
        // A wrapped title makes the next header taller than the pinned one, with part of a row between them.
        let pinned = CGRect(x: 0, y: 96, width: 320, height: 44)
        let upcoming = CGRect(x: 0, y: 160, width: 320, height: 88)
        let outgoing = CGRect(x: 0, y: 70, width: 320, height: 44)
        let incoming = CGRect(x: 0, y: 114, width: 320, height: 88)

        #expect(LibraryScrollAnchor.visibleTop(belowInset: 86, sectionHeaders: [pinned, upcoming]) == 140)
        #expect(LibraryScrollAnchor.visibleTop(belowInset: 86, sectionHeaders: [outgoing, incoming]) == 202)
    }
}

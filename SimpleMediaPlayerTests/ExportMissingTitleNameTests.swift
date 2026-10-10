import Foundation
import Testing
@testable import SimpleMediaPlayer

@MainActor
struct ExportMissingTitleNameTests {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let thirdID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let fourthID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    @Test func planStoresFilesWithoutEmbeddedTitlesInOrder() {
        let plan = makePlan()

        #expect(plan.missingTitleFiles.map(\.id) == [secondID, thirdID, fourthID])
        #expect(MediaExportPlan(files: [], preparationErrors: []).missingTitleFiles.isEmpty)
        let titled = MediaExportPlan(files: [draft(id: firstID, embeddedTitle: "Title")], preparationErrors: [])
        #expect(titled.missingTitleFiles.isEmpty)
    }

    @Test func everyMissingTitleNeedsANonBlankName() {
        let plan = makePlan()

        #expect(plan.hasNamesForMissingTitles([secondID: "Two", thirdID: " Three\n", fourthID: "Four"]))
        #expect(plan.hasNamesForMissingTitles([secondID: "Two", thirdID: "Three", fourthID: ""]) == false)
        #expect(plan.hasNamesForMissingTitles([secondID: "Two", thirdID: "Three", fourthID: "  \t "]) == false)
        #expect(plan.hasNamesForMissingTitles([secondID: "Two", thirdID: "Three", fourthID: "\n\r\n"]) == false)
        #expect(plan.hasNamesForMissingTitles([secondID: "Two", thirdID: "Three"]) == false)
        #expect(plan.hasNamesForMissingTitles([:]) == false)
    }

    @Test func embeddedTitlesNeedNoName() {
        let plan = MediaExportPlan(files: [draft(id: firstID, embeddedTitle: "Title")], preparationErrors: [])

        #expect(plan.hasNamesForMissingTitles([:]))
    }

    @Test func trimmedNamesKeepEveryEntryAndTrimWhitespaceAndNewlines() {
        let trimmed = MediaExportPlan.trimmedNames([
            secondID: "  Two  ",
            thirdID: "\nThree\t",
            fourthID: " \n "
        ])

        #expect(trimmed == [secondID: "Two", thirdID: "Three", fourthID: ""])
    }

    @Test func trimmedNamesResolveToTheExportedTitles() {
        let plan = makePlan()
        let names = MediaExportPlan.trimmedNames([secondID: " Two ", thirdID: "Three\n", fourthID: "\tFour"])

        let resolved = plan.resolvedFiles(nameOverrides: names)

        #expect(resolved.map(\.title) == ["Embedded", "Two", "Three", "Four"])
    }

    private func makePlan() -> MediaExportPlan {
        MediaExportPlan(
            files: [
                draft(id: firstID, embeddedTitle: "Embedded"),
                draft(id: secondID, embeddedTitle: nil),
                draft(id: thirdID, embeddedTitle: nil),
                draft(id: fourthID, embeddedTitle: nil)
            ],
            preparationErrors: []
        )
    }

    private func draft(id: UUID, embeddedTitle: String?) -> MediaExportFileDraft {
        MediaExportFileDraft(
            id: id,
            sourceURL: URL(fileURLWithPath: "/tmp/\(id.uuidString).m4a"),
            albumName: "Album",
            embeddedTitle: embeddedTitle,
            fileExtension: "m4a",
            originalFileName: "\(id.uuidString).m4a"
        )
    }
}

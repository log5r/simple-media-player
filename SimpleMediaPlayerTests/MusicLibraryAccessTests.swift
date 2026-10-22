#if os(iOS)
import Foundation
import MediaPlayer
import Testing
import UIKit
@testable import SimpleMediaPlayer

@MainActor
struct MusicLibraryAccessTests {
    @Test(arguments: [MPMediaLibraryAuthorizationStatus.authorized, .denied, .restricted])
    func decidedAuthorizationDoesNotRequestAgain(status: MPMediaLibraryAuthorizationStatus) async {
        let result = await MusicLibraryAccess.requestAuthorization(currentStatus: { status }, request: {
            Issue.record("An already decided permission must not prompt again.")
            return .notDetermined
        })
        #expect(result == expected(status))
    }

    @Test(arguments: [MPMediaLibraryAuthorizationStatus.authorized, .denied, .restricted, .notDetermined])
    func undecidedAuthorizationUsesTheRequestResult(status: MPMediaLibraryAuthorizationStatus) async {
        var calls = 0
        let result = await MusicLibraryAccess.requestAuthorization(currentStatus: { .notDetermined }, request: {
            calls += 1
            return status
        })
        #expect(calls == 1)
        #expect(result == expected(status))
    }

    @Test func settingsLinkUsesTheApplicationsSettingsURL() {
        #expect(MusicLibraryAccess.settingsURL == URL(string: UIApplication.openSettingsURLString))
    }

    private func expected(_ status: MPMediaLibraryAuthorizationStatus) -> MusicLibraryAccess.Availability {
        switch status {
        case .authorized: .authorized
        case .restricted: .restricted
        default: .denied
        }
    }
}
#endif

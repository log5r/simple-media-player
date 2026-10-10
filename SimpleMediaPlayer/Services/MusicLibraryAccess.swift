#if os(iOS)
import Foundation
import MediaPlayer
import UIKit

/// Music library permission for iPhone and iPad. This is separate from the macOS Apple Events
/// permission that reads song information from the Music app.
@MainActor
enum MusicLibraryAccess {
    enum Availability: Equatable {
        case authorized
        case denied
        case restricted
    }

    static func requestAuthorization() async -> Availability {
        if let availability = availability(for: MPMediaLibrary.authorizationStatus()) {
            return availability
        }
        let status = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) }
        }
        return availability(for: status) ?? .denied
    }

    static var settingsURL: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }

    private static func availability(for status: MPMediaLibraryAuthorizationStatus) -> Availability? {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: nil
        @unknown default: .denied
        }
    }
}

extension MusicLibraryTrack {
    /// Copies every text value while the item is still valid on the main actor. Artwork is only
    /// referenced here and rendered later by `resolvedArtworkData()`.
    @MainActor
    init(mediaItem: MPMediaItem, artworkPixelSize: CGFloat = 600) {
        self.init(id: mediaItem.persistentID, assetURL: mediaItem.assetURL)
        hasProtectedAsset = mediaItem.hasProtectedAsset
        isCloudItem = mediaItem.isCloudItem
        title = mediaItem.title
        artist = mediaItem.artist
        album = mediaItem.albumTitle
        albumArtist = mediaItem.albumArtist
        composer = mediaItem.composer
        genre = mediaItem.genre
        year = mediaItem.releaseDate.map { String(Self.yearCalendar.component(.year, from: $0)) }
        trackNumber = Self.numberPair(current: mediaItem.albumTrackNumber, total: mediaItem.albumTrackCount)
        discNumber = Self.numberPair(current: mediaItem.discNumber, total: mediaItem.discCount)
        comment = mediaItem.comments
        isCompilation = mediaItem.isCompilation
        lyrics = mediaItem.lyrics
        duration = mediaItem.playbackDuration
        if let artwork = mediaItem.artwork {
            let artworkSize = CGSize(width: artworkPixelSize, height: artworkPixelSize)
            loadArtwork = { artwork.image(at: artworkSize)?.cgImage }
        }
    }

    /// Release dates are calendar dates; reading them in UTC avoids shifting the year at midnight.
    private static let yearCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }()
}
#endif

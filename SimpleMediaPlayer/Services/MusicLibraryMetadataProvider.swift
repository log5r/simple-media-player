import Foundation

struct MusicLibraryMatchHints: Equatable, Sendable {
    var sortTitle: String?
    var sortArtist: String?
    var sortAlbum: String?
    var duration: TimeInterval
}

enum MusicLibraryMetadataLookupResult: Sendable {
    case found(MediaMetadataEmbeddedValues)
    case notFound
    case failed(String)
}

enum MusicLibraryMetadataProvider {
    nonisolated static func lookup(url: URL, hints: MusicLibraryMatchHints) async -> MusicLibraryMetadataLookupResult {
        #if os(macOS)
        return await Task.detached(priority: .utility) {
            lookupSynchronously(url: url, hints: hints)
        }.value
        #else
        return .notFound
        #endif
    }

    #if os(macOS)
    nonisolated static func appleScriptSource(url: URL, hints: MusicLibraryMatchHints) -> String {
        let targetPath = appleScriptString(url.standardizedFileURL.path)
        let sortTitle = appleScriptString(hints.sortTitle ?? "")
        let sortArtist = appleScriptString(hints.sortArtist ?? "")
        let sortAlbum = appleScriptString(hints.sortAlbum ?? "")
        let duration = hints.duration.isFinite ? max(0, hints.duration) : 0

        return """
        on textOrEmpty(theValue)
            if theValue is missing value then return ""
            return theValue as text
        end textOrEmpty

        on metadataFor(musicTrack)
            tell application "Music"
                return {my textOrEmpty(name of musicTrack), my textOrEmpty(artist of musicTrack), \
        my textOrEmpty(album of musicTrack), my textOrEmpty(album artist of musicTrack), \
        my textOrEmpty(composer of musicTrack), my textOrEmpty(genre of musicTrack), year of musicTrack, \
        track number of musicTrack, track count of musicTrack, disc number of musicTrack, \
        disc count of musicTrack, compilation of musicTrack, my textOrEmpty(comment of musicTrack)}
            end tell
        end metadataFor

        set targetPath to "\(targetPath)"
        set sortTitleHint to "\(sortTitle)"
        set sortArtistHint to "\(sortArtist)"
        set sortAlbumHint to "\(sortAlbum)"
        set durationHint to \(duration)

        tell application "Music"
            set matchedTrack to missing value

            try
                set targetFile to POSIX file targetPath as alias
                set pathMatches to every file track of library playlist 1 whose location is targetFile
                if (count of pathMatches) > 0 then set matchedTrack to item 1 of pathMatches
            end try

            if matchedTrack is missing value and sortTitleHint is not "" then
                try
                    set metadataMatches to every file track of library playlist 1 whose sort name is sortTitleHint
                    repeat with candidateTrack in metadataMatches
                        set artistMatches to sortArtistHint is "" or sort artist of candidateTrack is sortArtistHint
                        set albumMatches to sortAlbumHint is "" or sort album of candidateTrack is sortAlbumHint
                        set durationDifference to (duration of candidateTrack) - durationHint
                        if durationDifference < 0 then set durationDifference to -durationDifference
                        if artistMatches and albumMatches and durationDifference < 1 then
                            set matchedTrack to candidateTrack
                            exit repeat
                        end if
                    end repeat
                end try
            end if

            if matchedTrack is missing value then return {}
            return my metadataFor(matchedTrack)
        end tell
        """
    }

    nonisolated private static func lookupSynchronously(
        url: URL,
        hints: MusicLibraryMatchHints
    ) -> MusicLibraryMetadataLookupResult {
        guard let script = NSAppleScript(source: appleScriptSource(url: url, hints: hints)) else {
            return .failed("Could not prepare Music library access.")
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? "Music library access failed."
            return .failed(message)
        }
        guard result.numberOfItems >= 13 else {
            return .notFound
        }

        var values = MediaMetadataEmbeddedValues()
        values.title = normalized(result.atIndex(1)?.stringValue)
        values.artist = normalized(result.atIndex(2)?.stringValue)
        values.album = normalized(result.atIndex(3)?.stringValue)
        values.albumArtist = normalized(result.atIndex(4)?.stringValue)
        values.composer = normalized(result.atIndex(5)?.stringValue)
        values.genre = normalized(result.atIndex(6)?.stringValue)

        let year = result.atIndex(7)?.int32Value ?? 0
        values.year = year > 0 ? String(year) : nil
        values.trackNumber = numberPair(
            current: result.atIndex(8)?.int32Value ?? 0,
            total: result.atIndex(9)?.int32Value ?? 0
        )
        values.discNumber = numberPair(
            current: result.atIndex(10)?.int32Value ?? 0,
            total: result.atIndex(11)?.int32Value ?? 0
        )
        values.isCompilation = result.atIndex(12)?.booleanValue
        values.comment = normalized(result.atIndex(13)?.stringValue)
        return .found(values)
    }

    nonisolated private static func normalized(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    nonisolated private static func numberPair(current: Int32, total: Int32) -> String? {
        guard current > 0 else { return nil }
        return total > 0 ? "\(current)/\(total)" : "\(current)"
    }

    nonisolated private static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
    #endif
}

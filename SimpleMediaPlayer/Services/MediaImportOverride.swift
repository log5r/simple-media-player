import Foundation

/// Metadata that outranks a file's embedded tags during import, such as the values of the Music
/// library song a file was exported from. Edits made after the import outrank both, as usual.
nonisolated struct MediaImportOverride: Sendable, Equatable {
    var values = MediaMetadataEmbeddedValues()
    var artworkData: Data?
    var lyrics: String?
    var musicLibraryItemID: String?
    /// True when the same values were already written into the file, so the file and the item agree.
    var isEmbeddedInFile = false
}

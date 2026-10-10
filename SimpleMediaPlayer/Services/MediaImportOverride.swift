import Foundation

/// The outcome of one `importFiles` request. Imports are serialized, so a caller reads its own result
/// from here rather than from the service's shared progress state, which the next request resets.
nonisolated struct MediaImportSummary: Sendable, Equatable {
    var createdCount = 0
    var duplicateCount = 0
    var errors: [String] = []
}

/// Metadata that outranks a file's embedded tags during import, such as the values of the Music
/// library song a file was exported from. Edits made after the import outrank both, as usual.
nonisolated struct MediaImportOverride: Sendable, Equatable {
    var values = MediaMetadataEmbeddedValues()
    var artworkData: Data?
    var lyrics: String?
    var musicLibraryItemID: String?
    /// True when `values` is the complete set of text fields: a nil field clears the embedded value.
    /// False applies only the fields that are present.
    var replacesTextFields = false
    /// True when the same values were already written into the file, so the file and the item agree.
    var isEmbeddedInFile = false
}

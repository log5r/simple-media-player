import Foundation

/// Entry points for the Music library picker. Only iPhone and iPad provide them; macOS keeps the
/// defaults, which do nothing and show no controls.
@MainActor
struct MusicLibraryActions {
    var play: () -> Void = {}
    var importSongs: () -> Void = {}
}

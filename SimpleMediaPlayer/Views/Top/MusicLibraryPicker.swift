#if os(iOS)
import MediaPlayer
import SwiftUI

enum MusicLibraryPickerMode: String, Identifiable {
    case play
    case importing

    var id: String { rawValue }

    var allowsMultipleSelection: Bool {
        self == .importing
    }

    var prompt: String {
        switch self {
        case .play: L10n.string("Choose a song to play")
        case .importing: L10n.string("Choose songs to import")
        }
    }
}

/// Shows only songs whose assets are on the device and unprotected. Those flags are checked again on
/// each picked item, because the picker filters display, not the selection result.
struct MusicLibraryPicker: UIViewControllerRepresentable {
    let mode: MusicLibraryPickerMode
    let onPick: @MainActor ([MusicLibraryTrack]) -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = mode.allowsMultipleSelection
        picker.showsCloudItems = false
        picker.showsItemsWithProtectedAssets = false
        picker.prompt = mode.prompt
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: MPMediaPickerController, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onCancel = onCancel
    }

    // The delegate protocol is not main-actor annotated, but MediaPlayer calls it on the main thread.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency MPMediaPickerControllerDelegate {
        var onPick: @MainActor ([MusicLibraryTrack]) -> Void
        var onCancel: @MainActor () -> Void

        init(onPick: @escaping @MainActor ([MusicLibraryTrack]) -> Void, onCancel: @escaping @MainActor () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func mediaPicker(
            _ mediaPicker: MPMediaPickerController, didPickMediaItems mediaItemCollection: MPMediaItemCollection
        ) {
            onPick(mediaItemCollection.items.map { MusicLibraryTrack(mediaItem: $0) })
        }

        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
            onCancel()
        }
    }
}
#endif

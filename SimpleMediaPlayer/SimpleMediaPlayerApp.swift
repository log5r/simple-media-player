//
//  SimpleMediaPlayerApp.swift
//  SimpleMediaPlayer
//
//  Created by Judau on 2026/07/04.
//

import Foundation
import SwiftData
import SwiftUI

@main
struct SimpleMediaPlayerApp: App {
    @State private var libraryService: LibraryService
    @State private var player: PlayerViewModel
    @State private var isImporterPresented = false

    init() {
        BundledFontRegistry.registerFonts()
        let libraryService = LibraryService()
        _libraryService = State(initialValue: libraryService)
        _player = State(initialValue: PlayerViewModel(libraryService: libraryService))
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            MediaItem.self,
            Playlist.self,
            PlaylistEntry.self
        ])
        let isMultipleSelectionUITest = ProcessInfo.processInfo.arguments.contains("--ui-testing-multiple-selection")
        #if DEBUG && os(iOS)
        let isPhoneLayoutUITest = ProcessInfo.processInfo.arguments.contains("--ui-testing-phone-layout")
        #else
        let isPhoneLayoutUITest = false
        #endif
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: isMultipleSelectionUITest || isPhoneLayoutUITest
        )

        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            if isMultipleSelectionUITest {
                let context = container.mainContext
                let mediaCountArgument = ProcessInfo.processInfo.arguments.first {
                    $0.hasPrefix("--ui-testing-media-count=")
                }
                let requestedMediaCount = mediaCountArgument.flatMap {
                    Int($0.dropFirst("--ui-testing-media-count=".count))
                }
                let mediaCount = max(requestedMediaCount ?? 10, 1)

                for index in 1...mediaCount {
                    context.insert(
                        MediaItem(
                            title: "UI Test Track \(index)",
                            artist: "UI Test Artist",
                            album: "UI Test Album",
                            duration: TimeInterval(index * 10),
                            isVideo: false,
                            bookmarkData: Data(),
                            addedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                            fileName: "ui-test-\(index).mp3"
                        )
                    )
                }
                try context.save()
            }
            #if DEBUG && os(iOS)
            if isPhoneLayoutUITest { try PhoneLayoutUITestFixture.insert(into: container.mainContext) }
            #endif
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView(
                libraryService: libraryService,
                player: player,
                isImporterPresented: $isImporterPresented
            )
        }
        .modelContainer(sharedModelContainer)
        #if os(macOS)
        .defaultSize(width: 1100, height: 720)
        #endif
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import...") {
                    isImporterPresented = true
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            MediaInfoCommands()
            AACVersionCommands()
            AppMenuCommands(player: player)
        }

        #if os(macOS)
        WindowGroup("Artwork", id: ArtworkPreviewWindow.sceneID, for: UUID.self) { $itemID in
            ArtworkPreviewWindow(itemID: itemID)
        }
        .modelContainer(sharedModelContainer)
        .defaultSize(width: 640, height: 640)
        .windowResizability(.contentMinSize)
        #endif
    }
}

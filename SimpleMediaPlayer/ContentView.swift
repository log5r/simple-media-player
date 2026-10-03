//
//  ContentView.swift
//  SimpleMediaPlayer
//
//  Created by Judau on 2026/07/04.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    let libraryService: LibraryService
    let player: PlayerViewModel
    @Binding var isImporterPresented: Bool
    @AppStorage(AppSettingsKey.appearanceMode) private var appearanceModeRaw = AppSettingsDefault.appearanceMode

    var body: some View {
        MainView(
            libraryService: libraryService,
            player: player,
            isImporterPresented: $isImporterPresented
        )
            .preferredColorScheme(appearanceMode.preferredColorScheme)
            #if DEBUG && os(iOS)
            .transformEnvironment(\.dynamicTypeSize) { size in
                if let override = PhoneLayoutUITestFixture.dynamicTypeSizeOverride { size = override }
            }
            #endif
            #if os(macOS)
            .syncsDockIcon()
            #endif
            .task {
                #if os(macOS)
                // 起動描画が落ち着いてから、再生開始前にシート機構をロードしておく
                try? await Task.sleep(for: .milliseconds(500))
                SettingsSheetPrewarmer.prewarm()
                #endif
            }
    }

    private var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceModeRaw) ?? .system
    }
}

#if DEBUG && os(iOS)
import CryptoKit
import Darwin
import SwiftUI
import UIKit

struct DuoBrowsingDiagnostics: ViewModifier {
    let browsingState: LibraryBrowsingState

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-duo-layout") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(diagnostics(), id: \.identifier) { diagnostic in
                        Text(diagnostic.identifier)
                            .accessibilityElement(children: .ignore)
                            .accessibilityIdentifier(diagnostic.identifier)
                            .accessibilityValue(diagnostic.value)
                            .onChange(of: diagnostic.value, initial: true) { _, value in
                                print("D\(diagnostic.identifier.dropFirst()) \(value)")
                                fflush(nil)
                            }
                    }
                }
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.top, 24)
                .allowsHitTesting(false)
            }
        }
    }

    private func diagnostics() -> [Diagnostic] {
        let state = browsingState
        return [
            Diagnostic(identifier: "duoBrowsingMetrics", values: [
                "tab": state.phoneTab, "selection": selectionName,
                "groupSection": state.group?.section.rawValue ?? "", "groupName": state.group?.name ?? "",
                "libraryPath": state.libraryPath.map(routeName), "playlistPath": state.playlistPath.map(\.uuidString)
            ]),
            Diagnostic(identifier: "duoSearchMetrics", values: [
                "search": state.searchText,
                "filter": [
                    "title": state.searchFilter.title, "artist": state.searchFilter.artist,
                    "album": state.searchFilter.album, "genre": state.searchFilter.genre,
                    "albumArtist": state.searchFilter.albumArtist, "composer": state.searchFilter.composer,
                    "matchMode": state.searchFilter.matchMode.rawValue
                ],
                "sort": state.sortField.rawValue, "direction": state.sortDirection.rawValue
            ]),
            Diagnostic(identifier: "duoSelectionMetrics", values: [
                "selectedItemID": state.selectedItemID?.uuidString ?? "",
                "bulkIDs": state.bulkSelection.ids.map(\.uuidString).sorted(),
                "isBulkEditing": state.isBulkEditMode, "scrollItemID": state.scrollItemID?.uuidString ?? "",
                "albumScrollID": state.albumScrollID ?? ""
            ]),
            Diagnostic(identifier: "duoSessionMetrics", values: [
                "panelContent": state.panelContent == .information ? "information" : "lyrics",
                "showsDetails": state.showsDetails,
                "infoItemID": state.infoItem?.id.uuidString ?? "",
                "lyricsItemID": state.lyricsItem?.id.uuidString ?? "",
                "bulkSessionID": state.bulkEditSession?.id.uuidString ?? "",
                "bulkSessionItemIDs": state.bulkEditSession?.items.map { $0.id.uuidString } ?? []
            ])
        ]
    }

    private struct Diagnostic {
        let identifier: String
        let values: [String: Any]

        var value: String {
            guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
                  let value = String(data: data, encoding: .utf8) else { return "unavailable" }
            return value
        }
    }

    private var selectionName: String {
        switch browsingState.selection {
        case let .library(section): "library.\(section.rawValue)"
        case let .playlist(id): "playlist.\(id.uuidString)"
        }
    }

    private func routeName(_ route: LibraryBrowsingRoute) -> String {
        switch route {
        case let .section(section): "section.\(section.rawValue)"
        case let .group(group): "group.\(group.section.rawValue).\(group.name)"
        }
    }
}

/// The identifier and draft come from the live editor, not a second copy of its state.
struct DuoEditorDiagnostics: ViewModifier {
    let kind: String
    let itemID: UUID
    let draft: [String: String]
    let isBusy: Bool
    @State private var sessionID = UUID()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-duo-layout") {
                GeometryReader { geometry in
                    VStack(alignment: .leading, spacing: 0) {
                        diagnostic("duoEditorMetrics", value: metrics())
                        diagnostic("duoEditorLayoutMetrics", value: layoutMetrics(geometry))
                    }
                }
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
    }

    private func diagnostic(_ identifier: String, value: String) -> some View {
        Text(identifier)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(value)
            .onChange(of: value, initial: true) { _, value in
                print("D\(identifier.dropFirst()) \(value)")
                fflush(nil)
            }
    }

    private func layoutMetrics(_ geometry: GeometryProxy) -> String {
        var values: [String: Any] = [
            "width": geometry.size.width, "height": geometry.size.height,
            "portrait": geometry.size.height > geometry.size.width,
            "horizontalSizeClass": sizeClassName(horizontalSizeClass),
            "verticalSizeClass": sizeClassName(verticalSizeClass)
        ]
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: {
            $0.activationState == .foregroundActive && $0.windows.contains(where: \.isKeyWindow)
        }) {
            let bounds = scene.windows.first(where: \.isKeyWindow)?.bounds ?? scene.coordinateSpace.bounds
            values["sceneWidth"] = bounds.width
            values["sceneHeight"] = bounds.height
            values["scenePortrait"] = bounds.height > bounds.width
        }
        if #available(iOS 27.1, *) {
            values["hasActiveDivision"] = geometry.reservedRegions(kind: .division).contains { $0.isActive }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "unavailable" }
        return value
    }

    private func sizeClassName(_ sizeClass: UserInterfaceSizeClass?) -> String {
        switch sizeClass {
        case .compact: "compact"
        case .regular: "regular"
        case nil: "unspecified"
        @unknown default: "unknown"
        }
    }

    private func metrics() -> String {
        let values: [String: Any] = [
            "kind": kind, "itemID": itemID.uuidString, "sessionID": sessionID.uuidString,
            "draftHashes": draft.mapValues { value in
                SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
            },
            "draftLengths": draft.mapValues(\.count), "isBusy": isBusy
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "unavailable" }
        return value
    }
}
#endif

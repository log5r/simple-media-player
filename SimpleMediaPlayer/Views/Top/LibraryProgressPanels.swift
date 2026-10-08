import SwiftUI

struct PanelToolbarLabel: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: LocalizedStringKey
    let systemImage: String
    let isSelected: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .foregroundStyle(labelColor)
    }

    private var labelColor: Color {
        guard isEnabled else { return .secondary }
        return isSelected ? .accentColor : .primary
    }
}

/// Reads an observable progress value in its own body, so frequent updates redraw only this bar
/// instead of the screen that hosts it.
struct ObservedProgressView<Source: AnyObject & Observable>: View {
    let source: Source
    let value: KeyPath<Source, Double>

    var body: some View {
        ProgressView(value: source[keyPath: value])
    }
}

struct AACVersionProgressPanel: View {
    let exporter: TransformedTrackExporter
    let sourceTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Creating AAC Version")
                    .font(.headline)
            }

            ProgressView(value: clampedProgress)
                .progressViewStyle(.linear)

            if let sourceTitle {
                Text(sourceTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
        .shadow(radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Creating AAC version")
        .accessibilityValue(exporter.progress.formatted(.percent.precision(.fractionLength(0))))
    }

    private var clampedProgress: Double {
        min(max(exporter.progress, 0), 1)
    }
}

struct ImportProgressPanel: View {
    let libraryService: LibraryService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Importing")
                    .font(.headline)
                Spacer(minLength: 16)
                Text(progressCountText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: clampedProgress)
                .progressViewStyle(.linear)

            if let fileName = libraryService.currentImportFileName {
                Text(fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
        .shadow(radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Importing media")
        .accessibilityValue("\(libraryService.importCompletedFileCount) / \(libraryService.importTotalFileCount)")
    }

    private var clampedProgress: Double {
        min(max(libraryService.importProgress, 0), 1)
    }

    private var progressCountText: String {
        "\(libraryService.importCompletedFileCount)/\(libraryService.importTotalFileCount)"
    }
}

struct ExportProgressPanel: View {
    let libraryService: LibraryService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Exporting")
                    .font(.headline)
                Spacer(minLength: 16)
                Text(progressCountText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: clampedProgress)
                .progressViewStyle(.linear)

            if let fileName = libraryService.currentExportFileName {
                Text(fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        }
        .shadow(radius: 10, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Exporting media")
        .accessibilityValue("\(libraryService.exportCompletedFileCount) / \(libraryService.exportTotalFileCount)")
    }

    private var clampedProgress: Double {
        min(max(libraryService.exportProgress, 0), 1)
    }

    private var progressCountText: String {
        "\(libraryService.exportCompletedFileCount)/\(libraryService.exportTotalFileCount)"
    }
}

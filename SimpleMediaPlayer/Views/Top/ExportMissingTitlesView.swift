import SwiftUI

struct ExportMissingTitlesView: View {
    let plan: MediaExportPlan
    let export: ([UUID: String]) -> Void
    let cancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var names: [UUID: String]
    @State private var timestampFillConfirmationPresented = false

    init(
        plan: MediaExportPlan,
        export: @escaping ([UUID: String]) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.plan = plan
        self.export = export
        self.cancel = cancel
        _names = State(initialValue: Dictionary(uniqueKeysWithValues: plan.missingTitleFiles.map { ($0.id, "") }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name Untitled Media")
                    .font(.title2.weight(.semibold))
                Text(
                    """
                    Some selected media files do not have embedded titles. \
                    Enter a file name for each item before exporting.
                    """
                )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.missingTitleFiles) { file in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.displayName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(file.albumName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(width: 230, alignment: .leading)

                            TextField("File name", text: binding(for: file.id))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(22)
            }
            .frame(minHeight: 280)

            Divider()

            HStack(spacing: 10) {
                Button("Fill All Names with Timestamps") {
                    timestampFillConfirmationPresented = true
                }

                Spacer()

                Button("Cancel", role: .cancel) {
                    cancel()
                    dismiss()
                }

                Button("Export") {
                    export(trimmedNames)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(canExport == false)
            }
            .padding(16)
        }
        .frame(width: 680, height: 520)
        .confirmationDialog(
            "Fill all names with timestamps?",
            isPresented: $timestampFillConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Fill with Timestamps") {
                fillNamesWithTimestamps()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing entries in this list will be replaced.")
        }
    }

    private var trimmedNames: [UUID: String] {
        names.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private var canExport: Bool {
        plan.missingTitleFiles.allSatisfy { file in
            trimmedNames[file.id]?.isEmpty == false
        }
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { names[id, default: ""] },
            set: { names[id] = $0 }
        )
    }

    private func fillNamesWithTimestamps() {
        let date = Date()
        for (index, file) in plan.missingTitleFiles.enumerated() {
            names[file.id] = MediaExportNaming.timestampName(date: date, index: index + 1)
        }
    }
}

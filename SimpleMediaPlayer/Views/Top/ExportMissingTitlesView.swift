import SwiftUI

struct ExportMissingTitlesView: View {
    @Environment(\.usesPhoneLayout) private var usesPhoneLayout
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var availableWidth: CGFloat = 0
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
        exportContent
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .platformEditorFrame(width: 680, height: 520)
        #if DEBUG && os(iOS)
        .modifier(DuoEditorDiagnostics(
            kind: "export", itemID: plan.id,
            draft: Dictionary(uniqueKeysWithValues: names.map { ($0.key.uuidString, $0.value) }), isBusy: false
        ))
        #endif
        .confirmationDialog(
            "Fill all names with timestamps?",
            isPresented: $timestampFillConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Fill with Timestamps") { fillNamesWithTimestamps() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Existing entries in this list will be replaced.")
        }
    }

    @ViewBuilder
    private var exportContent: some View {
        #if os(iOS)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(
                        """
                        Some selected media files do not have embedded titles. \
                        Enter a file name for each item before exporting.
                        """
                    )
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Fill All Names with Timestamps") { timestampFillConfirmationPresented = true }
                        .frame(minHeight: 44)
                    nameFields
                }
                .padding(22)
            }
            .navigationTitle("Name Untitled Media")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { export(trimmedNames); dismiss() }
                        .disabled(!canExport)
                }
            }
        }
        #else
        desktopContent
        #endif
    }

    private var nameFields: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(plan.missingTitleFiles) { file in
                let layout = usesStackedRows
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.displayName).lineLimit(1).truncationMode(.middle)
                        Text(file.albumName).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(width: usesStackedRows ? nil : 230, alignment: .leading)
                    TextField("File name", text: binding(for: file.id)).textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private var usesStackedRows: Bool {
        #if os(iOS)
        usesPhoneLayout || availableWidth < 600 || dynamicTypeSize.isAccessibilitySize
        #else
        false
        #endif
    }

    private var desktopContent: some View {
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
                nameFields
                .padding(22)
            }
            .frame(minHeight: usesPhoneLayout ? 0 : 280)

            Divider()

            let buttonLayout = usesPhoneLayout
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(spacing: 10))
            buttonLayout {
                Button("Fill All Names with Timestamps") {
                    timestampFillConfirmationPresented = true
                }

                if usesPhoneLayout == false {
                    Spacer()
                }

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
    }

    private var trimmedNames: [UUID: String] {
        MediaExportPlan.trimmedNames(names)
    }

    private var canExport: Bool {
        plan.hasNamesForMissingTitles(names)
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

/// Name entry rules for files without embedded titles. The checks run on every keystroke,
/// so each name is trimmed once per check.
extension MediaExportPlan {
    /// Trims the names entered for files without embedded titles.
    static func trimmedNames(_ names: [UUID: String]) -> [UUID: String] {
        names.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Whether every file without an embedded title has a name that is not blank after trimming.
    func hasNamesForMissingTitles(_ names: [UUID: String]) -> Bool {
        missingTitleFiles.allSatisfy { file in
            names[file.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }
}

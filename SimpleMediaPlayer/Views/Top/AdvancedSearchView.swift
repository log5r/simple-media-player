import SwiftUI

struct AdvancedSearchView: View {
    @Binding var filter: LibrarySearchFilter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.usesPhoneLayout) private var usesPhoneLayout
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var headerLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerLayout {
                Text("Advanced Search")
                    .font(.headline)

                if !dynamicTypeSize.isAccessibilitySize { Spacer() }

                Button("Clear Filters") {
                    filter.clear()
                }
                .accessibilityIdentifier("clearFiltersButton")
                .disabled(filter.isActive == false)

                Button("Done") {
                    dismiss()
                }
                .accessibilityIdentifier("advancedSearchDoneButton")
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Form {
                Section {
                    AdaptiveSettingsPicker(
                        title: "Match", selection: $filter.matchMode,
                        options: LibraryFilterMatchMode.allCases.map { .init(value: $0, title: $0.title) },
                        identifier: "libraryFilterMatch"
                    )
                } footer: {
                    Text("Choose whether media must match all filled filters or any filled filter.")
                }

                Section("Filters") {
                    TextField("Title", text: $filter.title)
                    TextField("Album", text: $filter.album)
                    TextField("Artist", text: $filter.artist)
                    TextField("Album Artist", text: $filter.albumArtist)
                    TextField("Composer", text: $filter.composer)
                    TextField("Genre", text: $filter.genre)
                }
            }
            .formStyle(.grouped)
        }
        .frame(idealWidth: usesPhoneLayout ? nil : 420, idealHeight: usesPhoneLayout ? nil : 420)
    }
}

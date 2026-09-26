import SwiftUI

struct AdvancedSearchView: View {
    @Binding var filter: LibrarySearchFilter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Advanced Search")
                    .font(.headline)

                Spacer()

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
                    Picker("Match", selection: $filter.matchMode) {
                        ForEach(LibraryFilterMatchMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
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
        .frame(idealWidth: 420, idealHeight: 420)
    }
}

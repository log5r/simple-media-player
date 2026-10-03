import SwiftUI

struct SettingsPickerOption<Selection: Hashable> {
    let value: Selection
    let title: String
    var isEnabled = true
}

struct AdaptiveSettingsPicker<Selection: Hashable>: View {
    @Environment(\.usesPhoneLayout) private var usesPhoneLayout
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: LocalizedStringKey
    @Binding var selection: Selection
    let options: [SettingsPickerOption<Selection>]
    let identifier: String

    var body: some View {
        if usesPhoneLayout || dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(options, id: \.value) { option in
                    Button {
                        selection = option.value
                    } label: {
                        HStack(spacing: 10) {
                            Text(option.title)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Image(systemName: selection == option.value ? "checkmark.circle.fill" : "circle")
                                .accessibilityHidden(true)
                        }
                        .font(.body)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!option.isEnabled)
                    .accessibilityLabel(option.title)
                    .accessibilityIdentifier("\(identifier).\(option.value)")
                    .accessibilityAddTraits(selection == option.value ? .isSelected : [])
                }
            }
        } else {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.value) { option in
                    Text(option.title)
                        .tag(option.value)
                        .disabled(!option.isEnabled)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

enum NumberPairComponent {
    case current
    case total
}

struct NumberPairParts {
    var current: String
    var total: String

    init(_ value: String) {
        let pieces = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        current = pieces.first.map(String.init) ?? ""
        total = pieces.dropFirst().first.map(String.init) ?? ""
    }

    subscript(component: NumberPairComponent) -> String {
        get {
            switch component {
            case .current:
                current
            case .total:
                total
            }
        }
        set {
            switch component {
            case .current:
                current = newValue
            case .total:
                total = newValue
            }
        }
    }

    var combinedValue: String {
        if current.isEmpty, total.isEmpty {
            return ""
        }
        if total.isEmpty {
            return current
        }
        return "\(current)/\(total)"
    }
}

struct ArtworkView: View {
    let data: Data?
    let isVideo: Bool
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let data, let image = platformImage(data: data) {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: isVideo ? "film" : "music.note")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: 3))
    }

    private func platformImage(data: Data) -> Image? {
        #if os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        return Image(nsImage: image)
        #else
        guard let image = UIImage(data: data) else { return nil }
        return Image(uiImage: image)
        #endif
    }
}

extension TimeInterval {
    var mediaTime: String {
        guard isFinite else { return "00:00" }
        let value = max(0, Int(self))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

extension MediaInfoView {
    func infoSection(title: String, rows: [MediaInfoRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(rows) { row in
                    infoRow(row)
                }
            }
        }
    }

    func infoRow(_ row: MediaInfoRow) -> some View {
        GridRow {
            Text(row.label)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
            Text(row.value)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

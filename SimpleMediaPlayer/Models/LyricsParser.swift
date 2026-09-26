import Foundation

struct ParsedLyrics {
    var lines: [Line]
    var hasTimeTags: Bool

    struct Line: Identifiable {
        let id = UUID()
        var text: String
        var timestamp: TimeInterval?
    }
}

enum LyricsParser {
    private static let metadataPrefixes = ["ar", "ti", "al", "by", "offset", "length", "re"]

    static func parse(_ raw: String?) -> ParsedLyrics {
        guard let raw, raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return ParsedLyrics(lines: [], hasTimeTags: false)
        }

        var output: [ParsedLyrics.Line] = []
        var foundTimeTag = false

        raw.components(separatedBy: .newlines).forEach { originalLine in
            let trimmed = originalLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty == false else {
                output.append(.init(text: "", timestamp: nil))
                return
            }

            if isMetadataLine(trimmed) {
                return
            }

            let parsed = parseTimedLine(trimmed)
            if parsed.timestamps.isEmpty {
                output.append(.init(text: trimmed, timestamp: nil))
            } else {
                foundTimeTag = true
                parsed.timestamps.forEach { time in
                    output.append(.init(text: parsed.text, timestamp: time))
                }
            }
        }

        output.sort {
            switch ($0.timestamp, $1.timestamp) {
            case let (lhs?, rhs?): lhs < rhs
            case (.some, .none): true
            default: false
            }
        }

        return ParsedLyrics(lines: output, hasTimeTags: foundTimeTag)
    }

    private static func isMetadataLine(_ line: String) -> Bool {
        guard line.hasPrefix("["),
              let close = line.firstIndex(of: "]"),
              close == line.index(before: line.endIndex)
        else { return false }

        let body = String(line[line.index(after: line.startIndex)..<close]).lowercased()
        return metadataPrefixes.contains { body.hasPrefix($0 + ":") }
    }

    private static func parseTimedLine(_ line: String) -> (timestamps: [TimeInterval], text: String) {
        var remainder = line[...]
        var timestamps: [TimeInterval] = []

        while remainder.first == "[", let close = remainder.firstIndex(of: "]") {
            let tag = String(remainder[remainder.index(after: remainder.startIndex)..<close])
            guard let time = parseTimestamp(tag) else { break }
            timestamps.append(time)
            remainder = remainder[remainder.index(after: close)...]
        }

        return (timestamps, String(remainder).trimmingCharacters(in: .whitespaces))
    }

    private static func parseTimestamp(_ tag: String) -> TimeInterval? {
        let parts = tag.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let minutes = Double(parts[0]) else { return nil }
        let secondsParts = parts[1].split(separator: ".", maxSplits: 1).map(String.init)
        guard let seconds = Double(secondsParts[0]) else { return nil }
        let fraction: Double
        if secondsParts.count == 2, let value = Double("0." + secondsParts[1]) {
            fraction = value
        } else {
            fraction = 0
        }
        return minutes * 60 + seconds + fraction
    }
}

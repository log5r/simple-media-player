import Foundation

nonisolated enum AdditionalAudioMetadata {
    static func canWrite(to url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ["flac", "wav", "ogg", "oga", "opus"].contains(ext) else { return false }
        guard let source = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? source.close() }
        guard let header = try? source.read(upToCount: 12) else { return false }
        switch ext {
        case "flac": return header.starts(with: Data("fLaC".utf8))
        case "wav": return header.starts(with: Data("RIFF".utf8)) && header.count >= 12
            && Data(header[8..<12]) == Data("WAVE".utf8)
        default: return header.starts(with: Data("OggS".utf8)) && OggMetadataWriter.canWriteMetadata(to: url)
        }
    }

    static func read(from url: URL) throws -> AudioTagReadResult {
        switch url.pathExtension.lowercased() {
        case "flac": return try FLACMetadataWriter.read(from: url)
        case "wav": return try WAVMetadataWriter.read(from: url)
        case "ogg", "oga", "opus": return try OggMetadataWriter.read(from: url)
        default: throw MediaMetadataEditError.unsupportedFileFormat
        }
    }

    static func write(_ draft: MediaMetadataEditDraft, to url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "flac": try FLACMetadataWriter.write(draft, to: url)
        case "wav": try WAVMetadataWriter.write(draft, to: url)
        case "ogg", "oga", "opus": try OggMetadataWriter.write(draft, to: url)
        default: throw MediaMetadataEditError.unsupportedFileFormat
        }
    }
}

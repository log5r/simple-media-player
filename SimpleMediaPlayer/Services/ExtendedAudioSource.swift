import AVFoundation
import CryptoKit
import Foundation
import SFBAudioEngine

nonisolated enum ExtendedAudioSource {
    enum Kind: String, Sendable {
        case wma
        case wavPack
        case monkeysAudio
        case musepack
    }

    struct Info: Sendable {
        let duration: TimeInterval
        let sampleRate: Double?
        let channelCount: Int
        let bitrateKbps: Int?
        let codec: String
        let title: String?
        let artist: String?
        let album: String?
        let albumArtist: String?
        let genre: String?
        let year: String?
        let trackNumber: String?
        let discNumber: String?
        let composer: String?
        let comment: String?
        let lyrics: String?
        let isCompilation: Bool
        let artworkData: Data?
    }

    private static let maximumFileBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
    private static let cache = ExtendedAudioCache(maximumBytes: 8 * 1_024 * 1_024 * 1_024)
    private static let extensions: [String: Kind] = [
        "wma": .wma, "wv": .wavPack, "ape": .monkeysAudio, "mpc": .musepack
    ]

    static func kind(for url: URL) throws -> Kind? {
        guard let claimed = extensions[url.pathExtension.lowercased()] else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var header = try handle.read(upToCount: 16) ?? Data()
        if claimed == .monkeysAudio || claimed == .musepack,
           header.count >= 10,
           header.starts(with: Data("ID3".utf8)),
           header[3] < 0xFF, header[4] < 0xFF,
           header[5] & 0x0F == 0,
           header[6...9].allSatisfy({ $0 < 0x80 }) {
            let tagSize = header[6...9].reduce(0) { ($0 << 7) | Int($1) }
            let footerSize = header[5] & 0x10 == 0 ? 0 : 10
            try handle.seek(toOffset: UInt64(10 + tagSize + footerSize))
            header = try handle.read(upToCount: 16) ?? Data()
        }
        let detected: Kind?
        if header.starts(with: Data([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11,
                                     0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C])) {
            detected = .wma
        } else if header.starts(with: Data("wvpk".utf8)) {
            detected = .wavPack
        } else if header.starts(with: Data("MAC ".utf8)) {
            detected = .monkeysAudio
        } else if header.starts(with: Data("MPCK".utf8)) || header.starts(with: Data("MP+".utf8)) {
            detected = .musepack
        } else {
            detected = nil
        }
        if claimed != detected {
            throw CocoaError(.fileReadCorruptFile)
        }
        return detected
    }

    static func probeInfo(for url: URL) async throws -> Info? {
        let probeTask = Task.detached(priority: .utility) { () throws -> Info? in
            try Task.checkCancellation()
            guard let kind = try kind(for: url) else { return nil }
            let info = try info(for: url, kind: kind)
            try Task.checkCancellation()
            return info
        }
        return try await withTaskCancellationHandler {
            try await probeTask.value
        } onCancel: { probeTask.cancel() }
    }

    static func info(for url: URL, kind: Kind) throws -> Info {
        switch kind {
        case .wma:
            let source: SMPFFmpegAudioInfo
            do {
                source = try SMPFFmpegAudio.probeURL(url)
            } catch {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard source.duration > 0, source.sampleRate > 0, source.channelCount > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let tags = source.tags
            return Info(
                duration: source.duration,
                sampleRate: source.sampleRate,
                channelCount: source.channelCount,
                bitrateKbps: source.bitrate > 0 ? Int(source.bitrate / 1_000) : nil,
                codec: source.codecName,
                title: tags["title"], artist: tags["artist"], album: tags["album"],
                albumArtist: tags["album_artist"], genre: tags["genre"], year: tags["date"],
                trackNumber: tags["track"], discNumber: tags["disc"], composer: tags["composer"],
                comment: tags["comment"], lyrics: tags["lyrics"], isCompilation: false,
                artworkData: source.artworkData
            )
        case .wavPack, .monkeysAudio, .musepack:
            let source = try AudioFile(readingPropertiesAndMetadataFrom: url)
            let properties = source.properties
            guard let duration = properties.duration, duration.isFinite, duration > 0,
                  let sampleRate = properties.sampleRate, sampleRate > 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let tags = source.metadata
            return Info(
                duration: duration,
                sampleRate: sampleRate,
                channelCount: Int(properties.channelCount ?? 2),
                // TagLib の bitrate() は kb/s。SFBAudioEngine は値を変換せずに公開する。
                bitrateKbps: properties.bitrate.map { Int($0) },
                codec: properties.formatName ?? kind.rawValue,
                title: tags.title, artist: tags.artist, album: tags.albumTitle,
                albumArtist: tags.albumArtist, genre: tags.genre, year: tags.releaseDate,
                trackNumber: tags.trackNumber.map(String.init), discNumber: tags.discNumber.map(String.init),
                composer: tags.composer, comment: tags.comment, lyrics: tags.lyrics,
                isCompilation: tags.isCompilation ?? false,
                artworkData: tags.attachedPictures.first?.imageData
            )
        }
    }

    static func validate(for url: URL) throws {
        try Task.checkCancellation()
        guard let kind = try kind(for: url) else { return }
        try checkDecodedSize(for: url, kind: kind)
        try decode(url, kind: kind, to: nil, shouldCancel: { Task<Never, Never>.isCancelled })
        try Task.checkCancellation()
    }

    static func readableFile(for url: URL) throws -> ExtendedAudioCache.ReadableFile {
        try Task.checkCancellation()
        guard let kind = try kind(for: url) else { return ExtendedAudioCache.ReadableFile(url: url) }
        let key = try cacheKey(for: url)
        let directory = try cacheDirectory()
        let destination = directory.appendingPathComponent(key).appendingPathExtension("caf")
        return try cache.acquireReadableFile(at: destination, create: { temporary, shouldCancel in
            try checkDecodedSize(for: url, kind: kind)
            try decode(url, kind: kind, to: temporary, shouldCancel: shouldCancel)
            let byteCount = try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int64 ?? 0
            guard byteCount > 0, byteCount <= maximumFileBytes else {
                throw CocoaError(.fileReadTooLarge)
            }
        }, isSourceCurrent: { try cacheKey(for: url) == key })
    }

    private static func checkDecodedSize(for url: URL, kind: Kind) throws {
        let sourceInfo = try info(for: url, kind: kind)
        let estimatedBytes = sourceInfo.duration * (sourceInfo.sampleRate ?? 0)
            * Double(sourceInfo.channelCount) * 4
        if estimatedBytes > Double(maximumFileBytes) { throw CocoaError(.fileReadTooLarge) }
    }

    private static func decode(
        _ url: URL, kind: Kind, to destination: URL?, shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        switch kind {
        case .wma:
            do {
                if let destination {
                    try SMPFFmpegAudio.decode(
                        url, toCAF: destination, maxBytes: maximumFileBytes, shouldCancel: shouldCancel
                    )
                } else {
                    try SMPFFmpegAudio.validate(url, maxBytes: maximumFileBytes, shouldCancel: shouldCancel)
                }
            } catch let error as NSError {
                if error.code == NSUserCancelledError { throw CancellationError() }
                if error.code == POSIXErrorCode.EFBIG.rawValue { throw CocoaError(.fileReadTooLarge) }
                throw CocoaError(.fileReadCorruptFile)
            }
        case .wavPack, .monkeysAudio, .musepack:
            try decodeWithSFB(url, to: destination, shouldCancel: shouldCancel)
        }
    }

    static func removeCache(for url: URL) {
        guard let cacheURL = cacheURL(for: url) else { return }
        removeCache(at: cacheURL)
    }

    static func cacheURL(for url: URL) -> URL? {
        guard let key = try? cacheKey(for: url), let directory = try? cacheDirectory() else { return nil }
        return directory.appendingPathComponent(key).appendingPathExtension("caf")
    }

    static func removeCacheInBackground(at cacheURL: URL) {
        cache.removeInBackground(at: cacheURL)
    }

    private static func removeCache(at cacheURL: URL) {
        cache.remove(at: cacheURL)
    }

    private static func cacheKey(for url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else {
            throw CocoaError(.fileReadUnknown)
        }
        let identity = "\(url.standardizedFileURL.path)|\(size)|\(modified.timeIntervalSince1970)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func decodeWithSFB(
        _ source: URL, to destination: URL?, shouldCancel: () -> Bool
    ) throws {
        let decoder = try AudioDecoder(url: source)
        try decoder.open()
        defer { try? decoder.close() }
        let format = decoder.processingFormat
        let maximumFrames = try SMPAudioCacheSizeLimit.maximumFrames(
            for: format, maxFileBytes: maximumFileBytes
        ).int64Value
        let output = try destination.map {
            try AVAudioFile(
                forWriting: $0, settings: format.settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved
            )
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var writtenBytes: Int64 = 0
        var decodedFrames: AVAudioFramePosition = 0
        while true {
            if shouldCancel() { throw CancellationError() }
            try decoder.decode(into: buffer, length: buffer.frameCapacity)
            guard buffer.frameLength > 0 else { break }
            decodedFrames += AVAudioFramePosition(buffer.frameLength)
            guard decodedFrames <= maximumFrames else { throw CocoaError(.fileReadTooLarge) }
            let channelMultiplier = format.isInterleaved ? 1 : Int64(format.channelCount)
            writtenBytes += Int64(buffer.frameLength) * Int64(format.streamDescription.pointee.mBytesPerFrame)
                * channelMultiplier
            guard writtenBytes <= maximumFileBytes else { throw CocoaError(.fileReadTooLarge) }
            try output?.write(from: buffer)
        }
        guard writtenBytes > 0, decoder.length <= 0 || decodedFrames == decoder.length else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private static func cacheDirectory() throws -> URL {
        let directory = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("CompatibleAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

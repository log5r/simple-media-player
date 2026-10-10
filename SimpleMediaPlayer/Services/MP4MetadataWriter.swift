import Foundation

enum MP4MetadataWriter {
    nonisolated private static let editableItemTypes: Set<BoxType> = [
        BoxType([0xA9, 0x6E, 0x61, 0x6D]),
        BoxType([0xA9, 0x41, 0x52, 0x54]),
        BoxType([0xA9, 0x61, 0x6C, 0x62]),
        BoxType([0xA9, 0x67, 0x65, 0x6E]),
        BoxType("gnre"),
        BoxType([0xA9, 0x64, 0x61, 0x79]),
        BoxType("trkn"),
        BoxType([0xA9, 0x63, 0x6D, 0x74]),
        BoxType("aART"),
        BoxType([0xA9, 0x77, 0x72, 0x74]),
        BoxType("disk"),
        BoxType("cpil"), BoxType("sonm"), BoxType("soar"), BoxType("soal"), BoxType("soaa"), BoxType("soco")
    ]
    nonisolated private static let artworkItemType = BoxType("covr")
    nonisolated private static let lyricsItemType = BoxType([0xA9, 0x6C, 0x79, 0x72])
    /// Boxes ISO/IEC 14496-12 lets readers ignore; the writer reuses their space.
    nonisolated private static let paddingTypes: Set<BoxType> = [BoxType("free"), BoxType("skip")]

    nonisolated static func canWriteMetadata(to url: URL) -> Bool {
        ["m4a", "m4v", "mp4", "mov"].contains(url.pathExtension.lowercased())
    }

    nonisolated static func write(_ draft: MediaMetadataEditDraft, to url: URL) throws {
        guard canWriteMetadata(to: url) else {
            throw MediaMetadataEditError.unsupportedFileFormat
        }

        try MediaFileRewriter.update(at: url) { handle, fileSize in
            try inPlaceEdit(for: rebuiltMovie(draft, source: handle, fileSize: fileSize), fileSize: fileSize)
        } rewrite: { source, output, fileSize in
            let movie = try rebuiltMovie(draft, source: source, fileSize: fileSize)
            let moovBox = movie.moovBox
            let oldMoovSize = moovBox.totalRange.upperBound - moovBox.totalRange.lowerBound
            var rebuiltMoovBox = paddedMoovBox(movie, size: oldMoovSize)
            let sizeDelta = rebuiltMoovBox.count - Int(oldMoovSize)
            if sizeDelta != 0 {
                // Fragment/index offsets are not covered by stco/co64 adjustment.
                // Fixed-size edits keep those offsets valid; otherwise preserve the source.
                let fragmentTypes: Set<BoxType> = [BoxType("moof"), BoxType("mfra"), BoxType("sidx")]
                let movieChildren = try boxes(in: 0..<movie.originalContent.count, data: movie.originalContent)
                let hasFragments = movie.topLevelBoxes.contains { fragmentTypes.contains($0.type) }
                    || movieChildren.contains { $0.type == BoxType("mvex") }
                guard hasFragments == false else {
                    throw MediaMetadataEditError.unsupportedMP4MetadataLayout
                }
                rebuiltMoovBox = try adjustingChunkOffsets(
                    inMoovBox: rebuiltMoovBox,
                    by: Int64(sizeDelta),
                    startingAt: moovBox.totalRange.upperBound
                )
            }

            try MediaFileRewriter.copy(from: source, range: 0..<moovBox.totalRange.lowerBound, to: output)
            try output.write(contentsOf: rebuiltMoovBox)
            try MediaFileRewriter.copy(from: source, range: moovBox.totalRange.upperBound..<fileSize, to: output)
        }
    }

    nonisolated private static func rewriteMoovContent(
        _ draft: MediaMetadataEditDraft,
        in range: Range<Int>,
        data: Data
    ) throws -> Data {
        try rewriteContainer(
            in: range,
            data: data,
            targetType: BoxType("udta"),
            makeReplacement: { udtaBox in
                if let udtaBox {
                    let rewrittenContent = try rewriteUdtaContent(draft, in: udtaBox.contentRange, data: data)
                    return makeBox(type: udtaBox.type, content: rewrittenContent)
                }
                return makeBox(type: BoxType("udta"), content: try makeMetaBox(draft))
            }
        )
    }

    nonisolated private static func rewriteUdtaContent(
        _ draft: MediaMetadataEditDraft,
        in range: Range<Int>,
        data: Data
    ) throws -> Data {
        try rewriteContainer(
            in: range,
            data: data,
            targetType: BoxType("meta"),
            makeReplacement: { metaBox in
                if let metaBox {
                    return try rewriteMetaBox(draft, box: metaBox, data: data)
                }
                return try makeMetaBox(draft)
            }
        )
    }

    nonisolated private static func rewriteMetaBox(
        _ draft: MediaMetadataEditDraft,
        box: MP4Box,
        data: Data
    ) throws -> Data {
        let content = data[box.contentRange]
        guard content.count >= 4 else {
            throw MediaMetadataEditError.invalidMP4Metadata
        }

        let fullBoxHeader = Data(content.prefix(4))
        let childRange = (box.contentRange.lowerBound + 4)..<box.contentRange.upperBound
        let rewrittenChildren = try rewriteContainer(
            in: childRange,
            data: data,
            targetType: BoxType("ilst"),
            makeReplacement: { ilstBox in
                if let ilstBox {
                    return try makeIlstBox(draft, existingContentRange: ilstBox.contentRange, data: data)
                }
                return try makeIlstBox(draft, existingContentRange: nil, data: data)
            }
        )

        return makeBox(type: box.type, content: fullBoxHeader + rewrittenChildren)
    }

    nonisolated private static func makeMetaBox(_ draft: MediaMetadataEditDraft) throws -> Data {
        makeBox(
            type: BoxType("meta"),
            content: Data([0, 0, 0, 0]) + makeMetadataHandlerBox()
                + (try makeIlstBox(draft, existingContentRange: nil, data: Data()))
        )
    }

    nonisolated private static func makeMetadataHandlerBox() -> Data {
        // iTunes HandlerBox: version/flags, pre_defined, mdir, appl, reserved, empty name.
        let content = Data(repeating: 0, count: 8) + Data("mdirappl".utf8) + Data(repeating: 0, count: 9)
        return makeBox(type: BoxType("hdlr"), content: content)
    }

    nonisolated private static func makeIlstBox(
        _ draft: MediaMetadataEditDraft,
        existingContentRange: Range<Int>?,
        data: Data
    ) throws -> Data {
        var content = Data()

        if let existingContentRange {
            let itemBoxes = try boxes(in: existingContentRange, data: data)
            for itemBox in itemBoxes where shouldPreserve(itemBox.type, for: draft) {
                content.append(data[itemBox.totalRange])
            }
        }

        for item in metadataItems(for: draft) {
            content.append(makeMetadataItemBox(type: item.type, dataType: item.dataType, payload: item.payload))
        }

        return makeBox(type: BoxType("ilst"), content: content)
    }

    nonisolated private static func metadataItems(for draft: MediaMetadataEditDraft) -> [MP4MetadataItem] {
        var items: [MP4MetadataItem] = []
        if draft.editsTextMetadata {
            appendTextItem(type: BoxType([0xA9, 0x6E, 0x61, 0x6D]), value: draft.title, to: &items)
            appendTextItem(type: BoxType([0xA9, 0x41, 0x52, 0x54]), value: draft.artist, to: &items)
            appendTextItem(type: BoxType([0xA9, 0x61, 0x6C, 0x62]), value: draft.album, to: &items)
            appendTextItem(type: BoxType([0xA9, 0x67, 0x65, 0x6E]), value: draft.genre, to: &items)
            appendTextItem(type: BoxType([0xA9, 0x64, 0x61, 0x79]), value: draft.year, to: &items)
            appendTextItem(type: BoxType([0xA9, 0x63, 0x6D, 0x74]), value: draft.comment, to: &items)
            appendTextItem(type: BoxType("aART"), value: draft.albumArtist, to: &items)
            appendTextItem(type: BoxType([0xA9, 0x77, 0x72, 0x74]), value: draft.composer, to: &items)
            if let trackPayload = numberPairPayload(draft.trackNumber) {
                items.append(MP4MetadataItem(type: BoxType("trkn"), dataType: 0, payload: trackPayload))
            }
            if let discPayload = numberPairPayload(draft.discNumber) {
                items.append(MP4MetadataItem(type: BoxType("disk"), dataType: 0, payload: discPayload))
            }
            if draft.isCompilation {
                items.append(MP4MetadataItem(type: BoxType("cpil"), dataType: 21, payload: Data([1])))
            }
        }
        if draft.editsArtwork, let artworkData = draft.artworkData {
            let dataType: UInt32 = artworkData.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? 14 : 13
            items.append(MP4MetadataItem(type: artworkItemType, dataType: dataType, payload: artworkData))
        }
        if draft.editsLyrics, let lyrics = normalized(draft.lyrics) {
            items.append(MP4MetadataItem(type: lyricsItemType, dataType: 1, payload: Data(lyrics.utf8)))
        }
        return items
    }

    nonisolated private static func shouldPreserve(_ type: BoxType, for draft: MediaMetadataEditDraft) -> Bool {
        if draft.editsTextMetadata, editableItemTypes.contains(type) {
            return false
        }
        if draft.editsArtwork, type == artworkItemType {
            return false
        }
        return draft.editsLyrics == false || type != lyricsItemType
    }

    nonisolated private static func appendTextItem(type: BoxType, value: String, to items: inout [MP4MetadataItem]) {
        guard let value = normalized(value) else { return }
        items.append(MP4MetadataItem(type: type, dataType: 1, payload: Data(value.utf8)))
    }

    nonisolated private static func numberPairPayload(_ value: String) -> Data? {
        guard let value = normalized(value) else { return nil }
        let components = value.split(separator: "/", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let firstText = components.first,
              let first = UInt16(firstText),
              first > 0
        else { return nil }
        let second = components.dropFirst().first.flatMap(UInt16.init) ?? 0

        var payload = Data([0, 0])
        payload.append(uint16Data(first))
        payload.append(uint16Data(second))
        payload.append(contentsOf: [0, 0])
        return payload
    }

    nonisolated private static func makeMetadataItemBox(type: BoxType, dataType: UInt32, payload: Data) -> Data {
        var dataPayload = uint32Data(dataType)
        dataPayload.append(contentsOf: [0, 0, 0, 0])
        dataPayload.append(payload)
        return makeBox(type: type, content: makeBox(type: BoxType("data"), content: dataPayload))
    }

    nonisolated private static func makeBox(type: BoxType, content: Data) -> Data {
        var box = Data()
        let size = content.count + 8
        box.append(uint32Data(UInt32(size)))
        box.append(type.data)
        box.append(content)
        return box
    }

    nonisolated private static func makeFreeBox(size: Int) -> Data {
        guard size >= 8 else { return Data() }
        return makeBox(type: BoxType("free"), content: Data(repeating: 0, count: size - 8))
    }

    nonisolated private static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func uint32Data(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    nonisolated private static func uint16Data(_ value: UInt16) -> Data {
        Data([
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }
}

extension MP4MetadataWriter {
    /// The movie box with `rewriteMoovContent` applied. Its `free` and `skip` children are dropped, so space the
    /// writer left in an earlier save can be reused.
    nonisolated private static func rebuiltMovie(
        _ draft: MediaMetadataEditDraft,
        source: FileHandle,
        fileSize: UInt64
    ) throws -> RebuiltMovie {
        let topLevelBoxes = try fileBoxes(in: source, fileSize: fileSize)
        guard let moovBox = topLevelBoxes.first(where: { $0.type == BoxType("moov") }) else {
            throw MediaMetadataEditError.unsupportedMP4MetadataLayout
        }
        let contentSize = moovBox.contentRange.upperBound - moovBox.contentRange.lowerBound
        let originalSize = moovBox.totalRange.upperBound - moovBox.totalRange.lowerBound
        guard contentSize <= UInt64(Int.max), originalSize <= UInt64(Int.max) else {
            throw MediaMetadataEditError.unsupportedMP4MetadataLayout
        }
        let data = try MediaFileRewriter.read(
            from: source,
            at: moovBox.contentRange.lowerBound,
            count: Int(contentSize)
        )
        var compacted = Data()
        var offset = 0
        for child in try boxes(in: 0..<data.count, data: data) {
            compacted.append(data[offset..<child.totalRange.lowerBound])
            if paddingTypes.contains(child.type) == false {
                compacted.append(data[child.totalRange])
            }
            offset = child.totalRange.upperBound
        }
        compacted.append(data[offset...])
        return RebuiltMovie(
            topLevelBoxes: topLevelBoxes,
            moovBox: moovBox,
            originalContent: data,
            content: try rewriteMoovContent(draft, in: 0..<compacted.count, data: compacted)
        )
    }

    /// The rebuilt movie box, with a trailing `free` child that keeps it at `size` bytes when it shrinks by 8 or more.
    nonisolated private static func paddedMoovBox(_ movie: RebuiltMovie, size: UInt64) -> Data {
        let unpaddedSize = UInt64(movie.content.count) + 8
        guard unpaddedSize + 8 <= size else { return makeBox(type: movie.moovBox.type, content: movie.content) }
        return makeBox(type: movie.moovBox.type, content: movie.content + makeFreeBox(size: Int(size - unpaddedSize)))
    }

    /// An edit that leaves every other box in place, so no chunk or fragment offset changes; nil when none fits.
    nonisolated private static func inPlaceEdit(
        for movie: RebuiltMovie,
        fileSize: UInt64
    ) -> MediaFileRewriter.InPlaceEdit? {
        let moovRange = movie.moovBox.totalRange
        let oldSize = moovRange.upperBound - moovRange.lowerBound
        let newSize = UInt64(movie.content.count) + 8
        if newSize == oldSize || newSize + 8 <= oldSize {
            // The same bytes the full rewrite writes for an unchanged size.
            return .init(
                offset: moovRange.lowerBound, originalLength: oldSize, data: paddedMoovBox(movie, size: oldSize)
            )
        }
        let moov = makeBox(type: movie.moovBox.type, content: movie.content)
        if moovRange.upperBound == fileSize {
            return .init(
                offset: moovRange.lowerBound, originalLength: oldSize, data: moov,
                newFileLength: moovRange.lowerBound + newSize
            )
        }
        guard let next = movie.topLevelBoxes.first(where: { $0.totalRange.lowerBound == moovRange.upperBound }),
              paddingTypes.contains(next.type) else { return nil }
        let available = next.totalRange.upperBound - moovRange.lowerBound
        guard newSize == available || (newSize + 8 <= available && available - newSize <= UInt64(UInt32.max)) else {
            return nil
        }
        return .init(
            offset: moovRange.lowerBound, originalLength: available,
            data: moov + makeFreeBox(size: Int(available - newSize))
        )
    }
}

nonisolated private struct RebuiltMovie {
    let topLevelBoxes: [MP4MetadataWriter.MP4FileBox]
    let moovBox: MP4MetadataWriter.MP4FileBox
    let originalContent: Data
    /// The children with the rewritten `udta`, without `free` and `skip` boxes.
    let content: Data
}

nonisolated private struct MP4MetadataItem: Sendable {
    let type: MP4MetadataWriter.BoxType
    let dataType: UInt32
    let payload: Data
}

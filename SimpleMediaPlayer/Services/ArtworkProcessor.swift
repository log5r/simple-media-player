import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct ArtworkProcessor: Sendable {
    private let downsample: @Sendable (Data, CGFloat) -> Data?

    init() {
        downsample = Self.downsampleArtwork
    }

    init(downsample: @escaping @Sendable (Data, CGFloat) -> Data?) {
        self.downsample = downsample
    }

    func thumbnail(from data: Data) async -> Data? {
        await Task.detached(priority: .utility) {
            downsample(data, 600)
        }.value
    }

    func load(from url: URL) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: url)
            guard let artwork = downsample(data, 600) else {
                throw MediaMetadataEditError.invalidArtwork
            }
            return artwork
        }.value
    }

    private static func downsampleArtwork(_ data: Data, maxPixelSize: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let mutableData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  mutableData,
                  UTType.jpeg.identifier as CFString,
                  1,
                  nil
              )
        else { return data }

        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        return CGImageDestinationFinalize(destination) ? mutableData as Data : data
    }
}

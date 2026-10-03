import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

enum ArtworkUITestFixture {
    static func addArtwork(in context: ModelContext) throws {
        let items = try context.fetch(FetchDescriptor<MediaItem>(sortBy: [SortDescriptor(\.addedAt)]))
        let data = try imageData()
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 2) {
                item.legacyArtworkData = data
                item.album = "UI Test Legacy Artwork"
            } else {
                item.artworkData = data
                item.album = "UI Test Stored Artwork"
            }
        }
    }

    private static func imageData() throws -> Data {
        guard let context = CGContext(
            data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let data = CFDataCreateMutable(nil, 0) else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }
}

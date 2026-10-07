// Compile with: xcrun swiftc -parse-as-library scripts/GenerateMP4MetadataFixture.swift -o /tmp/generate-mp4
// Run with a temporary output path. The fragment-snapshot.mp4 sibling is the test fixture.
import AVFoundation
import Foundation

@main
struct GenerateFragments {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.producesCombinableFragments = true
        writer.movieFragmentInterval = CMTime(seconds: 0.5, preferredTimescale: 30)
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = "Fragmented fixture title" as NSString
        writer.metadata = [title]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 32,
            AVVideoHeightKey: 32,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 15]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                         kCVPixelBufferWidthKey as String: 32,
                                         kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB,
                                      nil, &buffer) == kCVReturnSuccess, let buffer else { fatalError() }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30))
            else { throw writer.error! }
        }
        try await Task.sleep(for: .milliseconds(200))
        // Snapshot before finalization: finishWriting flattens the file on Xcode 27.1.
        try Data(contentsOf: url).write(to: url.deletingLastPathComponent().appendingPathComponent("fragment-snapshot.mp4"))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
    }
}

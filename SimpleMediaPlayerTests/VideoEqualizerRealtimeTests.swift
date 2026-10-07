import AVFoundation
import Foundation
import Testing
@testable import SimpleMediaPlayer

struct VideoEqualizerRealtimeTests {
    @Test(arguments: [1, 2], [false, true])
    func rawBufferProcessingPreservesChannelsAndPreamp(channels: Int, interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
            channels: AVAudioChannelCount(channels), interleaved: interleaved
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 64
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for channel in 0..<channels {
            let pointer = list[interleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<64 {
                pointer[interleaved ? frame * channels + channel : frame] = channel == 0 ? 0.1 : -0.2
            }
        }
        let settings = EqualizerSettings(
            isEnabled: true, preampDecibels: 6, bandGains: Array(repeating: 0, count: EqualizerSettings.bandCount)
        )
        let processor = VideoEqualizerProcessor(settings: settings)
        processor.prepare(format: format)
        processor.process(buffer.mutableAudioBufferList, frameCount: 64)
        let gain = pow(Float(10), 6 / 20)
        for channel in 0..<channels {
            let pointer = list[interleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
            for frame in 0..<64 {
                let expected: Float = (channel == 0 ? 0.1 : -0.2) * gain
                #expect(abs(pointer[interleaved ? frame * channels + channel : frame] - expected) < 0.000_01)
            }
        }
    }

    @Test func longRunningConcurrentSettingsUpdatesRetainAtMostTwoSnapshots() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 64
        let processor = VideoEqualizerProcessor()
        processor.prepare(format: format)
        let writer = DispatchGroup()
        writer.enter()
        DispatchQueue.global().async {
            for index in 0..<10_000 {
                processor.setSettings(EqualizerSettings(
                    isEnabled: true, preampDecibels: Float(index % 13),
                    bandGains: Array(repeating: 0, count: EqualizerSettings.bandCount)
                ))
                #expect(processor.retainedConfigurationCount <= 2)
            }
            writer.leave()
        }
        for _ in 0..<10_000 {
            buffer.floatChannelData![0].update(repeating: 0.1, count: 64)
            processor.process(buffer.mutableAudioBufferList, frameCount: 64)
            let value = buffer.floatChannelData![0][0]
            #expect(value.isFinite && value >= 0.1 && value < 0.4)
            #expect((0..<64).allSatisfy { buffer.floatChannelData![0][$0] == value })
        }
        writer.wait()
        #expect(processor.retainedConfigurationCount <= 2)
        // A final publication with no active reader reclaims every obsolete snapshot.
        processor.setSettings(.flat)
        #expect(processor.retainedConfigurationCount == 1)
    }
}

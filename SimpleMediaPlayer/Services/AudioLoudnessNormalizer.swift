import AVFoundation
import Foundation

nonisolated enum AudioLoudnessNormalizer {
    static let minimumGainDecibels: Float = -24
    static let maximumGainDecibels: Float = 12

    private static let targetLevelDecibels = -18.0
    private static let absoluteGateDecibels = -70.0
    private static let relativeGateDecibels = -10.0
    private static let maximumPeakAmplitude = 0.95
    private static let cacheKey = "audioLoudnessNormalizationCache.v1"
    private static let maximumCacheEntryCount = 256
    private static let cacheLock = NSLock()

    static func cachedOrMeasuredGain(for url: URL, defaults: UserDefaults = .standard) throws -> Float {
        try cachedOrMeasuredGain(for: url, defaults: defaults, measure: measuredGain)
    }

    static func cachedOrMeasuredGain(
        for url: URL,
        defaults: UserDefaults,
        measure: (URL) throws -> Float
    ) throws -> Float {
        try Task.checkCancellation()
        let hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess { url.stopAccessingSecurityScopedResource() }
        }

        let fileKey = fileCacheKey(for: url)
        if let fileKey,
           let cachedGain = cachedGain(forKey: fileKey, defaults: defaults) {
            try Task.checkCancellation()
            return cachedGain
        }

        let gain: Float
        do {
            gain = try measure(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            gain = 0
        }
        try Task.checkCancellation()
        if let fileKey {
            try store(gain: gain, forKey: fileKey, defaults: defaults)
        }
        return gain
    }

    static func gainDecibels(forBlockMeanSquares blockMeanSquares: [Double], peakAmplitude: Float) -> Float {
        let absoluteGatePower = pow(10, absoluteGateDecibels / 10)
        let audibleBlocks = blockMeanSquares.filter { $0.isFinite && $0 > absoluteGatePower }
        guard audibleBlocks.isEmpty == false else { return 0 }

        let ungatedMeanSquare = audibleBlocks.reduce(0, +) / Double(audibleBlocks.count)
        let relativeGatePower = ungatedMeanSquare * pow(10, relativeGateDecibels / 10)
        let gatePower = max(absoluteGatePower, relativeGatePower)
        let gatedBlocks = audibleBlocks.filter { $0 >= gatePower }
        guard gatedBlocks.isEmpty == false else { return 0 }

        let integratedMeanSquare = gatedBlocks.reduce(0, +) / Double(gatedBlocks.count)
        guard integratedMeanSquare.isFinite, integratedMeanSquare > 0 else { return 0 }

        let measuredLevel = 10 * log10(integratedMeanSquare)
        var gain = targetLevelDecibels - measuredLevel

        if peakAmplitude.isFinite, peakAmplitude > 0 {
            let peakHeadroom = 20 * log10(maximumPeakAmplitude / Double(peakAmplitude))
            gain = min(gain, peakHeadroom)
        }

        return Float(max(Double(minimumGainDecibels), min(Double(maximumGainDecibels), gain)))
    }

    private static func measuredGain(for url: URL) throws -> Float {
        try Task.checkCancellation()
        let source = try ExtendedAudioSource.readableFile(for: url)
        defer { source.release() }
        let file = try AVAudioFile(forReading: source.url)
        return try measuredGain(in: file)
    }

    private static func measuredGain(in file: AVAudioFile) throws -> Float {
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount > 0,
              format.commonFormat == .pcmFormatFloat32,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384)
        else {
            return 0
        }

        let blockFrameCapacity = max(1, Int(format.sampleRate * 0.4))
        var blockMeanSquares: [Double] = []
        blockMeanSquares.reserveCapacity(max(1, Int(file.length) / blockFrameCapacity))
        var blockSquareSum = 0.0
        var blockFrameCount = 0
        var peakAmplitude: Float = 0

        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            try Task.checkCancellation()
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0, let channelData = buffer.floatChannelData else { break }

            var frameOffset = 0
            while frameOffset < frameLength {
                let framesToConsume = min(blockFrameCapacity - blockFrameCount, frameLength - frameOffset)
                let frameRange = frameOffset..<(frameOffset + framesToConsume)

                for channelIndex in 0..<channelCount {
                    let samples = channelData[channelIndex]
                    for frameIndex in frameRange {
                        let sample = samples[frameIndex]
                        let magnitude = abs(sample)
                        peakAmplitude = max(peakAmplitude, magnitude)
                        blockSquareSum += Double(sample) * Double(sample)
                    }
                }

                blockFrameCount += framesToConsume
                frameOffset += framesToConsume

                if blockFrameCount == blockFrameCapacity {
                    blockMeanSquares.append(blockSquareSum / Double(blockFrameCount * channelCount))
                    blockSquareSum = 0
                    blockFrameCount = 0
                }
            }
        }

        if blockFrameCount > 0 {
            blockMeanSquares.append(blockSquareSum / Double(blockFrameCount * channelCount))
        }

        try Task.checkCancellation()
        return gainDecibels(forBlockMeanSquares: blockMeanSquares, peakAmplitude: peakAmplitude)
    }

    private static func fileCacheKey(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let fileSize = values.fileSize,
              let modificationDate = values.contentModificationDate
        else {
            return nil
        }
        return "\(url.path)|\(fileSize)|\(modificationDate.timeIntervalSince1970)"
    }

    private static func cachedGain(forKey fileKey: String, defaults: UserDefaults) -> Float? {
        cacheLock.withLock {
            guard let number = defaults.dictionary(forKey: cacheKey)?[fileKey] as? NSNumber else { return nil }
            return Float(truncating: number)
        }
    }

    private static func store(gain: Float, forKey fileKey: String, defaults: UserDefaults) throws {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        try Task.checkCancellation()
        var cache = defaults.dictionary(forKey: cacheKey) ?? [:]
        if cache[fileKey] == nil, cache.count >= maximumCacheEntryCount {
            for key in cache.keys.sorted().prefix(maximumCacheEntryCount / 4) {
                cache.removeValue(forKey: key)
            }
        }
        cache[fileKey] = Double(gain)
        try Task.checkCancellation()
        defaults.set(cache, forKey: cacheKey)
    }
}

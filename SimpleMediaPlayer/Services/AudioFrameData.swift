import Foundation

nonisolated struct AudioFrameData: Sendable {
    var bandsL: [Float]
    var bandsR: [Float]
    var peaksL: [Float]
    var peaksR: [Float]
    var rmsL: Float
    var rmsR: Float
    var peakRmsL: Float
    var peakRmsR: Float
    var isPlaying: Bool
    var currentTime: TimeInterval

    var isSilent: Bool {
        rmsL == 0 && rmsR == 0 && peakRmsL == 0 && peakRmsR == 0
            && bandsL.allSatisfy { $0 == 0 } && bandsR.allSatisfy { $0 == 0 }
            && peaksL.allSatisfy { $0 == 0 } && peaksR.allSatisfy { $0 == 0 }
    }

    static func silent(bandCount: Int = 16, currentTime: TimeInterval = 0, isPlaying: Bool = false) -> AudioFrameData {
        AudioFrameData(
            bandsL: Array(repeating: 0, count: bandCount),
            bandsR: Array(repeating: 0, count: bandCount),
            peaksL: Array(repeating: 0, count: bandCount),
            peaksR: Array(repeating: 0, count: bandCount),
            rmsL: 0,
            rmsR: 0,
            peakRmsL: 0,
            peakRmsR: 0,
            isPlaying: isPlaying,
            currentTime: currentTime
        )
    }
}

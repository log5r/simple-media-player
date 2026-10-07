import Foundation

struct SpectrumFrameRateCounter {
    private var windowStartTime: TimeInterval?
    private var frameCount = 0
    private let publishInterval: TimeInterval = 0.5

    mutating func recordFrame(at time: TimeInterval) -> Int? {
        guard let windowStartTime else {
            self.windowStartTime = time
            frameCount = 1
            return nil
        }

        frameCount += 1
        let elapsed = time - windowStartTime
        guard elapsed >= publishInterval else { return nil }

        let frameRate = Int((Double(frameCount - 1) / elapsed).rounded())
        self.windowStartTime = time
        frameCount = 1
        return min(999, max(0, frameRate))
    }

    mutating func reset() {
        windowStartTime = nil
        frameCount = 0
    }
}

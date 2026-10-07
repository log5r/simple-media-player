// 更新頻度(低速: 約10Hz / 通常: 30Hz / 高速: 60Hz)ごとに、1回あたりの減衰量を
// 秒あたりの視覚的な減衰速度が近くなるよう調整した定数
nonisolated struct SpectrumSmoothing {
    let levelRelease: Float
    let peakHoldUpdates: Int
    let peakFall: Float
    let rmsRelease: Float

    static let slow = SpectrumSmoothing(
        levelRelease: 0.64,
        peakHoldUpdates: 8,
        peakFall: 0.08,
        rmsRelease: 0.82
    )
    static let normal = SpectrumSmoothing(
        levelRelease: 0.86,
        peakHoldUpdates: 24,
        peakFall: 0.027,
        rmsRelease: 0.94
    )
    static let fast = SpectrumSmoothing(
        levelRelease: 0.90,
        peakHoldUpdates: 48,
        peakFall: 0.014,
        rmsRelease: 0.96
    )

    static func parameters(for mode: VisualizerResponseMode) -> Self {
        switch mode {
        case .slow: slow
        case .normal: normal
        case .fast: fast
        }
    }

    func updatePeaks(levels: [Float], peaks: inout [Float], ages: inout [Int]) {
        for index in levels.indices {
            if levels[index] >= peaks[index] {
                peaks[index] = levels[index]
                ages[index] = 0
            } else if ages[index] > peakHoldUpdates {
                peaks[index] = max(levels[index], peaks[index] - peakFall)
            } else {
                ages[index] += 1
            }
        }
    }
}

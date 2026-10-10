nonisolated enum VUMeterScale {
    static let settlingDuration = 1.5
    static let referenceLevelDBFS: Float = -18
    static let minimumVU: Float = -20
    static let maximumVU: Float = 3
    static let ticks: [(vu: Float, t: Float)] = [
        (-20, 0), (-10, 0.23), (-7, 0.35), (-5, 0.46), (-3, 0.58),
        (-1, 0.71), (0, 0.78), (1, 0.86), (2, 0.93), (3, 1)
    ]

    static func needlePosition(normalizedRMS: Float) -> Float {
        let dbfs = normalizedRMS * 60 - 60
        let volumeUnits = min(maximumVU, max(minimumVU, dbfs - referenceLevelDBFS))
        for index in 1..<ticks.count {
            let lower = ticks[index - 1]
            let upper = ticks[index]
            if volumeUnits <= upper.vu {
                let fraction = (volumeUnits - lower.vu) / (upper.vu - lower.vu)
                return lower.t + fraction * (upper.t - lower.t)
            }
        }
        return 1
    }

    static func angleDegrees(for position: Float) -> Float {
        -47 + 94 * position
    }

    nonisolated struct Ballistics {
        /// The longest single integration step. Longer frame intervals are split into equal sub-steps,
        /// so the needle moves at the same real-time speed at 10, 30, and 60 fps.
        static let maximumSubstep: Float = 1.0 / 60
        /// The longest interval integrated at once. It covers one late frame in the 10 fps mode, but keeps the
        /// first frame after drawing was paused from jumping ahead by the whole pause.
        static let maximumElapsedTime: Float = 0.2

        var position: Float = 0
        var velocity: Float = 0

        mutating func step(toward target: Float, dt elapsedTime: Float) {
            let elapsedTime = min(max(elapsedTime, 0), Self.maximumElapsedTime)
            guard elapsedTime > 0 else { return }
            // The tolerance keeps an interval of exactly 1/60 s in one sub-step despite rounding.
            let substeps = max(1, Int((elapsedTime / Self.maximumSubstep - 0.001).rounded(.up)))
            let timeStep = elapsedTime / Float(substeps)
            for _ in 0..<substeps {
                integrate(toward: target, timeStep: timeStep)
            }
        }

        private mutating func integrate(toward target: Float, timeStep: Float) {
            let omega: Float = 2 * .pi * 1.6
            let zeta: Float = 0.7
            velocity += (omega * omega * (target - position) - 2 * zeta * omega * velocity) * timeStep
            position += velocity * timeStep
        }
    }
}

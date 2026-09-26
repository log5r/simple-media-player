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
        var position: Float = 0
        var velocity: Float = 0

        mutating func step(toward target: Float, dt timeStep: Float) {
            let timeStep = min(max(timeStep, 0), 1.0 / 20)
            let omega: Float = 2 * .pi * 1.6
            let zeta: Float = 0.7
            velocity += (omega * omega * (target - position) - 2 * zeta * omega * velocity) * timeStep
            position += velocity * timeStep
        }
    }
}

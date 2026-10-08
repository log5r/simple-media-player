import Foundation
import Synchronization
import Testing
@testable import SimpleMediaPlayer

struct ProgressReportThrottleTests {
    private final class ManualClock: Sendable {
        private let instant = Mutex(ContinuousClock.now)

        var now: ContinuousClock.Instant { instant.withLock { $0 } }

        func advance(by duration: Duration) {
            instant.withLock { $0 = $0.advanced(by: duration) }
        }
    }

    @Test func forwardsFirstReportAndStepsOfAtLeastMinimum() {
        let clock = ManualClock()
        let throttle = ProgressReportThrottle(minimumStep: 0.01, minimumInterval: .milliseconds(100)) { clock.now }

        #expect(throttle.shouldReport(0))
        #expect(throttle.shouldReport(0.005) == false)
        #expect(throttle.shouldReport(0.009) == false)
        #expect(throttle.shouldReport(0.01))
        #expect(throttle.shouldReport(0.015) == false)
        #expect(throttle.shouldReport(0.03))
    }

    @Test func forwardsSmallAdvanceAfterMinimumInterval() {
        let clock = ManualClock()
        let throttle = ProgressReportThrottle(minimumStep: 0.01, minimumInterval: .milliseconds(100)) { clock.now }

        #expect(throttle.shouldReport(0.2))
        clock.advance(by: .milliseconds(99))
        #expect(throttle.shouldReport(0.201) == false)
        clock.advance(by: .milliseconds(1))
        #expect(throttle.shouldReport(0.202))
        #expect(throttle.shouldReport(0.203) == false)
    }

    @Test func neverForwardsUnchangedOrRegressingValues() {
        let clock = ManualClock()
        let throttle = ProgressReportThrottle(minimumStep: 0.01, minimumInterval: .milliseconds(100)) { clock.now }

        #expect(throttle.shouldReport(0.5))
        clock.advance(by: .seconds(1))
        #expect(throttle.shouldReport(0.5) == false)
        #expect(throttle.shouldReport(0.4) == false)
        #expect(throttle.shouldReport(1))
        clock.advance(by: .seconds(1))
        #expect(throttle.shouldReport(1) == false)
    }

    @Test func alwaysForwardsCompletion() {
        let clock = ManualClock()
        let throttle = ProgressReportThrottle(minimumStep: 0.01, minimumInterval: .milliseconds(100)) { clock.now }

        #expect(throttle.shouldReport(0.995))
        #expect(throttle.shouldReport(1))
    }

    @Test func boundsReportsForPerBufferProgress() {
        let clock = ManualClock()
        let throttle = ProgressReportThrottle(minimumStep: 0.01, minimumInterval: .milliseconds(100)) { clock.now }
        // A five-minute track at 44.1 kHz rendered in 4096-frame buffers, all within one interval.
        let bufferCount = 44_100 * 300 / 4096
        var forwarded = 0
        for index in 1...bufferCount where throttle.shouldReport(Double(index) / Double(bufferCount)) {
            forwarded += 1
        }

        #expect(forwarded <= 101)
        #expect(forwarded >= 50)
    }
}

@MainActor
struct TransformedExportProgressThrottlingTests {
    @Test func exporterForwardsOnlyVisibleRenderProgressChanges() async throws {
        let fixture = try TransformedExportFixture()
        defer { fixture.remove() }
        let renderer = ControlledExportRenderer(behavior: .ignoreCancellation)
        // A long interval leaves only the step rule, so the outcome does not depend on scheduling delays.
        let exporter = TransformedTrackExporter(
            renderer: renderer,
            temporaryDirectory: fixture.renderDirectory,
            progressReportInterval: .seconds(3600)
        )
        let task = Task { try await fixture.export(using: exporter) }
        defer { task.cancel(); renderer.release() }

        try await renderer.waitUntilStarted()
        try await waitForProgress(0.5 * 0.95, on: exporter)

        renderer.reportProgress(0.505)
        try await Task.sleep(for: .milliseconds(20))
        #expect(exporter.progress == 0.5 * 0.95)

        renderer.reportProgress(0.52)
        try await waitForProgress(0.52 * 0.95, on: exporter)

        renderer.release()
        _ = try await task.value
        #expect(exporter.progress == 1)
    }

    private func waitForProgress(_ expected: Double, on exporter: TransformedTrackExporter) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while exporter.progress != expected && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(exporter.progress == expected)
    }
}

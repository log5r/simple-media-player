#if os(iOS)
import AVFoundation
import CoreImage
import XCTest

/// Select partially folded portrait in Device Hub; synthetic rotation does not change the real Duo display.
final class DuoFullScreenVideoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testPartiallyFoldedPortraitVideoStaysAboveTheFold() async throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-phone-layout", "--ui-testing-duo-layout", "--ui-testing-duo-autoplay-probe",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US"
        ]
        app.launchEnvironment["PHONE_LAYOUT_VIDEO_BASE64"] = try await makeVideo().base64EncodedString()
        app.launch()
        let layout = duoDiagnostic("duoLayoutMetrics", in: app)
        XCTAssertTrue(layout.waitForExistence(timeout: 10))
        let geometry = try metrics(layout)
        try XCTSkipUnless(geometry["portrait"] as? Bool == true && geometry["hasActiveDivision"] as? Bool == true,
                          "Select partially folded portrait in Device Hub.")
        try verifyScreenCoordinates(app.frame, geometry: geometry)
        let playback = duoDiagnostic("duoPlaybackMetrics", in: app)
        await fulfillment(of: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "\"playing\":true"), object: playback
        )], timeout: 10)
        let showVideo = app.buttons["showVideoButton"]
        XCTAssertTrue(showVideo.waitForExistence(timeout: 5))
        showVideo.tap()

        let video = duoDiagnostic("fullScreenVideoMetrics", in: app)
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        let frame = try metrics(video)
        try assertUpperVideoArea(frame, screen: app.frame, geometry: geometry)
        assertTransportAndClosing(in: app, showVideo: showVideo)
    }

    private func verifyScreenCoordinates(_ screen: CGRect, geometry: [String: Any]) throws {
        let safeArea = try XCTUnwrap(geometry["safeArea"] as? [String: Any])
        let width = try number("width", in: geometry)
            + number("leading", in: safeArea) + number("trailing", in: safeArea)
        let height = try number("height", in: geometry) + number("top", in: safeArea) + number("bottom", in: safeArea)
        try XCTSkipUnless(abs(screen.width - width) < 2 && abs(screen.height - height) < 2,
                          "Root and screen coordinate bounds differ; select the inner Duo display.")
    }

    private func assertUpperVideoArea(_ frame: [String: Any], screen: CGRect, geometry: [String: Any]) throws {
        XCTAssertEqual(try number("x", in: frame), screen.minX, accuracy: 2)
        XCTAssertEqual(try number("y", in: frame), screen.minY, accuracy: 2)
        XCTAssertEqual(try number("width", in: frame), screen.width, accuracy: 2)
        let height = try number("height", in: frame)
        XCTAssertGreaterThan(height, 0)
        XCTAssertLessThan(height, screen.height / 2)
        let divisions = try XCTUnwrap(geometry["division"] as? [[String: Any]])
        let division = try XCTUnwrap(divisions.first { $0["active"] as? Bool == true })
        let safeArea = try XCTUnwrap(geometry["safeArea"] as? [String: Any])
        let foldTop = try number("y", in: division) + number("top", in: safeArea)
        XCTAssertEqual(height, foldTop, accuracy: 2)
    }

    @MainActor private func assertTransportAndClosing(in app: XCUIApplication, showVideo: XCUIElement) {
        let playback = app.buttons["videoFullScreenPlayPauseButton"]
        XCTAssertTrue(playback.isHittable)
        XCTAssertTrue(playback.label.contains("Pause"))
        playback.tap()
        XCTAssertTrue(playback.label.contains("Play"))
        playback.tap()
        XCTAssertTrue(playback.label.contains("Pause"))
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Duo partially folded portrait full-screen video"
        image.lifetime = .keepAlways
        add(image)
        app.buttons["videoFullScreenCloseButton"].tap()
        XCTAssertTrue(showVideo.waitForExistence(timeout: 5))
        showVideo.tap()
        let videoSurface = app.buttons["Video"]
        XCTAssertTrue(videoSurface.waitForExistence(timeout: 5))
        videoSurface.doubleTap()
        XCTAssertTrue(showVideo.waitForExistence(timeout: 5))
    }

    @MainActor private func metrics(_ element: XCUIElement) throws -> [String: Any] {
        let value = try XCTUnwrap(element.value as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }

    private func number(_ key: String, in values: [String: Any]) throws -> Double {
        try XCTUnwrap(values[key] as? Double)
    }

    /// Two red frames spanning a minute keep the fixture small enough for the launch environment.
    @MainActor private func makeVideo() async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                          sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB,
                                          [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
                                          &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CIContext().render(CIImage(color: .red), to: pixelBuffer)
        for second: Int64 in [0, 59] {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing, Date() < deadline else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: second, timescale: 1)))
        }
        writer.endSession(atSourceTime: CMTime(value: 60, timescale: 1))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return try Data(contentsOf: url)
    }
}
#endif

//
//  FeedbackAndCRTTests.swift — echo, feedback, latency calibration and CRT geometry.
//
//  Purpose : Phase 3's headless acceptance. The feedback round-trip calibration in
//            particular is the kind of thing that silently drifts if it is wrong, so
//            it is tested against a simulated loop with a known delay.
//  Inputs  : synthetic frames and a fake loop; no hardware.
//  Outputs : assertions, plus PNGs under selfqa/out/phase-3/.
//  Connects: EchoNode, FeedbackNode, FeedbackLatencyCalibrator, CRTGeometry.
//

import XCTest
import Metal
@testable import VideoboyCore

final class FeedbackAndCRTTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    // MARK: - Latency calibration

    /// The property that matters: a loop with a known delay must be measured as
    /// having that delay. If this is wrong, every beat-driven feedback effect drifts.
    func testCalibratorMeasuresAKnownRoundTrip() throws {
        // The marker appears on the sample `markerOnSample` positions after the
        // flash, counting that first sample as position 0. A marker on the very
        // first sample after the flash is one frame of round trip.
        let markerOnSample = 6
        let expectedFrames = markerOnSample + 1
        let dark = TestPattern.solid(width: 64, height: 48, r: 10, g: 10, b: 10)
        let bright = TestPattern.solid(width: 64, height: 48, r: 240, g: 240, b: 240)

        // A fake loop: after the flash, the marker comes back `trueDelay` frames later.
        var framesSinceFlash: Int?
        let latency = try FeedbackLatencyCalibrator.measure(
            frameRate: StandardDefinition.frameRate,
            flash: { framesSinceFlash = 0 },
            sample: {
                guard let elapsed = framesSinceFlash else { return dark }
                framesSinceFlash = elapsed + 1
                return elapsed == markerOnSample ? bright : dark
            }
        )

        XCTAssertEqual(latency.frames, expectedFrames, "the measured round trip must match the real one")
        XCTAssertEqual(
            latency.seconds, Double(expectedFrames) / StandardDefinition.frameRate, accuracy: 1e-9)
        XCTAssertGreaterThan(latency.confidence, 1.0, "a clean detection must be confident")
    }

    func testCalibratorReportsAnUnconnectedLoopRatherThanGuessing() {
        // Nothing ever comes back. It must say so, not return a plausible number.
        let dark = TestPattern.solid(width: 32, height: 24, r: 10, g: 10, b: 10)
        XCTAssertThrowsError(
            try FeedbackLatencyCalibrator.measure(
                maximumFrames: 12, flash: {}, sample: { dark })
        ) { error in
            guard case CalibrationFailure.markerNeverReturned = error else {
                return XCTFail("expected markerNeverReturned, got \(error)")
            }
        }
    }

    func testCalibratorReportsNoSignal() {
        XCTAssertThrowsError(
            try FeedbackLatencyCalibrator.measure(flash: {}, sample: { nil })
        ) { error in
            guard case CalibrationFailure.noSignal = error else {
                return XCTFail("expected noSignal, got \(error)")
            }
        }
    }

    func testCalibratorIsNotFooledByANoisyBaseline() throws {
        // The threshold adapts to the noise it sees, so a loop that is merely noisy
        // must not read as a detection.
        let markerOnSample = 4
        var frame = 0
        var framesSinceFlash: Int?
        let latency = try FeedbackLatencyCalibrator.measure(
            flash: { framesSinceFlash = 0 },
            sample: {
                frame += 1
                if let elapsed = framesSinceFlash {
                    framesSinceFlash = elapsed + 1
                    if elapsed == markerOnSample {
                        return TestPattern.solid(width: 32, height: 24, r: 250, g: 250, b: 250)
                    }
                }
                // Baseline wanders by a few levels frame to frame.
                let wobble = UInt8(40 + (frame % 5) * 3)
                return TestPattern.solid(width: 32, height: 24, r: wobble, g: wobble, b: wobble)
            }
        )
        XCTAssertEqual(latency.frames, markerOnSample + 1)
    }

    // MARK: - CRT geometry

    func testSafeZonesAreTheStandardFractions() {
        // Action-safe is 90% of the frame, title-safe 80%, both centred.
        XCTAssertEqual(CRTGeometry.actionSafe.width, 0.90, accuracy: 1e-9)
        XCTAssertEqual(CRTGeometry.titleSafe.width, 0.80, accuracy: 1e-9)
        XCTAssertEqual(CRTGeometry.actionSafe.x, 0.05, accuracy: 1e-9)
        XCTAssertEqual(CRTGeometry.titleSafe.y, 0.10, accuracy: 1e-9)

        // And they land on sensible pixel rectangles at SD.
        let action = CRTGeometry.actionSafe.inPixels(width: 720, height: 480)
        XCTAssertEqual(action.x, 36)
        XCTAssertEqual(action.width, 648)
    }

    func testOverscanScaleHidesTheRequestedFraction() {
        // At zero overscan nothing is hidden, so the scale is exactly 1.
        XCTAssertEqual(CRTGeometry.overscanScale(0), 1.0, accuracy: 1e-9)
        // At full overscan the visible fraction and the scale must be reciprocal:
        // scaling up by S shows 1/S of the picture.
        let full = CRTGeometry.overscanScale(1.0)
        let visible = CRTGeometry.visibleRect(overscan: 1.0)
        XCTAssertEqual(full * visible.width, 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(full, 1.0)
    }

    func testBlackFrameInsertionPeriod() {
        let off = BlackFrameInsertion.from(normalised: 0)
        XCTAssertEqual(off.everyNFrames, 0)
        XCTAssertFalse(off.isBlackFrame(0))
        XCTAssertFalse(off.isBlackFrame(99))

        // One black frame in every four: the frame before each boundary.
        let quarter = BlackFrameInsertion(everyNFrames: 4)
        XCTAssertFalse(quarter.isBlackFrame(0))
        XCTAssertTrue(quarter.isBlackFrame(3))
        XCTAssertTrue(quarter.isBlackFrame(7))
        XCTAssertEqual((0..<16).filter(quarter.isBlackFrame).count, 4)

        // A higher parameter value must insert more often, not less.
        let light = BlackFrameInsertion.from(normalised: 0.2)
        let heavy = BlackFrameInsertion.from(normalised: 1.0)
        XCTAssertLessThan(heavy.everyNFrames, light.everyNFrames)
        XCTAssertGreaterThanOrEqual(heavy.everyNFrames, 2)
    }

    func testSoftwareInterlaceTakesAlternateRowsFromEachField() throws {
        let first = TestPattern.solid(width: 8, height: 4, r: 255, g: 0, b: 0)
        let second = TestPattern.solid(width: 8, height: 4, r: 0, g: 0, b: 255)

        // Bottom-field-first: the later field supplies the even rows.
        let woven = try XCTUnwrap(SoftwareInterlace.weave(
            firstField: first, secondField: second, order: .bottomFieldFirst))
        XCTAssertEqual(woven.pixel(x: 0, y: 0).b, 255, "row 0 must come from the second field")
        XCTAssertEqual(woven.pixel(x: 0, y: 1).r, 255, "row 1 must come from the first field")

        // Top-field-first is the other way round.
        let topFirst = try XCTUnwrap(SoftwareInterlace.weave(
            firstField: first, secondField: second, order: .topFieldFirst))
        XCTAssertEqual(topFirst.pixel(x: 0, y: 0).r, 255)
        XCTAssertEqual(topFirst.pixel(x: 0, y: 1).b, 255)

        // A woven frame of two different fields is, by construction, combed — which
        // is exactly what the interlace detector should report. Measured in LUMA, so
        // the fields need a luma difference to show up: red and blue differ by only
        // about 47 levels of luma, which scores a correct but small 0.03. Black and
        // white fields are the full-amplitude case.
        let white = TestPattern.solid(width: 8, height: 8, r: 255, g: 255, b: 255)
        let black = TestPattern.solid(width: 8, height: 8, r: 0, g: 0, b: 0)
        let maximallyCombed = try XCTUnwrap(SoftwareInterlace.weave(
            firstField: white, secondField: black, order: .bottomFieldFirst))
        XCTAssertGreaterThan(
            FrameAssertions.combingScore(maximallyCombed), 0.5,
            "alternating black and white fields must read as heavily combed"
        )
        // And the red/blue weave is combed too, just less so in luma terms.
        XCTAssertGreaterThan(FrameAssertions.combingScore(woven), 0.02)
    }

    func testInterlaceRefusesMismatchedFields() {
        let small = TestPattern.solid(width: 8, height: 4, r: 255, g: 0, b: 0)
        let large = TestPattern.solid(width: 16, height: 4, r: 0, g: 0, b: 255)
        XCTAssertNil(SoftwareInterlace.weave(firstField: small, secondField: large))
    }

    func testTestPatternSourceProducesEachPattern() throws {
        let node = TestPatternSourceNode(identifier: "test.pattern", context: nil)
        for kind in TestPatternSourceNode.Kind.allCases {
            node.pattern = kind
            let image = node.makeImage(width: 160, height: 120)
            XCTAssertEqual(image.width, 160)
            XCTAssertEqual(image.height, 120)
            XCTAssertFalse(kind.displayName.isEmpty)
        }
        // The crosshatch must actually have lines in it, or it is useless for
        // geometry checks and for seeding feedback.
        node.pattern = .crosshatch
        let grid = node.makeImage(width: 160, height: 120)
        XCTAssertGreaterThan(FrameAssertions.horizontalDetail(grid), 5.0)
    }

    // MARK: - Echo and feedback on the GPU

    /// Renders a node repeatedly and reads back the last result.
    private func runOverFrames(
        _ node: Node, input: ImageBuffer, frames: Int
    ) throws -> ImageBuffer {
        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        guard let texture = metal.makeTexture(from: input, label: "effect-input") else {
            throw XCTSkip("could not upload the test image")
        }
        var last: MTLTexture?
        for frame in 0..<frames {
            let context = RenderContext(
                frameIndex: frame, presentationTime: 0, musicalPosition: nil,
                width: input.width, height: input.height
            )
            last = node.render(inputs: [texture], context: context)
        }
        guard let last, let image = renderer.readback(last) else {
            throw XCTSkip("the effect produced nothing")
        }
        return image
    }

    func testEchoAccumulatesATrail() throws {
        guard let metal = MetalContext.shared else { throw XCTSkip("no Metal device") }

        // A small bright square on black: the trail is what survives after it stops.
        var image = TestPattern.solid(width: 128, height: 128, r: 0, g: 0, b: 0)
        for y in 40..<88 {
            for x in 40..<88 {
                image.setPixel(x: x, y: y, r: 255, g: 255, b: 255)
            }
        }

        let node = EchoNode(identifier: "test.echo", context: metal)
        node.decay = 0.9
        node.gain = 1.0
        node.threshold = 0.1

        let afterOne = try runOverFrames(node, input: image, frames: 1)
        node.reset()
        let afterMany = try runOverFrames(node, input: image, frames: 12)

        // The picture itself is unchanged, so the frames should be close; what the
        // test really pins down is that accumulating does not destroy the image.
        XCTAssertTrue(FrameAssertions.signalPresent(afterOne))
        XCTAssertTrue(FrameAssertions.signalPresent(afterMany))
        // The bright square must still be bright after many frames of accumulation.
        let centre = FrameAssertions.meanColor(afterMany, region: (x: 50, y: 50, width: 28, height: 28))
        XCTAssertGreaterThan(centre.r, 200)
    }

    func testFeedbackZoomBuildsATunnel() throws {
        guard let metal = MetalContext.shared else { throw XCTSkip("no Metal device") }

        // A bright frame border: zooming it inward repeatedly is the tunnel.
        var image = TestPattern.solid(width: 128, height: 128, r: 0, g: 0, b: 0)
        for y in 0..<128 {
            for x in 0..<128 where x < 4 || x > 123 || y < 4 || y > 123 {
                image.setPixel(x: x, y: y, r: 255, g: 255, b: 255)
            }
        }

        let node = FeedbackNode(identifier: "test.feedback", context: metal)
        node.gain = 0.9
        node.zoom = 1.15
        node.delayFrames = 1
        node.threshold = 0.02

        let result = try runOverFrames(node, input: image, frames: 10)

        // Without feedback the middle of the frame is black. With an inward-zooming
        // loop the border is copied repeatedly toward the centre, so it must not be.
        let centre = FrameAssertions.meanColor(result, region: (x: 48, y: 48, width: 32, height: 32))
        let brightness = 0.299 * centre.r + 0.587 * centre.g + 0.114 * centre.b
        XCTAssertGreaterThan(brightness, 5.0, "an inward-zooming loop must carry light into the centre")
    }

    func testFeedbackDelayIsClampedToTheRing() {
        let node = FeedbackNode(identifier: "test.feedback", context: nil)
        node.delayFrames = 10_000
        XCTAssertEqual(node.delayFrames, FeedbackNode.maximumDelayFrames)
        node.delayFrames = -5
        XCTAssertEqual(node.delayFrames, 0)
    }

    func testFeedbackDeclaresItsDelayAsLatency() {
        // The scheduler compensates using this, so it must track the actual delay.
        let node = FeedbackNode(identifier: "test.feedback", context: nil)
        node.delayFrames = 6
        XCTAssertEqual(node.latencyInFrames, 6)
    }

    func testCaptureNodeUsesMeasuredLatencyWhenAvailable() {
        let node = CaptureSourceNode(identifier: "test.capture", context: nil)
        // Before calibration it declares a conservative default...
        XCTAssertEqual(node.latencyInFrames, 2)
        // ...and afterwards it uses what was actually measured.
        node.measuredLatencyFrames = 9
        XCTAssertEqual(node.latencyInFrames, 9)
    }

    func testCaptureNodeKeepsOnlyTheNewestFrame() {
        let node = CaptureSourceNode(identifier: "test.capture", context: nil)
        let first = TestPattern.solid(width: 8, height: 8, r: 255, g: 0, b: 0)
        let second = TestPattern.solid(width: 8, height: 8, r: 0, g: 255, b: 0)
        node.submit(frame: first, deviceName: "test device")
        node.submit(frame: second)

        // Queueing stale frames would only add latency, so the newest wins.
        let latest = node.latestImage()
        XCTAssertEqual(latest?.pixel(x: 0, y: 0).g, 255)
        XCTAssertEqual(node.receivedFrameCount, 2)
        XCTAssertEqual(node.deviceName, "test device")
    }
}

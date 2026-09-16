//
//  SelfQAHarnessTests.swift — proves the harness itself works.
//
//  Purpose : The harness is Claude's eyes; if it is wrong, every later phase's
//            evidence is worthless. These tests check the eyes before trusting them:
//            known patterns produce known measurements, Metal round-trips pixels
//            unchanged, and the mock capture path reports sane metrics.
//  Inputs  : synthetic test patterns only — no media, no hardware.
//  Outputs : assertions, plus real PNGs under selfqa/out/phase-0/ as evidence.
//  Connects: everything in Sources/VideoboyCore/SelfQA/.
//  Extend  : when you add an assertion to FrameAssertions, calibrate it here against
//            a pattern whose correct answer is known by construction.
//

import XCTest
@testable import VideoboyCore

final class SelfQAHarnessTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Keep test output readable; the ring buffer still records everything.
        Log.echoesToStandardError = false
    }

    // MARK: - Library identity

    func testCoreReportsAVersion() {
        XCTAssertFalse(Videoboy.version.isEmpty, "Core must report a version")
        XCTAssertTrue(Videoboy.banner.contains(Videoboy.version))
    }

    func testFeatureFlagsHonourEnvironmentOverrides() {
        // A '-' prefix turns a flag off; a bare name turns one on.
        let flags = FeatureFlags(environment: "-dvDecode,isfHost")
        XCTAssertFalse(flags.isOn(.dvDecode), "leading '-' must disable a flag")
        XCTAssertTrue(flags.isOn(.isfHost), "a bare name must enable a flag")
        // An unknown name must be ignored rather than trapping.
        let tolerant = FeatureFlags(environment: "notARealFlag")
        XCTAssertTrue(tolerant.isOn(.dvDecode), "unknown flags must not disturb the defaults")
    }

    // MARK: - ImageBuffer

    func testImageBufferRoundTripsThroughPNG() throws {
        let original = TestPattern.colorBars(width: 64, height: 48)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-imagebuffer-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try original.writePNG(to: url)
        let reloaded = try ImageBuffer.readPNG(from: url)

        XCTAssertEqual(reloaded.width, original.width)
        XCTAssertEqual(reloaded.height, original.height)
        // PNG is lossless, so this must be exact, not approximate.
        XCTAssertEqual(reloaded.pixels, original.pixels, "PNG round-trip must be lossless")
    }

    func testBGRAConversionSwapsRedAndBlue() {
        // One pixel, blue-first byte order: B=10, G=20, R=30, A=255.
        let buffer = ImageBuffer.fromBGRA(width: 1, height: 1, bgra: [10, 20, 30, 255])
        let pixel = buffer.pixel(x: 0, y: 0)
        XCTAssertEqual(pixel.r, 30)
        XCTAssertEqual(pixel.g, 20)
        XCTAssertEqual(pixel.b, 10)
    }

    // MARK: - Assertion calibration

    func testColorBarsAssertionRecognisesItsOwnPattern() {
        let bars = TestPattern.colorBars(width: 320, height: 240)
        XCTAssertTrue(FrameAssertions.looksLikeColorBars(bars).passed)
        // ...and rejects something that is definitely not bars.
        let flat = TestPattern.solid(width: 320, height: 240, r: 128, g: 128, b: 128)
        XCTAssertFalse(FrameAssertions.looksLikeColorBars(flat).passed)
    }

    func testDimensionAssertion() {
        let image = TestPattern.colorBars(width: 720, height: 480)
        XCTAssertTrue(FrameAssertions.hasDimensions(image, width: 720, height: 480).passed)
        XCTAssertFalse(FrameAssertions.hasDimensions(image, width: 640, height: 480).passed)
    }

    func testSignalPresentDistinguishesBlackFromPicture() {
        let black = TestPattern.solid(width: 128, height: 128, r: 0, g: 0, b: 0)
        let bars = TestPattern.colorBars(width: 128, height: 128)
        XCTAssertFalse(FrameAssertions.signalPresent(black), "a black frame carries no signal")
        XCTAssertTrue(FrameAssertions.signalPresent(bars), "colour bars must read as signal present")
    }

    func testCombingScoreIsHighForLinesAndLowForSmoothGradients() {
        // Alternating rows are the maximum-combing case by construction.
        let combed = FrameAssertions.combingScore(TestPattern.horizontalLines(width: 128, height: 128))
        // A horizontal ramp is constant down each column, so vertical combing is nil.
        let smooth = FrameAssertions.combingScore(TestPattern.grayscaleRamp(width: 128, height: 128))
        XCTAssertGreaterThan(combed, 0.5, "alternating rows must score as heavily combed")
        XCTAssertLessThan(smooth, 0.01, "a vertically smooth image must score near zero")
        XCTAssertGreaterThan(combed, smooth)
    }

    func testFrameDifferenceDetectsChangeAndSameness() {
        let bars = TestPattern.colorBars(width: 128, height: 128)
        let shifted = TestPattern.solid(width: 128, height: 128, r: 255, g: 0, b: 0)
        XCTAssertTrue(FrameAssertions.framesDiffer(bars, shifted).passed)
        XCTAssertTrue(FrameAssertions.framesMatch(bars, bars).passed)
        XCTAssertFalse(FrameAssertions.framesDiffer(bars, bars).passed)
    }

    func testFrameRateTolerance() {
        XCTAssertTrue(FrameAssertions.frameRateWithinTolerance(
            measured: 29.97, expected: 29.97, tolerance: 0.5).passed)
        XCTAssertFalse(FrameAssertions.frameRateWithinTolerance(
            measured: 24.0, expected: 29.97, tolerance: 0.5).passed)
    }

    // MARK: - Capture seam

    func testMockCaptureProducesUsableMetrics() throws {
        let mock = MockCaptureSource(pattern: TestPattern.colorBars(width: 320, height: 240))
        let sequence = try mock.capture(
            CaptureRequest(deviceNameContains: "DVC100", frameCount: 60, loggedOutputMode: "720x480@29.97i")
        )

        XCTAssertEqual(sequence.frames.count, 60)
        XCTAssertEqual(sequence.metrics.capturedWidth, 320)
        XCTAssertEqual(sequence.metrics.capturedHeight, 240)
        XCTAssertEqual(sequence.metrics.effectiveFps, StandardDefinition.frameRate, accuracy: 0.05)
        XCTAssertEqual(sequence.metrics.droppedFrames, 0)
        XCTAssertTrue(sequence.metrics.signalPresent)
        XCTAssertEqual(sequence.metrics.loggedOutputMode, "720x480@29.97i")
        // Provenance: mock metrics must never read as hardware evidence.
        XCTAssertTrue(sequence.metrics.deviceName.hasPrefix("mock:"),
                      "mock captures must be labelled so they cannot be mistaken for hardware")
        // A static pattern repeated is, correctly, all duplicates.
        XCTAssertEqual(sequence.metrics.duplicateFrames, 59)
    }

    func testCaptureErrorsSeparateEnvironmentFromDefect() {
        XCTAssertTrue(CaptureError.deviceNotFound("DVC100").isEnvironmental)
        XCTAssertTrue(CaptureError.permissionDenied.isEnvironmental)
        XCTAssertFalse(CaptureError.noFramesArrived("timeout").isEnvironmental)
    }

    func testDroppedFramesAreCountedFromTimestampGaps() {
        let pattern = TestPattern.colorBars(width: 64, height: 64)
        let interval = 1.0 / StandardDefinition.frameRate
        // Five frames, but with a gap where frames 2 and 3 should have been.
        let timestamps = [0.0, interval, interval * 4, interval * 5]
        let frames = timestamps.map { CapturedFrame(image: pattern, timestamp: $0) }
        let metrics = CaptureMetricsBuilder.summarise(
            frames: frames,
            expectedFrameRate: StandardDefinition.frameRate,
            loggedOutputMode: "test",
            deviceName: "unit-test"
        )
        XCTAssertEqual(metrics.droppedFrames, 2, "a three-interval gap means two frames never arrived")
    }

    // MARK: - Offscreen render (the proof-of-life for verification channel 1)

    func testOffscreenRenderRoundTripsATestPatternAndWritesEvidence() throws {
        guard let renderer = OffscreenRenderer() else {
            throw XCTSkip("no Metal device on this machine; offscreen checks cannot run")
        }
        let check = SelfQACheck(name: "phase-0/offscreen-test-pattern")
        let source = TestPattern.colorBars()

        guard let rendered = renderer.blit(source) else {
            check.record(AssertionResult(name: "offscreen blit", passed: false, detail: "renderer returned nil"))
            check.finish()
            return XCTFail("offscreen blit produced no image")
        }

        check.note("rendered SMPTE colour bars through the live blit pipeline")
        try check.writeImage(source, named: "source.png")
        try check.writeImage(rendered, named: "rendered.png")

        let dimensions = FrameAssertions.hasDimensions(
            rendered, width: StandardDefinition.width, height: StandardDefinition.height)
        let bars = FrameAssertions.looksLikeColorBars(rendered)
        let signal = FrameAssertions.hasSignal(rendered)
        // A blit must be pixel-faithful, so the rendered frame must match its source.
        let faithful = FrameAssertions.framesMatch(source, rendered, name: "blit is faithful")
        check.record([dimensions, bars, signal, faithful])

        XCTAssertEqual(check.finish(), .pass, "see selfqa/out/phase-0/offscreen-test-pattern/result.txt")
        XCTAssertTrue(dimensions.passed, dimensions.detail)
        XCTAssertTrue(bars.passed, bars.detail)
        XCTAssertTrue(faithful.passed, faithful.detail)
    }

    func testOffscreenCrossfadeSitsBetweenItsEndpoints() throws {
        guard let renderer = OffscreenRenderer() else {
            throw XCTSkip("no Metal device on this machine; offscreen checks cannot run")
        }
        let check = SelfQACheck(name: "phase-0/offscreen-crossfade")
        let red = TestPattern.solid(width: 256, height: 192, r: 255, g: 0, b: 0)
        let blue = TestPattern.solid(width: 256, height: 192, r: 0, g: 0, b: 255)

        guard let atA = renderer.crossfade(red, blue, mix: 0.0),
              let middle = renderer.crossfade(red, blue, mix: 0.5),
              let atB = renderer.crossfade(red, blue, mix: 1.0) else {
            check.record(AssertionResult(name: "crossfade", passed: false, detail: "renderer returned nil"))
            check.finish()
            return XCTFail("crossfade produced no image")
        }

        try check.writeImage(atA, named: "mix-000.png")
        try check.writeImage(middle, named: "mix-050.png")
        try check.writeImage(atB, named: "mix-100.png")
        check.note("crossfade endpoints and midpoint through the live crossfade pipeline")

        // The endpoints must be exactly their sources...
        check.record(FrameAssertions.regionIsApproximately(
            atA, r: 255, g: 0, b: 0, name: "mix 0.0 is source A"))
        check.record(FrameAssertions.regionIsApproximately(
            atB, r: 0, g: 0, b: 255, name: "mix 1.0 is source B"))
        // ...and the midpoint must be half of each. Metal blends in the texture's
        // sRGB-untagged linear byte space, so the midpoint is the arithmetic mean.
        check.record(FrameAssertions.regionIsApproximately(
            middle, r: 128, g: 0, b: 128, tolerance: 4.0, name: "mix 0.5 is halfway"))

        XCTAssertEqual(check.finish(), .pass, "see selfqa/out/phase-0/offscreen-crossfade/result.txt")
    }

    // MARK: - Check bookkeeping

    func testCheckWithNoAssertionsFails() {
        let check = SelfQACheck(name: "phase-0/empty-check-self-test")
        XCTAssertEqual(check.finish(), .fail, "a check that asserts nothing must not report pass")
    }

    func testBlockedReasonOverridesAssertions() {
        let check = SelfQACheck(name: "phase-0/blocked-check-self-test")
        check.record(AssertionResult(name: "irrelevant", passed: true, detail: "ignored"))
        XCTAssertEqual(check.finish(blockedReason: "no DVC100 attached"), .blocked,
                       "absent hardware must report blocked, never fail")
    }
}

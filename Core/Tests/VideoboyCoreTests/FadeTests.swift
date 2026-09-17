//
//  FadeTests.swift — auto-fade and cut-on-beat (SPEC 12, SPEC 21).
//
//  Purpose : SPEC 21 requires that a cut-on-beat visibly lands ON the beat. That is a
//            latency-compensation problem, and latency compensation is the thing in
//            this app most likely to be silently wrong — so it is pinned down here
//            against a transport driven by a fake clock.
//  Inputs   : plain numbers; no graph, no GPU.
//  Outputs  : assertions.
//  Connects : FadeAutomation, PendingCut, Transport.
//

import XCTest
@testable import VideoboyCore

final class FadeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    // MARK: - Fades

    func testFadeStartsAndEndsWhereItShould() {
        let fade = FadeAutomation(from: 0.2, to: 0.9, duration: 2.0, curve: .linear, startedAt: 100)
        XCTAssertEqual(fade.position(atHostTime: 100), 0.2, accuracy: 1e-9)
        XCTAssertEqual(fade.position(atHostTime: 102), 0.9, accuracy: 1e-9)
        // Before it starts and after it ends it holds, rather than extrapolating past
        // its endpoints — a fader that overshoots is a fader you cannot trust.
        XCTAssertEqual(fade.position(atHostTime: 99), 0.2, accuracy: 1e-9)
        XCTAssertEqual(fade.position(atHostTime: 500), 0.9, accuracy: 1e-9)
    }

    func testLinearFadeIsLinear() {
        let fade = FadeAutomation(from: 0, to: 1, duration: 4.0, curve: .linear, startedAt: 0)
        XCTAssertEqual(fade.position(atHostTime: 1), 0.25, accuracy: 1e-9)
        XCTAssertEqual(fade.position(atHostTime: 2), 0.5, accuracy: 1e-9)
        XCTAssertEqual(fade.position(atHostTime: 3), 0.75, accuracy: 1e-9)
    }

    func testSmoothFadeEasesAtBothEndsButPassesThroughTheMiddle() {
        let fade = FadeAutomation(from: 0, to: 1, duration: 4.0, curve: .smooth, startedAt: 0)
        // Smoothstep is symmetric: halfway in time is halfway in position.
        XCTAssertEqual(fade.position(atHostTime: 2), 0.5, accuracy: 1e-9)
        // ...but it has moved less than linear early on, which is the easing.
        XCTAssertLessThan(fade.position(atHostTime: 1), 0.25)
        XCTAssertGreaterThan(fade.position(atHostTime: 3), 0.75)
    }

    func testEveryCurveRunsZeroToOneAndStaysInRange() {
        for curve in FadeCurve.allCases {
            XCTAssertEqual(curve.apply(0), 0, accuracy: 1e-9, "\(curve.rawValue) must start at 0")
            XCTAssertEqual(curve.apply(1), 1, accuracy: 1e-9, "\(curve.rawValue) must end at 1")
            for step in 0...20 {
                let value = curve.apply(Double(step) / 20.0)
                XCTAssertGreaterThanOrEqual(value, -1e-9, "\(curve.rawValue) went below 0")
                XCTAssertLessThanOrEqual(value, 1 + 1e-9, "\(curve.rawValue) went above 1")
            }
            XCTAssertFalse(curve.displayName.isEmpty)
        }
    }

    func testAccelerateAndDecelerateAreOppositeShapes() {
        // At the quarter point, accelerate has moved less than decelerate.
        XCTAssertLessThan(FadeCurve.accelerate.apply(0.25), FadeCurve.decelerate.apply(0.25))
    }

    func testFadeFinishes() {
        let fade = FadeAutomation(from: 0, to: 1, duration: 1.0, startedAt: 10)
        XCTAssertFalse(fade.isFinished(atHostTime: 10.5))
        XCTAssertTrue(fade.isFinished(atHostTime: 11.0))
    }

    func testZeroDurationDoesNotDivideByZero() {
        let fade = FadeAutomation(from: 0, to: 1, duration: 0, startedAt: 0)
        XCTAssertEqual(fade.position(atHostTime: 1), 1.0, accuracy: 1e-9)
    }

    func testFadeRatePresets() {
        XCTAssertGreaterThan(FadeRate.slow.seconds, FadeRate.medium.seconds)
        XCTAssertGreaterThan(FadeRate.medium.seconds, FadeRate.fast.seconds)
        XCTAssertEqual(FadeRate.from(index: 0), .slow)
        XCTAssertEqual(FadeRate.from(index: 2), .fast)
        // Out of range clamps rather than trapping.
        XCTAssertEqual(FadeRate.from(index: 99), .fast)
        XCTAssertEqual(FadeRate.from(index: -4), .slow)
    }

    // MARK: - Cut on beat (SPEC 21)

    /// The requirement in full: a cut asked for mid-beat must be TAKEN early by
    /// exactly the graph's latency, so the picture changes on the beat itself.
    func testCutIsScheduledEarlyByExactlyTheGraphLatency() {
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 0)

        let latencyFrames = 3
        let frameRate = StandardDefinition.frameRate
        let expectedLatency = Double(latencyFrames) / frameRate

        // Asked for part-way through beat 0; the next quarter-note boundary is beat 1,
        // which at 120 BPM is host time 0.5.
        let cut = PendingCut.scheduled(
            target: 1.0, transport: transport, subdivision: .quarter,
            hostTime: 0.3, latencyInFrames: latencyFrames, frameRate: frameRate
        )

        XCTAssertEqual(cut.targetBeat, 1.0, accuracy: 1e-9)
        XCTAssertEqual(cut.target, 1.0, accuracy: 1e-9)
        XCTAssertEqual(
            cut.fireHostTime, 0.5 - expectedLatency, accuracy: 1e-9,
            "the cut must be taken early by exactly the graph's latency"
        )
    }

    func testCutBecomesDueAtItsFireTimeNotAtTheBeat() {
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 0)
        let cut = PendingCut.scheduled(
            target: 0.0, transport: transport, subdivision: .quarter,
            hostTime: 0.1, latencyInFrames: 6
        )
        // Not yet at the fire time.
        XCTAssertFalse(cut.isDue(atHostTime: cut.fireHostTime - 0.01))
        // Due at it — which is BEFORE the beat, which is the whole point.
        XCTAssertTrue(cut.isDue(atHostTime: cut.fireHostTime))
        XCTAssertLessThan(cut.fireHostTime, transport.hostTime(forBeat: cut.targetBeat))
    }

    func testCutWithNoLatencyLandsOnTheBeatItself() {
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 0)
        let cut = PendingCut.scheduled(
            target: 1.0, transport: transport, subdivision: .quarter,
            hostTime: 0.2, latencyInFrames: 0
        )
        XCTAssertEqual(
            cut.fireHostTime, transport.hostTime(forBeat: cut.targetBeat), accuracy: 1e-9)
    }

    func testCutTargetsTheNextBoundaryOfTheChosenSubdivision() {
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 0)

        // A bar-length subdivision waits for beat 4, not beat 1.
        let onTheBar = PendingCut.scheduled(
            target: 1.0, transport: transport, subdivision: .whole,
            hostTime: 0.2, latencyInFrames: 0
        )
        XCTAssertEqual(onTheBar.targetBeat, 4.0, accuracy: 1e-9)

        // An eighth waits for the nearest half beat.
        let onTheEighth = PendingCut.scheduled(
            target: 1.0, transport: transport, subdivision: .eighth,
            hostTime: 0.2, latencyInFrames: 0
        )
        XCTAssertEqual(onTheEighth.targetBeat, 0.5, accuracy: 1e-9)
    }
}

// MARK: - What a move is, versus when it happens

extension FadeTests {

    /// A scheduled move carries its rate, so the beat decides WHEN and the rate
    /// decides HOW. One flag answering both is why Fade with beat-sync on produced a
    /// hard cut instead of a fade.
    func testAScheduledMoveRemembersItIsAFade() {
        let transport = Transport()
        transport.beatsPerMinute = 120
        transport.start(atHostTime: 1000)

        let fade = PendingCut.scheduled(
            target: 1.0, transport: transport, subdivision: .quarter,
            hostTime: 1000, latencyInFrames: 0, rate: .slow)
        XCTAssertEqual(fade.rate, .slow, "a scheduled fade must still be a fade when it fires")

        let cut = PendingCut.scheduled(
            target: 1.0, transport: transport, subdivision: .quarter,
            hostTime: 1000, latencyInFrames: 0)
        XCTAssertNil(cut.rate, "a scheduled cut has no rate; it snaps")
    }

    /// The subdivision is honoured, so beat-syncing to 1/16 is a different decision
    /// from beat-syncing to a bar.
    func testAScheduledMoveLandsOnTheChosenSubdivision() {
        let transport = Transport()
        transport.beatsPerMinute = 120
        transport.start(atHostTime: 1000)

        // Part way into a beat, so the next boundary of each subdivision differs.
        let now = 1000.3
        let quarter = PendingCut.scheduled(
            target: 1, transport: transport, subdivision: .quarter,
            hostTime: now, latencyInFrames: 0)
        let sixteenth = PendingCut.scheduled(
            target: 1, transport: transport, subdivision: .sixteenth,
            hostTime: now, latencyInFrames: 0)

        XCTAssertLessThan(
            sixteenth.targetBeat, quarter.targetBeat,
            "a sixteenth boundary comes sooner than the next quarter")
        XCTAssertGreaterThan(sixteenth.targetBeat, transport.beats(atHostTime: now))
    }

    /// A fade started on the beat still takes its full time afterwards.
    func testAFadeStartedOnTheBeatRunsForItsFullDuration() {
        let started = 2000.0
        let fade = FadeAutomation(
            from: 0, to: 1, duration: FadeRate.slow.seconds, startedAt: started)

        XCTAssertEqual(fade.position(atHostTime: started), 0, accuracy: 0.001)
        XCTAssertFalse(fade.isFinished(atHostTime: started + FadeRate.slow.seconds / 2))
        XCTAssertEqual(
            fade.position(atHostTime: started + FadeRate.slow.seconds), 1, accuracy: 0.001,
            "the fade must arrive at the target, not stop short")
        XCTAssertTrue(fade.isFinished(atHostTime: started + FadeRate.slow.seconds + 0.01))
    }
}

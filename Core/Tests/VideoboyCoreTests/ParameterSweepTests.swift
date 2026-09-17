//
//  ParameterSweepTests.swift — a fader that plays itself.
//

import XCTest
@testable import VideoboyCore

final class ParameterSweepTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private let sweep = ParameterSweep(first: 0.2, second: 0.8, beatsPerCycle: 4)

    func testItStartsAtTheLowerMarkAndReachesTheUpperHalfwayThrough() {
        XCTAssertEqual(sweep.value(atBeats: 0), 0.2, accuracy: 0.001)
        XCTAssertEqual(sweep.value(atBeats: 2), 0.8, accuracy: 0.001, "half a cycle is the far mark")
        XCTAssertEqual(sweep.value(atBeats: 4), 0.2, accuracy: 0.001, "a full cycle is there AND back")
    }

    func testItNeverLeavesTheMarks() {
        for step in 0...400 {
            let value = sweep.value(atBeats: Double(step) * 0.05)
            XCTAssertGreaterThanOrEqual(value, 0.2 - 0.001)
            XCTAssertLessThanOrEqual(value, 0.8 + 0.001)
        }
    }

    func testTheOrderTheMarksWereClickedDoesNotMatter() {
        let reversed = ParameterSweep(first: 0.8, second: 0.2, beatsPerCycle: 4)
        for beats in stride(from: 0.0, to: 8.0, by: 0.25) {
            XCTAssertEqual(
                reversed.value(atBeats: beats), sweep.value(atBeats: beats), accuracy: 0.001,
                "clicking out-then-in must behave the same as in-then-out")
        }
    }

    /// The reason it is a cosine and not a triangle: it must ease at the ends rather
    /// than reverse hard, because the marks are exactly where the eye is looking.
    func testItEasesAtTheMarksRatherThanReversingHard() {
        // Near the turn, movement per beat should be SMALLER than in the middle.
        let atTurn = abs(sweep.value(atBeats: 0.1) - sweep.value(atBeats: 0.0))
        let atMiddle = abs(sweep.value(atBeats: 1.1) - sweep.value(atBeats: 1.0))
        XCTAssertLessThan(atTurn, atMiddle, "a sweep should slow into its marks, not flick")
    }

    func testMarksTooCloseTogetherAreRefusedRatherThanTwitching() {
        let degenerate = ParameterSweep(first: 0.5, second: 0.5001, beatsPerCycle: 4)
        XCTAssertFalse(degenerate.isUsable)
        XCTAssertEqual(degenerate.value(atBeats: 1.7), degenerate.midpoint, accuracy: 0.001)
    }

    func testANonFiniteOrZeroRateHoldsTheMidpointRatherThanTrapping() {
        XCTAssertEqual(sweep.value(atBeats: .nan), sweep.midpoint, accuracy: 0.001)
        var stopped = sweep
        stopped.beatsPerCycle = 0
        XCTAssertEqual(stopped.value(atBeats: 3), stopped.midpoint, accuracy: 0.001)
    }

    func testNegativeBeatsWrapRatherThanRunningBackwardsOffTheEnd() {
        XCTAssertEqual(sweep.value(atBeats: -2), 0.8, accuracy: 0.001)
    }

    // MARK: - The rate ladder, shared with the shuttle

    func testTheLadderIsTheSameOneTheShuttleWalks() {
        XCTAssertEqual(SweepRate.ladder.count, PlaybackTiming.presets.count)
        XCTAssertEqual(
            SweepRate.ladder.map(\.displayName), PlaybackTiming.presets.map(\.displayName),
            "one ladder in the app, not two that drift apart")
    }

    func testEveryRungGivesAUsableCycleLengthExceptOff() {
        XCTAssertNil(SweepRate.beatsPerCycle(.continuous), "STEP means not sweeping")
        for rung in SweepRate.ladder {
            guard let beats = SweepRate.beatsPerCycle(rung) else {
                return XCTFail("\(rung.displayName) has no cycle length")
            }
            XCTAssertGreaterThan(beats, 0)
        }
    }

    func testTheRungsAreOrderedSlowestFirst() {
        let lengths = SweepRate.ladder.compactMap { SweepRate.beatsPerCycle($0) }
        XCTAssertEqual(lengths, lengths.sorted(by: >), "clicking should walk toward faster")
    }

    func testAKnownRungMeansWhatItsNameSays() {
        // 1/4 is one beat per cycle; 4/1 is four bars, which is sixteen beats.
        let quarter = SweepRate.ladder.first { $0.displayName == "1/4" }
        XCTAssertEqual(quarter.flatMap { SweepRate.beatsPerCycle($0) }, 1.0)
        let fourBars = SweepRate.ladder.first { $0.displayName == "4/1" }
        XCTAssertEqual(fourBars.flatMap { SweepRate.beatsPerCycle($0) }, 16.0)
    }
}

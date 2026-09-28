//
//  LFOTests.swift — transport-locked oscillation (SPEC 6A).
//
//  Purpose : The LFO is timing logic, and timing logic that is subtly wrong looks
//            like "the motion feels off" rather than like a bug. Each shape is
//            checked at the points where its value is known exactly, and the
//            transport lock is checked by asking for a cycle at a known beat.
//  Inputs   : a Transport driven by a fake clock; no audio, no display.
//  Outputs  : assertions.
//  Connects : LFO, LFOBank, Transport, ParamRegistry.
//

import XCTest
@testable import VideoboyCore

final class LFOTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    // MARK: - Shapes

    func testSineRunsZeroToOneAndBack() {
        let lfo = LFO(shape: .sine)
        // A sine starts at its bottom, peaks halfway, and returns.
        XCTAssertEqual(lfo.rawValue(atPhase: 0.0, cycle: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(lfo.rawValue(atPhase: 0.25, cycle: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(lfo.rawValue(atPhase: 0.5, cycle: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(lfo.rawValue(atPhase: 0.75, cycle: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(lfo.rawValue(atPhase: 1.0, cycle: 0), 0.0, accuracy: 1e-9)
    }

    func testTriangleAndRamps() {
        let triangle = LFO(shape: .triangle)
        XCTAssertEqual(triangle.rawValue(atPhase: 0.0, cycle: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(triangle.rawValue(atPhase: 0.5, cycle: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(triangle.rawValue(atPhase: 1.0, cycle: 0), 0.0, accuracy: 1e-9)

        let up = LFO(shape: .rampUp)
        XCTAssertEqual(up.rawValue(atPhase: 0.3, cycle: 0), 0.3, accuracy: 1e-9)
        let down = LFO(shape: .rampDown)
        XCTAssertEqual(down.rawValue(atPhase: 0.3, cycle: 0), 0.7, accuracy: 1e-9)
    }

    func testSquareIsHardEdged() {
        let square = LFO(shape: .square)
        XCTAssertEqual(square.rawValue(atPhase: 0.0, cycle: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(square.rawValue(atPhase: 0.49, cycle: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(square.rawValue(atPhase: 0.5, cycle: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(square.rawValue(atPhase: 0.99, cycle: 0), 1.0, accuracy: 1e-9)
    }

    func testSampleAndHoldIsConstantWithinACycleAndChangesBetween() {
        let lfo = LFO(shape: .sampleAndHold, seed: 42)
        let early = lfo.rawValue(atPhase: 0.05, cycle: 3)
        let late = lfo.rawValue(atPhase: 0.95, cycle: 3)
        XCTAssertEqual(early, late, accuracy: 1e-12, "sample-and-hold must not move within a cycle")

        let nextCycle = lfo.rawValue(atPhase: 0.05, cycle: 4)
        XCTAssertNotEqual(early, nextCycle, accuracy: 1e-9, "it must change between cycles")
    }

    func testRandomShapesAreReproducibleAndSeedDependent() {
        // The same seed and cycle must always give the same value, whether or not
        // earlier cycles were ever evaluated — the LFO gets sampled at future times
        // for latency compensation and skipped when a frame is late.
        let a = LFO(shape: .sampleAndHold, seed: 7)
        let b = LFO(shape: .sampleAndHold, seed: 7)
        XCTAssertEqual(a.rawValue(atPhase: 0.5, cycle: 900),
                       b.rawValue(atPhase: 0.5, cycle: 900), accuracy: 1e-12)

        let different = LFO(shape: .sampleAndHold, seed: 8)
        XCTAssertNotEqual(a.rawValue(atPhase: 0.5, cycle: 900),
                          different.rawValue(atPhase: 0.5, cycle: 900), accuracy: 1e-9)
    }

    func testNoiseDriftsRatherThanStepping() {
        let lfo = LFO(shape: .noise, seed: 11)
        // Consecutive samples within a cycle must be close: noise drifts.
        var previous = lfo.rawValue(atPhase: 0, cycle: 2)
        for step in 1...20 {
            let current = lfo.rawValue(atPhase: Double(step) / 20.0, cycle: 2)
            XCTAssertLessThan(abs(current - previous), 0.35, "noise must not jump within a cycle")
            previous = current
        }
        // And it must arrive at the next cycle's starting value, so there is no
        // discontinuity at the boundary.
        XCTAssertEqual(
            lfo.rawValue(atPhase: 1.0, cycle: 2),
            lfo.rawValue(atPhase: 0.0, cycle: 3),
            accuracy: 1e-9,
            "noise must be continuous across a cycle boundary"
        )
    }

    func testEveryShapeStaysInRange() {
        for shape in LFOShape.allCases {
            let lfo = LFO(shape: shape, seed: 3)
            for step in 0...40 {
                let value = lfo.rawValue(atPhase: Double(step) / 40.0, cycle: step % 5)
                XCTAssertGreaterThanOrEqual(value, 0, "\(shape.rawValue) went below 0")
                XCTAssertLessThanOrEqual(value, 1, "\(shape.rawValue) went above 1")
            }
        }
    }

    // MARK: - Transport lock

    func testSubdivisionRateLocksToTheBeat() {
        // A 1/4 LFO completes one cycle per beat.
        let lfo = LFO(shape: .rampUp, rate: .subdivision(.quarter))
        XCTAssertEqual(lfo.phase(atBeats: 0.0, seconds: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(lfo.phase(atBeats: 0.5, seconds: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(lfo.phase(atBeats: 1.0, seconds: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(lfo.cycleNumber(atBeats: 2.5, seconds: 0), 2)

        // A 1/1 LFO takes four beats, so one bar of 4/4.
        let whole = LFO(shape: .rampUp, rate: .subdivision(.whole))
        XCTAssertEqual(whole.phase(atBeats: 2.0, seconds: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(whole.phase(atBeats: 4.0, seconds: 0), 0.0, accuracy: 1e-9)
    }

    func testFreeRunningRateIgnoresTheTransport() {
        // 2 Hz: one cycle every half second, regardless of tempo.
        let lfo = LFO(shape: .rampUp, rate: .free(hertz: 2.0))
        XCTAssertEqual(lfo.phase(atBeats: 999, seconds: 0.25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(lfo.phase(atBeats: 0, seconds: 0.5), 0.0, accuracy: 1e-9)
    }

    func testPhaseOffsetPutsTwoLFOsOutOfStep() {
        let leading = LFO(shape: .rampUp, rate: .subdivision(.quarter))
        let trailing = LFO(shape: .rampUp, rate: .subdivision(.quarter), phaseOffset: 0.25)
        XCTAssertEqual(leading.phase(atBeats: 0, seconds: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(trailing.phase(atBeats: 0, seconds: 0), 0.25, accuracy: 1e-9)
    }

    func testNegativePositionsWrapForward() {
        // A nudged transport can produce a negative beat count; the phase must stay
        // in 0..<1 rather than going negative and inverting every shape.
        let lfo = LFO(shape: .rampUp, rate: .subdivision(.quarter))
        let phase = lfo.phase(atBeats: -0.25, seconds: 0)
        XCTAssertGreaterThanOrEqual(phase, 0)
        XCTAssertLessThan(phase, 1)
        XCTAssertEqual(phase, 0.75, accuracy: 1e-9)
    }

    // MARK: - Depth and polarity

    func testDepthScalesAndUnipolarStartsAtZero() {
        let full = LFO(shape: .rampUp, depth: 1.0)
        let half = LFO(shape: .rampUp, depth: 0.5)
        XCTAssertEqual(full.value(atBeats: 0.5, seconds: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(half.value(atBeats: 0.5, seconds: 0), 0.25, accuracy: 1e-9)
        // At zero depth a unipolar LFO sits still at zero.
        let none = LFO(shape: .sine, depth: 0)
        XCTAssertEqual(none.value(atBeats: 0.3, seconds: 0), 0.0, accuracy: 1e-9)
    }

    func testBipolarSwingsAroundTheCentre() {
        let lfo = LFO(shape: .rampUp, depth: 1.0, bipolar: true)
        // Ramp at phase 0 is 0, which bipolar maps to the bottom of the swing.
        XCTAssertEqual(lfo.value(atBeats: 0.0, seconds: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(lfo.value(atBeats: 0.5, seconds: 0), 0.5, accuracy: 1e-9)
        // At zero depth a bipolar LFO sits at the centre, not at zero.
        let still = LFO(shape: .sine, depth: 0, bipolar: true)
        XCTAssertEqual(still.value(atBeats: 0.3, seconds: 0), 0.5, accuracy: 1e-9)
    }

    func testInvertFlipsTheOutput() {
        let plain = LFO(shape: .rampUp)
        let inverted = LFO(shape: .rampUp, invert: true)
        XCTAssertEqual(plain.value(atBeats: 0.25, seconds: 0), 0.25, accuracy: 1e-9)
        XCTAssertEqual(inverted.value(atBeats: 0.25, seconds: 0), 0.75, accuracy: 1e-9)
    }

    // MARK: - The bank

    func testBankWritesIntoTheRegistryScaledToTheParameterRange() {
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 0)
        let registry = ParamRegistry()
        // A parameter whose range is NOT 0...1, to prove the LFO is scaled into it.
        registry.register(slot: "fx", parameters: [
            Parameter(code: .feedbackZoom, range: 0.5...1.5, defaultValue: 1.0)
        ])

        let bank = LFOBank(transport: transport)
        bank.assign(LFOBank.Assignment(
            lfo: LFO(shape: .rampUp, rate: .subdivision(.quarter)),
            slot: "fx", code: .feedbackZoom
        ))

        // Half a beat in, a 1/4 ramp is at 0.5, which maps to the middle of 0.5...1.5.
        bank.update(atHostTime: 0.25, into: registry)
        XCTAssertEqual(
            try XCTUnwrap(registry.value(slot: "fx", code: .feedbackZoom)), 1.0, accuracy: 1e-6)

        // Three quarters in, the ramp is at 0.75, which maps to 1.25.
        bank.update(atHostTime: 0.375, into: registry)
        XCTAssertEqual(
            try XCTUnwrap(registry.value(slot: "fx", code: .feedbackZoom)), 1.25, accuracy: 1e-6)
    }

    /// Removing an LFO puts the parameter back where it was before the LFO took it —
    /// not wherever its last frame happened to leave it.
    func testRemovingAnLFORestoresThePreviousValue() {
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 0)
        let registry = ParamRegistry()
        registry.register(slot: "fx", parameters: [Parameter(code: .wetDry, range: 0...1, defaultValue: 0)])
        registry.setValue(1, slot: "fx", code: .wetDry)       // the effect was ON

        let bank = LFOBank(transport: transport)
        bank.assign(LFOBank.Assignment(lfo: LFO(shape: .square, rate: .subdivision(.quarter)),
                                       slot: "fx", code: .wetDry))
        bank.update(atHostTime: 0.3, into: registry)          // gating it
        bank.update(atHostTime: 0.9, into: registry)
        bank.remove(slot: "fx", code: .wetDry, restoringIn: registry)
        XCTAssertEqual(registry.value(slot: "fx", code: .wetDry), 1, "back ON, as it was")
        XCTAssertFalse(bank.isDriven(slot: "fx", code: .wetDry))

        // Removing without a registry (the old call) leaves the value alone.
        bank.assign(LFOBank.Assignment(lfo: LFO(shape: .rampUp, rate: .subdivision(.quarter)),
                                       slot: "fx", code: .wetDry))
        bank.update(atHostTime: 0.25, into: registry)
        bank.remove(slot: "fx", code: .wetDry)
        XCTAssertEqual(try XCTUnwrap(registry.value(slot: "fx", code: .wetDry)), 0.5, accuracy: 1e-6)
    }

    func testBankCompensatesForNodeLatency() {
        // An LFO on a node with latency must be evaluated at the time the frame will
        // be SEEN, not the time it is computed, or beat-synced motion lands late.
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 0)
        let registry = ParamRegistry()
        registry.register(slot: "a", parameters: [Parameter(code: .opacity, range: 0...1)])
        registry.register(slot: "b", parameters: [Parameter(code: .opacity, range: 0...1)])

        let bank = LFOBank(transport: transport)
        let lfo = LFO(shape: .rampUp, rate: .subdivision(.quarter))
        bank.assign(LFOBank.Assignment(lfo: lfo, slot: "a", code: .opacity, latencyInFrames: 0))
        bank.assign(LFOBank.Assignment(lfo: lfo, slot: "b", code: .opacity, latencyInFrames: 6))
        bank.update(atHostTime: 0.1, into: registry)

        let immediate = try! XCTUnwrap(registry.value(slot: "a", code: .opacity))
        let delayed = try! XCTUnwrap(registry.value(slot: "b", code: .opacity))
        // The high-latency node must be given a value from further ahead in the cycle.
        XCTAssertGreaterThan(delayed, immediate)

        // And by exactly the right amount: six frames at 29.97 fps, over a half-second
        // beat, is 6/29.97/0.5 of a cycle.
        let expectedLead = (6.0 / StandardDefinition.frameRate) / 0.5
        XCTAssertEqual(delayed - immediate, expectedLead, accuracy: 1e-6)
    }

    func testOneLFOPerParameter() {
        let transport = Transport(beatsPerMinute: 120)
        let bank = LFOBank(transport: transport)
        bank.assign(LFOBank.Assignment(lfo: LFO(shape: .sine), slot: "a", code: .opacity))
        bank.assign(LFOBank.Assignment(lfo: LFO(shape: .square), slot: "a", code: .opacity))
        // Two oscillators fighting over one value is never what anyone means.
        XCTAssertEqual(bank.assignments.count, 1)
        XCTAssertEqual(bank.assignments.first?.lfo.shape, .square)
        XCTAssertTrue(bank.isDriven(slot: "a", code: .opacity))

        bank.remove(slot: "a", code: .opacity)
        XCTAssertFalse(bank.isDriven(slot: "a", code: .opacity))
    }

    func testBankIgnoresParametersThatDoNotExist() {
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 0)
        let registry = ParamRegistry()
        let bank = LFOBank(transport: transport)
        bank.assign(LFOBank.Assignment(lfo: LFO(), slot: "missing", code: .opacity))
        // The assertion is simply that this does not trap.
        bank.update(atHostTime: 1.0, into: registry)
        XCTAssertNil(registry.value(slot: "missing", code: .opacity))
    }

    func testShapeSelectionFromANormalisedParameter() {
        XCTAssertEqual(LFOShape.from(normalised: 0), .sine)
        XCTAssertEqual(LFOShape.from(normalised: 1), LFOShape.allCases.last)
        for shape in LFOShape.allCases {
            XCTAssertFalse(shape.displayName.isEmpty)
        }
    }

    func testRateDisplayNames() {
        XCTAssertEqual(LFORate.subdivision(.quarter).displayName, "1/4")
        XCTAssertEqual(LFORate.free(hertz: 2.5).displayName, "2.50 Hz")
        XCTAssertEqual(LFORate.subdivision(.whole).beatsPerCycle, 4.0)
        XCTAssertNil(LFORate.free(hertz: 1).beatsPerCycle)
    }
}

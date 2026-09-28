//
//  NonFiniteParameterTests.swift — NaN and infinity must not reach Int().
//
//  EVERY TEST IN THIS FILE CRASHES THE RUNNER WITHOUT THE FIX IT GUARDS. They do not
//  fail; they take the process down with
//
//      Fatal error: Double value cannot be converted to Int because it is either
//      infinite or NaN
//
//  because `Int(Double)` is a trap in Swift, not an optional. That is why these were
//  written after the repair rather than before it: a reproducing test is only useful
//  if the suite survives running it.
//
//  The bug: a dozen enums were selected by sweeping a fader, each writing
//
//      let index = Int((min(max(value, 0), 1) * Double(count - 1)).rounded())
//
//  which looks safe and is not, because `min` and `max` do not sanitise NaN — every
//  comparison against NaN is false, so both hand it straight back. `ParamRegistry`
//  clamped the same way, so a NaN could be STORED and then reach all of them.
//
//  How a NaN gets there in the first place: any modulation path that divides. Tap
//  tempo dividing by the interval between two taps that landed in the same
//  millisecond, an audio analyser normalising a silent buffer by its own peak. Both
//  are one division by zero away from taking the app down at the moment a fader is
//  read.
//

import XCTest
@testable import VideoboyCore

final class NonFiniteParameterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private let nonFinite: [Double] = [.nan, .infinity, -.infinity, .signalingNaN]

    // MARK: - The boundary: nothing non-finite is stored

    func testTheRegistryRefusesNonFiniteValues() {
        let registry = ParamRegistry()
        registry.register(slot: "s", parameters: [
            Parameter(code: .opacity, range: 0...1, defaultValue: 0.5)
        ])

        for value in nonFinite {
            XCTAssertFalse(
                registry.setValue(value, slot: "s", code: .opacity),
                "a non-finite value must be refused, not clamped — min/max pass NaN through")
        }
        XCTAssertEqual(
            registry.value(slot: "s", code: .opacity), 0.5,
            "the parameter must still hold what it held before the bad write")
    }

    func testAGoodValueStillWritesAfterARefusedOne() {
        let registry = ParamRegistry()
        registry.register(slot: "s", parameters: [
            Parameter(code: .opacity, range: 0...1, defaultValue: 0.5)
        ])
        _ = registry.setValue(.nan, slot: "s", code: .opacity)
        XCTAssertTrue(registry.setValue(0.25, slot: "s", code: .opacity))
        XCTAssertEqual(registry.value(slot: "s", code: .opacity), 0.25)
    }

    // MARK: - Defence in depth: the sweeps themselves

    func testClampMapsNonFiniteToTheEndsOfTheRange() {
        XCTAssertEqual(NormalisedSweep.clamp(.nan), 0)
        XCTAssertEqual(NormalisedSweep.clamp(.infinity), 1)
        XCTAssertEqual(NormalisedSweep.clamp(-.infinity), 0)
        XCTAssertEqual(NormalisedSweep.clamp(0.5), 0.5)
        XCTAssertEqual(NormalisedSweep.clamp(-3), 0)
        XCTAssertEqual(NormalisedSweep.clamp(7), 1)
    }

    func testSweepIndexSurvivesNonFiniteInput() {
        for value in nonFinite {
            XCTAssertTrue((0..<5).contains(NormalisedSweep.index(value, count: 5)))
        }
    }

    func testSweepIndexSurvivesADegenerateSet() {
        // A caller with nothing to choose from is a bug worth surviving, not one
        // worth crashing on — `count - 1` would be negative.
        XCTAssertEqual(NormalisedSweep.index(0.5, count: 0), 0)
        XCTAssertEqual(NormalisedSweep.index(0.5, count: 1), 0)
        XCTAssertEqual(NormalisedSweep.index(.nan, count: 0), 0)
    }

    /// Every enum that is selected by a fader, given every non-finite value. Before
    /// the fix this single test crashed the runner on its first iteration.
    func testEveryFaderSelectedEnumSurvivesNonFiniteInput() {
        for value in nonFinite {
            _ = BlendMode.from(normalised: value)
            _ = MPEGCorruptionMode.from(normalised: value)
            _ = GeneratorKind.from(normalised: value)
            _ = TitlerAlignment.from(normalised: value)
            _ = TitlerWeight.from(normalised: value)
            _ = TitlerRollMode.from(normalised: value)
            _ = CompositePath.from(normalised: value)
            _ = ChromaSubsampling.from(normalised: value)
            _ = BlackFrameInsertion.from(normalised: value)
            _ = LFOShape.from(normalised: value)
        }
    }

    /// The low end is what a NaN falls back to, so the result is the first item of
    /// each set — the identity blend, the unmodified picture. Pinned so the fallback
    /// stays the least surprising one rather than drifting to whatever is at index 0
    /// after someone reorders a set.
    func testNaNFallsBackToTheNeutralEndOfASweep() {
        XCTAssertEqual(BlendMode.from(normalised: .nan), .normal)
        XCTAssertEqual(BlendMode.from(normalised: -.infinity), .normal)
        XCTAssertEqual(BlendMode.from(normalised: .infinity), .key)
    }
}

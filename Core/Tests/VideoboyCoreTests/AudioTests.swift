//
//  AudioTests.swift — analysis, reactivity and tempo (SPEC 4c, SPEC 13).
//
//  Purpose : Audio analysis is the easiest place in the app to fool yourself: a
//            band meter that moves at all looks like it works. These drive it with
//            synthetic signals whose correct answer is known — a 100 Hz tone must
//            light the bass band and not the treble one, a 120 BPM pulse train must
//            estimate 120 — so "it moves" is not mistaken for "it is right".
//  Inputs   : generated sample buffers; no audio device.
//  Outputs  : assertions.
//  Connects : AudioAnalyzer, AudioReactivityBus, TempoEstimator. BeatTracker has
//             its own file, BeatTrackerTests.
//

import XCTest
@testable import VideoboyCore

final class AudioTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private let sampleRate = 48_000.0

    /// A sine at a given frequency and amplitude.
    private func sine(frequency: Double, amplitude: Double = 0.5, count: Int = AudioAnalyzer.windowSize,
                      phaseOffset: Double = 0) -> [Float] {
        (0..<count).map { index in
            let t = Double(index) / sampleRate
            return Float(amplitude * sin(2.0 * Double.pi * frequency * t + phaseOffset))
        }
    }

    // MARK: - Levels

    func testRMSOfAKnownSineIsCorrect() {
        let analyzer = AudioAnalyzer(sampleRate: sampleRate)
        // The RMS of a sine is its amplitude over root two.
        let frame = analyzer.analyze(samples: sine(frequency: 1000, amplitude: 0.5))
        XCTAssertEqual(frame.rms, 0.5 / 2.0.squareRoot(), accuracy: 0.01)
        XCTAssertEqual(frame.peak, 0.5, accuracy: 0.02)
    }

    func testSilenceReadsAsSilence() {
        let analyzer = AudioAnalyzer(sampleRate: sampleRate)
        let frame = analyzer.analyze(samples: [Float](repeating: 0, count: AudioAnalyzer.windowSize))
        XCTAssertEqual(frame.rms, 0, accuracy: 1e-6)
        XCTAssertEqual(frame.peak, 0, accuracy: 1e-6)
        XCTAssertFalse(frame.onset)
        XCTAssertTrue(frame.bands.allSatisfy { $0 < 1e-3 })
    }

    // MARK: - Bands

    func testATonePutsEnergyInTheRightBand() {
        let analyzer = AudioAnalyzer(sampleRate: sampleRate)
        // 100 Hz sits in band 1 (60-150 Hz).
        let bass = analyzer.analyze(samples: sine(frequency: 100, amplitude: 0.8))
        let bassBand = 1
        let trebleBand = 5
        XCTAssertGreaterThan(
            bass.bands[bassBand], bass.bands[trebleBand] + 0.01,
            "a 100 Hz tone must light the bass band, not the presence band")

        analyzer.reset()
        // 4 kHz sits in band 5 (2500-6000 Hz).
        let treble = analyzer.analyze(samples: sine(frequency: 4000, amplitude: 0.8))
        XCTAssertGreaterThan(
            treble.bands[trebleBand], treble.bands[bassBand] + 0.01,
            "a 4 kHz tone must light the presence band, not the bass band")
    }

    func testBandCountMatchesTheEdges() {
        let analyzer = AudioAnalyzer(sampleRate: sampleRate)
        let frame = analyzer.analyze(samples: sine(frequency: 440))
        XCTAssertEqual(frame.bands.count, AudioAnalyzer.bandCount)
        XCTAssertEqual(AudioAnalyzer.bandCount, AudioAnalyzer.bandEdges.count - 1)
    }

    // MARK: - Onsets

    func testOnsetFiresOnASuddenStartAndNotOnSteadyTone() {
        let analyzer = AudioAnalyzer(sampleRate: sampleRate)
        let silence = [Float](repeating: 0, count: AudioAnalyzer.windowSize)

        // Feed enough silence to establish a baseline...
        for _ in 0..<12 { _ = analyzer.analyze(samples: silence) }
        // ...then a sudden loud tone.
        var sawOnset = false
        for _ in 0..<3 {
            if analyzer.analyze(samples: sine(frequency: 220, amplitude: 0.9)).onset { sawOnset = true }
        }
        XCTAssertTrue(sawOnset, "a sound starting out of silence must register as an onset")

        // A tone that simply continues must not keep firing.
        var continuingOnsets = 0
        for _ in 0..<20 {
            if analyzer.analyze(samples: sine(frequency: 220, amplitude: 0.9)).onset {
                continuingOnsets += 1
            }
        }
        XCTAssertLessThanOrEqual(
            continuingOnsets, 2,
            "a steady tone must not fire onsets continuously (\(continuingOnsets) fired)")
    }

    func testOnsetsAreNotReportedTwiceForOneHit() {
        // The minimum gap exists so a single drum hit is one onset, not a flam.
        let analyzer = AudioAnalyzer(sampleRate: sampleRate)
        let silence = [Float](repeating: 0, count: AudioAnalyzer.windowSize)
        for _ in 0..<12 { _ = analyzer.analyze(samples: silence) }

        var onsets = 0
        // Two windows of the same hit.
        for _ in 0..<2 {
            if analyzer.analyze(samples: sine(frequency: 80, amplitude: 1.0)).onset { onsets += 1 }
        }
        XCTAssertLessThanOrEqual(onsets, 1, "one hit must produce at most one onset")
    }

    // MARK: - Tempo

    func testTempoEstimatorFindsAKnownPulse() {
        let estimator = TempoEstimator(sampleRate: sampleRate)
        let windowsPerSecond = sampleRate / Double(AudioAnalyzer.windowSize)

        // A synthetic onset envelope: a spike every beat at exactly 120 BPM.
        let targetBPM = 120.0
        let windowsPerBeat = windowsPerSecond * 60.0 / targetBPM
        for window in 0..<Int(windowsPerSecond * TempoEstimator.historySeconds) {
            let positionInBeat = Double(window).truncatingRemainder(dividingBy: windowsPerBeat)
            estimator.add(flux: positionInBeat < 1.0 ? 1.0 : 0.02)
        }

        let estimate = try! XCTUnwrap(estimator.estimate())
        // The envelope is quantised to ~21 ms windows, which alone would only allow
        // 117.2 or 122.3 here. The comb's interpolated harmonics must see through
        // that: this used to be allowed ±4 BPM and flipped between the two.
        XCTAssertEqual(estimate.beatsPerMinute, targetBPM, accuracy: 0.5)
        XCTAssertGreaterThan(estimate.confidence, 0.1, "a clean pulse train must be confident")
    }

    func testTempoEstimatorRefusesToGuessOnFlatInput() {
        let estimator = TempoEstimator(sampleRate: sampleRate)
        // A drone: no pulse at all. Returning a plausible-looking BPM here would be
        // worse than returning nothing.
        for _ in 0..<200 { estimator.add(flux: 0.5) }
        XCTAssertNil(estimator.estimate(), "a flat envelope must not produce a tempo")
    }

    func testTempoEstimatorNeedsHistory() {
        let estimator = TempoEstimator(sampleRate: sampleRate)
        estimator.add(flux: 1.0)
        XCTAssertNil(estimator.estimate(), "one sample is not a tempo")
    }

    // MARK: - The reactivity bus

    private func makeBus() -> (AudioReactivityBus, ParamRegistry) {
        let bus = AudioReactivityBus()
        bus.isRunning = true
        let registry = ParamRegistry()
        registry.register(slot: "fx", parameters: [
            Parameter(code: .opacity, range: 0...1, defaultValue: 0),
            Parameter(code: .feedbackZoom, range: 0.5...1.5, defaultValue: 1.0)
        ])
        return (bus, registry)
    }

    func testDirectTapDrivesAParameter() {
        let (bus, registry) = makeBus()
        bus.assign(ReactivityAssignment(
            tap: .rms, shape: .direct, slot: "fx", code: .opacity, gain: 2.0, threshold: 0))
        bus.update(with: AudioFrame(rms: 0.25, peak: 0.3, bands: [], flux: 0, onset: false),
                   into: registry)
        // 0.25 with a gain of 2 is 0.5.
        XCTAssertEqual(try! XCTUnwrap(registry.value(slot: "fx", code: .opacity)), 0.5, accuracy: 1e-6)
    }

    /// Removing an audio binding puts the parameter back to its value from before.
    func testRemovingAnAudioBindingRestoresThePreviousValue() {
        let (bus, registry) = makeBus()
        registry.setValue(0.8, slot: "fx", code: .opacity)
        bus.assign(ReactivityAssignment(
            tap: .rms, shape: .direct, slot: "fx", code: .opacity, gain: 1.0, threshold: 0))
        bus.update(with: AudioFrame(rms: 0.1, peak: 0.1, bands: [], flux: 0, onset: false), into: registry)
        XCTAssertEqual(try XCTUnwrap(registry.value(slot: "fx", code: .opacity)), 0.1, accuracy: 1e-6)
        bus.remove(slot: "fx", code: .opacity, restoringIn: registry)
        XCTAssertEqual(try XCTUnwrap(registry.value(slot: "fx", code: .opacity)), 0.8, accuracy: 1e-6)
    }

    func testValuesAreScaledIntoTheParameterRange() {
        let (bus, registry) = makeBus()
        bus.assign(ReactivityAssignment(
            tap: .rms, shape: .direct, slot: "fx", code: .feedbackZoom, gain: 1.0, threshold: 0))
        bus.update(with: AudioFrame(rms: 1.0, peak: 1.0, bands: [], flux: 0, onset: false),
                   into: registry)
        // Full scale must reach the top of 0.5...1.5, not 1.0.
        XCTAssertEqual(
            try! XCTUnwrap(registry.value(slot: "fx", code: .feedbackZoom)), 1.5, accuracy: 1e-6)
    }

    func testThresholdGatesOutRoomNoise() {
        let (bus, registry) = makeBus()
        bus.assign(ReactivityAssignment(
            tap: .rms, shape: .direct, slot: "fx", code: .opacity, gain: 1.0, threshold: 0.2))
        bus.update(with: AudioFrame(rms: 0.1, peak: 0.1, bands: [], flux: 0, onset: false),
                   into: registry)
        XCTAssertEqual(try! XCTUnwrap(registry.value(slot: "fx", code: .opacity)), 0, accuracy: 1e-6)
    }

    func testPulseSnapsUpOnOnsetAndDecays() {
        let (bus, registry) = makeBus()
        bus.assign(ReactivityAssignment(
            tap: .onset, shape: .pulse, slot: "fx", code: .opacity,
            gain: 1.0, threshold: 0, decay: 0.25))

        let hit = AudioFrame(rms: 0.5, peak: 0.5, bands: [], flux: 1, onset: true)
        let quiet = AudioFrame(rms: 0.5, peak: 0.5, bands: [], flux: 0, onset: false)

        bus.update(with: hit, into: registry)
        XCTAssertEqual(try! XCTUnwrap(registry.value(slot: "fx", code: .opacity)), 1.0, accuracy: 1e-6)

        bus.update(with: quiet, into: registry)
        XCTAssertEqual(try! XCTUnwrap(registry.value(slot: "fx", code: .opacity)), 0.75, accuracy: 1e-6)
        bus.update(with: quiet, into: registry)
        XCTAssertEqual(try! XCTUnwrap(registry.value(slot: "fx", code: .opacity)), 0.5, accuracy: 1e-6)
    }

    func testEnvelopeRisesInstantlyAndFallsSlowly() {
        let (bus, registry) = makeBus()
        bus.assign(ReactivityAssignment(
            tap: .rms, shape: .envelope, slot: "fx", code: .opacity,
            gain: 1.0, threshold: 0, decay: 0.1))

        bus.update(with: AudioFrame(rms: 0.9, peak: 0.9, bands: [], flux: 0, onset: false), into: registry)
        XCTAssertEqual(try! XCTUnwrap(registry.value(slot: "fx", code: .opacity)), 0.9, accuracy: 1e-6)
        // The signal drops to nothing, but the envelope must ease down.
        bus.update(with: AudioFrame(rms: 0.0, peak: 0.0, bands: [], flux: 0, onset: false), into: registry)
        XCTAssertEqual(try! XCTUnwrap(registry.value(slot: "fx", code: .opacity)), 0.8, accuracy: 1e-6)
    }

    func testSampleHoldKeepsItsValueBetweenOnsets() {
        let (bus, registry) = makeBus()
        bus.assign(ReactivityAssignment(
            tap: .rms, shape: .sampleHold, slot: "fx", code: .opacity, gain: 1.0, threshold: 0))

        bus.update(with: AudioFrame(rms: 0.6, peak: 0.6, bands: [], flux: 1, onset: true), into: registry)
        let held = try! XCTUnwrap(registry.value(slot: "fx", code: .opacity))
        XCTAssertEqual(held, 0.6, accuracy: 1e-6)

        // The level changes, but with no onset the held value must not move.
        bus.update(with: AudioFrame(rms: 0.1, peak: 0.1, bands: [], flux: 0, onset: false), into: registry)
        XCTAssertEqual(try! XCTUnwrap(registry.value(slot: "fx", code: .opacity)), held, accuracy: 1e-6)
    }

    func testInvertAndGate() {
        let (bus, registry) = makeBus()
        bus.assign(ReactivityAssignment(
            tap: .rms, shape: .invert, slot: "fx", code: .opacity, gain: 1.0, threshold: 0))
        bus.update(with: AudioFrame(rms: 0.25, peak: 0.25, bands: [], flux: 0, onset: false), into: registry)
        XCTAssertEqual(try! XCTUnwrap(registry.value(slot: "fx", code: .opacity)), 0.75, accuracy: 1e-6)

        bus.assign(ReactivityAssignment(
            tap: .rms, shape: .gate, slot: "fx", code: .opacity, gain: 1.0, threshold: 0.3))
        bus.update(with: AudioFrame(rms: 0.5, peak: 0.5, bands: [], flux: 0, onset: false), into: registry)
        XCTAssertEqual(try! XCTUnwrap(registry.value(slot: "fx", code: .opacity)), 1.0, accuracy: 1e-6)
    }

    func testNothingMovesWhenAudioIsNotRunning() {
        // A mapping left in place with no input connected must be harmless, not a
        // parameter pinned at zero fighting the UI.
        let (bus, registry) = makeBus()
        bus.isRunning = false
        registry.setValue(0.42, slot: "fx", code: .opacity)
        bus.assign(ReactivityAssignment(tap: .rms, slot: "fx", code: .opacity))
        bus.update(with: AudioFrame(rms: 1.0, peak: 1.0, bands: [], flux: 0, onset: false), into: registry)
        XCTAssertEqual(try! XCTUnwrap(registry.value(slot: "fx", code: .opacity)), 0.42, accuracy: 1e-6)
    }

    func testOneAudioBindingPerParameter() {
        let (bus, _) = makeBus()
        bus.assign(ReactivityAssignment(tap: .rms, slot: "fx", code: .opacity))
        bus.assign(ReactivityAssignment(tap: .onset, slot: "fx", code: .opacity))
        XCTAssertEqual(bus.assignments.count, 1)
        XCTAssertEqual(bus.assignments.first?.tap, .onset)
        XCTAssertTrue(bus.isDriven(slot: "fx", code: .opacity))
        bus.remove(slot: "fx", code: .opacity)
        XCTAssertFalse(bus.isDriven(slot: "fx", code: .opacity))
    }

    func testBandTapIsBoundsChecked() {
        let (bus, _) = makeBus()
        bus.isRunning = true
        bus.update(with: AudioFrame(rms: 0, peak: 0, bands: [0.1, 0.2], flux: 0, onset: false),
                   into: ParamRegistry())
        XCTAssertEqual(bus.rawValue(of: .band(index: 1)), 0.2, accuracy: 1e-9)
        // An out-of-range band must read zero rather than trapping.
        XCTAssertEqual(bus.rawValue(of: .band(index: 99)), 0, accuracy: 1e-9)
        XCTAssertEqual(bus.rawValue(of: .band(index: -1)), 0, accuracy: 1e-9)
    }

    func testTapAndShapeNames() {
        XCTAssertEqual(ReactivityTap.band(index: 2).displayName, "Band 3")
        XCTAssertEqual(ReactivityTap.rms.displayName, "RMS")
        for shape in ReactivityShape.allCases {
            XCTAssertFalse(shape.displayName.isEmpty)
        }
    }
}

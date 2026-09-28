//
//  BeatNetTests.swift — the Swift BeatNet port against the original.
//
//  Purpose : A port of a trained network is either exact or silently wrong: a
//            feature off by a scale factor still produces activations, just
//            meaningless ones. These tests hold the port to numbers written out by
//            the original Python (madmom features, PyTorch network) for the same
//            signal, and check the tracker's clock against a known tempo.
//  Inputs  : App/Resources/BeatNet/beatnet-model1.bin (the shipped weights) and
//            Core/Tests/Fixtures/beatnet-reference.json (Python's output for the
//            signal `referenceSignal()` makes — see docs/BEATNET.md).
//  Outputs : assertions.
//  Connects: BeatNetWeights, BeatNetFeatures, BeatNetModel, BeatNetTracker.
//

import XCTest
@testable import VideoboyCore

final class BeatNetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    /// The repo root, from this file's path.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static var weightsURL: URL {
        repoRoot.appendingPathComponent("App/Resources/BeatNet/beatnet-model1.bin")
    }

    private struct Reference: Decodable {
        let numFrames: Int
        let featureRows: [String: [Float]]
        let activations: [[Float]]
    }

    private func loadReference() throws -> Reference {
        let url = Self.repoRoot.appendingPathComponent("Core/Tests/Fixtures/beatnet-reference.json")
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    /// The signal the reference was made from, computed exactly as the export script
    /// does (float64, then float32): a 55 Hz kick every 0.5 s (120 BPM) and a 6 kHz
    /// tick on each off-beat, 12 seconds at 22,050 Hz.
    static func referenceSignal(seconds: Double = 12) -> [Float] {
        let rate = BeatNetFeatures.sampleRate
        let count = Int(rate * seconds)
        var signal = [Double](repeating: 0, count: count)
        let beats = Int(seconds / 0.5) + 1
        for beat in 0..<beats {
            let kickTime = Double(beat) * 0.5
            let tickTime = kickTime + 0.25
            for index in 0..<count {
                let time = Double(index) / rate
                let sinceKick = time - kickTime
                if sinceKick >= 0 {
                    signal[index] += 0.8 * exp(-sinceKick * 25) * sin(2 * .pi * 55 * sinceKick)
                }
                let sinceTick = time - tickTime
                if sinceTick >= 0 {
                    signal[index] += 0.2 * exp(-sinceTick * 120) * sin(2 * .pi * 6000 * sinceTick)
                }
            }
        }
        return signal.map { Float($0) }
    }

    /// Features in chunks of an awkward size, to prove buffering does not matter.
    private func features(for signal: [Float], weights: BeatNetWeights) -> [[Float]] {
        let extractor = BeatNetFeatures(weights: weights)
        var frames: [[Float]] = []
        var index = 0
        while index < signal.count {
            let end = min(index + 373, signal.count)
            frames += extractor.add(Array(signal[index..<end]))
            index = end
        }
        // Flush the last frames, whose windows run past the end, the way madmom
        // zero-pads them.
        frames += extractor.add([Float](repeating: 0, count: BeatNetFeatures.frameSize))
        return frames
    }

    func testFeaturesMatchMadmom() throws {
        let weights = try BeatNetWeights(contentsOf: Self.weightsURL)
        let reference = try loadReference()
        let frames = features(for: Self.referenceSignal(), weights: weights)
        XCTAssertGreaterThanOrEqual(frames.count, reference.numFrames)
        for (key, expected) in reference.featureRows {
            let row = Int(key)!
            let actual = frames[row]
            let worst = zip(actual, expected).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThan(worst, 1e-3, "feature row \(row) differs from madmom by \(worst)")
        }
    }

    func testActivationsMatchPyTorch() throws {
        let weights = try BeatNetWeights(contentsOf: Self.weightsURL)
        let reference = try loadReference()
        let frames = features(for: Self.referenceSignal(), weights: weights)
        let model = BeatNetModel(weights: weights)
        var worst: Float = 0
        for frame in 0..<reference.numFrames {
            let activation = model.process(frames[frame])
            let expected = reference.activations[frame]
            worst = max(worst, abs(activation.beat - expected[0]), abs(activation.downbeat - expected[1]))
        }
        XCTAssertLessThan(worst, 2e-3, "activations differ from PyTorch by up to \(worst)")
    }

    /// 120 BPM kicks, delivered at 48 kHz in 1,024-sample buffers as a device would.
    /// The clock must lock to 120 within a tenth of a BPM, and its beats must land
    /// on the kicks — the phase is the half of a beat clock you can see.
    func testLocksToKnownTempoAndPhase() throws {
        try locksToKnownTempoAndPhase(mode: .activationTempo)
    }

    func testParticleFilterLocksToKnownTempoAndPhase() throws {
        try locksToKnownTempoAndPhase(mode: .particleFilter)
    }

    private func locksToKnownTempoAndPhase(mode: BeatNetTracker.Mode) throws {
        let weights = try BeatNetWeights(contentsOf: Self.weightsURL)
        let rate = 48_000.0
        let seconds = 20.0
        // The reference signal's formula, at 48 kHz.
        var signal = [Float](repeating: 0, count: Int(rate * seconds))
        for beat in 0..<Int(seconds / 0.5) {
            let start = Int(Double(beat) * 0.5 * rate)
            for offset in 0..<Int(0.3 * rate) where start + offset < signal.count {
                let time = Double(offset) / rate
                signal[start + offset] += Float(0.8 * exp(-time * 25) * sin(2 * .pi * 55 * time))
            }
            let tick = Int((Double(beat) * 0.5 + 0.25) * rate)
            for offset in 0..<Int(0.05 * rate) where tick + offset < signal.count {
                let time = Double(offset) / rate
                signal[tick + offset] += Float(0.2 * exp(-time * 120) * sin(2 * .pi * 6000 * time))
            }
        }
        let tracker = BeatNetTracker(weights: weights, inputRate: rate, mode: mode)
        var firstLock: Double?
        var last: BeatTrackerReport?
        var lastTime = 0.0      // stream time the last report was made at
        var index = 0
        while index < signal.count {
            let end = min(index + 1_024, signal.count)
            for report in tracker.add(Array(signal[index..<end])) {
                if report.state == .locked, firstLock == nil { firstLock = tracker.streamTime }
                last = report
                lastTime = tracker.streamTime
            }
            index = end
        }
        let lockTime = try XCTUnwrap(firstLock, "never locked")
        XCTAssertLessThan(lockTime, 10, "\(mode): took \(lockTime) s to lock")
        let report = try XCTUnwrap(last)
        XCTAssertEqual(report.state, .locked)
        XCTAssertEqual(try XCTUnwrap(report.beatsPerMinute), 120, accuracy: 0.1)

        // Where the tracker puts the latest beat, against where the kicks really are.
        let sinceBeat = try XCTUnwrap(report.secondsSinceBeat)
        let beatTime = lastTime - sinceBeat
        let error = beatTime - (beatTime / 0.5).rounded() * 0.5
        print("[beatnet] \(mode): locked after \(lockTime) s; phase error \(error * 1000) ms; beats \(tracker.beatTimes.suffix(6))")
        XCTAssertLessThan(abs(error), 0.015, "beat grid is \(error * 1000) ms off the kicks")
    }

    func testRefusesWrongFile() {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("not-beatnet.bin")
        try? Data("BNET-nope".utf8).write(to: junk)
        XCTAssertThrowsError(try BeatNetWeights(contentsOf: junk))
    }
}

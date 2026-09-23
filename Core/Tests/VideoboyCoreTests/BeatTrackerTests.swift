//
//  BeatTrackerTests.swift — the audio clock, driven by synthesized drums.
//
//  Purpose : Beat tracking fails in ways that look fine for a second: a readout that
//            is right on average but flips between two values, a lock that jumps to
//            double speed on a busy hi-hat, a clock that loses the beat in a quiet
//            bar. These run whole synthesized drum loops — kick, snare, hats, a pad
//            underneath — through the real analyser and tracker for tens of seconds
//            and check the things a performer would notice.
//  Inputs   : generated audio at 48 kHz; no device.
//  Outputs  : assertions.
//  Connects : AudioAnalyzer, TempoEstimator, BeatTracker, Transport.
//

import XCTest
@testable import VideoboyCore

final class BeatTrackerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private let sampleRate = 48_000.0

    // MARK: - Synthesis

    /// A small deterministic noise source, so every run hears the same drums.
    private struct Noise {
        var state: UInt32 = 0x1234_5678
        mutating func next() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: state)) / Float(Int32.max)
        }
    }

    /// A four-on-the-floor-ish loop: kick on 1 and 3, snare on 2 and 4, closed hats
    /// on every eighth, a quiet sustained chord underneath so the envelope is never
    /// trivially clean.
    ///
    /// - Parameters:
    ///   - sixteenthHats: hats on every sixteenth instead, loud — the classic trap
    ///     for a tracker that settles on double tempo.
    ///   - startBeatOffset: seconds into the loop the first sample sits at.
    private func drumLoop(
        beatsPerMinute: Double, seconds: Double, sixteenthHats: Bool = false
    ) -> [Float] {
        let count = Int(seconds * sampleRate)
        var output = [Float](repeating: 0, count: count)
        var noise = Noise()
        let beat = 60.0 / beatsPerMinute

        func add(at start: Double, length: Double, _ voice: (Double) -> Float) {
            let first = Int(start * sampleRate)
            let last = min(first + Int(length * sampleRate), count)
            guard first < count else { return }
            for index in max(first, 0)..<last {
                output[index] += voice(Double(index - first) / sampleRate)
            }
        }

        var beatIndex = 0
        while Double(beatIndex) * beat < seconds {
            let time = Double(beatIndex) * beat
            if beatIndex % 2 == 0 {
                // Kick: a pitch-dropping sine with a fast decay.
                add(at: time, length: 0.35) { t in
                    let frequency = 50 + 90 * exp(-t / 0.03)
                    return Float(0.9 * sin(2 * .pi * frequency * t) * exp(-t / 0.12))
                }
            } else {
                add(at: time, length: 0.25) { t in noise.next() * Float(0.5 * exp(-t / 0.07)) }
            }
            let hatsPerBeat = sixteenthHats ? 4 : 2
            for hat in 0..<hatsPerBeat {
                let hatTime = time + beat * Double(hat) / Double(hatsPerBeat)
                var previous: Float = 0
                add(at: hatTime, length: 0.05) { t in
                    // Differentiated noise: bright, like a closed hat.
                    let sample = noise.next()
                    defer { previous = sample }
                    return (sample - previous) * Float((sixteenthHats ? 0.35 : 0.15) * exp(-t / 0.015))
                }
            }
            beatIndex += 1
        }

        // The pad: an A minor triad, quiet and constant.
        for index in 0..<count {
            let t = Double(index) / sampleRate
            output[index] += Float(0.04 * (sin(2 * .pi * 220 * t) + sin(2 * .pi * 261.6 * t)
                                           + sin(2 * .pi * 329.6 * t)))
        }
        return output
    }

    /// Runs audio through the analyser and a tracker, returning every report.
    private func track(
        _ samples: [Float], tracker: BeatTracker, analyzer: AudioAnalyzer
    ) -> [BeatTrackerReport] {
        var reports: [BeatTrackerReport] = []
        let size = AudioAnalyzer.windowSize
        var start = 0
        while start + size <= samples.count {
            let frame = analyzer.analyze(samples: Array(samples[start..<(start + size)]))
            if let report = tracker.add(frame) { reports.append(report) }
            start += size
        }
        return reports
    }

    private func track(_ samples: [Float]) -> (BeatTracker, [BeatTrackerReport]) {
        let tracker = BeatTracker(sampleRate: sampleRate)
        let reports = track(samples, tracker: tracker, analyzer: AudioAnalyzer(sampleRate: sampleRate))
        return (tracker, reports)
    }

    // MARK: - Locking

    func testLocksToDrumLoopsAcrossTheUsefulRange() {
        for tempo in [84.0, 97.0, 120.0, 128.0, 140.0, 160.0] {
            let (tracker, reports) = track(drumLoop(beatsPerMinute: tempo, seconds: 14))
            XCTAssertEqual(tracker.state, .locked, "\(tempo) BPM should lock within 14 s")
            let locked = tracker.lockedTempo ?? 0
            XCTAssertEqual(locked, tempo, accuracy: tempo * 0.005,
                           "\(tempo) BPM locked at \(locked)")
            let locks = reports.filter {
                if case .locked = $0.event { return true } else { return false }
            }
            XCTAssertEqual(locks.count, 1, "\(tempo) BPM: exactly one lock announcement")
        }
    }

    func testLocksWithinAFewSeconds() {
        let (_, reports) = track(drumLoop(beatsPerMinute: 124, seconds: 12))
        guard let firstLock = reports.firstIndex(where: { $0.state == .locked }) else {
            return XCTFail("never locked")
        }
        // Reports are four a second.
        let seconds = Double(firstLock + 1) * 0.25
        XCTAssertLessThan(seconds, 8.0, "took \(seconds) s to lock; a performer waits no longer")
    }

    func testBusySixteenthHatsDoNotDoubleTheTempo() {
        let (tracker, _) = track(drumLoop(beatsPerMinute: 110, seconds: 14, sixteenthHats: true))
        XCTAssertEqual(tracker.lockedTempo ?? 0, 110, accuracy: 1.0)
    }

    // MARK: - Steadiness

    /// The complaint that started this: the readout moved all the time.
    func testLockedTempoStaysStill() {
        let (_, reports) = track(drumLoop(beatsPerMinute: 126, seconds: 40))
        let afterLock = reports.drop { $0.state != .locked }.dropFirst(8).compactMap(\.beatsPerMinute)
        XCTAssertGreaterThan(afterLock.count, 100)
        let spread = (afterLock.max() ?? 0) - (afterLock.min() ?? 0)
        XCTAssertLessThan(spread, 0.3, "locked tempo wandered \(spread) BPM on a steady loop")
        let events = reports.compactMap(\.event)
        XCTAssertEqual(events.count, 1, "one lock and then quiet, not \(events)")
    }

    func testRelocksOnceWhenTheTrackChanges() {
        let samples = drumLoop(beatsPerMinute: 120, seconds: 16)
            + drumLoop(beatsPerMinute: 100, seconds: 16)
        let (tracker, reports) = track(samples)
        XCTAssertEqual(tracker.lockedTempo ?? 0, 100, accuracy: 0.5)
        let relocks = reports.compactMap { report -> (Double, Double)? in
            if case .relocked(let from, let to) = report.event { return (from, to) }
            return nil
        }
        XCTAssertEqual(relocks.count, 1, "one move to the new tempo, not a wander")
        if let relock = relocks.first {
            XCTAssertEqual(relock.0, 120, accuracy: 0.5)
            XCTAssertEqual(relock.1, 100, accuracy: 1.0)
        }
    }

    // MARK: - No pulse

    func testSilenceReadsSilentAndKeepsTheTempo() {
        let samples = drumLoop(beatsPerMinute: 120, seconds: 12)
            + [Float](repeating: 0, count: Int(sampleRate * 4))
        let (tracker, reports) = track(samples)
        XCTAssertEqual(tracker.state, .silent)
        XCTAssertEqual(tracker.lockedTempo ?? 0, 120, accuracy: 0.5,
                       "silence is not a reason to forget the tempo")
        XCTAssertTrue(reports.contains { $0.event == .silenced })
    }

    func testNoiseNeverLocks() {
        var noise = Noise()
        let samples = (0..<Int(sampleRate * 15)).map { _ in noise.next() * 0.3 }
        let (tracker, _) = track(samples)
        XCTAssertNotEqual(tracker.state, .locked, "white noise has no tempo")
        XCTAssertNil(tracker.lockedTempo)
    }

    // MARK: - Phase

    func testFindsWhereTheBeatFalls() {
        let tempo = 120.0
        let period = 60.0 / tempo
        // Offset the loop so the beat does not conveniently line up with a window.
        let lead = [Float](repeating: 0, count: 700)
        let (_, reports) = track(lead + drumLoop(beatsPerMinute: tempo, seconds: 14))
        // Reports come every `windowsPerUpdate` windows; the Nth report describes
        // the audio up to the end of window N × windowsPerUpdate.
        let windowsPerUpdate = Int((0.25 * sampleRate / Double(AudioAnalyzer.windowSize)).rounded())
        var checked = 0
        for (index, report) in reports.enumerated() where report.state == .locked {
            guard let reported = report.secondsSinceBeat else {
                return XCTFail("a locked tracker must say where the beat is")
            }
            let endSample = (index + 1) * windowsPerUpdate * AudioAnalyzer.windowSize - lead.count
            let actual = (Double(endSample) / sampleRate).truncatingRemainder(dividingBy: period)
            // Circular difference: 0.49 s and 0.01 s are 20 ms apart at 120 BPM.
            var error = abs(reported - actual).truncatingRemainder(dividingBy: period)
            error = min(error, period - error)
            // Two analysis windows, ~43 ms: a little over a frame of video.
            XCTAssertLessThan(error, 0.043, "report \(index): beat placed \(Int(error * 1000)) ms off")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 10)
    }

    // MARK: - Phase correction

    func testPhaseCorrectionPullsTowardTheNearestBeat() {
        // Clock 0.2 beat ahead: step back by a quarter of that.
        XCTAssertEqual(BeatTracker.phaseCorrection(clockBeatsAtMusicBeat: 8.2, snap: false), -0.05, accuracy: 1e-9)
        // 0.3 behind (reads 7.7 when the music says 8): step forward.
        XCTAssertEqual(BeatTracker.phaseCorrection(clockBeatsAtMusicBeat: 7.7, snap: false), 0.075, accuracy: 1e-9)
        // A big error is capped, so no nudge can skip a scheduled boundary.
        XCTAssertEqual(BeatTracker.phaseCorrection(clockBeatsAtMusicBeat: 8.45, snap: false), -0.08, accuracy: 1e-9)
        // A fresh lock takes the whole correction.
        XCTAssertEqual(BeatTracker.phaseCorrection(clockBeatsAtMusicBeat: 8.45, snap: true), -0.45, accuracy: 1e-9)
        // Aligned, or near enough, is left alone rather than jittered.
        XCTAssertEqual(BeatTracker.phaseCorrection(clockBeatsAtMusicBeat: 8.01, snap: false), 0)
        XCTAssertEqual(BeatTracker.phaseCorrection(clockBeatsAtMusicBeat: .nan, snap: true), 0)
    }

    func testRepeatedCorrectionConvergesOnTheBeat() {
        // A running transport a third of a beat late against a steady 120 BPM pulse.
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 0)
        transport.shiftPosition(byBeats: -0.33)
        // Four reports a second for three seconds; the music's beats are on the
        // whole half-seconds.
        for report in 1...12 {
            let now = Double(report) * 0.25
            let lastMusicBeat = (now / 0.5).rounded(.down) * 0.5
            let clockAtBeat = transport.beats(atHostTime: now) - (now - lastMusicBeat) / transport.secondsPerBeat
            transport.shiftPosition(byBeats: BeatTracker.phaseCorrection(clockBeatsAtMusicBeat: clockAtBeat, snap: false))
        }
        let residual = transport.beats(atHostTime: 10.0) - (transport.beats(atHostTime: 10.0)).rounded()
        XCTAssertLessThan(abs(residual), 0.02, "clock still \(residual) beat off after three seconds")
    }

    // MARK: - Transport

    func testShiftingTheTransportMovesPositionNotTempo() {
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 0)
        let before = transport.beats(atHostTime: 1.0)
        transport.shiftPosition(byBeats: 0.25)
        XCTAssertEqual(transport.beats(atHostTime: 1.0), before + 0.25, accuracy: 1e-9)
        XCTAssertEqual(transport.beatsPerMinute, 120)
        transport.shiftPosition(byBeats: .nan)
        XCTAssertEqual(transport.beats(atHostTime: 1.0), before + 0.25, accuracy: 1e-9,
                       "a NaN correction must be ignored, not poison the clock")
    }
}


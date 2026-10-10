//
//  RecordingClockTests.swift — where recorded frames and audio land on a take.
//
//  Purpose : A recording whose sound drifts from its picture is only discovered when
//            someone watches it back, long after the set. These pin the two rules
//            that keep them together: frames stay on the grid through refresh
//            wobble but jump a gap when frames are lost; audio stays one unbroken
//            run, with silence for gaps and overlaps trimmed.
//  Inputs  : synthetic host times; no writer, no audio device.
//  Outputs : assertions.
//  Connects: RecordedFrameClock, RecordedAudioClock.
//

import XCTest
@testable import VideoboyCore

final class RecordingClockTests: XCTestCase {

    private let frame = 1 / StandardDefinition.frameRate

    // MARK: - Frames

    func testFramesOnARefreshGridCountWithoutSkipsOrRepeats() {
        // A 60 Hz display: each content frame lands on the next refresh, so the
        // presentation times wobble by up to a refresh around the 29.97 grid.
        var clock = RecordedFrameClock()
        let refresh = 1.0 / 60
        var indices: [Int] = []
        for n in 0..<3000 {
            let ideal = 100 + Double(n) * frame
            let onRefresh = (ideal / refresh).rounded(.up) * refresh
            if let index = clock.index(forPresentationTime: onRefresh) { indices.append(index) }
        }
        XCTAssertEqual(indices, Array(0..<3000), "every frame written once, in order, no gaps")
    }

    func testLostFramesLeaveAGapSoLaterFramesStayOnTime() {
        var clock = RecordedFrameClock()
        for n in 0..<10 { _ = clock.index(forPresentationTime: Double(n) * frame) }
        // Five frames never arrive (a stall); the next one is frame 15 in real time.
        XCTAssertEqual(clock.index(forPresentationTime: 15 * frame), 15)
        XCTAssertEqual(clock.index(forPresentationTime: 16 * frame), 16)
        XCTAssertEqual(clock.frameCount, 17)
    }

    func testLostFramesAndWobbleNeverPutThePictureMoreThanTheSlackOffTime() {
        // A 30 Hz link (the worst wobble: a whole refresh is a whole frame), with one
        // frame in forty lost at random. Whatever happens, written frames stay in
        // order and never further from real time than the slack.
        var clock = RecordedFrameClock()
        let refresh = 1.0 / 30
        var generator = SystemRandomNumberGenerator()
        var origin: Double?
        var last = -1
        for n in 0..<5000 {
            if n > 0, Int.random(in: 0..<40, using: &generator) == 0 { continue }
            let time = ((Double(n) * frame) / refresh).rounded(.up) * refresh
            guard let index = clock.index(forPresentationTime: time) else { continue }
            if origin == nil { origin = time }
            XCTAssertGreaterThan(index, last)
            last = index
            let ideal = (time - origin!) / frame
            XCTAssertLessThanOrEqual(abs(Double(index) - ideal), RecordedFrameClock.slackFrames + 0.5)
        }
    }

    func testFramesAheadOfTheClockAreNotWritten() {
        var clock = RecordedFrameClock()
        _ = clock.index(forPresentationTime: 0)
        _ = clock.index(forPresentationTime: frame)
        // One repeat is inside the wobble and is written; a second would put the
        // picture two frames early.
        XCTAssertEqual(clock.index(forPresentationTime: frame), 2)
        XCTAssertNil(clock.index(forPresentationTime: frame))
        XCTAssertEqual(clock.index(forPresentationTime: 3 * frame), 3)
    }

    // MARK: - Audio

    private let rate = 48_000.0

    func testTheFirstBufferLandsExactlyWhereItWasCaptured() {
        var clock = RecordedAudioClock(sampleRate: rate)
        let placement = clock.place(count: 480, atOffset: 2.0)
        XCTAssertEqual(placement, .init(silenceBefore: 0, dropLeading: 0, startSample: 96_000))
        XCTAssertEqual(clock.writtenSamples, 96_480)
    }

    func testAudioFromBeforeTheFirstFrameIsTrimmed() {
        var clock = RecordedAudioClock(sampleRate: rate)
        XCTAssertNil(clock.place(count: 480, atOffset: -0.5), "entirely before the take")
        let placement = clock.place(count: 480, atOffset: -0.005)   // 240 samples early
        XCTAssertEqual(placement, .init(silenceBefore: 0, dropLeading: 240, startSample: 0))
        XCTAssertEqual(clock.writtenSamples, 240)
    }

    func testContinuousBuffersWithJitteryTimesStayContiguous() {
        var clock = RecordedAudioClock(sampleRate: rate)
        _ = clock.place(count: 512, atOffset: 0)
        var expected: Int64 = 512
        for n in 1..<2000 {
            // Timestamps off by up to ±3 ms, well inside the tolerance.
            let jitter = Double((n * 7919) % 7 - 3) / 1000
            let placement = clock.place(count: 512, atOffset: Double(n * 512) / rate + jitter)
            XCTAssertEqual(placement, .init(silenceBefore: 0, dropLeading: 0, startSample: expected))
            expected += 512
        }
    }

    func testAGapIsFilledWithSilenceSoLaterAudioStaysInSync() {
        var clock = RecordedAudioClock(sampleRate: rate)
        _ = clock.place(count: 48_000, atOffset: 0)          // 0..1 s
        let placement = clock.place(count: 480, atOffset: 2.0)  // nothing from 1 to 2 s
        XCTAssertEqual(placement, .init(silenceBefore: 48_000, dropLeading: 0, startSample: 48_000))
        XCTAssertEqual(clock.writtenSamples, 96_480, "the buffer's last sample is at 2.01 s")
    }

    func testAnOverlapIsTrimmed() {
        var clock = RecordedAudioClock(sampleRate: rate)
        _ = clock.place(count: 48_000, atOffset: 0)
        // A device hiccup re-delivers from 0.9 s.
        let placement = clock.place(count: 9_600, atOffset: 0.9)
        XCTAssertEqual(placement, .init(silenceBefore: 0, dropLeading: 4_800, startSample: 48_000))
        XCTAssertNil(clock.place(count: 480, atOffset: 0.5), "entirely already written")
    }

    func testSlowDriftIsCorrectedOnceItPassesTheTolerance() {
        // An audio device running 100 ppm slow against the host clock: its buffers
        // carry true host times, but each holds slightly more real time than its
        // sample count says.
        var clock = RecordedAudioClock(sampleRate: rate)
        var corrections = 0
        var hostTime = 0.0
        for _ in 0..<100_000 {   // ~17 minutes of 512-sample buffers
            let placement = clock.place(count: 512, atOffset: hostTime)!
            if placement.silenceBefore > 0 { corrections += 1 }
            hostTime += 512 / rate * 1.0001
            let error = abs(Double(clock.writtenSamples) / rate - hostTime)
            XCTAssertLessThan(error, 0.021, "never further out than the tolerance")
        }
        XCTAssertGreaterThan(corrections, 0)
        XCTAssertLessThan(corrections, 10, "corrected rarely, not every buffer")
    }

    func testSilenceCatchesUpWhileTheSourceIsQuiet() {
        var clock = RecordedAudioClock(sampleRate: rate)
        XCTAssertEqual(clock.silenceToCatchUp(atOffset: 10), 0, "nothing until audio has started")
        _ = clock.place(count: 48_000, atOffset: 0)
        XCTAssertEqual(clock.silenceToCatchUp(atOffset: 1.1), 0, "audio still flowing")
        XCTAssertEqual(clock.silenceToCatchUp(atOffset: 3.25), 96_000, "up to 0.25 s behind now")
        // Audio that was only late, captured from 2.9 s: half already covered by
        // silence, so that half is trimmed and the rest lands on time.
        let late = clock.place(count: 9_600, atOffset: 2.9)
        XCTAssertEqual(late, .init(silenceBefore: 0, dropLeading: 4_800, startSample: 144_000))
        // The source coming back properly later gets silence up to where it belongs.
        let back = clock.place(count: 480, atOffset: 3.5)
        XCTAssertEqual(back?.silenceBefore, 19_200)
    }
}

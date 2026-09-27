//
//  ClockTests.swift — the transport and the latency-compensating scheduler.
//
//  Purpose : SPEC 1.5 names the clock/scheduler as one of the three things most
//            likely to break silently, and latency compensation is the part that is
//            easiest to skip and hardest to notice. These tests pin down that a
//            scheduled action fires early by exactly its module's latency, so the
//            visible result lands on the beat.
//  Inputs  : a fake host clock — plain Doubles, no CoreAudio, no display link.
//  Outputs : assertions.
//  Connects: Transport, Scheduler, Subdivision.
//  Extend  : a new tempo source still sets `beatsPerMinute`; test it here.
//

import XCTest
@testable import VideoboyCore

final class ClockTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    // MARK: - Transport

    func testBeatsAdvanceWithHostTime() {
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 1000)
        // At 120 BPM a beat is half a second.
        XCTAssertEqual(transport.secondsPerBeat, 0.5, accuracy: 1e-9)
        XCTAssertEqual(transport.beats(atHostTime: 1000), 0, accuracy: 1e-9)
        XCTAssertEqual(transport.beats(atHostTime: 1002), 4, accuracy: 1e-9)
    }

    func testStoppedTransportDoesNotAdvance() {
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 0)
        transport.stop(atHostTime: 1.0)
        // Two beats elapsed before the stop, and none after.
        XCTAssertEqual(transport.beats(atHostTime: 1.0), 2, accuracy: 1e-9)
        XCTAssertEqual(transport.beats(atHostTime: 99.0), 2, accuracy: 1e-9)
    }

    func testPositionReportsBarAndBeat() {
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 0)
        // Beat 5 of a 4/4 bar is bar 1, beat 1.
        let position = transport.position(atHostTime: 2.75)
        XCTAssertEqual(position.totalBeats, 5.5, accuracy: 1e-9)
        XCTAssertEqual(position.bar, 1)
        XCTAssertEqual(position.beat, 1)
        XCTAssertEqual(position.phase, 0.5, accuracy: 1e-9)
    }

    func testTempoChangeDoesNotJumpThePosition() {
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 0)
        _ = transport.beats(atHostTime: 2.0)  // four beats in
        transport.beatsPerMinute = 60
        // The position must be continuous across the change, not reset or leap.
        XCTAssertEqual(transport.beats(atHostTime: 2.0), 4, accuracy: 1e-6)
        // And from there it advances at the new, slower tempo: one beat per second.
        XCTAssertEqual(transport.beats(atHostTime: 3.0), 5, accuracy: 1e-6)
    }

    func testInvalidTempoIsRejectedRatherThanApplied() {
        let transport = Transport(beatsPerMinute: 120)
        transport.beatsPerMinute = 0
        XCTAssertEqual(transport.beatsPerMinute, 120, "a non-positive tempo must be refused")
    }

    func testSubdivisionBoundaries() {
        let transport = Transport(beatsPerMinute: 120)
        transport.start(atHostTime: 0)
        XCTAssertEqual(transport.nextBoundary(after: 0.0, subdivision: .quarter), 1.0, accuracy: 1e-9)
        XCTAssertEqual(transport.nextBoundary(after: 0.4, subdivision: .quarter), 1.0, accuracy: 1e-9)
        XCTAssertEqual(transport.nextBoundary(after: 0.0, subdivision: .eighth), 0.5, accuracy: 1e-9)
        XCTAssertEqual(transport.nextBoundary(after: 0.0, subdivision: .whole), 4.0, accuracy: 1e-9)
        // A boundary landing exactly on the query must advance, not repeat — this is
        // what stops one beat firing an event twice.
        XCTAssertEqual(transport.nextBoundary(after: 1.0, subdivision: .quarter), 2.0, accuracy: 1e-9)
    }

    func testTripletsDivideTheBeatInThree() {
        XCTAssertEqual(Subdivision.tripletEighth.beats, 1.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(Subdivision.dottedEighth.beats, 0.75, accuracy: 1e-12)
    }

    // MARK: - Scheduler

    func testSchedulerFiresOnEveryBoundary() {
        let transport = Transport(beatsPerMinute: 120)
        let scheduler = Scheduler(transport: transport)
        transport.start(atHostTime: 0)

        var firedBeats: [Double] = []
        scheduler.subscribe(subdivision: .quarter) { event in
            firedBeats.append(event.targetBeat)
        }

        // Step forward as the render loop would. The host time is computed from an
        // integer step rather than accumulated, so the sample at exactly 2.0 seconds
        // really is 2.0 and beat 4 is not missed by a rounding error.
        for step in 0...125 {
            scheduler.advance(to: Double(step) / 60.0)
        }

        // Two seconds at 120 BPM is four beats: 1, 2, 3, 4.
        XCTAssertEqual(firedBeats, [1, 2, 3, 4])
    }

    /// The heart of the matter: an event targeted at beat N must be *fired* at
    /// `N's host time − the module's latency`, so the visible result lands on N.
    func testLatencyCompensationFiresEarlyByExactlyTheDeclaredLatency() {
        let transport = Transport(beatsPerMinute: 120)
        let scheduler = Scheduler(transport: transport)
        transport.start(atHostTime: 0)

        // Three frames of latency at 29.97 fps is about 100 ms.
        let latencyFrames = 3
        let frameRate = StandardDefinition.frameRate
        let expectedLatency = Double(latencyFrames) / frameRate

        var events: [ScheduledEvent] = []
        scheduler.subscribe(subdivision: .quarter, latencyInFrames: latencyFrames, frameRate: frameRate) {
            events.append($0)
        }

        var hostTime = 0.0
        while hostTime <= 1.6 {
            scheduler.advance(to: hostTime)
            hostTime += 1.0 / 120.0
        }

        let first = try! XCTUnwrap(events.first)
        // Beat 1 at 120 BPM is host time 0.5.
        XCTAssertEqual(first.targetBeat, 1.0, accuracy: 1e-9)
        XCTAssertEqual(first.targetHostTime, 0.5, accuracy: 1e-9)
        // ...and the action must be taken `expectedLatency` earlier than that.
        XCTAssertEqual(first.fireHostTime, 0.5 - expectedLatency, accuracy: 1e-9)
        XCTAssertEqual(first.targetHostTime - first.fireHostTime, expectedLatency, accuracy: 1e-9)
    }

    func testZeroLatencyFiresOnTheBeatItself() {
        let transport = Transport(beatsPerMinute: 120)
        let scheduler = Scheduler(transport: transport)
        transport.start(atHostTime: 0)

        var events: [ScheduledEvent] = []
        scheduler.subscribe(subdivision: .quarter, latencyInFrames: 0) { events.append($0) }

        var hostTime = 0.0
        while hostTime <= 1.1 {
            scheduler.advance(to: hostTime)
            hostTime += 1.0 / 120.0
        }

        let first = try! XCTUnwrap(events.first)
        XCTAssertEqual(first.fireHostTime, first.targetHostTime, accuracy: 1e-9)
    }

    /// Two modules with different latencies must still land their results together.
    func testDifferentLatenciesStillLandOnTheSameBeat() {
        let transport = Transport(beatsPerMinute: 100)
        let scheduler = Scheduler(transport: transport)
        transport.start(atHostTime: 0)

        var fast: [ScheduledEvent] = []
        var slow: [ScheduledEvent] = []
        scheduler.subscribe(subdivision: .quarter, latencyInFrames: 0) { fast.append($0) }
        scheduler.subscribe(subdivision: .quarter, latencyInFrames: 6) { slow.append($0) }

        var hostTime = 0.0
        while hostTime <= 2.0 {
            scheduler.advance(to: hostTime)
            hostTime += 1.0 / 240.0
        }

        XCTAssertFalse(fast.isEmpty)
        XCTAssertEqual(fast.count, slow.count, "both modules must fire on the same beats")
        for (fastEvent, slowEvent) in zip(fast, slow) {
            // The whole point: different fire times, identical target times.
            XCTAssertEqual(fastEvent.targetHostTime, slowEvent.targetHostTime, accuracy: 1e-9)
            XCTAssertLessThan(slowEvent.fireHostTime, fastEvent.fireHostTime,
                              "the higher-latency module must act earlier")
        }
    }

    func testStoppedTransportFiresNothing() {
        let transport = Transport(beatsPerMinute: 120)
        let scheduler = Scheduler(transport: transport)

        var fired = 0
        scheduler.subscribe(subdivision: .quarter) { _ in fired += 1 }
        for step in 0...120 { scheduler.advance(to: Double(step) / 60.0) }

        XCTAssertEqual(fired, 0, "a stopped transport must not schedule anything")
    }

    func testUnsubscribeStopsDelivery() {
        let transport = Transport(beatsPerMinute: 120)
        let scheduler = Scheduler(transport: transport)
        transport.start(atHostTime: 0)

        var fired = 0
        let id = scheduler.subscribe(subdivision: .quarter) { _ in fired += 1 }
        var hostTime = 0.0
        while hostTime <= 1.1 { scheduler.advance(to: hostTime); hostTime += 1.0 / 120.0 }
        let firedBeforeUnsubscribe = fired
        XCTAssertGreaterThan(firedBeforeUnsubscribe, 0)

        scheduler.unsubscribe(id)
        while hostTime <= 3.0 { scheduler.advance(to: hostTime); hostTime += 1.0 / 120.0 }
        XCTAssertEqual(fired, firedBeforeUnsubscribe)
    }

    func testLateSubscriberDoesNotReplayThePast() {
        let transport = Transport(beatsPerMinute: 120)
        let scheduler = Scheduler(transport: transport)
        transport.start(atHostTime: 0)

        // Run for ten beats before anyone subscribes.
        var hostTime = 0.0
        while hostTime <= 5.0 { scheduler.advance(to: hostTime); hostTime += 1.0 / 120.0 }

        var fired = 0
        scheduler.subscribe(subdivision: .quarter) { _ in fired += 1 }
        while hostTime <= 5.6 { scheduler.advance(to: hostTime); hostTime += 1.0 / 120.0 }

        // At most the one boundary actually crossed since subscribing.
        XCTAssertLessThanOrEqual(fired, 2, "a late subscriber must not receive every past beat at once")
    }

    // MARK: - Waking from sleep (BUGHUNT S5)

    /// One display-link tick after an 8-hour sleep must not replay every missed beat.
    /// Before the fix this one call fired 57,600 events synchronously.
    func testAnEightHourGapInOneAdvanceFiresABoundedNumberOfEvents() {
        let transport = Transport(beatsPerMinute: 120)
        let scheduler = Scheduler(transport: transport)
        transport.start(atHostTime: 0)

        var fired = 0
        scheduler.subscribe(subdivision: .sixteenth) { _ in fired += 1 }
        scheduler.advance(to: 0)
        scheduler.advance(to: 8 * 3600)

        // At most the catch-up window (2 beats of sixteenths) plus the look-ahead.
        XCTAssertLessThanOrEqual(fired, 12, "a long gap must be skipped, not replayed")
        XCTAssertGreaterThan(fired, 0, "the boundaries nearest now still fire")

        // And the clock carries on normally afterwards: one more second is two beats.
        fired = 0
        for step in 1...60 { scheduler.advance(to: 8 * 3600 + Double(step) / 60.0) }
        XCTAssertEqual(Double(fired), 8, accuracy: 1, "sixteenths at 120 BPM: 8 per second")
    }
}

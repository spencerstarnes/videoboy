//
//  ClipQueueTests.swift — the per-source queue, and who is allowed to consult it.
//
//  The load-bearing rule is the last group: ONLY one shot pulls from a queue.
//  Loop and ping-pong already answer "what happens at the end", and a queue that
//  overrode them would silently redefine the shuttle key.
//

import XCTest
@testable import VideoboyCore

final class ClipQueueTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    // MARK: - Queue behaviour

    func testAppendAddsToTheBackAndInsertNextToTheFront() {
        var queue = ClipQueue()
        queue.append(url: url("first.mov"))
        queue.append(url: url("second.mov"))
        queue.insertNext(url: url("jumped.mov"))

        XCTAssertEqual(
            queue.items.map(\.displayName),
            ["jumped.mov", "first.mov", "second.mov"],
            "Play Next goes in front of the queue, Add goes on the end")
    }

    func testRepeatIsOnByDefault() {
        XCTAssertTrue(ClipQueue().repeats, "a queue cycles unless the performer turns REPEAT off")
    }

    func testWithRepeatOffTakingAnItemConsumesIt() {
        var queue = ClipQueue(repeats: false)
        queue.append(url: url("one.mov"))
        queue.append(url: url("two.mov"))

        XCTAssertEqual(queue.takeNext()?.displayName, "one.mov")
        XCTAssertEqual(queue.count, 1, "playing an item takes it off the queue — Up Next's rule")
        XCTAssertEqual(queue.takeNext()?.displayName, "two.mov")
        XCTAssertNil(queue.takeNext(), "an exhausted queue reports empty rather than repeating")
    }

    func testWithRepeatOnTakingAnItemMovesItToTheBottom() {
        var queue = ClipQueue()
        for name in ["one", "two", "three"] { queue.append(url: url("\(name).mov")) }
        let firstID = queue.items[0].id

        XCTAssertEqual(queue.takeNext()?.displayName, "one.mov")
        XCTAssertEqual(queue.items.map(\.displayName), ["two.mov", "three.mov", "one.mov"],
                       "the played clip goes to the bottom, the rest move up")
        XCTAssertEqual(queue.items.last?.id, firstID, "same item, moved — not a copy")

        let order = (0..<4).compactMap { _ in queue.takeNext()?.displayName }
        XCTAssertEqual(order, ["two.mov", "three.mov", "one.mov", "two.mov"], "it cycles forever")
        XCTAssertEqual(queue.count, 3)
    }

    func testTurningRepeatOffMidSetKeepsTheQueueAndStopsTheCycle() {
        var queue = ClipQueue()
        queue.append(url: url("one.mov"))
        queue.append(url: url("two.mov"))
        _ = queue.takeNext()
        queue.repeats = false
        XCTAssertEqual(queue.items.map(\.displayName), ["two.mov", "one.mov"])
        _ = queue.takeNext()
        _ = queue.takeNext()
        XCTAssertTrue(queue.isEmpty)
    }

    func testAQueueWrittenBeforeRepeatExistedDecodesAsRepeating() throws {
        // Today's encoding with the `repeats` key taken out = what an older build wrote.
        var written = ClipQueue(repeats: false)
        written.append(url: url("a.mov"))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(written)) as? [String: Any])
        object["repeats"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        let queue = try JSONDecoder().decode(ClipQueue.self, from: old)
        XCTAssertTrue(queue.repeats)
        XCTAssertEqual(queue.count, 1)
        let round = try JSONDecoder().decode(ClipQueue.self, from: JSONEncoder().encode(ClipQueue(repeats: false)))
        XCTAssertFalse(round.repeats, "REPEAT off survives a round trip")
    }

    func testBatchAppendKeepsOrderAndStopsAtTheLimit() {
        var queue = ClipQueue()
        queue.append(url: url("already.mov"))
        let added = queue.append(urls: ["a", "b", "c", "d"].map { url("\($0).mov") }, limit: 3)
        XCTAssertEqual(added, 2, "room for two: the queue already held one")
        XCTAssertEqual(queue.items.map(\.displayName), ["already.mov", "a.mov", "b.mov"])
        XCTAssertEqual(queue.append(urls: [url("e.mov")], limit: 3), 0, "a full queue takes nothing")
    }

    func testBatchPlayNextKeepsTheSelectionsOrderInFront() {
        var queue = ClipQueue()
        queue.append(url: url("later.mov"))
        let added = queue.insertNext(urls: [url("one.mov"), url("two.mov")], limit: 10)
        XCTAssertEqual(added, 2)
        XCTAssertEqual(queue.items.map(\.displayName), ["one.mov", "two.mov", "later.mov"],
                       "the first selected plays first")
    }

    func testAutoLimitScalesWithMemoryAndIsClamped() {
        let gb: UInt64 = 1 << 30
        let small = QueueLimit.automatic(physicalMemory: 8 * gb)
        let big = QueueLimit.automatic(physicalMemory: 64 * gb)
        XCTAssertLessThan(small, big, "more memory, longer queues")
        XCTAssertEqual(QueueLimit.automatic(physicalMemory: 1 * gb), QueueLimit.automaticFloor)
        XCTAssertEqual(QueueLimit.automatic(physicalMemory: 1024 * gb), QueueLimit.automaticCeiling)
        XCTAssertTrue((QueueLimit.automaticFloor...QueueLimit.automaticCeiling).contains(QueueLimit.automaticAtLaunch))
    }

    func testManualLimitWinsAndIsClamped() {
        XCTAssertEqual(QueueLimit.resolved(manual: nil), QueueLimit.automaticAtLaunch)
        XCTAssertEqual(QueueLimit.resolved(manual: 250), 250)
        XCTAssertEqual(QueueLimit.resolved(manual: 0), QueueLimit.manualRange.lowerBound)
        XCTAssertEqual(QueueLimit.resolved(manual: 1_000_000), QueueLimit.manualRange.upperBound)
    }

    func testQueueLimitPreferenceRoundTripsAndDefaultsToAuto() throws {
        var preferences = Preferences()
        XCTAssertNil(preferences.queueLimit, "Auto unless set by hand")
        preferences.queueLimit = 500
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(decoded.queueLimit, 500)
        let auto = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(Preferences()))
        XCTAssertNil(auto.queueLimit)
    }

    func testPeekDoesNotConsume() {
        var queue = ClipQueue()
        queue.append(url: url("one.mov"))
        XCTAssertEqual(queue.peekNext?.displayName, "one.mov")
        XCTAssertEqual(queue.count, 1, "peeking is for showing what is next, not for taking it")
    }

    func testMoveReordersAndIgnoresNonsense() {
        var queue = ClipQueue()
        for name in ["a", "b", "c"] { queue.append(url: url("\(name).mov")) }

        queue.move(from: 2, to: 0)
        XCTAssertEqual(queue.items.map(\.displayName), ["c.mov", "a.mov", "b.mov"])

        // A gesture that lands badly should do nothing, not trap mid-set.
        queue.move(from: 99, to: 0)
        queue.move(from: 0, to: 99)
        XCTAssertEqual(queue.count, 3)
    }

    func testRemoveTakesTheNamedItemRatherThanAPosition() {
        var queue = ClipQueue()
        queue.append(url: url("a.mov"))
        queue.append(url: url("b.mov"))
        let second = queue.items[1]

        queue.remove(id: second.id)

        XCTAssertEqual(queue.items.map(\.displayName), ["a.mov"])
    }

    // MARK: - Four of them, one per source

    func testThereIsOneQueuePerSourceAndTheyAreIndependent() {
        var set = QueueSet()
        XCTAssertEqual(QueueSet.channels, ["A", "B", "C", "D"])

        set["A"].append(url: url("only-a.mov"))

        XCTAssertEqual(set["A"].count, 1)
        for channel in ["B", "C", "D"] {
            XCTAssertTrue(set[channel].isEmpty, "queuing on A must not touch \(channel)")
        }
        XCTAssertEqual(set.totalCount, 1)
    }

    func testAnUnknownChannelReadsAsEmptyRatherThanTrapping() {
        let set = QueueSet()
        XCTAssertTrue(set["Z"].isEmpty)
    }

    // MARK: - Saved with the show (template v5)

    func testQueuesRoundTripInATemplateInPlayOrder() throws {
        var set = QueueSet()
        set["A"].append(url: url("second.mov"))
        set["A"].insertNext(url: url("first.mov"))
        set["D"].append(url: url("only-d.mov"))

        let document = TemplateDocument(queues: set.savedPaths)
        let data = try JSONEncoder().encode(document)
        let back = QueueSet(savedPaths: try JSONDecoder().decode(TemplateDocument.self, from: data).queues ?? [:])

        XCTAssertEqual(back["A"].items.map(\.displayName), ["first.mov", "second.mov"],
                       "Play Next's position survives the save")
        XCTAssertEqual(back["D"].items.map(\.displayName), ["only-d.mov"])
        XCTAssertTrue(back["B"].isEmpty && back["C"].isEmpty)
        XCTAssertNil(set.savedPaths["B"], "an empty queue is left out of the file")
    }

    func testAShowFromBeforeQueuesWereSavedOpensWithEmptyQueues() throws {
        let old = try JSONDecoder().decode(TemplateDocument.self, from: Data(#"{"version":4}"#.utf8))
        XCTAssertNil(old.queues)
        XCTAssertEqual(QueueSet(savedPaths: old.queues ?? [:]).totalCount, 0)
    }

    func testASavedQueueForANonChannelIsIgnored() {
        let set = QueueSet(savedPaths: ["E": ["/clips/x.mov"], "B": ["/clips/b.mov"]])
        XCTAssertEqual(set.totalCount, 1, "there is no fifth source for a queue to play into")
        XCTAssertEqual(set["B"].peekNext?.displayName, "b.mov")
    }

    // MARK: - Only ONE SHOT asks the queue

    /// Runs a source to the end of its clip in the given loop mode and reports
    /// whether it announced that it had finished.
    private func reachesEnd(in mode: LoopMode) throws -> Bool {
        let url = RepoPaths.samples.appendingPathComponent("motion.mov")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("samples/motion.mov is missing — run scripts/make-fixtures.sh")
        }
        let node = ClipSourceNode(identifier: "test.queue", context: nil)
        XCTAssertTrue(node.load(url: url))
        node.loopMode = mode

        var announced = false
        node.onReachedEnd = { announced = true }

        // Park the playhead on the last frame and advance once more, which is the
        // moment each mode's rule actually applies.
        node.isPlaying = true
        node.seek(toNormalised: 1.0)
        node.advancePlayhead(by: 1, frameCount: node.frameCount)
        return announced
    }

    func testOneShotAnnouncesThatItFinished() throws {
        XCTAssertTrue(
            try reachesEnd(in: .oneShot),
            "one shot is the mode that hands over to the queue")
    }

    func testLoopNeverAnnouncesAnEnd() throws {
        XCTAssertFalse(
            try reachesEnd(in: .loop),
            "a looping source has no end to hand over, and must not consume the queue")
    }

    func testPingPongNeverAnnouncesAnEnd() throws {
        XCTAssertFalse(
            try reachesEnd(in: .pingPong),
            "ping-pong turns around instead of finishing — taking a queue item here "
                + "would quietly redefine what the shuttle key means")
    }
}

// MARK: - Echo / Trails

/// Reported as "echo trails doesn't work". Everything around it looked wired — the
/// node is in the graph, its slot is in the name table, applyParameters is called —
/// so these check the one thing reading the code cannot: whether a trail actually
/// appears in the pixels.
final class EchoTrailsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    /// A bright square on black, at a position that moves with the frame.
    private func movingSquare(at step: Int) -> ImageBuffer {
        var image = ImageBuffer(width: 128, height: 128)
        let x0 = 10 + step * 12
        for y in 50..<70 {
            for x in x0..<(x0 + 20) where x < 128 {
                image.setPixel(x: x, y: y, r: 255, g: 255, b: 255)
            }
        }
        return image
    }

    func testEchoLeavesATrailBehindAMovingObject() throws {
        guard let metal = MetalContext.shared else {
            throw XCTSkip("no Metal device")
        }
        guard let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no offscreen renderer")
        }
        let echo = EchoNode(identifier: "test.echo", context: metal)
        echo.wetDry = 1.0
        echo.decay = 0.9
        echo.gain = 0.9
        echo.threshold = 0.05

        var last: ImageBuffer?
        for step in 0..<5 {
            let frame = movingSquare(at: step)
            guard let texture = metal.makeTexture(from: frame, label: "echo-in") else {
                return XCTFail("could not upload the test frame")
            }
            let context = RenderContext(
                frameIndex: step, presentationTime: Double(step) / 30.0, musicalPosition: nil)
            guard let out = echo.render(inputs: [texture], context: context) else {
                return XCTFail("echo returned no texture on step \(step)")
            }
            last = renderer.readback(out)
        }

        guard let result = last else { return XCTFail("no frame came back") }
        let check = SelfQACheck(name: "phase-4/echo-trails")
        try? check.writeImage(result, named: "echo-after-5-frames.png")

        // Where the square WAS two steps ago must still be lit, or there is no trail.
        // Square 4 sits at x 58..78; square 2 sat at x 34..54.
        var trailBrightness = 0
        for y in 55..<65 {
            for x in 36..<50 { trailBrightness += Int(result.pixel(x: x, y: y).r) }
        }
        XCTAssertGreaterThan(
            trailBrightness, 0,
            "nothing is lit where the square was two frames ago — that is the trail, and "
                + "without it the effect is doing nothing visible")
    }
}

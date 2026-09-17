//
//  PlaylistTests.swift — the per-source queue, and who is allowed to consult it.
//
//  The load-bearing rule is the last group: ONLY one shot pulls from a playlist.
//  Loop and ping-pong already answer "what happens at the end", and a playlist that
//  overrode them would silently redefine the shuttle key.
//

import XCTest
@testable import VideoboyCore

final class PlaylistTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    // MARK: - Queue behaviour

    func testAppendAddsToTheBackAndInsertNextToTheFront() {
        var playlist = Playlist()
        playlist.append(url: url("first.mov"))
        playlist.append(url: url("second.mov"))
        playlist.insertNext(url: url("jumped.mov"))

        XCTAssertEqual(
            playlist.items.map(\.displayName),
            ["jumped.mov", "first.mov", "second.mov"],
            "Play Next goes in front of the queue, Add goes on the end")
    }

    func testTakingAnItemConsumesIt() {
        var playlist = Playlist()
        playlist.append(url: url("one.mov"))
        playlist.append(url: url("two.mov"))

        XCTAssertEqual(playlist.takeNext()?.displayName, "one.mov")
        XCTAssertEqual(playlist.count, 1, "playing an item takes it off the queue — Up Next's rule")
        XCTAssertEqual(playlist.takeNext()?.displayName, "two.mov")
        XCTAssertNil(playlist.takeNext(), "an exhausted queue reports empty rather than repeating")
    }

    func testPeekDoesNotConsume() {
        var playlist = Playlist()
        playlist.append(url: url("one.mov"))
        XCTAssertEqual(playlist.peekNext?.displayName, "one.mov")
        XCTAssertEqual(playlist.count, 1, "peeking is for showing what is next, not for taking it")
    }

    func testMoveReordersAndIgnoresNonsense() {
        var playlist = Playlist()
        for name in ["a", "b", "c"] { playlist.append(url: url("\(name).mov")) }

        playlist.move(from: 2, to: 0)
        XCTAssertEqual(playlist.items.map(\.displayName), ["c.mov", "a.mov", "b.mov"])

        // A gesture that lands badly should do nothing, not trap mid-set.
        playlist.move(from: 99, to: 0)
        playlist.move(from: 0, to: 99)
        XCTAssertEqual(playlist.count, 3)
    }

    func testRemoveTakesTheNamedItemRatherThanAPosition() {
        var playlist = Playlist()
        playlist.append(url: url("a.mov"))
        playlist.append(url: url("b.mov"))
        let second = playlist.items[1]

        playlist.remove(id: second.id)

        XCTAssertEqual(playlist.items.map(\.displayName), ["a.mov"])
    }

    // MARK: - Four of them, one per source

    func testThereIsOnePlaylistPerSourceAndTheyAreIndependent() {
        var set = PlaylistSet()
        XCTAssertEqual(PlaylistSet.channels, ["A", "B", "C", "D"])

        set["A"].append(url: url("only-a.mov"))

        XCTAssertEqual(set["A"].count, 1)
        for channel in ["B", "C", "D"] {
            XCTAssertTrue(set[channel].isEmpty, "queuing on A must not touch \(channel)")
        }
        XCTAssertEqual(set.totalCount, 1)
    }

    func testAnUnknownChannelReadsAsEmptyRatherThanTrapping() {
        let set = PlaylistSet()
        XCTAssertTrue(set["Z"].isEmpty)
    }

    // MARK: - Only ONE SHOT asks the playlist

    /// Runs a source to the end of its clip in the given loop mode and reports
    /// whether it announced that it had finished.
    private func reachesEnd(in mode: LoopMode) throws -> Bool {
        let url = RepoPaths.samples.appendingPathComponent("motion.mov")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("samples/motion.mov is missing — run scripts/make-fixtures.sh")
        }
        let node = ClipSourceNode(identifier: "test.playlist", context: nil)
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
            "one shot is the mode that hands over to the playlist")
    }

    func testLoopNeverAnnouncesAnEnd() throws {
        XCTAssertFalse(
            try reachesEnd(in: .loop),
            "a looping source has no end to hand over, and must not consume the queue")
    }

    func testPingPongNeverAnnouncesAnEnd() throws {
        XCTAssertFalse(
            try reachesEnd(in: .pingPong),
            "ping-pong turns around instead of finishing — taking a playlist item here "
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

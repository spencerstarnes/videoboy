//
//  ClipSourceEjectTests.swift — taking media back out of a channel.
//
//  There was no eject at all before this: a clip could be loaded into a source and
//  never removed. These check the inverse of `load` actually inverts it, field by
//  field, because a partial eject is the worse failure — a channel that looks empty
//  while still holding a decoder is one that will surprise someone mid-set.
//

import XCTest
@testable import VideoboyCore

final class ClipSourceEjectTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private func loadedSource() throws -> ClipSourceNode {
        let url = RepoPaths.samples.appendingPathComponent("motion.mov")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("samples/motion.mov is missing — run scripts/make-fixtures.sh")
        }
        let node = ClipSourceNode(identifier: "test.source", context: nil)
        XCTAssertTrue(node.load(url: url), "the fixture should load before there is anything to eject")
        return node
    }

    func testEjectClearsTheMedia() throws {
        let node = try loadedSource()
        XCTAssertNotNil(node.mediaURL)

        node.unload()

        XCTAssertNil(node.mediaURL, "the URL must go, or the panel still thinks a clip is in there")
        XCTAssertEqual(node.frameCount, 0, "an ejected source has no frames")
    }

    func testEjectStopsPlayback() throws {
        let node = try loadedSource()
        node.isPlaying = true

        node.unload()

        XCTAssertFalse(
            node.isPlaying,
            "a source holding nothing must not still report itself as playing — that leaves "
                + "the transport lit for a deck with no tape in it")
    }

    func testEjectRewindsThePlayhead() throws {
        let node = try loadedSource()
        node.seek(toNormalised: 0.7)
        XCTAssertGreaterThan(node.playheadFrame, 0)

        node.unload()

        XCTAssertEqual(
            node.playheadFrame, 0,
            "the next clip loaded into this channel should start at its own beginning, "
                + "not wherever the last one happened to be stopped")
    }

    func testTheSameChannelCanBeLoadedAgainAfterEjecting() throws {
        let node = try loadedSource()
        node.unload()

        let url = RepoPaths.samples.appendingPathComponent("motion.mov")
        XCTAssertTrue(
            node.load(url: url),
            "eject must leave the source reusable — a channel you can only fill once is worse "
                + "than one you cannot empty")
        XCTAssertNotNil(node.mediaURL)
    }

    func testEjectingAnEmptySourceIsHarmless() {
        let node = ClipSourceNode(identifier: "test.empty", context: nil)
        node.unload()
        node.unload()
        XCTAssertNil(node.mediaURL)
    }
}

// MARK: - Exchanging clips between two channels (the ⇅ show control)

extension ClipSourceEjectTests {

    private func sampleURLs() throws -> (URL, URL) {
        let a = RepoPaths.samples.appendingPathComponent("motion.mov")
        let b = RepoPaths.samples.appendingPathComponent("bars.dv")
        for url in [a, b] where !FileManager.default.fileExists(atPath: url.path) {
            throw XCTSkip("\(url.lastPathComponent) is missing — run scripts/make-fixtures.sh")
        }
        return (a, b)
    }

    /// The clips change places, and each keeps playing from where it had got to.
    func testSwappingTwoChannelsExchangesTheirClips() throws {
        let (first, second) = try sampleURLs()
        let left = ClipSourceNode(identifier: "source.a", context: nil)
        let right = ClipSourceNode(identifier: "source.b", context: nil)
        XCTAssertTrue(left.load(url: first))
        XCTAssertTrue(right.load(url: second))

        left.isPlaying = true
        right.loopMode = .pingPong
        left.seek(toNormalised: 0.5)
        let leftPosition = left.playheadFrame

        let takenFromLeft = left.takeLoadedClip()
        let takenFromRight = right.takeLoadedClip()
        left.adopt(takenFromRight)
        right.adopt(takenFromLeft)

        XCTAssertEqual(left.mediaURL?.lastPathComponent, second.lastPathComponent)
        XCTAssertEqual(right.mediaURL?.lastPathComponent, first.lastPathComponent)
        XCTAssertEqual(
            right.playheadFrame, leftPosition,
            "a clip keeps its playhead when it moves channel — a swap that restarts "
                + "both clips is not usable mid-show")
        XCTAssertTrue(right.isPlaying, "the clip that was playing goes on playing")
        XCTAssertEqual(left.loopMode, .pingPong, "loop mode belongs to the clip")
    }

    /// The registry-driven settings belong to the CHANNEL and must stay put. A
    /// performer who has dialled damage into A expects A to keep sounding like A when
    /// a different picture arrives in it.
    func testSwappingDoesNotCarryChannelSettingsAcross() throws {
        let (first, second) = try sampleURLs()
        let left = ClipSourceNode(identifier: "source.a", context: nil)
        let right = ClipSourceNode(identifier: "source.b", context: nil)
        XCTAssertTrue(left.load(url: first))
        XCTAssertTrue(right.load(url: second))

        left.corruption.amount = 0.8
        right.corruption.amount = 0.0

        let takenFromLeft = left.takeLoadedClip()
        left.adopt(right.takeLoadedClip())
        right.adopt(takenFromLeft)

        XCTAssertEqual(left.corruption.amount, 0.8, accuracy: 1e-9,
                       "damage is the channel's, not the clip's")
        XCTAssertEqual(right.corruption.amount, 0.0, accuracy: 1e-9)
    }

    /// Swapping an empty channel with a loaded one is a move, not a no-op, and must
    /// not leave the clip in both places.
    func testSwappingWithAnEmptyChannelMovesTheClip() throws {
        let (first, _) = try sampleURLs()
        let loaded = ClipSourceNode(identifier: "source.a", context: nil)
        let empty = ClipSourceNode(identifier: "source.b", context: nil)
        XCTAssertTrue(loaded.load(url: first))

        let taken = loaded.takeLoadedClip()
        loaded.adopt(empty.takeLoadedClip())
        empty.adopt(taken)

        XCTAssertNil(loaded.mediaURL, "the clip must not still be in the channel it left")
        XCTAssertEqual(loaded.frameCount, 0)
        XCTAssertEqual(empty.mediaURL?.lastPathComponent, first.lastPathComponent)
        XCTAssertGreaterThan(empty.frameCount, 0)
    }
}

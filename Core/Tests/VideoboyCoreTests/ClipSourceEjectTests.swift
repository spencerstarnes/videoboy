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

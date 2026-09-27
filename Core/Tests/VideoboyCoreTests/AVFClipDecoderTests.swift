//
//  AVFClipDecoderTests.swift — ordinary video really decoding.
//
//  "Only .dv plays" was the biggest functional gap in the app, so the point of these
//  is to prove the gap is actually closed rather than that the types compile. They
//  decode a real .mov from samples/ and check the frames are pictures, that seeking
//  backwards works (which is the case needing a reader restart), and that the node
//  reports the right data-effect family — because offering the wedge on footage that
//  cannot carry it would be worse than not playing it at all.
//

import XCTest
@testable import VideoboyCore

final class AVFClipDecoderTests: XCTestCase {

    private func movieURL() throws -> URL {
        let url = RepoPaths.samples.appendingPathComponent("motion.mov")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("samples/motion.mov is missing — run scripts/make-fixtures.sh")
        }
        return url
    }

    func testOrdinaryVideoOpensAndReportsItsLength() throws {
        let url = try movieURL()
        guard let decoder = AVFClipDecoder(url: url) else {
            return XCTFail("motion.mov did not open")
        }
        XCTAssertGreaterThan(decoder.frameCount, 1)
        XCTAssertGreaterThan(decoder.frameRate, 1)
    }

    func testFramesAreRealPictures() throws {
        let url = try movieURL()
        guard let decoder = AVFClipDecoder(url: url),
              let frame = decoder.image(at: 0, corruption: .inert) else {
            return XCTFail("no first frame")
        }
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        XCTAssertTrue(
            FrameAssertions.signalPresent(frame, varianceThreshold: 1.0),
            "the decoded frame is flat; it is probably not being read at all")
    }

    func testTheClipMovesBetweenFrames() throws {
        let url = try movieURL()
        guard let decoder = AVFClipDecoder(url: url) else { return XCTFail("did not open") }
        let first = decoder.image(at: 0, corruption: .inert)
        let later = decoder.image(at: min(20, decoder.frameCount - 1), corruption: .inert)
        XCTAssertNotNil(first)
        XCTAssertNotNil(later)
        XCTAssertNotEqual(
            first?.pixels, later?.pixels,
            "two different frames of a moving clip should not be identical")
    }

    /// Going backwards is the case that needs the reader restarting, so it is the one
    /// most likely to hand back nothing or the wrong frame.
    func testSeekingBackwardsStillProducesTheRightFrame() throws {
        let url = try movieURL()
        guard let decoder = AVFClipDecoder(url: url) else { return XCTFail("did not open") }
        let target = min(5, decoder.frameCount - 1)

        guard let firstPass = decoder.image(at: target, corruption: .inert) else {
            return XCTFail("no frame on the way up")
        }
        // Go well past it, far enough to fall out of the cache, then come back.
        _ = decoder.image(at: min(decoder.frameCount - 1, target + 120), corruption: .inert)
        guard let secondPass = decoder.image(at: target, corruption: .inert) else {
            return XCTFail("no frame after seeking back")
        }
        XCTAssertEqual(
            firstPass.pixels, secondPass.pixels,
            "the same frame index should give the same picture whichever way it was reached")
    }

    func testABrokenFileFailsToOpenRatherThanCrashing() {
        XCTAssertNil(AVFClipDecoder(url: URL(fileURLWithPath: "/nonexistent/nope.mov")))
    }

    // MARK: - Through the node

    func testTheNodePlaysOrdinaryVideo() throws {
        let url = try movieURL()
        let node = ClipSourceNode(identifier: GraphTopology.sourceA, context: nil)
        XCTAssertTrue(node.load(url: url), "the source should load a .mov")
        XCTAssertGreaterThan(node.frameCount, 1)
        XCTAssertNotNil(node.renderToImage(frameIndex: 0))
    }

    /// Ordinary video must NOT advertise the bitstream effects.
    ///
    /// The wedge only works on bytes that can carry it. A .mov offering DV damage
    /// would be a control that does nothing, which is the failure this whole seam
    /// exists to make impossible.
    func testOrdinaryVideoOffersNoDataEffects() throws {
        let url = try movieURL()
        let node = ClipSourceNode(identifier: GraphTopology.sourceA, context: nil)
        XCTAssertTrue(node.load(url: url))
        XCTAssertEqual(node.dataEffectFamily, .none)
    }

    func testDVStillOffersTheDVDataEffects() throws {
        let url = RepoPaths.samples.appendingPathComponent("motion.dv")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("samples/motion.dv is missing")
        }
        let node = ClipSourceNode(identifier: GraphTopology.sourceA, context: nil)
        XCTAssertTrue(node.load(url: url))
        XCTAssertEqual(node.dataEffectFamily, .dv)
    }

    /// Loading a .mov over a .dv must drop the DV effects with it.
    func testSwappingFromDVToOrdinaryVideoDropsTheDataEffects() throws {
        let movie = try movieURL()
        let dv = RepoPaths.samples.appendingPathComponent("motion.dv")
        guard FileManager.default.fileExists(atPath: dv.path) else {
            throw XCTSkip("samples/motion.dv is missing")
        }
        let node = ClipSourceNode(identifier: GraphTopology.sourceA, context: nil)
        XCTAssertTrue(node.load(url: dv))
        XCTAssertEqual(node.dataEffectFamily, .dv)
        XCTAssertTrue(node.load(url: movie))
        XCTAssertEqual(
            node.dataEffectFamily, .none,
            "the panel would still be offering DV damage on a clip that cannot take it")
    }
}

// MARK: - Reverse playback does not rebuild the reader per frame (audit C2)

extension AVFClipDecoderTests {

    /// Ping-pong's backward half used to construct a whole `AVAssetReader` for EVERY
    /// displayed frame: the restart set `nextFrameIndex = wrapped`, one frame was
    /// decoded so it became `wrapped + 1`, and the next frame backwards was therefore
    /// `< nextFrameIndex` again. Each restart also seeks from the preceding keyframe,
    /// so on a two-second GOP that is ~60 decodes to show one frame.
    ///
    /// The symptom is dropped frames, which a unit test cannot observe — so this counts
    /// reader restarts instead, which is the thing actually causing them.
    func testPlayingBackwardsDoesNotRestartTheReaderEveryFrame() throws {
        let url = try movieURL()
        guard let decoder = AVFClipDecoder(url: url) else {
            return XCTFail("motion.mov did not open")
        }

        // THE WALK MUST OUTRUN THE CACHE or it proves nothing. A backward pass shorter
        // than `cacheSize` is served entirely from frames the forward priming pass
        // already stored, so it restarts a handful of times whatever the seek logic
        // does — an earlier version of this test walked 60 frames, sat inside the
        // 48-frame cache, and passed with the fix deliberately disabled.
        let frames = decoder.frameCount
        try XCTSkipUnless(
            frames >= 120,
            "clip must be well over the 48-frame cache for a backward walk to mean anything")

        // Prime the forward direction the way playback would.
        _ = decoder.image(at: frames - 1, corruption: .inert)
        let restartsBefore = decoder.readerRestarts

        var decoded = 0
        for index in stride(from: frames - 1, through: 0, by: -1) {
            if decoder.image(at: index, corruption: .inert) != nil { decoded += 1 }
        }
        let restarts = decoder.readerRestarts - restartsBefore

        XCTAssertEqual(decoded, frames, "every frame of the backward walk should decode")
        // One restart per block, not one per frame. Generous bound: the point is the
        // ORDER of magnitude, so this still fails loudly if per-frame behaviour returns.
        XCTAssertLessThan(
            restarts, frames / 4,
            "\(restarts) reader restarts for \(frames) backward frames — that is the "
                + "restart-per-frame regression audit C2 describes")
    }

    // MARK: - HEVC tagged hev1 (BUGHUNT S7)

    /// AVAssetReader refuses to decode `hev1`; the decoder routes it through
    /// VideoToolbox directly. It must open, show real moving pictures, and seek back.
    func testHEVCTaggedHev1Plays() throws {
        let url = RepoPaths.samples.appendingPathComponent("motion-hev1.mov")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("samples/motion-hev1.mov is missing — run scripts/make-fixtures.sh")
        }
        guard let decoder = AVFClipDecoder(url: url) else {
            return XCTFail("hev1 clip did not open (S7 regression)")
        }
        let first = decoder.image(at: 0, corruption: .inert)
        let later = decoder.image(at: 40, corruption: .inert)
        let back = decoder.image(at: 5, corruption: .inert)
        guard let first, let later, let back else { return XCTFail("hev1 frames missing") }
        XCTAssertTrue(FrameAssertions.signalPresent(first, varianceThreshold: 1.0))
        XCTAssertNotEqual(first.pixels, later.pixels, "hev1 playback does not advance")
        XCTAssertNotEqual(back.pixels, later.pixels, "hev1 backward seek returned the wrong frame")

        // Decoded no larger than the canvas needs, like every other AVF clip.
        let fitted = AVFClipDecoder(url: url, canvas: CanvasGeometry.standardDefinition)
        XCTAssertNotNil(fitted?.image(at: 10, corruption: .inert))
    }
}

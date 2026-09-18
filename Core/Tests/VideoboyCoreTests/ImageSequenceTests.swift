//
//  ImageSequenceTests.swift — a folder of photographs, played as a clip.
//
//  The point of routing this through `ClipDecoding` is that nothing else had to change:
//  playback, looping, in and out points and stepping a frame on the beat are all
//  ClipSourceNode's, and they work on a stack of pictures because a stack of pictures
//  can answer the two questions it asks. These check that it really does answer them,
//  and the two things that are easy to get wrong — frame ORDER and picture SHAPE.
//

import XCTest
import CoreGraphics
@testable import VideoboyCore

final class ImageSequenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    /// Writes a folder of solid-colour PNGs, one per frame.
    private func makeFolder(
        frames: Int, width: Int = 64, height: Int = 48, namer: (Int) -> String
    ) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("seq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for index in 0..<frames {
            // Each frame a different red, so a decoded frame says which one it is.
            // Wrapped, because a 200-frame fixture would otherwise overflow a UInt8 —
            // which it did, and the crash was in the test rather than the code.
            let level = UInt8(20 + (index * 20) % 200)
            let image = ImageBuffer(width: width, height: height, r: level, g: 0, b: 0)
            let url = folder.appendingPathComponent(namer(index))
            try image.writePNG(to: url)
        }
        return folder
    }

    func testAFolderOfImagesBecomesAClip() throws {
        let folder = try makeFolder(frames: 5) { "frame\($0).png" }
        let decoder = try ImageSequenceDecoder(folder: folder)

        XCTAssertEqual(decoder.frameCount, 5)
        XCTAssertEqual(decoder.frameRate, 30)
        XCTAssertEqual(decoder.dataEffectFamily, .none, "decoded pictures have no bitstream")
    }

    func testFramesAreInTheORDERAPERSONWouldExpect() throws {
        // THE classic way to get this wrong. A plain string sort puts frame10 second,
        // between frame1 and frame2, and turns the sequence into nonsense.
        let folder = try makeFolder(frames: 12) { "frame\($0 + 1).png" }
        let decoder = try ImageSequenceDecoder(folder: folder)

        let names = decoder.urls.map(\.lastPathComponent)
        XCTAssertEqual(names.first, "frame1.png")
        XCTAssertEqual(names[1], "frame2.png", "frame10 must not sort between 1 and 2")
        XCTAssertEqual(names.last, "frame12.png")
    }

    func testZeroPaddedNamesAlsoWork() throws {
        let folder = try makeFolder(frames: 3) { String(format: "img_%04d.png", $0) }
        let decoder = try ImageSequenceDecoder(folder: folder)
        XCTAssertEqual(decoder.urls.first?.lastPathComponent, "img_0000.png")
        XCTAssertEqual(decoder.urls.last?.lastPathComponent, "img_0002.png")
    }

    func testTheFirstFramesAreReadyImmediately() throws {
        // A clip that shows nothing for its first few frames looks broken on load, so
        // the head of the sequence is decoded when it opens rather than prefetched.
        let folder = try makeFolder(frames: 6) { "frame\($0).png" }
        let decoder = try ImageSequenceDecoder(folder: folder)

        guard let first = decoder.image(at: 0, corruption: .inert) else {
            return XCTFail("the first frame must be there the moment the clip loads")
        }
        XCTAssertEqual(first.width, StandardDefinition.width)
        XCTAssertEqual(first.height, StandardDefinition.height)
    }

    func testThePictureIsLetterboxedRatherThanStretched() throws {
        // A photo folder is full of whatever shape the camera was held in. Stretching
        // each one to fill 4:3 makes a sequence where people change width from frame to
        // frame, which is much worse than a black edge.
        let folder = try makeFolder(frames: 2, width: 200, height: 40) { "frame\($0).png" }
        let decoder = try ImageSequenceDecoder(folder: folder)
        guard let frame = decoder.image(at: 0, corruption: .inert) else {
            return XCTFail("expected a frame")
        }

        // A very wide picture in a 4:3 frame leaves black at top and bottom, and the
        // middle carries the image.
        let top = frame.pixel(x: frame.width / 2, y: 4)
        XCTAssertLessThan(Int(top.r), 12, "the top should be letterbox, not stretched image")
        let middle = frame.pixel(x: frame.width / 2, y: frame.height / 2)
        XCTAssertGreaterThan(Int(middle.r), 12, "and the middle should carry the picture")
    }

    func testThePictureIsTheRightWayUp() throws {
        // CGContext draws from the bottom left and an ImageBuffer's row 0 is the top.
        // Getting the flip wrong gives an upside-down slideshow, which is obvious on a
        // photograph and invisible on a test pattern.
        let width = 64
        let height = 48
        var source = ImageBuffer(width: width, height: height)
        for y in 0..<(height / 2) {
            for x in 0..<width {
                source.setPixel(x: x, y: y, r: 255, g: 255, b: 255)
            }
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("seq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try source.writePNG(to: folder.appendingPathComponent("a.png"))
        try source.writePNG(to: folder.appendingPathComponent("b.png"))

        let decoder = try ImageSequenceDecoder(folder: folder)
        guard let frame = decoder.image(at: 0, corruption: .inert) else {
            return XCTFail("expected a frame")
        }
        // White half at the top of the source must still be at the top.
        let upper = frame.pixel(x: frame.width / 2, y: frame.height / 2 - 40)
        let lower = frame.pixel(x: frame.width / 2, y: frame.height / 2 + 40)
        XCTAssertGreaterThan(Int(upper.r), Int(lower.r) + 60, "the picture is upside down")
    }

    func testAFolderWithOneImageIsNotASequence() throws {
        // One picture is a still, and calling it a one-frame clip is a worse answer
        // than leaving it alone.
        let folder = try makeFolder(frames: 1) { "only\($0).png" }
        XCTAssertFalse(ImageSequenceDecoder.isSequence(folder))

        let two = try makeFolder(frames: 2) { "frame\($0).png" }
        XCTAssertTrue(ImageSequenceDecoder.isSequence(two))
    }

    func testAFolderWithNoImagesSaysSo() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("seq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "not a picture".write(
            to: folder.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        XCTAssertFalse(ImageSequenceDecoder.isSequence(folder))
        XCTAssertThrowsError(try ImageSequenceDecoder(folder: folder)) { error in
            XCTAssertTrue(
                (error as? ImageSequenceDecoder.SequenceError)?
                    .errorDescription?.contains("at least two") ?? false)
        }
    }

    func testTheRenderPathNeverBlocksOnADecode() throws {
        // The rule that outranks every feature: a JPEG decode on the render path is a
        // dropped frame. Asking for a frame that is not cached hands back the last one
        // rather than decoding, and a repeated frame is a far smaller problem.
        let folder = try makeFolder(frames: 200) { String(format: "f%04d.png", $0) }
        let decoder = try ImageSequenceDecoder(folder: folder)

        _ = decoder.image(at: 0, corruption: .inert)
        let started = CFAbsoluteTimeGetCurrent()
        // Far beyond anything prefetched.
        _ = decoder.image(at: 180, corruption: .inert)
        let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000

        XCTAssertLessThan(
            elapsed, 5,
            "a cache miss must return immediately, not decode — \(elapsed)ms")
    }

    // MARK: - Through the source node

    func testASourceNodeLoadsAFolderAndSteps() throws {
        // The whole point: nothing about stepping had to be written for photographs.
        let folder = try makeFolder(frames: 8) { "frame\($0).png" }
        let node = ClipSourceNode(identifier: "test.seq", context: nil)

        XCTAssertTrue(node.load(url: folder), "a folder is a clip")
        XCTAssertEqual(node.frameCount, 8)

        node.step(by: 3)
        XCTAssertEqual(node.playheadFrame, 3, "step works because it always did")

        node.seek(toNormalised: 1)
        XCTAssertEqual(node.playheadFrame, 7)
    }
}

// MARK: - Beat-locked on arrival (SPEC 153)

extension ImageSequenceTests {

    /// The whole point of the feature, per SPEC 153: a folder of photographs is a
    /// beat-locked clip, NOT a frame sequence baked to the project rate.
    ///
    /// It loaded as `.continuous` before, which meant four hundred photographs went
    /// past in thirteen seconds and everyone had to find the STEP key before the
    /// feature did the one thing it exists to do.
    func testAPhotoFolderArrivesSteppedToTheBeat() throws {
        let folder = try makeFolder(frames: 8) { "shot\($0).png" }
        let node = ClipSourceNode(identifier: "source.a", context: nil)

        XCTAssertEqual(node.timing, .continuous, "a fresh node starts continuous")
        XCTAssertTrue(node.load(url: folder), "the folder should load")
        XCTAssertEqual(
            node.timing, .stepped(subdivision: .quarter, frames: 1),
            "a stack of photographs advances one frame per quarter note")
    }

    /// The converse, and the reason the default is set on the folder branch rather
    /// than in `load` generally: a video file has its own frame rate, and stepping it
    /// to the beat by default would be wrong.
    func testAVideoFileIsLeftContinuous() throws {
        let folder = try makeFolder(frames: 3) { "f\($0).png" }
        let node = ClipSourceNode(identifier: "source.b", context: nil)
        XCTAssertTrue(node.load(url: folder))
        XCTAssertNotEqual(node.timing, .continuous, "precondition: the folder stepped it")

        // Loading something that is NOT a folder must not inherit the stepped timing
        // from whatever was there before.
        let missing = folder.appendingPathComponent("nope.mov")
        XCTAssertFalse(node.load(url: missing), "a missing file does not load")
    }
}

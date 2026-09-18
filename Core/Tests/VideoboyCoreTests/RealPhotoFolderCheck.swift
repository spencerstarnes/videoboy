//
//  RealPhotoFolderCheck.swift — the photo sequence against real photographs.
//
//  The synthetic tests prove the mechanism. This proves it against the thing it is
//  actually for: a folder of screenshots and camera photos, at mixed sizes and mixed
//  aspect ratios, which is what a person's photo folder looks like. It writes frames
//  out so they can be looked at rather than only measured.
//
//  Skipped when the folder is not there, so it never fails a clean checkout.
//

import XCTest
@testable import VideoboyCore

final class RealPhotoFolderCheck: XCTestCase {

    /// Where to put photographs for this check: `samples/photos/`.
    ///
    /// In the repo's samples directory rather than a scratch path, so anyone can drop a
    /// folder of pictures there and get the same evidence. Skipped when it is absent,
    /// so a clean checkout never fails on media it does not have.
    private var folder: URL {
        RepoPaths.samples.appendingPathComponent("photos")
    }

    func testRealPhotographsPlayAsAClip() throws {
        guard ImageSequenceDecoder.isSequence(folder) else {
            throw XCTSkip("no photo folder to check against")
        }
        Log.echoesToStandardError = false

        let decoder = try ImageSequenceDecoder(folder: folder)
        XCTAssertGreaterThan(decoder.frameCount, 10)

        let check = SelfQACheck(name: "phase-4/photo-sequence")
        var written = 0
        // Spread across the sequence rather than the first few, so the sample includes
        // whatever odd shapes are further in.
        for index in stride(from: 0, to: decoder.frameCount, by: max(decoder.frameCount / 4, 1)) {
            // Ask, wait for the prefetch, ask again — the render path deliberately
            // never blocks on a decode, so a test that reads once is testing the
            // fallback rather than the picture.
            _ = decoder.image(at: index, corruption: .inert)
            let deadline = Date().addingTimeInterval(3)
            var frame: ImageBuffer?
            while Date() < deadline {
                if let candidate = decoder.image(at: index, corruption: .inert),
                   candidate.width == StandardDefinition.width {
                    frame = candidate
                    break
                }
            }
            guard let frame else { continue }
            _ = try? check.writeImage(frame, named: String(format: "frame-%03d.png", index))
            written += 1

            XCTAssertEqual(frame.width, StandardDefinition.width)
            XCTAssertEqual(frame.height, StandardDefinition.height)
        }
        XCTAssertGreaterThan(written, 2, "expected several frames to decode")
        Log.echoesToStandardError = true
    }

    func testARealFolderLoadsIntoASourceAndSteps() throws {
        guard ImageSequenceDecoder.isSequence(folder) else {
            throw XCTSkip("no photo folder to check against")
        }
        let node = ClipSourceNode(identifier: "test.photos", context: nil)
        XCTAssertTrue(node.load(url: folder))
        XCTAssertGreaterThan(node.frameCount, 10)

        node.step(by: 5)
        XCTAssertEqual(node.playheadFrame, 5)
    }
}

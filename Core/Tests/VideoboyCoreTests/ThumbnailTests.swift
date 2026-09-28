//
//  ThumbnailTests.swift — hover-scrub frames and the scaler behind them.
//
//  The library's thumbnails are decoded frames, so the things worth testing are that
//  different positions give DIFFERENT pictures (or the scrub is a very expensive way
//  to show one frame), that the cache does not change what comes back, and that an
//  unreadable file fails quietly rather than throwing on every mouse move.
//

import XCTest
@testable import VideoboyCore

final class ThumbnailTests: XCTestCase {

    private func sampleURL(_ name: String = "motion.m2v") throws -> URL {
        let url = RepoPaths.samples.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("samples/\(name) is missing — run scripts/make-fixtures.sh")
        }
        return url
    }

    func testScrubbingGivesDifferentFramesAlongTheClip() throws {
        let url = try sampleURL()
        let thumbnails = ClipThumbnails()

        guard let start = thumbnails.frame(for: url, at: 0),
              let middle = thumbnails.frame(for: url, at: 0.5) else {
            return XCTFail("the clip produced no thumbnails")
        }
        XCTAssertNotEqual(
            start.pixels, middle.pixels,
            "scrubbing must show the clip moving, not the same frame at every position")
    }

    func testTheCacheReturnsTheSamePicture() throws {
        let url = try sampleURL()
        let thumbnails = ClipThumbnails()
        let first = thumbnails.frame(for: url, at: 0.25)
        let second = thumbnails.frame(for: url, at: 0.25)
        XCTAssertEqual(first?.pixels, second?.pixels)
    }

    func testThumbnailsAreScaledDown() throws {
        let url = try sampleURL()
        guard let frame = ClipThumbnails().poster(for: url) else {
            return XCTFail("no poster frame")
        }
        XCTAssertEqual(frame.width, ClipThumbnails.width)
        XCTAssertLessThan(
            frame.height, StandardDefinition.height,
            "a thumbnail should not be carrying a full SD frame around")
    }

    func testAnUnreadableFileFailsQuietly() {
        let thumbnails = ClipThumbnails()
        let missing = URL(fileURLWithPath: "/nonexistent/nope.mov")
        XCTAssertNil(thumbnails.frame(for: missing, at: 0))
        // Twice, because the second call takes the "already failed" path — the one
        // that stops a broken file being re-opened on every pointer move.
        XCTAssertNil(thumbnails.frame(for: missing, at: 0.5))
    }

    // MARK: - The scaler

    func testScalingKeepsTheAspectRatio() {
        var source = ImageBuffer(width: 720, height: 480)
        source.setPixel(x: 0, y: 0, r: 255, g: 0, b: 0)
        let scaled = source.scaled(toWidth: 180)
        XCTAssertEqual(scaled.width, 180)
        XCTAssertEqual(scaled.height, 120)
    }

    func testScalingAveragesRatherThanPointSampling() {
        // Alternating black and white rows, which is what interlaced SD looks like to
        // a scaler. Point-sampling would return one or the other; averaging returns
        // grey, and grey is what stops thumbnails flickering.
        var source = ImageBuffer(width: 4, height: 4)
        for y in 0..<4 {
            let value: UInt8 = y % 2 == 0 ? 0 : 255
            for x in 0..<4 {
                source.setPixel(x: x, y: y, r: value, g: value, b: value)
            }
        }
        let scaled = source.scaled(toWidth: 2)
        let sample = scaled.pixel(x: 0, y: 0)
        XCTAssertEqual(
            Int(sample.r), 127, accuracy: 2,
            "a scaled pair of black and white rows should be grey, not one of the two")
    }

    func testScalingUpIsRefusedRatherThanGuessed() {
        let source = ImageBuffer(width: 10, height: 10)
        let scaled = source.scaled(toWidth: 40)
        XCTAssertEqual(scaled.width, 10, "this is a downscaler; it should hand back the original")
    }
}

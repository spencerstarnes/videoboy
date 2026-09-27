//
//  ClipOptimizerTests.swift — Copy + Optimize's conversion (0.4.10).
//
//  An HD 16:9 clip becomes NTSC DV that the app's own DV path reads, at the canvas
//  rate, letterboxed rather than stretched; MPEG-2 output reads through the MPEG
//  decoder; a 25 fps clip is conformed to 29.97.
//

import XCTest
@testable import VideoboyCore

final class ClipOptimizerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("optimizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func fixture(_ name: String) throws -> URL {
        let url = RepoPaths.samples.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("samples/\(name) is missing — run scripts/make-fixtures.sh")
        }
        return url
    }

    func testHDBecomesLetterboxedNTSCDVAtTheCanvasRate() throws {
        let source = try fixture("hd-h264-2997.mov")
        let output = directory.appendingPathComponent("out.dv")
        let frames = try ClipOptimizer.optimize(source, to: output, preset: .performance)
        XCTAssertEqual(frames, 600, accuracy: 2, "20 s at 29.97")
        let decoder = try XCTUnwrap(ClipDecoders.open(output), "the app reads its own DV")
        XCTAssertEqual(decoder.frameCount, frames)
        let picture = try XCTUnwrap(decoder.image(at: 100, corruption: .inert))
        XCTAssertEqual(picture.width, 720)
        XCTAssertEqual(picture.height, 480)
        // 16:9 in 4:3: black bars top and bottom, picture in the middle.
        func rowLuma(_ y: Int) -> Double {
            var total = 0
            for x in stride(from: 0, to: 720, by: 8) {
                let i = (y * 720 + x) * 4
                total += Int(picture.pixels[i]) + Int(picture.pixels[i + 1]) + Int(picture.pixels[i + 2])
            }
            return Double(total) / Double(90 * 3)
        }
        XCTAssertLessThan(rowLuma(10), 30, "top bar is black")
        XCTAssertLessThan(rowLuma(470), 30, "bottom bar is black")
        XCTAssertGreaterThan(rowLuma(240), 40, "the picture is in the middle")
    }

    func test25fpsIsConformedTo2997() throws {
        let source = try fixture("hd-h264-25.mov")
        let output = directory.appendingPathComponent("conform.dv")
        let frames = try ClipOptimizer.optimize(source, to: output, preset: .performance)
        XCTAssertEqual(frames, 599, accuracy: 2, "20 s of 25 fps becomes 20 s of 29.97")
    }

    func testCompactWritesMPEG2TheWedgeReads() throws {
        let source = try fixture("motion.mov")
        let output = directory.appendingPathComponent("out.m2v")
        let frames = try ClipOptimizer.optimize(source, to: output, preset: .compact)
        let decoder = try XCTUnwrap(ClipDecoders.open(output))
        XCTAssertEqual(decoder.dataEffectFamily, .mpeg, "keeps the MPEG wedge")
        XCTAssertEqual(decoder.frameCount, frames, accuracy: 2)
        XCTAssertNotNil(decoder.image(at: 20, corruption: .inert))
    }

    func testCancelStops() throws {
        let source = try fixture("motion.mov")
        let output = directory.appendingPathComponent("cancel.dv")
        XCTAssertThrowsError(try ClipOptimizer.optimize(source, to: output, preset: .performance,
                                                         isCancelled: { true }))
    }
}

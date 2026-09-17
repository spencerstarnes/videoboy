//
//  DVDecodeBenchmark.swift — DV decode has to fit inside a frame.
//
//  Not a micro-benchmark for chasing percentages. The one thing that matters here is
//  a budget: the whole point of this app is a live SD signal at 29.97, so a frame has
//  33.4 ms for EVERYTHING — decode, the corruptor, the graph, the composite, output.
//  If decoding one DV frame ever approaches that on its own, the wedge has stopped
//  being playable and no amount of tuning elsewhere will save it.
//
//  The threshold is deliberately loose so this does not go off on a busy machine. It
//  is a cliff detector, not a stopwatch.
//

import XCTest
@testable import VideoboyCore

final class DVDecodeBenchmark: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    func testDecodingADVFrameStaysWellInsideTheFrameBudget() throws {
        let url = RepoPaths.samples.appendingPathComponent("motion.dv")
        guard FileManager.default.fileExists(atPath: url.path),
              let reader = try? DVReader(url: url) else {
            throw XCTSkip("samples/motion.dv missing — run scripts/make-fixtures.sh")
        }
        guard let decoder = try? DVDecoder() else { throw XCTSkip("no DV decoder") }

        let frames = (0..<min(reader.frameCount, 60)).compactMap { reader.frame(at: $0) }
        guard !frames.isEmpty else { throw XCTSkip("no frames in the fixture") }

        // Warm up: the first decode pays for codec setup and page faults.
        for frame in frames.prefix(5) { _ = decoder.decode(frameBytes: frame) }

        let start = Date()
        var decoded = 0
        for _ in 0..<5 {
            for frame in frames where decoder.decode(frameBytes: frame) != nil { decoded += 1 }
        }
        let millisecondsPerFrame = Date().timeIntervalSince(start) / Double(decoded) * 1000

        // Recorded so a regression is visible in the log even when it passes.
        Log.info(.dv, String(
            format: "decode benchmark: %.2f ms/frame over %d frames of %d bytes",
            millisecondsPerFrame, decoded, frames[0].count))

        XCTAssertLessThan(
            millisecondsPerFrame, 12.0,
            "DV decode is eating the frame budget — 33.4 ms has to cover decode, the "
                + "corruptor, the graph, the composite and output, not just this")
    }
}

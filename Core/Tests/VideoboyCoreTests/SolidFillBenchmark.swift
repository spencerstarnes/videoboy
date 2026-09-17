//
//  SolidFillBenchmark.swift — a solid fill must not go back to being per-pixel.
//
//  `ImageBuffer(width:height:r:g:b:)` exists because filling a frame through
//  `setPixel` pays a bounds precondition and a uniqueness check per PIXEL — 345,600
//  of them for one SD frame. In a release build that measured 1.489 ms against
//  0.233 ms, and anything painting a plate every frame (the character generator used
//  as a source, test patterns, generator backgrounds) was spending about 4% of a
//  33.4 ms frame budget putting one colour on the screen.
//
//  This asserts the RELATIONSHIP rather than a wall-clock number, because the two
//  build configurations differ by roughly six times and an absolute threshold would
//  either be flaky in debug or meaningless in release. What must stay true is that
//  the bulk path is the faster one.
//

import XCTest
@testable import VideoboyCore

final class SolidFillBenchmark: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    func testTheBulkFillBeatsFillingPixelByPixel() {
        let width = StandardDefinition.width
        let height = StandardDefinition.height
        let rounds = 10

        // Per-pixel, the way this used to be done everywhere.
        let perPixelStart = Date()
        for _ in 0..<rounds {
            var image = ImageBuffer(width: width, height: height)
            for y in 0..<height {
                for x in 0..<width { image.setPixel(x: x, y: y, r: 16, g: 16, b: 16) }
            }
            _ = image.pixel(x: 0, y: 0)
        }
        let perPixel = Date().timeIntervalSince(perPixelStart)

        let bulkStart = Date()
        for _ in 0..<rounds {
            let image = ImageBuffer(width: width, height: height, r: 16, g: 16, b: 16)
            _ = image.pixel(x: 0, y: 0)
        }
        let bulk = Date().timeIntervalSince(bulkStart)

        Log.info(.selfqa, String(
            format: "solid fill: %.3f ms/frame bulk vs %.3f ms/frame per-pixel",
            bulk / Double(rounds) * 1000, perPixel / Double(rounds) * 1000))

        XCTAssertLessThan(
            bulk, perPixel,
            "the bulk fill must stay faster than filling pixel by pixel — if this fails, "
                + "the initialiser has quietly gone back to looping setPixel")
    }

    func testTheBulkFillProducesExactlyTheSamePixels() {
        // Faster is only worth having if it is also identical.
        var byHand = ImageBuffer(width: 32, height: 16)
        for y in 0..<16 {
            for x in 0..<32 { byHand.setPixel(x: x, y: y, r: 10, g: 200, b: 30, a: 255) }
        }
        let bulk = ImageBuffer(width: 32, height: 16, r: 10, g: 200, b: 30)
        XCTAssertEqual(bulk.pixels, byHand.pixels)
    }
}

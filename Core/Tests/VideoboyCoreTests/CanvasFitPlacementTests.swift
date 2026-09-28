//
//  CanvasFitPlacementTests.swift — Fit, Fill, Stretch and Centre place a picture
//  differently in the canvas (the source panel's FIT key drives these in the FEED).
//

import XCTest
@testable import VideoboyCore

final class CanvasFitPlacementTests: XCTestCase {

    private let canvas = CanvasGeometry.standardDefinition   // 720x480, shown 4:3

    func testSixteenByNineInFourByThree() {
        let wide = 16.0 / 9.0
        let fit = canvas.placement(sourceAspect: wide, framing: .fit)
        XCTAssertEqual(fit.size.x, 1, accuracy: 0.001)
        XCTAssertEqual(fit.size.y, 0.75, accuracy: 0.001, "letterboxed")
        let fill = canvas.placement(sourceAspect: wide, framing: .fill)
        XCTAssertEqual(fill.size.y, 1, accuracy: 0.001)
        XCTAssertEqual(fill.size.x, 1.3333, accuracy: 0.001, "cropped at the sides")
        let stretch = canvas.placement(sourceAspect: wide, framing: .stretch)
        XCTAssertEqual(stretch.size, SIMD2<Float>(1, 1))
    }

    func testCentreIsNativeSize() {
        // A 1080-line picture shows 1080/480 = 2.25 canvas heights: the middle, cropped.
        let big = canvas.placement(sourceAspect: 16.0 / 9.0, framing: .centre, nativeHeight: 1080)
        XCTAssertEqual(big.size.y, 2.25, accuracy: 0.001)
        // A 240-line picture sits at half height in the middle.
        let small = canvas.placement(sourceAspect: 4.0 / 3.0, framing: .centre, nativeHeight: 240)
        XCTAssertEqual(small.size.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(small.origin.y, 0.25, accuracy: 0.001)
        // Unknown size: Centre fits rather than guessing.
        let unknown = canvas.placement(sourceAspect: 16.0 / 9.0, framing: .centre)
        XCTAssertEqual(unknown.size, canvas.placement(sourceAspect: 16.0 / 9.0, framing: .fit).size)
    }
}

//
//  TransformTests.swift — scale, rotate and flip, proved on pixels.
//
//  Geometry is the easiest thing to get backwards, because sampling runs INVERSE to
//  the visible transform: to make the picture bigger you sample a smaller region. Get
//  the direction wrong and every control does precisely the opposite of its label
//  while still looking like it works. So each test checks the DIRECTION, not just
//  that something moved.
//

import XCTest
@testable import VideoboyCore

final class TransformTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    /// A frame with a white block in the TOP-LEFT quadrant only, so every operation
    /// has an unambiguous before and after.
    private func cornerMarked() -> ImageBuffer {
        var image = ImageBuffer(width: 64, height: 64, r: 0, g: 0, b: 0)
        for y in 4..<28 {
            for x in 4..<28 { image.setPixel(x: x, y: y, r: 255, g: 255, b: 255) }
        }
        return image
    }

    private func transformed(_ settings: TransformSettings, input: ImageBuffer? = nil) throws -> ImageBuffer {
        guard let metal = MetalContext.shared,
              let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        let source = input ?? cornerMarked()
        guard let texture = metal.makeTexture(from: source, label: "transform-in") else {
            throw XCTSkip("could not upload")
        }
        let node = TransformNode(identifier: "test.transform", context: metal)
        node.settings = settings
        guard let out = node.render(
            inputs: [texture],
            context: RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil)),
              let read = renderer.readback(out) else {
            throw XCTSkip("render failed")
        }
        return read
    }

    /// Mean brightness of a quadrant, for asking where the bright block ended up.
    private func quadrant(_ image: ImageBuffer, _ corner: (x: Int, y: Int)) -> Double {
        var total = 0
        for y in corner.y..<(corner.y + 32) {
            for x in corner.x..<(corner.x + 32) { total += Int(image.pixel(x: x, y: y).r) }
        }
        return Double(total) / (32 * 32)
    }

    private var topLeft: (x: Int, y: Int) { (0, 0) }
    private var topRight: (x: Int, y: Int) { (32, 0) }
    private var bottomLeft: (x: Int, y: Int) { (0, 32) }

    func testTheDefaultsChangeNothing() throws {
        XCTAssertTrue(TransformSettings.neutral.isNeutral)
        let out = try transformed(.neutral)
        XCTAssertGreaterThan(quadrant(out, topLeft), 100, "the block should still be top-left")
    }

    func testFlipHorizontalMovesTheBlockToTheOtherSide() throws {
        let out = try transformed(TransformSettings(flipHorizontal: true))
        XCTAssertGreaterThan(quadrant(out, topRight), 100, "it should have crossed to the right")
        XCTAssertLessThan(quadrant(out, topLeft), 20, "and left the left side empty")
    }

    func testFlipVerticalMovesTheBlockDown() throws {
        let out = try transformed(TransformSettings(flipVertical: true))
        XCTAssertGreaterThan(quadrant(out, bottomLeft), 100)
        XCTAssertLessThan(quadrant(out, topLeft), 20)
    }

    func testBothFlipsTogetherLandDiagonally() throws {
        let out = try transformed(TransformSettings(flipHorizontal: true, flipVertical: true))
        XCTAssertGreaterThan(quadrant(out, (32, 32)), 100)
        XCTAssertLessThan(quadrant(out, topLeft), 20)
    }

    /// THE direction test. Scaling UP must make the picture bigger, which means
    /// sampling a SMALLER region — get the inverse backwards and this shrinks.
    func testScalingUpMakesThePictureBigger() throws {
        // A CENTRED block, and the total lit area across the whole frame. The first
        // version of this measured one quadrant with an off-centre block, and scaling
        // moved exactly as many lit pixels out of that quadrant as it grew — both
        // cases came to 576 and the test could not tell them apart while passing for
        // the wrong reason on any other input.
        var centred = ImageBuffer(width: 64, height: 64, r: 0, g: 0, b: 0)
        for y in 26..<38 {
            for x in 26..<38 { centred.setPixel(x: x, y: y, r: 255, g: 255, b: 255) }
        }
        func litPixels(_ image: ImageBuffer) -> Int {
            var count = 0
            for y in 0..<image.height {
                for x in 0..<image.width where image.pixel(x: x, y: y).r > 128 { count += 1 }
            }
            return count
        }

        let plain = litPixels(try transformed(.neutral, input: centred))
        let bigger = litPixels(try transformed(TransformSettings(scale: 2), input: centred))
        let smaller = litPixels(try transformed(TransformSettings(scale: 0.5), input: centred))

        XCTAssertGreaterThan(
            bigger, plain,
            "scale 2 must light MORE pixels — if this fails the inverse sampling is "
                + "the wrong way round and every scale control does the opposite of its label")
        XCTAssertLessThan(smaller, plain, "and scale 0.5 fewer")
    }

    func testScalingDownLeavesBlackAroundThePicture() throws {
        let smaller = try transformed(TransformSettings(scale: 0.4), input: {
            var full = ImageBuffer(width: 64, height: 64, r: 255, g: 255, b: 255)
            full.setPixel(x: 0, y: 0, r: 255, g: 255, b: 255)
            return full
        }())
        // The corners must be BLACK, not a smeared copy of the edge pixel — clamping
        // there reads as a broken render rather than a picture that has been shrunk.
        XCTAssertLessThan(Double(smaller.pixel(x: 1, y: 1).r), 20)
        XCTAssertGreaterThan(Double(smaller.pixel(x: 32, y: 32).r), 200, "the middle survives")
    }

    func testAHalfTurnPutsTheBlockDiagonallyOpposite() throws {
        let out = try transformed(TransformSettings(rotation: 0.5))
        XCTAssertGreaterThan(quadrant(out, (32, 32)), 100)
        XCTAssertLessThan(quadrant(out, topLeft), 20)
    }

    func testAFullTurnIsTheSameAsNoTurn() throws {
        var full = TransformSettings(rotation: 1.0)
        full.clampToValidRanges()
        XCTAssertEqual(full.rotation, 0, accuracy: 0.001, "a full turn wraps to zero")
    }

    func testRotationWrapsRatherThanJamming() {
        var over = TransformSettings(rotation: 1.25)
        over.clampToValidRanges()
        XCTAssertEqual(over.rotation, 0.25, accuracy: 0.001)

        var under = TransformSettings(rotation: -0.25)
        under.clampToValidRanges()
        XCTAssertEqual(under.rotation, 0.75, accuracy: 0.001, "negative rotation comes round")
    }

    func testScaleIsClampedToWhatTheShaderExpects() {
        var wild = TransformSettings(scale: 99)
        wild.clampToValidRanges()
        XCTAssertEqual(wild.scale, 4)
        var tiny = TransformSettings(scale: 0)
        tiny.clampToValidRanges()
        XCTAssertEqual(tiny.scale, 0.1)
    }

    func testEveryParameterIsWiredIntoApplyParameters() {
        let node = TransformNode(identifier: "test.transform", context: nil)
        let registry = ParamRegistry()
        registry.register(slot: node.identifier, parameters: node.parameters)
        registry.setValue(2.5, slot: node.identifier, code: .scale)
        registry.setValue(0.25, slot: node.identifier, code: .rotation)
        registry.setValue(1, slot: node.identifier, code: .flipHorizontal)
        registry.setValue(1, slot: node.identifier, code: .flipVertical)
        node.applyParameters(from: registry)

        XCTAssertEqual(node.settings.scale, 2.5, accuracy: 0.001)
        XCTAssertEqual(node.settings.rotation, 0.25, accuracy: 0.001)
        XCTAssertTrue(node.settings.flipHorizontal)
        XCTAssertTrue(node.settings.flipVertical)
        XCTAssertEqual(node.parameters.count, 5, "a new control needs a line here too")
    }

    func testTheTransformIsVisibleEndToEnd() throws {
        let out = try transformed(
            TransformSettings(scale: 0.6, rotation: 0.08, flipHorizontal: true),
            input: TestPattern.colorBars())
        let check = SelfQACheck(name: "phase-4/transform")
        _ = try? check.writeImage(out, named: "transformed-bars.png")
        XCTAssertTrue(FrameAssertions.signalPresent(out, varianceThreshold: 25))
    }
}

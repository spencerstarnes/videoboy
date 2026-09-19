//
//  TransformPositionTests.swift — the transform can move the picture, not only size it.
//

import XCTest
@testable import VideoboyCore

final class TransformPositionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    /// Offsetting must actually be a change, or the pass is skipped and the control
    /// silently does nothing — which is how a fader comes to look broken.
    func testAnOffsetIsNotNeutral() {
        XCTAssertTrue(TransformSettings.neutral.isNeutral)
        var moved = TransformSettings.neutral
        moved.offsetX = 0.25
        XCTAssertFalse(
            moved.isNeutral,
            "a moved picture must not count as neutral, or the render is skipped")
    }

    /// Clamped rather than wrapped. Rotation coming round again is a continuous
    /// gesture; a picture leaping from one edge to the other is not.
    func testOffsetIsClampedNotWrapped() {
        var settings = TransformSettings.neutral
        settings.offsetX = 4
        settings.offsetY = -9
        settings.clampToValidRanges()
        XCTAssertEqual(settings.offsetX, 1)
        XCTAssertEqual(settings.offsetY, -1)
    }

    /// And it arrives through the registry, so a MIDI knob, an LFO and a beat-synced
    /// sweep all reach it by the same route as every other parameter in the app.
    func testTheRegistryDrivesIt() {
        let node = TransformNode(identifier: "fx.one.transform", context: nil)
        let registry = ParamRegistry()
        registry.register(slot: node.identifier, parameters: node.parameters)

        XCTAssertTrue(
            node.parameters.contains { $0.code == .positionX },
            "the node must declare a position, or nothing can map to it")

        registry.setValue(0.5, slot: node.identifier, code: .positionX)
        registry.setValue(-0.25, slot: node.identifier, code: .positionY)
        node.applyParameters(from: registry)

        XCTAssertEqual(node.settings.offsetX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(node.settings.offsetY, -0.25, accuracy: 1e-9)
    }

    /// Centred is the DEFAULT, so the faders open in the middle of their travel and
    /// read as an adjustment either way rather than a push from nothing.
    func testItOpensCentred() {
        let node = TransformNode(identifier: "fx.one.transform", context: nil)
        let x = node.parameters.first { $0.code == .positionX }
        XCTAssertEqual(x?.defaultValue, 0)
        XCTAssertEqual(x?.range.lowerBound, -1)
        XCTAssertEqual(x?.range.upperBound, 1)
    }
}

// MARK: - It actually moves the picture

extension TransformPositionTests {

    /// The model tests above would all pass with a shader that ignored the offset
    /// entirely. This one renders and looks at where the light went.
    func testOffsettingMovesThePictureOnTheGPU() throws {
        guard let metal = MetalContext.shared,
              let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }

        // A bright block on the LEFT of an otherwise black frame, so "did it move and
        // which way" is answerable by comparing the two halves.
        var source = ImageBuffer(width: 320, height: 240, r: 0, g: 0, b: 0)
        for y in 90..<150 {
            for x in 40..<100 { source.setPixel(x: x, y: y, r: 255, g: 255, b: 255) }
        }
        guard let texture = metal.makeTexture(from: source, label: "offset-in") else {
            throw XCTSkip("could not upload")
        }

        func brightness(_ image: ImageBuffer, xRange: Range<Int>) -> Int {
            var total = 0
            for y in 0..<image.height {
                for x in xRange {
                    total += Int(image.pixel(x: x, y: y).r)
                }
            }
            return total
        }

        func render(_ settings: TransformSettings) throws -> ImageBuffer {
            let node = TransformNode(identifier: "test.offset", context: metal)
            node.settings = settings
            guard let out = node.render(
                inputs: [texture],
                context: RenderContext(
                    frameIndex: 0, presentationTime: 0, musicalPosition: nil)),
                  let read = renderer.readback(out) else {
                throw XCTSkip("render produced nothing")
            }
            return read
        }

        let centred = try render(.neutral)
        var shifted = TransformSettings.neutral
        shifted.offsetX = 0.5
        let moved = try render(shifted)

        let leftBefore = brightness(centred, xRange: 0..<(centred.width / 2))
        let rightBefore = brightness(centred, xRange: (centred.width / 2)..<centred.width)
        let leftAfter = brightness(moved, xRange: 0..<(moved.width / 2))
        let rightAfter = brightness(moved, xRange: (moved.width / 2)..<moved.width)

        XCTAssertGreaterThan(leftBefore, rightBefore, "precondition: the block starts on the left")
        XCTAssertGreaterThan(
            rightAfter, rightBefore,
            "a positive X offset must move the picture RIGHT — if this fails the sign "
                + "is inverted, which reads as the control working backwards")
        XCTAssertLessThan(leftAfter, leftBefore, "and take it off the left")
    }
}

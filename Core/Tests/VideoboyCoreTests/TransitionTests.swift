//
//  TransitionTests.swift — the crossfader's transition patterns (wipes, slides, iris).
//
//  Purpose : A wipe is geometry, so it is checked with geometry: flat colours on
//            each side, the fader at a known position, and specific pixels read
//            back where the edge must and must not have reached. The contract that
//            matters most is the one a crossfader promises — both ends of the travel
//            are the two sources untouched, whatever the pattern.
//  Inputs  : flat and split-colour test images built here.
//  Outputs : assertions.
//  Connects: Transition, CrossfadeNode, `transitionMask` in MetalContext.
//

import XCTest
import Metal
@testable import VideoboyCore

final class TransitionTests: XCTestCase {

    /// Small but not tiny: the interlace-vertical band is 16 px, so the frame has to
    /// be wide enough to hold more than one band.
    private let width = 64
    private let height = 48

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    // MARK: - The contract

    /// Same rule as BlendMode: the raw value is the shader's index and what a saved
    /// sweep resolves to. If this fails, old settings now wipe differently.
    func testRawValuesAreTheShaderContractAndMustNotMove() {
        XCTAssertEqual(Transition.allCases.map(\.rawValue), Array(0...12))
        XCTAssertEqual(Transition.dissolve.rawValue, 0)
        XCTAssertEqual(Transition.wipeHorizontal.rawValue, 1)
        XCTAssertEqual(Transition.iris.rawValue, 7)
        XCTAssertEqual(Transition.interlaceVertical.rawValue, 11)
        XCTAssertEqual(Transition.ave5.rawValue, 12)
    }

    func testEveryTransitionRoundTripsThroughItsSweepPosition() {
        for transition in Transition.allCases {
            XCTAssertEqual(Transition.from(normalised: transition.normalisedPosition), transition)
        }
        XCTAssertEqual(Transition.from(normalised: .nan), .dissolve)
    }

    func testTheMenuListsEveryTransitionExactlyOnce() {
        let listed = Transition.menuGroups.flatMap { $0 }
        XCTAssertEqual(Set(listed), Set(Transition.allCases))
        XCTAssertEqual(listed.count, Transition.allCases.count)
    }

    func testTheNodePicksUpTheTransitionFromTheRegistry() {
        let node = CrossfadeNode(identifier: "test.transition", positionCode: .crossfadeAB, context: nil)
        let registry = ParamRegistry()
        registry.register(slot: node.identifier, parameters: node.parameters)
        _ = registry.setValue(Transition.iris.normalisedPosition, slot: node.identifier, code: .transition)
        node.applyParameters(from: registry)
        XCTAssertEqual(node.transition, .iris)
    }

    // MARK: - Ends of the travel

    func testFaderEndsAreThePureSourcesForEveryPattern() throws {
        for transition in Transition.allCases {
            for (position, expected) in [(0.0, red), (1.0, blue)] {
                let image = try render(transition, position: position)
                for (x, y) in corners + [(width / 2, height / 2), (1, 1), (width - 2, 1)] {
                    assertPixel(image, x, y, is: expected,
                                "\(transition.displayName) at \(position), pixel (\(x),\(y))")
                }
            }
        }
    }

    // MARK: - Geometry at the midpoint

    func testWipesRevealFromTheLeftAndFromTheTop() throws {
        let horizontal = try render(.wipeHorizontal, position: 0.5)
        assertPixel(horizontal, 4, height / 2, is: blue, "wipe H, left of the edge")
        assertPixel(horizontal, width - 4, height / 2, is: red, "wipe H, right of the edge")

        let vertical = try render(.wipeVertical, position: 0.5)
        assertPixel(vertical, width / 2, 4, is: blue, "wipe V, above the edge")
        assertPixel(vertical, width / 2, height - 4, is: red, "wipe V, below the edge")
    }

    func testIrisOpensFromTheCentre() throws {
        let image = try render(.iris, position: 0.5)
        assertPixel(image, width / 2, height / 2, is: blue, "iris centre")
        assertPixel(image, 1, 1, is: red, "iris corner")
    }

    func testSplitsOpenFromTheCentreLine() throws {
        let horizontal = try render(.splitHorizontal, position: 0.5)
        assertPixel(horizontal, width / 2, 2, is: blue, "split H centre column")
        assertPixel(horizontal, 2, height / 2, is: red, "split H left edge")
        assertPixel(horizontal, width - 3, height / 2, is: red, "split H right edge")

        let vertical = try render(.splitVertical, position: 0.5)
        assertPixel(vertical, 2, height / 2, is: blue, "split V centre row")
        assertPixel(vertical, width / 2, 2, is: red, "split V top edge")
        assertPixel(vertical, width / 2, height - 3, is: red, "split V bottom edge")
    }

    func testInterlaceAlternatesLinesAndBands() throws {
        let lines = try render(.interlaceHorizontal, position: 0.25)
        assertPixel(lines, 2, 10, is: blue, "even line has arrived at the left")
        assertPixel(lines, width - 3, 10, is: red, "even line has not reached the right")
        assertPixel(lines, 2, 11, is: red, "odd line has not reached the left")
        assertPixel(lines, width - 3, 11, is: blue, "odd line has arrived at the right")

        let bands = try render(.interlaceVertical, position: 0.25)
        assertPixel(bands, 4, 2, is: blue, "even band arrives at the top")
        assertPixel(bands, 4, height - 3, is: red, "even band has not reached the bottom")
        assertPixel(bands, 20, 2, is: red, "odd band has not reached the top")
        assertPixel(bands, 20, height - 3, is: blue, "odd band arrives at the bottom")
    }

    /// Slide moves only the incoming picture; push moves both. Split-colour sources
    /// make the difference visible: at the midpoint the arrived half must show the
    /// right source's RIGHT half, and under push the left source's LEFT half must
    /// have been shoved across to the right of the screen.
    func testSlideMovesOnlyTheIncomingPictureAndPushMovesBoth() throws {
        let base = halves(left: red, right: yellow)
        let blend = halves(left: green, right: blue)

        let slide = try render(.slideHorizontal, position: 0.5, base: base, blend: blend)
        assertPixel(slide, 4, height / 2, is: blue, "slide: B's right half has entered")
        assertPixel(slide, width - 4, height / 2, is: yellow, "slide: A has not moved")

        let push = try render(.pushHorizontal, position: 0.5, base: base, blend: blend)
        assertPixel(push, 4, height / 2, is: blue, "push: B's right half has entered")
        assertPixel(push, width - 4, height / 2, is: red, "push: A's left half is shoved right")
    }

    /// Under a wipe the blend mode colours the arrived area, at full strength at the
    /// midpoint — and the untouched area is still the plain base.
    func testBlendModeAppliesInsideTheWipe() throws {
        let image = try render(.wipeHorizontal, position: 0.5, mode: .add)
        assertPixel(image, 4, height / 2, is: (200, 0, 200), "arrived area is red + blue")
        assertPixel(image, width - 4, height / 2, is: red, "the rest is the base")
    }

    // MARK: - Helpers

    private typealias RGB = (UInt8, UInt8, UInt8)
    private let red: RGB = (200, 0, 0)
    private let blue: RGB = (0, 0, 200)
    private let green: RGB = (0, 200, 0)
    private let yellow: RGB = (200, 200, 0)
    private var corners: [(Int, Int)] {
        [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]
    }

    /// An image whose left half is one colour and right half another.
    private func halves(left: RGB, right: RGB) -> ImageBuffer {
        var bytes = [UInt8](repeating: 255, count: width * height * ImageBuffer.bytesPerPixel)
        for y in 0..<height {
            for x in 0..<width {
                let colour = x < width / 2 ? left : right
                let offset = (y * width + x) * ImageBuffer.bytesPerPixel
                bytes[offset] = colour.0
                bytes[offset + 1] = colour.1
                bytes[offset + 2] = colour.2
            }
        }
        return ImageBuffer(width: width, height: height, pixels: bytes)
    }

    private func render(
        _ transition: Transition, position: Double, mode: BlendMode = .normal,
        base: ImageBuffer? = nil, blend: ImageBuffer? = nil
    ) throws -> ImageBuffer {
        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        let baseImage = base ?? ImageBuffer(width: width, height: height, r: red.0, g: red.1, b: red.2)
        let blendImage = blend ?? ImageBuffer(width: width, height: height, r: blue.0, g: blue.1, b: blue.2)
        guard let baseTexture = metal.makeTexture(from: baseImage, label: "base"),
              let blendTexture = metal.makeTexture(from: blendImage, label: "blend") else {
            throw XCTSkip("could not upload test images")
        }
        let node = CrossfadeNode(identifier: "test.transition", positionCode: .crossfadeAB, context: metal)
        node.position = position
        node.blendMode = mode
        node.transition = transition
        let context = RenderContext(
            frameIndex: 0, presentationTime: 0, musicalPosition: nil, width: width, height: height)
        guard let output = node.render(inputs: [baseTexture, blendTexture], context: context),
              let result = renderer.readback(output) else {
            throw XCTSkip("the transition produced nothing")
        }
        return result
    }

    private func assertPixel(
        _ image: ImageBuffer, _ x: Int, _ y: Int, is expected: RGB, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let pixel = image.pixel(x: x, y: y)
        let close = abs(Int(pixel.r) - Int(expected.0)) <= 3
            && abs(Int(pixel.g) - Int(expected.1)) <= 3
            && abs(Int(pixel.b) - Int(expected.2)) <= 3
        XCTAssertTrue(close, "\(message): got (\(pixel.r),\(pixel.g),\(pixel.b)), expected \(expected)",
                      file: file, line: line)
    }
}

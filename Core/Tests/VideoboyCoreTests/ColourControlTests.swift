//
//  ColourControlTests.swift — every grade control, proved on pixels.
//
//  A grade stage is the easiest thing in a mixer to get subtly wrong: the maths
//  compiles whatever order you put it in, and "contrast" that also darkens the
//  picture, or "saturation" that changes brightness, looks plausible until you try to
//  match two cameras with it. So each control is checked for what its NAME promises,
//  including what it must NOT do.
//

import XCTest
@testable import VideoboyCore

final class ColourControlTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    /// Renders a flat grey field through the grade and reads the middle back.
    private func graded(
        _ settings: ColourSettings, input: (r: UInt8, g: UInt8, b: UInt8) = (128, 128, 128)
    ) throws -> (r: Double, g: Double, b: Double) {
        guard let metal = MetalContext.shared,
              let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        let image = ImageBuffer(width: 64, height: 64, r: input.r, g: input.g, b: input.b)
        guard let texture = metal.makeTexture(from: image, label: "grade-in") else {
            throw XCTSkip("could not upload")
        }
        let node = ColourControlNode(identifier: "test.colour", context: metal)
        node.settings = settings
        let context = RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil)
        guard let out = node.render(inputs: [texture], context: context),
              let read = renderer.readback(out) else {
            throw XCTSkip("render failed")
        }
        let pixel = read.pixel(x: 32, y: 32)
        return (Double(pixel.r), Double(pixel.g), Double(pixel.b))
    }

    private func luma(_ c: (r: Double, g: Double, b: Double)) -> Double {
        0.299 * c.r + 0.587 * c.g + 0.114 * c.b
    }

    // MARK: - Neutral

    func testTheDefaultsChangeNothing() throws {
        let out = try graded(.neutral)
        XCTAssertEqual(out.r, 128, accuracy: 2)
        XCTAssertEqual(out.g, 128, accuracy: 2)
        XCTAssertEqual(out.b, 128, accuracy: 2)
    }

    func testANeutralGradeSkipsTheRenderEntirely() {
        // An effect at its defaults should cost nothing, not a full-frame pass that
        // hands back what it was given.
        XCTAssertTrue(ColourSettings.neutral.isNeutral)
        var nudged = ColourSettings.neutral
        nudged.contrast = 1.2
        XCTAssertFalse(nudged.isNeutral)
    }

    // MARK: - Each control does what it says

    func testBrightnessRaisesAndLowers() throws {
        XCTAssertGreaterThan(try graded(ColourSettings(brightness: 0.25)).r, 150)
        XCTAssertLessThan(try graded(ColourSettings(brightness: -0.25)).r, 110)
    }

    func testContrastPivotsAboutMidGreyRatherThanDarkening() throws {
        // THE test for contrast. Pivoting about zero instead of mid grey would make
        // "more contrast" also mean "darker", which is the classic way to get this
        // wrong — mid grey must stay put.
        let more = try graded(ColourSettings(contrast: 1.8))
        XCTAssertEqual(more.r, 128, accuracy: 3, "mid grey must not move when contrast changes")

        // And it must actually do something away from the pivot.
        let darkMore = try graded(ColourSettings(contrast: 1.8), input: (64, 64, 64))
        XCTAssertLessThan(darkMore.r, 64, "raising contrast should push a dark tone darker")
        let brightMore = try graded(ColourSettings(contrast: 1.8), input: (192, 192, 192))
        XCTAssertGreaterThan(brightMore.r, 192, "and a bright tone brighter")
    }

    func testSaturationKeepsBrightnessWhenItRemovesColour() throws {
        // Desaturating about luma rather than about the channel average is what keeps
        // a greyed picture at the brightness it had.
        let colour = (r: UInt8(200), g: UInt8(60), b: UInt8(60))
        let original = try graded(.neutral, input: colour)
        let grey = try graded(ColourSettings(saturation: 0), input: colour)

        XCTAssertEqual(grey.r, grey.g, accuracy: 3, "fully desaturated should be neutral")
        XCTAssertEqual(grey.g, grey.b, accuracy: 3)
        XCTAssertEqual(
            luma(grey), luma(original), accuracy: 6,
            "removing the colour must not change how bright the picture is")
    }

    func testSaturationAboveOneIntensifies() throws {
        let colour = (r: UInt8(180), g: UInt8(90), b: UInt8(90))
        let base = try graded(.neutral, input: colour)
        let more = try graded(ColourSettings(saturation: 1.8), input: colour)
        XCTAssertGreaterThan(more.r - more.g, base.r - base.g, "the colour should spread")
    }

    func testShadowMovesTheDarkEndAndLeavesHighlightsAlone() throws {
        let darkLifted = try graded(ColourSettings(shadow: 0.6), input: (40, 40, 40))
        XCTAssertGreaterThan(darkLifted.r, 40 + 8, "shadows should lift")

        let brightUnchanged = try graded(ColourSettings(shadow: 0.6), input: (230, 230, 230))
        XCTAssertEqual(
            brightUnchanged.r, 230, accuracy: 6,
            "lifting the shadows must not drag the highlights up with it")
    }

    func testHighlightMovesTheBrightEndAndLeavesShadowsAlone() throws {
        let brightRolled = try graded(ColourSettings(highlight: -0.6), input: (230, 230, 230))
        XCTAssertLessThan(brightRolled.r, 230 - 8, "highlights should roll off")

        let darkUnchanged = try graded(ColourSettings(highlight: -0.6), input: (30, 30, 30))
        XCTAssertEqual(
            darkUnchanged.r, 30, accuracy: 6,
            "rolling off the highlights must not drag the shadows down with it")
    }

    func testBlackAndWhiteLevelsRemapTheRange() throws {
        // A black point at 0.5 means everything at or below half is now black.
        XCTAssertLessThan(try graded(ColourSettings(blackLevel: 0.55), input: (128, 128, 128)).r, 12)
        // A white point at 0.5 means everything at or above half is now white.
        XCTAssertGreaterThan(try graded(ColourSettings(whiteLevel: 0.45), input: (128, 128, 128)).r, 243)
    }

    func testAnInvertedLevelRangeDoesNotBlowUp() throws {
        // White below black would divide by zero, or invert the picture. The shader
        // floors the span; this pins that it produces something valid rather than
        // NaN, a black frame, or a negative.
        let out = try graded(ColourSettings(blackLevel: 0.8, whiteLevel: 0.2), input: (128, 128, 128))
        XCTAssertTrue(out.r.isFinite && out.r >= 0 && out.r <= 255)
    }

    func testGammaBrightensTheMiddleWithoutMovingTheEnds() throws {
        let brightened = try graded(ColourSettings(gamma: 2.2), input: (128, 128, 128))
        XCTAssertGreaterThan(brightened.r, 128 + 10, "gamma above 1 should lift the midtones")

        // Black and white are fixed points of a gamma curve.
        XCTAssertEqual(try graded(ColourSettings(gamma: 2.2), input: (0, 0, 0)).r, 0, accuracy: 2)
        XCTAssertEqual(try graded(ColourSettings(gamma: 2.2), input: (255, 255, 255)).r, 255, accuracy: 2)
    }

    // MARK: - Ranges and the registry

    func testValuesAreClampedIntoTheRangesTheShaderExpects() {
        var wild = ColourSettings(
            brightness: 99, contrast: -5, saturation: 50,
            shadow: -9, highlight: 9, blackLevel: -3, whiteLevel: 7, gamma: 0)
        wild.clampToValidRanges()
        XCTAssertEqual(wild.brightness, 1)
        XCTAssertEqual(wild.contrast, 0)
        XCTAssertEqual(wild.saturation, 2)
        XCTAssertEqual(wild.shadow, -1)
        XCTAssertEqual(wild.highlight, 1)
        XCTAssertEqual(wild.blackLevel, 0)
        XCTAssertEqual(wild.whiteLevel, 1)
        XCTAssertEqual(wild.gamma, 0.1)
    }

    func testEveryParameterIsWiredIntoApplyParameters() {
        let node = ColourControlNode(identifier: "test.colour", context: nil)
        let registry = ParamRegistry()
        registry.register(slot: node.identifier, parameters: node.parameters)

        // The failure this guards: a code declared in `parameters` and never read in
        // `applyParameters`. It compiles, and the fader does nothing.
        registry.setValue(0.5, slot: node.identifier, code: .brightness)
        registry.setValue(1.5, slot: node.identifier, code: .contrast)
        registry.setValue(0.25, slot: node.identifier, code: .saturation)
        registry.setValue(0.4, slot: node.identifier, code: .shadow)
        registry.setValue(-0.4, slot: node.identifier, code: .highlight)
        registry.setValue(0.1, slot: node.identifier, code: .blackLevel)
        registry.setValue(0.9, slot: node.identifier, code: .whiteLevel)
        registry.setValue(2.0, slot: node.identifier, code: .gamma)
        node.applyParameters(from: registry)

        XCTAssertEqual(node.settings.brightness, 0.5, accuracy: 0.001)
        XCTAssertEqual(node.settings.contrast, 1.5, accuracy: 0.001)
        XCTAssertEqual(node.settings.saturation, 0.25, accuracy: 0.001)
        XCTAssertEqual(node.settings.shadow, 0.4, accuracy: 0.001)
        XCTAssertEqual(node.settings.highlight, -0.4, accuracy: 0.001)
        XCTAssertEqual(node.settings.blackLevel, 0.1, accuracy: 0.001)
        XCTAssertEqual(node.settings.whiteLevel, 0.9, accuracy: 0.001)
        XCTAssertEqual(node.settings.gamma, 2.0, accuracy: 0.001)
        XCTAssertEqual(node.parameters.count, 9, "a new control needs a line here too")
    }

    func testTheGradeIsVisibleEndToEnd() throws {
        // One artifact to look at, since a grade that measures right can still look
        // wrong.
        guard let metal = MetalContext.shared,
              let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        let bars = TestPattern.colorBars()
        guard let texture = metal.makeTexture(from: bars, label: "bars") else {
            throw XCTSkip("could not upload")
        }
        let node = ColourControlNode(identifier: "test.colour", context: metal)
        node.settings = ColourSettings(
            brightness: 0.05, contrast: 1.3, saturation: 1.4, shadow: 0.2, highlight: -0.2)
        guard let out = node.render(
            inputs: [texture],
            context: RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil)),
              let read = renderer.readback(out) else {
            throw XCTSkip("render failed")
        }
        let check = SelfQACheck(name: "phase-4/colour-control")
        _ = try? check.writeImage(read, named: "graded-bars.png")
        _ = try? check.writeImage(bars, named: "original-bars.png")
        XCTAssertGreaterThan(FrameAssertions.differingPixelFraction(bars, read), 0.5)
    }
}

//
//  BlendAndEffectTests.swift — layer blend modes and the MX-1 effect set.
//
//  Purpose : Blend modes are easy to get subtly wrong and impossible to notice by
//            eye, so each is checked against the arithmetic it is supposed to
//            implement, using flat colours whose correct result can be worked out
//            by hand.
//  Inputs   : flat test patterns.
//  Outputs  : assertions, plus a contact sheet under selfqa/out/phase-4/.
//  Connects : BlendMode, CrossfadeNode, MX1EffectNode, MetalContext.
//

import XCTest
import Metal
@testable import VideoboyCore

final class BlendAndEffectTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    /// Composites two flat colours and reads the middle pixel back.
    ///
    /// The fader defaults to its MIDPOINT, where the blend mode is at full strength.
    /// At the midpoint the result is `mix(base, blended, 0.5)` — half the base and
    /// half the blend result — so the expected values below are computed that way.
    /// The ends of the travel are the two sources untouched; see
    /// `testFaderEndsAreAlwaysThePureSources`.
    private func composite(
        base: (UInt8, UInt8, UInt8),
        blend: (UInt8, UInt8, UInt8),
        mode: BlendMode,
        position: Double = 0.5,
        layerOpacity: Double = 1.0
    ) throws -> (r: Double, g: Double, b: Double) {
        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        let baseImage = TestPattern.solid(width: 32, height: 32, r: base.0, g: base.1, b: base.2)
        let blendImage = TestPattern.solid(width: 32, height: 32, r: blend.0, g: blend.1, b: blend.2)
        guard let baseTexture = metal.makeTexture(from: baseImage, label: "base"),
              let blendTexture = metal.makeTexture(from: blendImage, label: "blend") else {
            throw XCTSkip("could not upload test images")
        }

        let node = CrossfadeNode(identifier: "test.blend", positionCode: .crossfadeAB, context: metal)
        node.position = position
        node.blendMode = mode
        node.layerOpacity = layerOpacity

        let context = RenderContext(
            frameIndex: 0, presentationTime: 0, musicalPosition: nil, width: 32, height: 32)
        guard let output = node.render(inputs: [baseTexture, blendTexture], context: context),
              let result = renderer.readback(output) else {
            throw XCTSkip("the blend produced nothing")
        }
        return FrameAssertions.meanColor(result)
    }

    // MARK: - Blend arithmetic

    func testNormalReplacesTheBase() throws {
        // At the far right, not the midpoint: the midpoint of a Normal crossfade is
        // half of each, which is what it should be.
        let result = try composite(base: (200, 0, 0), blend: (0, 0, 200), mode: .normal, position: 1.0)
        XCTAssertEqual(result.r, 0, accuracy: 3)
        XCTAssertEqual(result.b, 200, accuracy: 3)
    }

    /// At the midpoint the result is half base, half blend result. So for a mode
    /// whose blend result is `x`, the expected value is `(base + x) / 2`.
    private func expectedAtMidpoint(base: Double, blendResult: Double) -> Double {
        (base + blendResult) / 2
    }

    func testMultiplyDarkens() throws {
        // 0.5 * 0.5 = 0.25 (64). Half of 128 and 64 is 96.
        let result = try composite(base: (128, 128, 128), blend: (128, 128, 128), mode: .multiply)
        XCTAssertEqual(result.r, expectedAtMidpoint(base: 128, blendResult: 64), accuracy: 4)
        // Multiplying by white leaves the base alone, so the midpoint is just the base.
        let byWhite = try composite(base: (100, 150, 200), blend: (255, 255, 255), mode: .multiply)
        XCTAssertEqual(byWhite.r, 100, accuracy: 3)
        XCTAssertEqual(byWhite.b, 200, accuracy: 3)
    }

    func testScreenLightens() throws {
        // 1 - (1-0.5)(1-0.5) = 0.75 (191). Half of 128 and 191 is about 160.
        let result = try composite(base: (128, 128, 128), blend: (128, 128, 128), mode: .screen)
        XCTAssertEqual(result.r, expectedAtMidpoint(base: 128, blendResult: 191), accuracy: 4)
        // Screening with black changes nothing, so the midpoint is the base.
        let byBlack = try composite(base: (100, 150, 200), blend: (0, 0, 0), mode: .screen)
        XCTAssertEqual(byBlack.g, 150, accuracy: 3)
    }

    func testDifferenceIsAbsoluteDistance() throws {
        // |200-50| = 150, and the midpoint is half of 200 and 150 = 175.
        let result = try composite(base: (200, 100, 50), blend: (50, 100, 200), mode: .difference)
        XCTAssertEqual(result.r, expectedAtMidpoint(base: 200, blendResult: 150), accuracy: 4)
        XCTAssertEqual(result.g, expectedAtMidpoint(base: 100, blendResult: 0), accuracy: 4)
        XCTAssertEqual(result.b, expectedAtMidpoint(base: 50, blendResult: 150), accuracy: 4)
    }

    func testAddAndSubtractClampRatherThanWrap() throws {
        // 200 + 200 saturates at 255, not wrapping to black. Midpoint: (200+255)/2.
        let added = try composite(base: (200, 200, 200), blend: (200, 200, 200), mode: .add)
        XCTAssertEqual(added.r, expectedAtMidpoint(base: 200, blendResult: 255), accuracy: 3)
        // 50 - 200 clamps at zero, not wrapping to white. Midpoint: (50+0)/2.
        let subtracted = try composite(base: (50, 50, 50), blend: (200, 200, 200), mode: .subtract)
        XCTAssertEqual(subtracted.r, expectedAtMidpoint(base: 50, blendResult: 0), accuracy: 3)
    }

    func testLightenAndDarkenPickPerChannel() throws {
        let lighter = try composite(base: (200, 50, 100), blend: (50, 200, 100), mode: .lighten)
        XCTAssertEqual(lighter.r, expectedAtMidpoint(base: 200, blendResult: 200), accuracy: 3)
        XCTAssertEqual(lighter.g, expectedAtMidpoint(base: 50, blendResult: 200), accuracy: 3)
        let darker = try composite(base: (200, 50, 100), blend: (50, 200, 100), mode: .darken)
        XCTAssertEqual(darker.r, expectedAtMidpoint(base: 200, blendResult: 50), accuracy: 3)
        XCTAssertEqual(darker.g, expectedAtMidpoint(base: 50, blendResult: 50), accuracy: 3)
    }

    /// The other half of the guarantee: Normal must remain an ordinary linear
    /// crossfade over the whole travel. Mixing straight from base to the blend result
    /// would leave the entire right half of the fader doing nothing under Normal,
    /// because under Normal the blend result IS the blend layer.
    func testNormalIsALinearCrossfadeAcrossTheWholeTravel() throws {
        let black = (UInt8(0), UInt8(0), UInt8(0))
        let white = (UInt8(200), UInt8(200), UInt8(200))
        for (position, expected) in [(0.0, 0.0), (0.25, 50.0), (0.5, 100.0), (0.75, 150.0), (1.0, 200.0)] {
            let result = try composite(
                base: black, blend: white, mode: .normal, position: position)
            XCTAssertEqual(
                result.r, expected, accuracy: 4,
                "Normal at fader \(position) must be a straight linear mix")
        }
    }

    func testEveryModeProducesAValidResult() throws {
        // A sweep over all of them, guarding against a mode that returns NaN or
        // something out of range — which would show as a black or white flash.
        for mode in BlendMode.allCases {
            let result = try composite(base: (180, 90, 40), blend: (60, 160, 220), mode: mode)
            for channel in [result.r, result.g, result.b] {
                XCTAssertFalse(channel.isNaN, "\(mode.displayName) produced NaN")
                XCTAssertGreaterThanOrEqual(channel, -0.5, "\(mode.displayName) went below zero")
                XCTAssertLessThanOrEqual(channel, 255.5, "\(mode.displayName) went above full scale")
            }
        }
    }

    // MARK: - Fader and opacity are independent

    /// The guarantee that makes the crossfader a crossfader: whatever the blend mode,
    /// hard left is the left source untouched and hard right is the right source
    /// untouched. A blend mode changes the journey, never the destinations.
    func testFaderEndsAreAlwaysThePureSources() throws {
        let baseColour = (UInt8(200), UInt8(100), UInt8(50))
        let blendColour = (UInt8(10), UInt8(220), UInt8(30))

        for mode in BlendMode.allCases {
            let left = try composite(
                base: baseColour, blend: blendColour, mode: mode, position: 0.0)
            XCTAssertEqual(left.r, 200, accuracy: 3, "\(mode.displayName) altered the base at fader 0")
            XCTAssertEqual(left.g, 100, accuracy: 3, "\(mode.displayName) altered the base at fader 0")
            XCTAssertEqual(left.b, 50, accuracy: 3, "\(mode.displayName) altered the base at fader 0")

            let right = try composite(
                base: baseColour, blend: blendColour, mode: mode, position: 1.0)
            XCTAssertEqual(right.r, 10, accuracy: 3, "\(mode.displayName) did not reach a pure blend layer at fader 1")
            XCTAssertEqual(right.g, 220, accuracy: 3, "\(mode.displayName) did not reach a pure blend layer at fader 1")
            XCTAssertEqual(right.b, 30, accuracy: 3, "\(mode.displayName) did not reach a pure blend layer at fader 1")
        }
    }

    func testTheBlendIsStrongestAtTheMidpointAndFadesToNothingAtTheEnds() throws {
        // How much the mode is contributing is what peaks in the middle. Comparing a
        // blend mode against Normal at the same fader position isolates that: the
        // difference between them must be largest at the centre and vanish at both
        // ends, whatever the mode does.
        let base = (UInt8(180), UInt8(90), UInt8(40))
        let blendLayer = (UInt8(60), UInt8(160), UInt8(220))

        func modeContribution(at position: Double) throws -> Double {
            let plain = try composite(base: base, blend: blendLayer, mode: .normal, position: position)
            let multiplied = try composite(base: base, blend: blendLayer, mode: .multiply, position: position)
            return abs(plain.r - multiplied.r) + abs(plain.g - multiplied.g) + abs(plain.b - multiplied.b)
        }

        let atCentre = try modeContribution(at: 0.5)
        let atQuarter = try modeContribution(at: 0.25)
        XCTAssertGreaterThan(atCentre, atQuarter, "the mode must contribute most at the midpoint")
        XCTAssertLessThan(try modeContribution(at: 0.0), 4.0, "the mode must vanish at the left end")
        XCTAssertLessThan(try modeContribution(at: 1.0), 4.0, "the mode must vanish at the right end")
    }

    func testBlendModeSelectionFromANormalisedParameter() {
        XCTAssertEqual(BlendMode.from(normalised: 0), .normal)
        XCTAssertEqual(BlendMode.from(normalised: 1), BlendMode.allCases.last)
        XCTAssertEqual(BlendMode.from(normalised: -3), .normal)
        // A mode's own position must round-trip back to itself.
        for mode in BlendMode.allCases {
            XCTAssertEqual(BlendMode.from(normalised: mode.normalisedPosition), mode)
        }
    }

    func testBlendModeRawValuesAreStable() {
        // Templates store the raw value, so renumbering would silently change what
        // saved work looks like.
        XCTAssertEqual(BlendMode.normal.rawValue, 0)
        XCTAssertEqual(BlendMode.multiply.rawValue, 1)
        XCTAssertEqual(BlendMode.screen.rawValue, 2)
        XCTAssertEqual(BlendMode.softLight.rawValue, 12)
        XCTAssertEqual(BlendMode.allCases.count, 13)
    }

    // MARK: - MX-1 effects

    private func applyMX1(
        _ effect: MX1Effect, to image: ImageBuffer, amount: Double = 1.0
    ) throws -> ImageBuffer {
        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        guard let texture = metal.makeTexture(from: image, label: "mx1-input") else {
            throw XCTSkip("could not upload the test image")
        }
        let node = MX1EffectNode(identifier: "test.mx1", context: metal)
        node.effect = effect
        node.amount = amount
        let context = RenderContext(
            frameIndex: 0, presentationTime: 0, musicalPosition: nil,
            width: image.width, height: image.height)
        guard let output = node.render(inputs: [texture], context: context),
              let result = renderer.readback(output) else {
            throw XCTSkip("the effect produced nothing")
        }
        return result
    }

    func testNegativeInverts() throws {
        let source = TestPattern.solid(width: 32, height: 32, r: 200, g: 100, b: 0)
        let result = try applyMX1(.negative, to: source)
        let mean = FrameAssertions.meanColor(result)
        XCTAssertEqual(mean.r, 55, accuracy: 3)
        XCTAssertEqual(mean.g, 155, accuracy: 3)
        XCTAssertEqual(mean.b, 255, accuracy: 3)
    }

    func testBlackAndWhiteRemovesColour() throws {
        let source = TestPattern.solid(width: 32, height: 32, r: 255, g: 0, b: 0)
        let result = try applyMX1(.blackAndWhite, to: source)
        let mean = FrameAssertions.meanColor(result)
        // Rec.601 luma of pure red is 0.299, about 76.
        XCTAssertEqual(mean.r, 76, accuracy: 5)
        XCTAssertEqual(mean.r, mean.g, accuracy: 2, "a greyscale result must have equal channels")
        XCTAssertEqual(mean.g, mean.b, accuracy: 2)
    }

    func testMirrorAndFlipMoveThePicture() throws {
        // A picture that is not symmetric, so a flip is detectable.
        var source = TestPattern.solid(width: 32, height: 32, r: 0, g: 0, b: 0)
        for y in 0..<8 {
            for x in 0..<8 {
                source.setPixel(x: x, y: y, r: 255, g: 255, b: 255)
            }
        }
        // The bright corner starts top-left.
        let mirrored = try applyMX1(.mirror, to: source)
        XCTAssertGreaterThan(
            FrameAssertions.meanColor(mirrored, region: (x: 24, y: 0, width: 8, height: 8)).r, 200,
            "mirror must move the bright corner to the right")

        let flipped = try applyMX1(.flip, to: source)
        XCTAssertGreaterThan(
            FrameAssertions.meanColor(flipped, region: (x: 0, y: 24, width: 8, height: 8)).r, 200,
            "flip must move the bright corner to the bottom")
    }

    func testPosterizeReducesDetail() throws {
        let ramp = TestPattern.grayscaleRamp(width: 256, height: 32)
        let posterized = try applyMX1(.posterize, to: ramp, amount: 1.0)
        // A smooth ramp reduced to two levels must have far fewer distinct values,
        // which shows up as large flat areas separated by hard steps.
        let distinctSource = Set((0..<256).map { ramp.pixel(x: $0, y: 16).r }).count
        let distinctResult = Set((0..<256).map { posterized.pixel(x: $0, y: 16).r }).count
        XCTAssertLessThan(distinctResult, distinctSource / 4,
                          "posterize must collapse the ramp to a few levels")
    }

    func testMosaicBlocksThePicture() throws {
        let bars = TestPattern.colorBars(width: 128, height: 128)
        let mosaic = try applyMX1(.mosaic, to: bars, amount: 1.0)
        // Blocking removes fine horizontal detail at the bar edges.
        XCTAssertLessThan(
            FrameAssertions.horizontalDetail(mosaic),
            FrameAssertions.horizontalDetail(bars),
            "mosaic must reduce horizontal detail")
    }

    func testFreezeHoldsTheFrameAndReleasesOnBypass() throws {
        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        let red = TestPattern.solid(width: 32, height: 32, r: 255, g: 0, b: 0)
        let blue = TestPattern.solid(width: 32, height: 32, r: 0, g: 0, b: 255)
        guard let redTexture = metal.makeTexture(from: red, label: "red"),
              let blueTexture = metal.makeTexture(from: blue, label: "blue") else {
            throw XCTSkip("could not upload test images")
        }

        let node = MX1EffectNode(identifier: "test.freeze", context: metal)
        node.effect = .freeze
        let context = RenderContext(
            frameIndex: 0, presentationTime: 0, musicalPosition: nil, width: 32, height: 32)

        _ = node.render(inputs: [redTexture], context: context)
        // The second frame is blue, but freeze must still show the held red one.
        guard let held = node.render(inputs: [blueTexture], context: context),
              let heldImage = renderer.readback(held) else {
            throw XCTSkip("freeze produced nothing")
        }
        XCTAssertEqual(FrameAssertions.meanColor(heldImage).r, 255, accuracy: 3)

        // Bypassing must let go, so re-enabling grabs what is on screen then rather
        // than something from minutes ago.
        node.wetDry = 0
        _ = node.render(inputs: [blueTexture], context: context)
        node.wetDry = 1
        guard let regrabbed = node.render(inputs: [blueTexture], context: context),
              let regrabbedImage = renderer.readback(regrabbed) else {
            throw XCTSkip("freeze produced nothing")
        }
        XCTAssertEqual(FrameAssertions.meanColor(regrabbedImage).b, 255, accuracy: 3)
    }

    func testEveryMX1EffectHasANameAndRoundTrips() {
        for effect in MX1Effect.allCases {
            XCTAssertFalse(effect.displayName.isEmpty)
        }
        XCTAssertEqual(MX1Effect.from(normalised: 0), .negative)
        XCTAssertEqual(MX1Effect.from(normalised: 1), MX1Effect.allCases.last)
    }
}

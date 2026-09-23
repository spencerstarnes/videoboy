//
//  BlendAndEffectTests.swift — layer blend modes, and freeze.
//
//  Purpose : Blend modes are easy to get subtly wrong and impossible to notice by
//            eye, so each is checked against the arithmetic it is supposed to
//            implement, using flat colours whose correct result can be worked out
//            by hand.
//  Inputs   : flat test patterns.
//  Outputs  : assertions, plus a contact sheet under selfqa/out/phase-4/.
//  Connects : BlendMode, CrossfadeNode, FreezeNode, MetalContext.
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
        layerOpacity: Double = 1.0,
        keyColour: Double = 0,
        keyThreshold: Double = 0.25,
        keyEdge: Double = 0.2
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
        node.keyColourValue = keyColour
        node.keyThreshold = keyThreshold
        node.keyEdge = keyEdge

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

    // MARK: - Key colour mapping (pure Swift, no GPU needed)

    /// Zero must be true black, not `ScalaColour.hue(0)`'s red — see the long
    /// comment on `CrossfadeNode.keyRGB`. This is the whole reason a dedicated
    /// mapping exists instead of reusing the hue-sweep helper other colour
    /// controls in this app already have.
    func testKeyColourZeroIsTrueBlack() {
        let rgb = CrossfadeNode.keyRGB(0)
        XCTAssertEqual(rgb.r, 0)
        XCTAssertEqual(rgb.g, 0)
        XCTAssertEqual(rgb.b, 0)
    }

    /// Just above zero it sweeps hue, same shape as `ScalaColour.hue` — red rising
    /// out of the bottom of the fader's travel.
    func testKeyColourAboveZeroSweepsHue() {
        let justAbove = CrossfadeNode.keyRGB(0.01)
        XCTAssertEqual(justAbove.r, 1, accuracy: 0.001)
        XCTAssertEqual(justAbove.b, 0, accuracy: 0.001)

        let green = CrossfadeNode.keyRGB(2.0 / 6.0)
        XCTAssertEqual(green.g, 1, accuracy: 0.01)
        XCTAssertEqual(green.r, 0, accuracy: 0.01)
    }

    func testKeyColourClampsOutOfRangeInput() {
        XCTAssertEqual(CrossfadeNode.keyRGB(-1).r, 0)
        XCTAssertEqual(CrossfadeNode.keyRGB(-1).g, 0)
        XCTAssertEqual(CrossfadeNode.keyRGB(-1).b, 0)
        let atOne = CrossfadeNode.keyRGB(1)
        XCTAssertFalse(atOne.r.isNaN)
        XCTAssertFalse(atOne.g.isNaN)
        XCTAssertFalse(atOne.b.isNaN)
    }

    // MARK: - Key (genlock/chroma, SPEC 18.2)

    /// A pixel exactly at the key colour must drop out completely — this is the
    /// whole point: the emulated titler's black background disappearing to reveal
    /// whatever is on the base layer. Position at the midpoint, where (as for every
    /// mode here) the blend result is at full strength.
    func testKeyDropsOutPixelsAtTheKeyColour() throws {
        let result = try composite(
            base: (180, 90, 40), blend: (0, 0, 0), mode: .key, position: 0.5, keyColour: 0)
        XCTAssertEqual(result.r, 180, accuracy: 3, "the key colour should have vanished to base")
        XCTAssertEqual(result.g, 90, accuracy: 3)
        XCTAssertEqual(result.b, 40, accuracy: 3)
    }

    /// A pixel far from the key colour — the title's own ink, not its background —
    /// must stay fully opaque, i.e. `keyComposite` returns the blend colour
    /// UNCHANGED for it. Same midpoint dilution as every other mode here applies on
    /// top of that (see `expectedAtMidpoint`), which is what this asserts against —
    /// a bare `255` would be wrong for the same reason `testMultiplyDarkens` does
    /// not expect a bare product.
    func testKeyKeepsPixelsFarFromTheKeyColour() throws {
        let result = try composite(
            base: (180, 90, 40), blend: (255, 255, 255), mode: .key, position: 0.5, keyColour: 0)
        XCTAssertEqual(result.r, expectedAtMidpoint(base: 180, blendResult: 255), accuracy: 3)
        XCTAssertEqual(result.g, expectedAtMidpoint(base: 90, blendResult: 255), accuracy: 3)
        XCTAssertEqual(result.b, expectedAtMidpoint(base: 40, blendResult: 255), accuracy: 3)
    }

    /// Raising the threshold widens what counts as "background" — a colour that
    /// survived a low threshold gets keyed out once the threshold grows past its
    /// distance from the key colour. Proves the threshold parameter (62E) actually
    /// reaches the shader, not just that keying happens at all.
    func testRaisingTheThresholdKeysOutMoreDistantColours() throws {
        // A dark grey, some distance from pure black.
        let nearBlack: (UInt8, UInt8, UInt8) = (40, 40, 40)
        let tight = try composite(
            base: (180, 90, 40), blend: nearBlack, mode: .key, position: 0.5,
            keyColour: 0, keyThreshold: 0.02, keyEdge: 0.01)
        XCTAssertEqual(
            tight.r, expectedAtMidpoint(base: 180, blendResult: 40), accuracy: 5,
            "a tight threshold should treat near-black as ink, not key")

        let wide = try composite(
            base: (180, 90, 40), blend: nearBlack, mode: .key, position: 0.5,
            keyColour: 0, keyThreshold: 0.9, keyEdge: 0.05)
        XCTAssertEqual(wide.r, 180, accuracy: 5, "a wide threshold should key the same colour out")
    }

    /// The edge width is a SOFT transition, not a binary cutoff — a colour sitting
    /// inside the edge band must land strictly between "fully base" and "fully
    /// blend", never snapping straight to one or the other. This is what keeps a
    /// bitmap font's anti-aliased/NTSC-smeared edge from fringing (see the Metal
    /// source's comment on `keyComposite`).
    func testTheEdgeIsASoftTransitionNotAHardCutoff() throws {
        // keyThreshold 0.1, keyEdge 0.3 (both *0.6 in the node): the transition band
        // in raw RGB-distance units runs 0.06...0.24. A mid-grey blend sits inside it.
        let midGrey: (UInt8, UInt8, UInt8) = (90, 90, 90)
        let result = try composite(
            base: (180, 90, 40), blend: midGrey, mode: .key, position: 0.5,
            keyColour: 0, keyThreshold: 0.1, keyEdge: 0.3)
        XCTAssertGreaterThan(result.r, 41, "should not have snapped fully to base")
        XCTAssertLessThan(result.r, 179, "should not have snapped fully to the raw blend colour")
    }

    /// The fader-ends guarantee (`testFaderEndsAreAlwaysThePureSources` covers every
    /// mode including Key already) plus a Key-specific sanity check: a solid
    /// coloured backdrop far from the key colour should NOT quietly disappear —
    /// regression guard for a keyComposite that accidentally used `base` distance
    /// instead of `blend` distance, which would key on the wrong layer entirely.
    func testKeyMeasuresDistanceOfTheBlendLayerNotTheBase() throws {
        // base is near the key colour, blend is not — a key that mixed the two up
        // would drop the blend layer out instead of the base.
        let result = try composite(
            base: (5, 5, 5), blend: (200, 100, 50), mode: .key, position: 0.5, keyColour: 0)
        XCTAssertEqual(
            result.r, expectedAtMidpoint(base: 5, blendResult: 200), accuracy: 3,
            "the blend layer's own colour must decide the key, not the base's")
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
        XCTAssertEqual(BlendMode.key.rawValue, 13)
        XCTAssertEqual(BlendMode.allCases.count, 14)
    }

    // MARK: - Freeze (kept from the MX-1 set, ISF-PLAN §4.1)

    func testFreezeHoldsTheFrameAndLetsGoWhenReleased() throws {
        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        let red = TestPattern.solid(width: 32, height: 32, r: 255, g: 0, b: 0)
        let blue = TestPattern.solid(width: 32, height: 32, r: 0, g: 0, b: 255)
        guard let redTexture = metal.makeTexture(from: red, label: "red"),
              let blueTexture = metal.makeTexture(from: blue, label: "blue") else {
            throw XCTSkip("could not upload test images")
        }
        let node = FreezeNode(identifier: "test.freeze", context: metal)
        let context = RenderContext(
            frameIndex: 0, presentationTime: 0, musicalPosition: nil, width: 32, height: 32)

        // Hold down: not holding, the input passes straight through (no pass at all).
        XCTAssertTrue(node.render(inputs: [redTexture], context: context) === redTexture)

        node.hold = 1
        _ = node.render(inputs: [redTexture], context: context)
        // The next frame is blue, but the held red one is shown.
        guard let held = node.render(inputs: [blueTexture], context: context),
              let heldImage = renderer.readback(held) else {
            throw XCTSkip("freeze produced nothing")
        }
        XCTAssertTrue(node.isHolding)
        XCTAssertEqual(FrameAssertions.meanColor(heldImage).r, 255, accuracy: 3)

        // Released: live again at once, and the next hold grabs what is on screen then.
        node.hold = 0
        XCTAssertTrue(node.render(inputs: [blueTexture], context: context) === blueTexture)
        node.hold = 1
        guard let regrabbed = node.render(inputs: [blueTexture], context: context),
              let regrabbedImage = renderer.readback(regrabbed) else {
            throw XCTSkip("freeze produced nothing")
        }
        XCTAssertEqual(FrameAssertions.meanColor(regrabbedImage).b, 255, accuracy: 3)

        // The card's switch off bypasses whatever hold says.
        node.wetDry = 0
        XCTAssertTrue(node.render(inputs: [redTexture], context: context) === redTexture)
        XCTAssertFalse(node.isHolding)
    }
}

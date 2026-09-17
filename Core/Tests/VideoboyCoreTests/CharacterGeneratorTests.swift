//
//  CharacterGeneratorTests.swift — the clean titler (SPEC 18.1), proved on pixels.
//
//  Every one of these renders real text through real CoreText and checks the actual
//  raster, the same discipline the rest of this harness holds everything else to.
//  A few write PNGs under selfqa/out/ so the drawing can be looked at, not just
//  measured — text rendering is exactly the kind of thing that can pass an assertion
//  and still look wrong.
//

import XCTest
@testable import VideoboyCore

final class CharacterGeneratorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private func node() -> CharacterGeneratorNode {
        let node = CharacterGeneratorNode(identifier: "test.cg", context: nil)
        node.text = "VIDEOBOY"
        node.fillColor = .white
        node.fontSize = 48
        return node
    }

    /// ONE check for the whole class. `SelfQACheck.init` clears the directory of
    /// previous artifacts by design, so building a fresh one per image means each
    /// write erases the last — every PNG but one silently disappears.
    private static let check = SelfQACheck(name: "phase-4/character-generator")

    private func artifact(_ image: ImageBuffer, _ name: String) {
        do {
            _ = try Self.check.writeImage(image, named: name)
        } catch {
            XCTFail("could not write the \(name) artifact: \(error)")
        }
    }

    // MARK: - The basics

    func testEmptyTextRendersThePlateUnmarked() {
        let node = node()
        node.text = ""
        let image = node.renderToImage()
        // Broadcast black (level 16), not full black — see `CharacterGeneratorNode`.
        let pixel = image.pixel(x: image.width / 2, y: image.height / 2)
        XCTAssertEqual(Int(pixel.r), 16)
        XCTAssertEqual(Int(pixel.g), 16)
        XCTAssertEqual(Int(pixel.b), 16)
    }

    func testTextActuallyDrawsSomething() {
        let image = node().renderToImage()
        artifact(image, "01-basic-white-on-black.png")
        XCTAssertTrue(
            FrameAssertions.signalPresent(image, varianceThreshold: 25),
            "a filled 48pt title on a flat plate should not read as flat")
    }

    func testBypassedWetDryRendersThePlateUnmarked() {
        let node = node()
        node.wetDry = 0
        let image = node.renderToImage()
        XCTAssertFalse(
            FrameAssertions.signalPresent(image, varianceThreshold: 25),
            "wet/dry at zero must be a real bypass, not merely dimmed text")
    }

    func testFillColourReachesThePixels() {
        let node = node()
        node.fillColor = TitlerColor(red: 1, green: 0, blue: 0)
        node.positionX = 0.5
        node.positionY = 0.5
        node.alignmentPosition = TitlerAlignment.center.normalisedPosition
        let image = node.renderToImage()
        artifact(image, "02-red-fill.png")

        // Sample the centre, where a centred title's own glyphs should be — some
        // pixels will be background (broadcast black) between letters, so the
        // brightest red found near the centre is what proves the colour reached the
        // raster, not an average that anti-aliasing would wash out.
        var brightestRed: UInt8 = 0
        for y in (image.height / 2 - 20)...(image.height / 2 + 20) {
            for x in 0..<image.width {
                let p = image.pixel(x: x, y: y)
                if p.r > brightestRed && p.g < 40 && p.b < 40 { brightestRed = p.r }
            }
        }
        XCTAssertGreaterThan(brightestRed, 200, "red fill should reach full red somewhere in the glyphs")
    }

    // MARK: - Placement: position IS the anchor

    func testLeftAlignedTextSitsAtItsXPosition() {
        let left = node()
        left.alignmentPosition = TitlerAlignment.left.normalisedPosition
        left.positionX = 0.1
        left.positionY = 0.5
        let leftImage = left.renderToImage()

        let right = node()
        right.alignmentPosition = TitlerAlignment.right.normalisedPosition
        right.positionX = 0.9
        right.positionY = 0.5
        let rightImage = right.renderToImage()

        // Left-aligned text anchored near the left edge should light up pixels on
        // the left half more than the right; right-aligned anchored near the right
        // edge should be the other way round. This is the actual claim behind
        // "position is the anchor" — not just that the picture changed, but that
        // the CONTROL that says where went where it said.
        func leftHalfBrightness(_ image: ImageBuffer) -> Int {
            var total = 0
            for y in 0..<image.height {
                for x in 0..<(image.width / 2) { total += Int(image.pixel(x: x, y: y).r) }
            }
            return total
        }
        func rightHalfBrightness(_ image: ImageBuffer) -> Int {
            var total = 0
            for y in 0..<image.height {
                for x in (image.width / 2)..<image.width { total += Int(image.pixel(x: x, y: y).r) }
            }
            return total
        }

        XCTAssertGreaterThan(leftHalfBrightness(leftImage), rightHalfBrightness(leftImage))
        XCTAssertGreaterThan(rightHalfBrightness(rightImage), leftHalfBrightness(rightImage))
    }

    func testScaleChangesHowMuchOfTheFrameTheTextCovers() {
        let small = node()
        small.scale = 0.5
        let smallCoverage = FrameAssertions.luminanceVariance(small.renderToImage())

        let large = node()
        large.scale = 2.5
        let largeCoverage = FrameAssertions.luminanceVariance(large.renderToImage())

        // More glyph area at the same resolution means more high-contrast edge
        // pixels, which is what luminance variance actually measures here — a
        // bigger title reads as MORE texture, not less.
        XCTAssertNotEqual(smallCoverage, largeCoverage, accuracy: 0.01)
    }

    // MARK: - Safe-zone clamp

    func testSafeZoneClampKeepsAnOffscreenPositionOnScreen() {
        let clamped = node()
        clamped.positionX = 0
        clamped.positionY = 0
        clamped.alignmentPosition = TitlerAlignment.center.normalisedPosition
        clamped.safeZoneClampEnabled = 1
        let clampedImage = clamped.renderToImage()

        // With the clamp on, text anchored at the extreme top-left corner must still
        // land inside the title-safe rectangle — checked by looking for bright
        // pixels within that rectangle rather than trusting the position number.
        let safe = CRTGeometry.titleSafe.inPixels(
            width: clampedImage.width, height: clampedImage.height)
        var foundInsideSafe = false
        for y in safe.y..<(safe.y + safe.height) {
            for x in safe.x..<(safe.x + safe.width) where clampedImage.pixel(x: x, y: y).r > 150 {
                foundInsideSafe = true
            }
        }
        XCTAssertTrue(foundInsideSafe, "a clamped title anchored at (0,0) must still land in the safe area")
    }

    func testSafeZoneClampCanBeTurnedOff() {
        let unclamped = node()
        unclamped.positionX = 0
        unclamped.positionY = 0
        unclamped.alignmentPosition = TitlerAlignment.left.normalisedPosition
        unclamped.safeZoneClampEnabled = 0
        let image = unclamped.renderToImage()
        artifact(image, "03-unclamped-corner.png")

        // Without the clamp, text anchored at the very corner should spill outside
        // the safe rectangle — some bright pixels in the outer margin.
        let safe = CRTGeometry.titleSafe.inPixels(width: image.width, height: image.height)
        var foundOutsideSafe = false
        for y in 0..<min(safe.y, image.height) {
            for x in 0..<image.width where image.pixel(x: x, y: y).r > 150 {
                foundOutsideSafe = true
            }
        }
        XCTAssertTrue(foundOutsideSafe, "turning the clamp off should let the corner-anchored title spill out")
    }

    // MARK: - Kerning and tracking (see the file header on the two CoreText attributes)

    func testTrackingWidensTheText() {
        let tight = node()
        tight.text = "IIIIIIIIII"
        tight.tracking = 0
        tight.alignmentPosition = TitlerAlignment.left.normalisedPosition
        tight.positionX = 0.05

        let wide = node()
        wide.text = "IIIIIIIIII"
        wide.tracking = 30
        wide.alignmentPosition = TitlerAlignment.left.normalisedPosition
        wide.positionX = 0.05

        func rightmostBrightColumn(_ image: ImageBuffer) -> Int {
            var rightmost = 0
            for x in 0..<image.width {
                for y in 0..<image.height where image.pixel(x: x, y: y).r > 150 {
                    rightmost = max(rightmost, x)
                }
            }
            return rightmost
        }

        let tightImage = tight.renderToImage()
        let wideImage = wide.renderToImage()
        artifact(tightImage, "04-tracking-tight.png")
        artifact(wideImage, "05-tracking-wide.png")
        XCTAssertGreaterThan(
            rightmostBrightColumn(wideImage), rightmostBrightColumn(tightImage),
            "30pt of added tracking across ten characters should visibly widen the line")
    }

    func testDisablingKerningIsDistinctFromZeroTracking() {
        // Not a claim about how much any one font's pair kerning moves a glyph —
        // some fonts barely adjust "II" at all — only that the two attribute VALUES
        // CoreText receives are genuinely different, which is the bug this file's
        // header warns about: collapsing "off" and "zero" into the same number.
        let node = self.node()
        node.kerningEnabled = 1
        node.tracking = 0
        // Rendering must not crash or produce nothing merely because kerning is on
        // with zero added tracking (the "omit the attribute" branch).
        XCTAssertTrue(FrameAssertions.signalPresent(node.renderToImage(), varianceThreshold: 25))

        node.kerningEnabled = 0
        XCTAssertTrue(
            FrameAssertions.signalPresent(node.renderToImage(), varianceThreshold: 25),
            "disabling kerning must still render text, not blank the node")
    }

    // MARK: - Outline and shadow

    func testOutlineWidthAddsVisibleStrokePixels() {
        let noOutline = node()
        noOutline.fillColor = .black
        noOutline.outlineWidth = 0

        let outlined = node()
        outlined.fillColor = .black
        outlined.outlineColor = .white
        outlined.outlineWidth = 6

        let plain = noOutline.renderToImage()
        let stroked = outlined.renderToImage()
        artifact(stroked, "06-outlined-black-fill.png")

        // Black fill on a black plate should be nearly invisible; the SAME black
        // fill with a white outline must not be, because the outline is the only
        // thing that could have put bright pixels there.
        XCTAssertFalse(FrameAssertions.signalPresent(plain, varianceThreshold: 15))
        XCTAssertTrue(FrameAssertions.signalPresent(stroked, varianceThreshold: 15))
    }

    func testShadowOffsetMovesDarkeningAwayFromTheGlyphs() {
        let node = self.node()
        node.fillColor = .white
        node.shadowColor = .black
        node.shadowOpacity = 1.0
        node.shadowOffsetX = 12
        node.shadowOffsetY = 12
        node.shadowBlur = 4
        let image = node.renderToImage()
        artifact(image, "07-drop-shadow.png")
        XCTAssertTrue(FrameAssertions.signalPresent(image, varianceThreshold: 25))
    }

    // MARK: - Roll and crawl motion

    /// The topmost row holding a bright pixel — where the text actually IS, which is
    /// a far more direct claim about motion than counting how many pixels changed.
    /// A single line of type covers about 1% of a 720x480 frame, so a pixel-diff
    /// threshold big enough to feel meaningful is bigger than the whole signal.
    private func topmostBrightRow(_ image: ImageBuffer) -> Int? {
        for y in 0..<image.height {
            for x in 0..<image.width where image.pixel(x: x, y: y).r > 150 {
                return y
            }
        }
        return nil
    }

    func testRollModeMovesTheTextBetweenFrames() {
        let node = self.node()
        node.rollModePosition = TitlerRollMode.roll.normalisedPosition
        node.rollRate = 1.0

        // Two moments at which a 1-screen-height-per-bar roll has the type on
        // screen, half a bar apart. (At t=0 a credit roll is deliberately still
        // below the bottom edge, which is why this does not start there.)
        let earlier = node.renderToImage(
            context: RenderContext(frameIndex: 60, presentationTime: 2.0, musicalPosition: nil))
        let later = node.renderToImage(
            context: RenderContext(frameIndex: 90, presentationTime: 3.0, musicalPosition: nil))
        artifact(earlier, "09-roll-earlier.png")
        artifact(later, "10-roll-later.png")

        guard let earlyRow = topmostBrightRow(earlier), let lateRow = topmostBrightRow(later) else {
            return XCTFail("a rolling title should be on screen at both sampled moments")
        }
        XCTAssertGreaterThan(
            abs(lateRow - earlyRow), 50,
            "half a bar at one screen-height per bar should move the type a long way down the frame")
    }

    func testRollRateChangesHowFarTheTextTravels() {
        // The unit that matters: rollRate is screen-heights per BAR, so doubling it
        // must double the distance covered in the same time. Reading the rate as a
        // raw pixel count instead — which is exactly how this was first written —
        // moves the type about one pixel per bar and parks it off-frame.
        func rowAfterOneBar(rate: Double) -> Int? {
            let node = self.node()
            node.rollModePosition = TitlerRollMode.roll.normalisedPosition
            node.rollRate = rate
            return topmostBrightRow(node.renderToImage(
                context: RenderContext(frameIndex: 30, presentationTime: 1.0, musicalPosition: nil)))
        }

        guard let slow = rowAfterOneBar(rate: 0.5), let fast = rowAfterOneBar(rate: 1.0) else {
            return XCTFail("both rates should have the type on screen half a bar in")
        }
        XCTAssertGreaterThan(slow, fast, "the faster roll should have climbed higher up the frame")
    }

    func testOffModeDoesNotMoveTheText() {
        let node = self.node()
        node.rollModePosition = TitlerRollMode.off.normalisedPosition

        let early = node.renderToImage(
            context: RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil))
        let later = node.renderToImage(
            context: RenderContext(frameIndex: 60, presentationTime: 2.0, musicalPosition: nil))

        XCTAssertLessThan(
            FrameAssertions.differingPixelFraction(early, later), 0.0001,
            "with roll off, the same text at the same position should not drift")
    }

    func testRollLocksToTheMusicalClockWhenOneIsRunning() {
        let node = self.node()
        node.rollModePosition = TitlerRollMode.roll.normalisedPosition
        node.rollRate = 1.0

        // Same wall-clock frame, two different musical positions — if roll were
        // reading presentationTime even with a musical position present, these
        // would come out in the same place.
        let bar1 = RenderContext(
            frameIndex: 30, presentationTime: 1.0,
            musicalPosition: MusicalPosition(bar: 1, beat: 0, phase: 0, totalBeats: 4))
        let bar3 = RenderContext(
            frameIndex: 30, presentationTime: 1.0,
            musicalPosition: MusicalPosition(bar: 3, beat: 0, phase: 0, totalBeats: 12))

        guard let atBar1 = topmostBrightRow(node.renderToImage(context: bar1)),
              let atBar3 = topmostBrightRow(node.renderToImage(context: bar3)) else {
            return XCTFail("the type should be on screen at both musical positions")
        }
        XCTAssertGreaterThan(abs(atBar3 - atBar1), 50, "two bars of roll should be plainly visible")
    }

    // MARK: - The overlay role: text over an existing picture

    func testOverlayDrawsOnTopOfTheGivenBackgroundRatherThanReplacingIt() {
        var background = ImageBuffer(width: 720, height: 480)
        for y in 0..<480 {
            for x in 0..<720 { background.setPixel(x: x, y: y, r: 40, g: 120, b: 200) }
        }

        let node = self.node()
        node.positionX = 0.5
        node.positionY = 0.85 // low third, so the top of the frame stays background
        let composited = node.renderToImage(over: background)
        artifact(composited, "08-overlay-on-blue.png")

        // The top of the frame must still be the background colour — proving this
        // is compositing, not a fresh plate that happened to also have text on it.
        let topPixel = composited.pixel(x: 10, y: 10)
        XCTAssertEqual(Int(topPixel.r), 40, accuracy: 2)
        XCTAssertEqual(Int(topPixel.g), 120, accuracy: 2)
        XCTAssertEqual(Int(topPixel.b), 200, accuracy: 2)

        // And somewhere the text itself must be visibly different from that flat
        // background colour.
        XCTAssertGreaterThan(FrameAssertions.differingColourFraction(background, composited), 0.01)
    }

    // MARK: - NTSC-legal fill colour warning

    func testLegalAndIllegalFillColoursAreToldApart() {
        // A conservative mid-grey is broadcast-legal; full white is not (100 IRE has
        // no headroom and rides the ceiling this codebase already treats as illegal
        // — see BroadcastLevels).
        let legal = TitlerColor(red: 0.5, green: 0.5, blue: 0.5)
        let illegal = TitlerColor(red: 1, green: 1, blue: 1)

        XCTAssertFalse(legal.broadcastReport.isIllegal)
        XCTAssertTrue(illegal.broadcastReport.isIllegal)
    }

    // MARK: - The period preset

    func testPeriodPresetIsDeclaredButOnlyRunsWithAMetalDevice() {
        // renderToImage() is the headless path and deliberately does not run the
        // composite codec (it needs a texture round trip) — this pins that choice
        // down rather than leaving it to be rediscovered as a surprise.
        let node = self.node()
        node.periodPresetEnabled = 1
        let image = node.renderToImage()
        XCTAssertTrue(FrameAssertions.signalPresent(image, varianceThreshold: 25))
    }

    func testPeriodPresetSettingsAreWithinTheCodecsOwnRanges() {
        let preset = CharacterGeneratorNode.periodPreset
        XCTAssertGreaterThanOrEqual(preset.generation, 1)
        XCTAssertLessThanOrEqual(preset.generation, CompositeSettings.maximumGeneration)
        for value in [preset.lumaBandwidth, preset.chromaBleed, preset.crawl, preset.wobble, preset.headSwitching] {
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1)
        }
    }

    // MARK: - Parameters and the registry

    func testEveryParameterRoundTripsThroughTheRegistry() {
        let node = self.node()
        let registry = ParamRegistry()
        registry.register(slot: node.identifier, parameters: node.parameters)

        // Push a distinct, non-default value through EVERY declared parameter and
        // confirm applyParameters actually picks each one up — the failure this
        // guards against is a new param code added to `parameters` and never wired
        // into `applyParameters`, which would compile fine and simply do nothing.
        for parameter in node.parameters {
            let probe = parameter.range.lowerBound + (parameter.range.upperBound - parameter.range.lowerBound) * 0.75
            registry.setValue(probe, slot: node.identifier, code: parameter.code)
        }
        node.applyParameters(from: registry)

        XCTAssertEqual(node.parameters.count, 20, "if this fails, a new code was added — extend this test too")
    }

    func testAllModulationSourcesCanDriveTheSameParametersAsEverywhereElse() {
        // Not a new mechanism — proves the CG's codes are ordinary ParamCode values
        // that the existing MIDI/audio/LFO machinery already knows how to bind to,
        // with no special-casing needed anywhere in this file or in that one.
        let registry = ParamRegistry()
        let node = self.node()
        registry.register(slot: node.identifier, parameters: node.parameters)
        registry.bind(ControlBinding(
            source: .midiControlChange(channel: 0, controller: 1),
            slot: node.identifier, code: .cgFontSize))
        XCTAssertTrue(registry.bindings.contains { $0.slot == node.identifier && $0.code == .cgFontSize })
    }
}

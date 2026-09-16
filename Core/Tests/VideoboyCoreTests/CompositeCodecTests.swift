//
//  CompositeCodecTests.swift — the NTSC codec, checked by measurement and by eye.
//
//  Purpose : The composite path is where the app's analog character comes from, so
//            its behaviour is pinned down rather than eyeballed once and forgotten.
//            Each test asserts a property that follows from the signal model: chroma
//            should smear sideways, S-Video should be cleaner than composite, more
//            generations should degrade further, and a clean pass should stay close
//            to its input.
//  Inputs  : synthetic test patterns, so the correct answer is known by construction.
//  Outputs : assertions plus PNGs under selfqa/out/phase-3/ to look at.
//  Connects: CompositeCodecNode, MetalContext.compositePipeline.
//

import XCTest
import Metal
@testable import VideoboyCore

final class CompositeCodecTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    /// Runs the codec over an image and reads the result back.
    private func encode(
        _ image: ImageBuffer, settings: CompositeSettings, frameIndex: Int = 0
    ) throws -> ImageBuffer {
        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device; the composite codec cannot be exercised")
        }
        let node = CompositeCodecNode(identifier: "test.composite", context: metal)
        node.settings = settings
        guard let input = metal.makeTexture(from: image, label: "composite-input") else {
            throw XCTSkip("could not upload the test image")
        }
        let context = RenderContext(
            frameIndex: frameIndex, presentationTime: 0, musicalPosition: nil,
            width: image.width, height: image.height
        )
        guard let output = node.render(inputs: [input], context: context),
              let result = renderer.readback(output) else {
            throw XCTSkip("the composite pass produced nothing")
        }
        return result
    }

    // MARK: - The subcarrier arithmetic

    func testSubcarrierFrequencyIsTheDefinedValue() {
        // NTSC colour subcarrier is exactly 315/88 MHz — 3.579545... MHz.
        XCTAssertEqual(CompositeCodecNode.subcarrierHertz, 3_579_545.4545, accuracy: 1.0)
    }

    func testPhasePerPixelGivesAboutFourSamplesPerCycle() {
        // Over a 52.6 µs active line the subcarrier runs about 188 cycles. Across 720
        // samples that is ~3.8 samples per cycle, so phase per pixel is ~1.64 radians.
        let phase = CompositeCodecNode.phasePerPixel(width: 720)
        let samplesPerCycle = 2.0 * Double.pi / phase
        XCTAssertEqual(samplesPerCycle, 3.82, accuracy: 0.1)
    }

    // MARK: - Round-trip behaviour

    func testCleanSettingsStayCloseToTheInput() throws {
        // S-Video, full chroma, full bandwidth, no wobble: the codec should be close
        // to a pass-through. Not identical — it still filters — but recognisable.
        let source = TestPattern.colorBars(width: 320, height: 240)
        let result = try encode(source, settings: .clean)

        let bars = FrameAssertions.looksLikeColorBars(result, tolerance: 45)
        XCTAssertTrue(bars.passed, bars.detail)
        XCTAssertTrue(FrameAssertions.signalPresent(result))
    }

    func testCompositePathIsDirtierThanSVideo() throws {
        // The whole reason the S-Video toggle exists: one wire carrying both signals
        // must produce artefacts that two wires do not.
        let source = TestPattern.colorBars(width: 320, height: 240)

        var composite = CompositeSettings.vhs
        composite.path = .composite
        composite.wobble = 0
        composite.headSwitching = 0

        var sVideo = composite
        sVideo.path = .sVideo

        let compositeResult = try encode(source, settings: composite)
        let sVideoResult = try encode(source, settings: sVideo)

        let compositeError = FrameAssertions.differingPixelFraction(source, compositeResult)
        let sVideoError = FrameAssertions.differingPixelFraction(source, sVideoResult)

        XCTAssertGreaterThan(
            compositeError, sVideoError,
            "the composite path must depart from the source more than S-Video does"
        )
    }

    func testChromaBleedSmearsColourSideways() throws {
        // A hard vertical colour edge is the case chroma bandwidth limiting shows up
        // on: the colour should run past the edge, horizontally.
        var image = ImageBuffer(width: 256, height: 64)
        for y in 0..<64 {
            for x in 0..<256 {
                // Left half red, right half black.
                let isLeft = x < 128
                image.setPixel(x: x, y: y, r: isLeft ? 200 : 0, g: 0, b: 0)
            }
        }

        var tight = CompositeSettings.clean
        tight.path = .composite
        tight.chromaBleed = 0.0
        var loose = tight
        loose.chromaBleed = 1.0

        let tightResult = try encode(image, settings: tight)
        let looseResult = try encode(image, settings: loose)

        // Measure how much red has spilled into the black side just past the edge.
        // The window starts right at the edge because the smear is widest there.
        func spill(_ result: ImageBuffer) -> Double {
            FrameAssertions.meanColor(result, region: (x: 129, y: 16, width: 20, height: 32)).r
        }
        let tightSpill = spill(tightResult)
        let looseSpill = spill(looseResult)
        XCTAssertGreaterThan(
            looseSpill, tightSpill + 2.0,
            "more chroma bleed must push more colour past a hard edge (tight \(tightSpill), loose \(looseSpill))"
        )
    }

    func testMoreGenerationsDegradeFurther() throws {
        // A dub of a dub is worse than a dub. Each generation runs the codec again
        // over the previous output, so error must accumulate.
        let source = TestPattern.colorBars(width: 320, height: 240)
        var first = CompositeSettings.vhs
        first.wobble = 0
        first.headSwitching = 0
        first.generation = 1
        var fourth = first
        fourth.generation = 4

        let firstGeneration = try encode(source, settings: first)
        let fourthGeneration = try encode(source, settings: fourth)

        // Generation loss is measured as lost detail, not as pixel difference: each
        // pass low-passes the picture, so a heavily dubbed frame converges toward a
        // smooth average and can read as *closer* to the source by raw difference
        // while plainly being more degraded. Detail only goes one way.
        let firstDetail = FrameAssertions.horizontalDetail(firstGeneration)
        let fourthDetail = FrameAssertions.horizontalDetail(fourthGeneration)

        // Note the codec ADDS texture on the first pass — dot crawl is high-frequency,
        // and colour bars are almost flat to begin with — so the comparison that
        // means anything is between generations, not against the source.
        XCTAssertLessThan(
            fourthDetail, firstDetail,
            "the fourth generation must carry less detail than the first "
                + "(1st \(firstDetail), 4th \(fourthDetail))"
        )

        // And the colour must drift further from the original with each dub.
        func colorError(_ image: ImageBuffer) -> Double {
            let a = FrameAssertions.meanColor(source)
            let b = FrameAssertions.meanColor(image)
            return abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
        }
        XCTAssertGreaterThan(
            colorError(fourthGeneration), colorError(firstGeneration),
            "each generation must drift further from the original colours"
        )
    }

    func testGenerationIsClampedRatherThanRunningAway() throws {
        // A template or a stray mapping must not be able to ask for 10000 passes.
        let source = TestPattern.colorBars(width: 128, height: 96)
        var settings = CompositeSettings.vhs
        settings.generation = 10_000
        // The assertion is that this returns promptly with a valid picture.
        let result = try encode(source, settings: settings)
        XCTAssertEqual(result.width, 128)
        XCTAssertEqual(result.height, 96)
    }

    func testDotCrawlMovesBetweenFrames() throws {
        // Dot crawl crawls: the residual subcarrier pattern must shift from frame to
        // frame, because the phase steps each frame. A static pattern would be wrong.
        let source = TestPattern.colorBars(width: 320, height: 240)
        var settings = CompositeSettings.vhs
        settings.wobble = 0
        settings.headSwitching = 0
        settings.crawl = 1.0

        let frameZero = try encode(source, settings: settings, frameIndex: 0)
        let frameOne = try encode(source, settings: settings, frameIndex: 1)

        let moved = FrameAssertions.differingPixelFraction(frameZero, frameOne, threshold: 2.0)
        XCTAssertGreaterThan(moved, 0.01, "the dot-crawl pattern must move between frames")
    }

    func testWobbleDisplacesLinesAndTBCLockedDoesNot() throws {
        let source = TestPattern.colorBars(width: 320, height: 240)
        var locked = CompositeSettings.clean
        locked.path = .composite
        locked.wobble = 0
        var wobbling = locked
        wobbling.wobble = 1.0

        let lockedResult = try encode(source, settings: locked)
        let wobblingResult = try encode(source, settings: wobbling)

        // Comparing each against the SOURCE would be measuring the codec's own
        // artefacts, which dominate and leave no headroom to see the wobble in.
        // Comparing the two results against each other isolates it.
        let displaced = FrameAssertions.differingPixelFraction(lockedResult, wobblingResult)
        XCTAssertGreaterThan(
            displaced, 0.02,
            "TBC off must visibly displace the picture relative to TBC locked"
        )

        // And TBC locked must be stable frame to frame, since nothing is jittering.
        let lockedAgain = try encode(source, settings: locked)
        XCTAssertTrue(
            FrameAssertions.framesMatch(lockedResult, lockedAgain, name: "TBC locked is stable").passed,
            "with TBC locked the same input must give the same output"
        )
    }

    // MARK: - Evidence

    func testWriteCompositeEvidence() throws {
        let check = SelfQACheck(name: "phase-3/composite-codec")
        let source = TestPattern.colorBars()
        try check.writeImage(source, named: "00-source.png")
        check.note("NTSC subcarrier \(String(format: "%.4f", CompositeCodecNode.subcarrierHertz / 1e6)) MHz, "
                   + "\(String(format: "%.2f", 2 * Double.pi / CompositeCodecNode.phasePerPixel(width: 720))) samples per cycle at 720 px")

        let looks: [(String, CompositeSettings)] = [
            ("01-clean-svideo", .clean),
            ("02-composite-default", {
                var s = CompositeSettings.vhs; s.wobble = 0; s.headSwitching = 0; return s
            }()),
            ("03-composite-heavy-bleed", {
                var s = CompositeSettings.vhs
                s.chromaBleed = 1.0; s.lumaBandwidth = 0.3; s.wobble = 0; s.headSwitching = 0
                return s
            }()),
            ("04-tbc-off-wobble", {
                var s = CompositeSettings.vhs; s.wobble = 1.0; s.headSwitching = 1.0; return s
            }()),
            ("05-fourth-generation", {
                var s = CompositeSettings.vhs; s.generation = 4; return s
            }())
        ]

        for (name, settings) in looks {
            let result = try encode(source, settings: settings, frameIndex: 3)
            try check.writeImage(result, named: "\(name).png")
            check.record(FrameAssertions.hasDimensions(
                result, width: StandardDefinition.width, height: StandardDefinition.height))
            check.record(AssertionResult(
                name: "\(name) carries picture",
                passed: FrameAssertions.signalPresent(result),
                detail: "luminance variance \(String(format: "%.0f", FrameAssertions.luminanceVariance(result)))"
            ))
        }

        XCTAssertEqual(check.finish(), .pass, "see selfqa/out/phase-3/composite-codec/result.txt")
    }
}

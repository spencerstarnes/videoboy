//
//  ScopeTests.swift — the measurement instruments, measured (SPEC 19).
//
//  Purpose : A scope's whole value is that it is trustworthy. These drive each one
//            with a pattern whose correct reading is known by construction — a black
//            frame's trace must sit at the bottom, a white frame's at the top, a
//            grey frame's histogram must be one spike — so "it drew something" is
//            never mistaken for "it is right".
//  Inputs   : synthetic patterns.
//  Outputs  : assertions, plus PNGs under selfqa/out/phase-5/scopes/.
//  Connects : ScopeRenderer, BroadcastSafety.
//

import XCTest
@testable import VideoboyCore

final class ScopeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    /// Mean brightness of a horizontal band of a scope, as a fraction of full.
    private func bandBrightness(_ scope: ImageBuffer, fromTop: Double, toTop: Double) -> Double {
        let y0 = Int(Double(scope.height) * fromTop)
        let y1 = Int(Double(scope.height) * toTop)
        guard y1 > y0 else { return 0 }
        let mean = FrameAssertions.meanColor(
            scope, region: (x: 0, y: y0, width: scope.width, height: y1 - y0))
        return (mean.r + mean.g + mean.b) / 3
    }

    // MARK: - Waveform

    func testWaveformPutsBlackAtTheBottomAndWhiteAtTheTop() {
        let black = TestPattern.solid(width: 320, height: 240, r: 0, g: 0, b: 0)
        let blackScope = ScopeRenderer.render(.waveform, from: black, width: 200, height: 150)
        // A black frame's trace belongs in the bottom fifth, not the top.
        XCTAssertGreaterThan(
            bandBrightness(blackScope, fromTop: 0.8, toTop: 1.0),
            bandBrightness(blackScope, fromTop: 0.0, toTop: 0.2),
            "a black frame must trace along the bottom of the waveform")

        let white = TestPattern.solid(width: 320, height: 240, r: 255, g: 255, b: 255)
        let whiteScope = ScopeRenderer.render(.waveform, from: white, width: 200, height: 150)
        XCTAssertGreaterThan(
            bandBrightness(whiteScope, fromTop: 0.0, toTop: 0.2),
            bandBrightness(whiteScope, fromTop: 0.8, toTop: 1.0),
            "a white frame must trace along the top of the waveform")
    }

    func testWaveformTracksHorizontalPosition() {
        // Two mid levels, deliberately NOT 0 or 255: those plot exactly on the
        // graticule rows the scope draws at 0 and 255, so a trace there is
        // indistinguishable from the graticule and the test would measure nothing.
        let darkLevel: UInt8 = 64
        let brightLevel: UInt8 = 192
        var image = ImageBuffer(width: 320, height: 240)
        for y in 0..<240 {
            for x in 0..<320 {
                let value = x < 160 ? darkLevel : brightLevel
                image.setPixel(x: x, y: y, r: value, g: value, b: value)
            }
        }
        let height = 150
        let scope = ScopeRenderer.render(.waveform, from: image, width: 200, height: height)

        /// The row a level plots on, matching the renderer's mapping.
        func row(for level: UInt8) -> Int {
            height - 1 - Int(Double(level) / 255.0 * Double(height - 1))
        }
        let darkRow = row(for: darkLevel)
        let brightRow = row(for: brightLevel)

        // At the bright level's row, the right half must carry trace and the left
        // must not — and vice versa. A waveform ignoring x would light both.
        let brightRight = FrameAssertions.meanColor(
            scope, region: (x: 110, y: brightRow - 1, width: 80, height: 3))
        let brightLeft = FrameAssertions.meanColor(
            scope, region: (x: 10, y: brightRow - 1, width: 80, height: 3))
        XCTAssertGreaterThan(brightRight.g, brightLeft.g + 10,
                             "the bright half must trace only on the right")

        let darkLeft = FrameAssertions.meanColor(
            scope, region: (x: 10, y: darkRow - 1, width: 80, height: 3))
        let darkRight = FrameAssertions.meanColor(
            scope, region: (x: 110, y: darkRow - 1, width: 80, height: 3))
        XCTAssertGreaterThan(darkLeft.g, darkRight.g + 10,
                             "the dark half must trace only on the left")
    }

    // MARK: - Parade

    func testParadeSeparatesTheChannels() {
        // Pure red: the left third must show a high trace, the other two low.
        let red = TestPattern.solid(width: 320, height: 240, r: 255, g: 0, b: 0)
        let scope = ScopeRenderer.render(.parade, from: red, width: 300, height: 150)
        let third = scope.width / 3

        let redPanelTop = FrameAssertions.meanColor(
            scope, region: (x: 0, y: 0, width: third, height: 20))
        let greenPanelTop = FrameAssertions.meanColor(
            scope, region: (x: third, y: 0, width: third, height: 20))
        XCTAssertGreaterThan(
            redPanelTop.r, greenPanelTop.g + 10,
            "pure red must trace high in the red panel and low in the green one")
    }

    // MARK: - Histogram

    func testHistogramOfAFlatFrameIsASingleSpike() {
        let grey = TestPattern.solid(width: 320, height: 240, r: 128, g: 128, b: 128)
        let scope = ScopeRenderer.render(.histogram, from: grey, width: 256, height: 150)

        // Everything is at 128, so the middle must be far brighter than the ends.
        // The comparison region avoids x = 16 and x = 235, where the scope draws its
        // legal-level graticule — sampling on those would measure the graticule.
        let middle = FrameAssertions.meanColor(
            scope, region: (x: 120, y: 0, width: 16, height: 150))
        let leftEnd = FrameAssertions.meanColor(
            scope, region: (x: 40, y: 0, width: 16, height: 150))
        XCTAssertGreaterThan(
            middle.r + middle.g + middle.b, leftEnd.r + leftEnd.g + leftEnd.b + 30,
            "a flat grey frame's histogram must spike in the middle")
    }

    func testHistogramOfARampIsBroad() {
        let ramp = TestPattern.grayscaleRamp(width: 320, height: 240)
        let scope = ScopeRenderer.render(.histogram, from: ramp, width: 256, height: 150)
        // A ramp covers every level, so both ends carry trace.
        let leftEnd = FrameAssertions.meanColor(scope, region: (x: 20, y: 100, width: 20, height: 50))
        let rightEnd = FrameAssertions.meanColor(scope, region: (x: 216, y: 100, width: 20, height: 50))
        XCTAssertGreaterThan(leftEnd.g, 5, "a ramp must put trace at the dark end")
        XCTAssertGreaterThan(rightEnd.g, 5, "a ramp must put trace at the bright end")
    }

    // MARK: - Vectorscope

    func testVectorscopePutsGreyAtTheCentre() {
        // Neutral grey has no chroma, so it must plot at the middle.
        let grey = TestPattern.solid(width: 200, height: 200, r: 128, g: 128, b: 128)
        let scope = ScopeRenderer.render(.vectorscope, from: grey, width: 160, height: 160)
        let centre = FrameAssertions.meanColor(
            scope, region: (x: 70, y: 70, width: 20, height: 20))
        let edge = FrameAssertions.meanColor(
            scope, region: (x: 4, y: 70, width: 16, height: 20))
        XCTAssertGreaterThan(centre.g, edge.g,
                             "neutral grey must plot at the vectorscope's centre")
    }

    func testVectorscopePushesSaturatedColourOutward() {
        let saturated = TestPattern.solid(width: 200, height: 200, r: 255, g: 0, b: 0)
        let scope = ScopeRenderer.render(.vectorscope, from: saturated, width: 160, height: 160)
        let centre = FrameAssertions.meanColor(
            scope, region: (x: 74, y: 74, width: 12, height: 12))
        // Saturated red must land away from the centre, not on it.
        XCTAssertLessThan(centre.g, 60, "saturated colour must not plot at the centre")
    }

    // MARK: - Quad

    func testQuadRendersAllFourPanels() {
        let bars = TestPattern.colorBars(width: 320, height: 240)
        let quad = ScopeRenderer.renderQuad(from: bars, width: 320, height: 240)
        XCTAssertEqual(quad.width, 320)
        XCTAssertEqual(quad.height, 240)
        // Every quadrant must carry something, or a panel is missing.
        for (x, y) in [(0, 0), (160, 0), (0, 120), (160, 120)] {
            let mean = FrameAssertions.meanColor(
                quad, region: (x: x + 10, y: y + 10, width: 140, height: 100))
            XCTAssertGreaterThan(
                mean.r + mean.g + mean.b, 1.0,
                "the quadrant at (\(x), \(y)) is empty")
        }
    }

    func testDisplayModeCyclesThroughEveryViewAndBackToOff() {
        // The scope tab is one control that must reach every mode, so the cycle has
        // to visit all of them and return.
        var mode = ScopeDisplayMode.off
        var seen: [ScopeDisplayMode] = []
        for _ in 0..<ScopeDisplayMode.allCases.count {
            mode = mode.next
            seen.append(mode)
        }
        XCTAssertEqual(mode, .off, "the cycle must return to off")
        XCTAssertEqual(Set(seen).count, ScopeDisplayMode.allCases.count,
                       "the cycle must visit every mode")
        XCTAssertTrue(ScopeDisplayMode.quadOverlay.showsPicture)
        XCTAssertFalse(ScopeDisplayMode.quadBlack.showsPicture)
    }

    // MARK: - Broadcast safety

    func testLegalGreyReadsAsLegal() {
        let legal = TestPattern.solid(width: 160, height: 120, r: 128, g: 128, b: 128)
        let report = BroadcastSafety.analyse(legal)
        XCTAssertFalse(report.isIllegal)
        XCTAssertEqual(report.belowBlack, 0, accuracy: 1e-9)
        XCTAssertEqual(report.aboveWhite, 0, accuracy: 1e-9)
    }

    func testFullScaleWhiteIsFlaggedAsHot() {
        let hot = TestPattern.solid(width: 160, height: 120, r: 255, g: 255, b: 255)
        let report = BroadcastSafety.analyse(hot)
        XCTAssertTrue(report.isIllegal, "255 white is above 100 IRE and must be flagged")
        XCTAssertEqual(report.aboveWhite, 1.0, accuracy: 0.01)
        XCTAssertGreaterThan(report.peakIRE, 100)
        XCTAssertTrue(report.summary.contains("hot"))
    }

    func testFullScaleBlackIsFlaggedAsCrushed() {
        let crushed = TestPattern.solid(width: 160, height: 120, r: 0, g: 0, b: 0)
        let report = BroadcastSafety.analyse(crushed)
        XCTAssertTrue(report.isIllegal, "0 black is below 7.5 IRE and must be flagged")
        XCTAssertEqual(report.belowBlack, 1.0, accuracy: 0.01)
        XCTAssertTrue(report.summary.contains("crushed"))
    }

    func testIREConversionMatchesTheStandardPoints() {
        // 16 is 7.5 IRE and 235 is 100 IRE, by definition.
        XCTAssertEqual(BroadcastLevels.ire(from: BroadcastLevels.black), 7.5, accuracy: 0.01)
        XCTAssertEqual(BroadcastLevels.ire(from: BroadcastLevels.white), 100, accuracy: 0.01)
    }

    func testASmallNumberOfHotPixelsIsNotWorthWarningAbout() {
        // Warning on a handful of pixels trains the operator to ignore warnings.
        var image = TestPattern.solid(width: 200, height: 200, r: 128, g: 128, b: 128)
        for y in 0..<2 {
            for x in 0..<2 {
                image.setPixel(x: x, y: y, r: 255, g: 255, b: 255)
            }
        }
        XCTAssertFalse(BroadcastSafety.analyse(image).isIllegal)
    }

    // MARK: - Zebra

    func testZebraMarksOnlyHotPixels() {
        // Left half legal, right half blown out.
        var image = ImageBuffer(width: 200, height: 100)
        for y in 0..<100 {
            for x in 0..<200 {
                let value: UInt8 = x < 100 ? 100 : 255
                image.setPixel(x: x, y: y, r: value, g: value, b: value)
            }
        }
        let striped = BroadcastSafety.applyZebra(to: image)

        // The legal half must be untouched.
        let legalHalf = FrameAssertions.meanColor(
            striped, region: (x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(legalHalf.r, 100, accuracy: 1)

        // The hot half must be striped, so darker on average than the 255 it was.
        let hotHalf = FrameAssertions.meanColor(
            striped, region: (x: 100, y: 0, width: 100, height: 100))
        XCTAssertLessThan(hotHalf.r, 200, "hot areas must be striped")
        XCTAssertGreaterThan(hotHalf.r, 50, "the stripes must not cover everything")
    }

    func testZebraPhaseMovesTheStripes() {
        let hot = TestPattern.solid(width: 120, height: 80, r: 255, g: 255, b: 255)
        let atRest = BroadcastSafety.applyZebra(to: hot, phase: 0)
        let moved = BroadcastSafety.applyZebra(to: hot, phase: 0.5)
        // Movement is what makes a zebra read as a warning rather than as content.
        XCTAssertTrue(FrameAssertions.framesDiffer(atRest, moved, minimumFraction: 0.1).passed)
    }

    func testCrushZebraMarksOnlyDarkPixels() {
        var image = ImageBuffer(width: 200, height: 100)
        for y in 0..<100 {
            for x in 0..<200 {
                let value: UInt8 = x < 100 ? 4 : 128
                image.setPixel(x: x, y: y, r: value, g: value, b: value)
            }
        }
        let striped = BroadcastSafety.applyCrushZebra(to: image)
        let legalHalf = FrameAssertions.meanColor(
            striped, region: (x: 100, y: 0, width: 100, height: 100))
        XCTAssertEqual(legalHalf.r, 128, accuracy: 1, "legal areas must not be marked")
        let crushedHalf = FrameAssertions.meanColor(
            striped, region: (x: 0, y: 0, width: 100, height: 100))
        XCTAssertGreaterThan(crushedHalf.r, 20, "crushed areas must be marked in red")
    }

    // MARK: - Evidence

    func testWriteScopeEvidence() throws {
        let check = SelfQACheck(name: "phase-5/scopes")
        let bars = TestPattern.colorBars()
        try check.writeImage(bars, named: "00-source.png")

        for kind in ScopeKind.allCases {
            let scope = ScopeRenderer.render(kind, from: bars, width: 480, height: 300)
            try check.writeImage(scope, named: "\(kind.rawValue).png")
            check.record(FrameAssertions.hasDimensions(scope, width: 480, height: 300))
            check.record(AssertionResult(
                name: "\(kind.displayName) draws a trace",
                passed: FrameAssertions.luminanceVariance(scope) > 20,
                detail: "variance \(String(format: "%.0f", FrameAssertions.luminanceVariance(scope)))"
            ))
        }

        let quad = ScopeRenderer.renderQuad(from: bars, width: 640, height: 480)
        try check.writeImage(quad, named: "quad.png")

        // A blown-out frame, striped, so the zebra can be looked at.
        let hot = TestPattern.solid(r: 250, g: 250, b: 250)
        try check.writeImage(BroadcastSafety.applyZebra(to: hot), named: "zebra.png")

        let report = BroadcastSafety.analyse(bars)
        check.note("colour bars read: \(report.summary)")

        XCTAssertEqual(check.finish(), .pass, "see selfqa/out/phase-5/scopes/result.txt")
    }
}

// MARK: - Preview fill modes

extension ScopeTests {

    /// A 16:9 picture in a 4:3 frame is the case every mode exists to answer, so it
    /// is the one worth pinning down. 320×180 into 400×300.
    private var wideSource: CGSize { CGSize(width: 320, height: 180) }
    private var narrowFrame: CGSize { CGSize(width: 400, height: 300) }

    func testFitShowsTheWholePictureWithBars() {
        let rect = PreviewFill.fit.rect(sourceSize: wideSource, in: narrowFrame)
        XCTAssertEqual(rect.width, 400, accuracy: 0.01, "fit uses the full width")
        XCTAssertEqual(rect.height, 225, accuracy: 0.01, "and leaves bars top and bottom")
        XCTAssertGreaterThanOrEqual(rect.minX, -0.01)
        XCTAssertGreaterThanOrEqual(rect.minY, -0.01, "nothing is cropped")
    }

    func testFillCoversTheFrameAndCropsTheOverflow() {
        let rect = PreviewFill.fill.rect(sourceSize: wideSource, in: narrowFrame)
        XCTAssertEqual(rect.height, 300, accuracy: 0.01, "fill uses the full height")
        XCTAssertEqual(rect.width, 533.33, accuracy: 0.1)
        XCTAssertLessThan(rect.minX, 0, "the overflow hangs outside the frame, to be clipped")
    }

    func testStretchFillsExactlyAndDistorts() {
        let rect = PreviewFill.stretch.rect(sourceSize: wideSource, in: narrowFrame)
        XCTAssertEqual(rect.width, 400, accuracy: 0.01)
        XCTAssertEqual(rect.height, 300, accuracy: 0.01)
        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.01)
    }

    func testCentreDoesNotScaleAtAll() {
        let rect = PreviewFill.centre.rect(sourceSize: wideSource, in: narrowFrame)
        XCTAssertEqual(rect.size.width, wideSource.width, accuracy: 0.01)
        XCTAssertEqual(rect.size.height, wideSource.height, accuracy: 0.01)
    }

    /// A source that already matches the frame must come out identical under every
    /// mode except centre — otherwise the modes are doing something to 4:3 material
    /// in a 4:3 window, which is the common case.
    func testMatchingAspectIsUntouched() {
        let frame = CGSize(width: 400, height: 300)
        for mode in [PreviewFill.fit, .fill, .stretch] {
            let rect = mode.rect(sourceSize: CGSize(width: 800, height: 600), in: frame)
            XCTAssertEqual(rect.width, 400, accuracy: 0.01, "\(mode.rawValue) width")
            XCTAssertEqual(rect.height, 300, accuracy: 0.01, "\(mode.rawValue) height")
        }
    }

    func testEveryModeExplainsItself() {
        for mode in PreviewFill.allCases {
            XCTAssertFalse(mode.displayName.isEmpty)
            XCTAssertFalse(mode.explanation.isEmpty)
        }
    }

    func testDegenerateSizesDoNotDivideByZero() {
        for mode in PreviewFill.allCases {
            let rect = mode.rect(sourceSize: .zero, in: narrowFrame)
            XCTAssertEqual(rect.size, narrowFrame, "a zero source falls back to the frame")
        }
    }
}

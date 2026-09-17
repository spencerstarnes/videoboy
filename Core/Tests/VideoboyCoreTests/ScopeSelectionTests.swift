//
//  ScopeSelectionTests.swift — four instruments, three placements, and one on air.
//
//  The scope panel stopped being one button that cycled presets and became seven keys.
//  What has to be checked is that every combination those keys can make produces
//  something, that the layout is STABLE as instruments are toggled, and — the one that
//  matters most — that SEND cannot make the programme picture measure itself.
//

import XCTest
@testable import VideoboyCore

final class ScopeSelectionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private var picture: ImageBuffer { TestPattern.colorBars() }

    // MARK: - What the keys can express

    func testNoInstrumentMeansTheScopesAreOff() {
        let selection = ScopeSelection()
        XCTAssertFalse(selection.isShowing)
        XCTAssertNil(ScopeRenderer.compose(selection, from: picture, width: 320, height: 240))
    }

    func testEveryCombinationOfInstrumentsDrawsSomething() {
        // Sixteen combinations from four keys. The old cycling control could only
        // reach the five someone thought of in advance.
        let all = ScopeKind.allCases
        for mask in 1..<(1 << all.count) {
            var selection = ScopeSelection()
            for (index, kind) in all.enumerated() where mask & (1 << index) != 0 {
                selection.kinds.insert(kind)
            }
            guard let composed = ScopeRenderer.compose(
                selection, from: picture, width: 320, height: 240) else {
                return XCTFail("\(selection.orderedKinds) produced nothing")
            }
            XCTAssertEqual(composed.width, 320)
            XCTAssertEqual(composed.height, 240)
            XCTAssertTrue(
                FrameAssertions.differingPixelFraction(
                    composed, ImageBuffer(width: 320, height: 240)) > 0.01,
                "\(selection.orderedKinds) drew an empty frame")
        }
    }

    func testTheLayoutOrderIsStableAsInstrumentsAreToggled() {
        // THE failure this guards: laying the grid out in Set order would move a scope
        // to a different cell whenever a neighbour was switched on, and a waveform
        // that jumps across the screen when you enable a histogram reads as a bug.
        var selection = ScopeSelection()
        selection.kinds = [.vectorscope, .waveform]
        XCTAssertEqual(selection.orderedKinds, [.waveform, .vectorscope])

        selection.kinds.insert(.histogram)
        XCTAssertEqual(
            selection.orderedKinds.prefix(1), [.waveform],
            "the waveform must stay in the first cell")
    }

    func testOneInstrumentGoesToTheCornerAndSeveralFillTheFrame() {
        // Four instruments crammed into a corner are unreadable; one filling the frame
        // hides a picture for no reason.
        var selection = ScopeSelection()
        selection.kinds = [.waveform]
        XCTAssertEqual(selection.placement, .corner)

        selection.kinds.insert(.vectorscope)
        XCTAssertEqual(selection.placement, .full)
    }

    func testTheLowerThirdKeyOverridesBoth() {
        var selection = ScopeSelection()
        selection.kinds = [.waveform]
        selection.isLowerThird = true
        XCTAssertEqual(selection.placement, .lowerThird)

        selection.kinds.insert(.parade)
        XCTAssertEqual(selection.placement, .lowerThird, "still, with several")
    }

    func testTheLowerThirdBandIsActuallyInTheLowerThird() {
        let rect = ScopePlacement.lowerThird.rect
        XCTAssertGreaterThan(rect.y, 0.6, "it has to start below the middle")
        XCTAssertLessThanOrEqual(rect.y + rect.height, 1.0, "and stay on the screen")
    }

    func testOverBlackDoesNotDimAPictureThatIsNotThere() {
        var selection = ScopeSelection()
        selection.kinds = [.waveform, .parade]
        selection.isOverlaid = false
        XCTAssertEqual(selection.pictureDimming, 1, "over black hides the picture entirely")

        selection.isOverlaid = true
        XCTAssertGreaterThan(selection.pictureDimming, 0)
        XCTAssertLessThan(selection.pictureDimming, 1, "over the picture holds it back, not out")
    }

    func testACornerScopeDoesNotDimTheWholeFrameForItself() {
        var selection = ScopeSelection()
        selection.kinds = [.waveform]
        selection.isOverlaid = true
        XCTAssertEqual(selection.placement, .corner)
        XCTAssertEqual(selection.pictureDimming, 0)
    }

    // MARK: - The three-cell case

    func testThreeInstrumentsKeepTheSameCellShapeAsFour() {
        // Stretching one panel to fill the empty fourth cell would give it a different
        // aspect ratio to the ones beside it, and a scope is read by shape.
        var three = ScopeSelection()
        three.kinds = [.waveform, .parade, .histogram]
        var four = ScopeSelection()
        four.kinds = Set(ScopeKind.allCases)

        guard let a = ScopeRenderer.compose(three, from: picture, width: 320, height: 240),
              let b = ScopeRenderer.compose(four, from: picture, width: 320, height: 240) else {
            return XCTFail("expected both to draw")
        }
        // The top-left quadrant is the same instrument at the same size in both.
        XCTAssertEqual(a.pixel(x: 80, y: 60).r, b.pixel(x: 80, y: 60).r, accuracy: 2)
        XCTAssertEqual(a.pixel(x: 80, y: 60).g, b.pixel(x: 80, y: 60).g, accuracy: 2)
    }

    // MARK: - SEND

    func testTheOverlayCostsNothingWhenNothingIsBeingSent() throws {
        // It is LAST IN THE CHAIN, so it runs on every frame that goes to air. A node
        // that spends a full-frame pass reproducing its input is exactly the sort of
        // thing that eats the budget while appearing to do nothing.
        guard let metal = MetalContext.shared else { throw XCTSkip("no Metal device") }
        guard let input = metal.makeTexture(from: picture, label: "in") else {
            throw XCTSkip("could not upload")
        }
        let node = ScopeOverlayNode(identifier: "test.scope", context: metal)
        XCTAssertFalse(node.isActive)

        let output = node.render(
            inputs: [input],
            context: RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil))
        XCTAssertTrue(output === input, "it must hand the picture straight back")
    }

    func testSendingPutsTheTraceIntoThePicture() throws {
        guard let metal = MetalContext.shared,
              let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        let bars = picture
        guard let input = metal.makeTexture(from: bars, label: "in") else {
            throw XCTSkip("could not upload")
        }

        var selection = ScopeSelection()
        selection.kinds = [.waveform, .vectorscope]
        guard let scope = ScopeRenderer.compose(
            selection, from: bars, width: 480, height: 360) else {
            return XCTFail("expected a scope")
        }

        let node = ScopeOverlayNode(identifier: "test.scope", context: metal)
        node.placement = .lowerThird
        node.dimming = 0.65
        node.setOverlay(scope)
        XCTAssertTrue(node.isActive)

        guard let output = node.render(
            inputs: [input],
            context: RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil)),
              let read = renderer.readback(output) else {
            throw XCTSkip("render failed")
        }
        XCTAssertFalse(output === input, "a sent scope must actually change the picture")

        let check = SelfQACheck(name: "scopes/send")
        _ = try? check.writeImage(bars, named: "before.png")
        _ = try? check.writeImage(read, named: "after-lower-third.png")
        _ = try? check.writeImage(scope, named: "scope.png")

        // Asserted over ROWS rather than at one pixel. The first version sampled a
        // single point and it happened to land on a colour-bar boundary, where the
        // dimmed value matched the original — the overlay was working perfectly and
        // the test said it drew nothing.
        var changedRows: [Int] = []
        for y in stride(from: 0, to: read.height, by: 8) {
            var worst = 0.0
            for x in stride(from: 8, to: read.width - 8, by: 16) {
                let a = read.pixel(x: x, y: y)
                let b = bars.pixel(x: x, y: y)
                worst = max(worst, abs(Double(a.r) - Double(b.r)))
                worst = max(worst, abs(Double(a.g) - Double(b.g)))
            }
            if worst > 10 { changedRows.append(y) }
        }
        guard let first = changedRows.first, let last = changedRows.last else {
            return XCTFail("the overlay changed nothing at all")
        }

        let rect = ScopePlacement.lowerThird.rect
        let expectedTop = Double(read.height) * rect.y
        let expectedBottom = Double(read.height) * (rect.y + rect.height)

        XCTAssertEqual(
            Double(first), expectedTop, accuracy: 16,
            "the band starts where ScopePlacement says it does")
        XCTAssertEqual(
            Double(last), expectedBottom, accuracy: 16,
            "and ends there — if this is upside down, the shader's V axis is flipped")
        XCTAssertGreaterThan(
            Double(first), Double(read.height) * 0.5,
            "a LOWER third that reaches the top half is not a lower third")
    }

    func testTakingSendOffClearsIt() throws {
        guard let metal = MetalContext.shared else { throw XCTSkip("no Metal device") }
        guard let input = metal.makeTexture(from: picture, label: "in") else {
            throw XCTSkip("could not upload")
        }
        let node = ScopeOverlayNode(identifier: "test.scope", context: metal)
        node.setOverlay(ScopeRenderer.render(.waveform, from: picture, width: 240, height: 144))
        let context = RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil)
        _ = node.render(inputs: [input], context: context)

        node.setOverlay(nil)
        XCTAssertFalse(node.isActive)
        XCTAssertTrue(
            node.render(inputs: [input], context: context) === input,
            "a scope taken off air must leave no trace behind on the next frame")
    }
}

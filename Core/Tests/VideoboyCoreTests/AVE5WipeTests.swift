//
//  AVE5WipeTests.swift — the WJ-AVE5 wipe block: its keys, and the wipes they make.
//
//  Purpose : Two halves. The front panel — what a press of each key does, what the
//            lit keys add up to — is checked against the operating manual's table
//            and key descriptions. The picture is checked with geometry, as
//            TransitionTests does: flat red for A, flat blue for B, and pixels read
//            back where B must and must not have arrived.
//  Inputs  : flat colour images built here.
//  Outputs : assertions.
//  Connects: AVE5Wipe, CrossfadeNode, `ave5Mask` in MetalContext.
//

import XCTest
import Metal
@testable import VideoboyCore

final class AVE5WipeTests: XCTestCase {

    private let width = 64
    private let height = 48

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    // MARK: - The front panel

    func testPowerOnIsAWipeFromTheRightWithEverythingElseOff() {
        let block = AVE5Wipe()
        XCTAssertEqual(block.keys, .fromRight)
        XCTAssertEqual(block.multi, .off)
        XCTAssertEqual(block.edge, .normal)
        XCTAssertFalse(block.oneWay)
        XCTAssertFalse(block.reverse)
        XCTAssertEqual(block.positionX, 0.5)
        XCTAssertEqual(block.positionY, 0.5)
    }

    func testPatternKeysAreToggles() {
        var block = AVE5Wipe(keys: [])
        block.press(.circle)
        block.press(.fromTop)
        XCTAssertEqual(block.keys, [.circle, .fromTop])
        XCTAssertTrue(block.isLit(.circle))
        block.press(.circle)
        XCTAssertEqual(block.keys, .fromTop)
        XCTAssertFalse(block.isLit(.circle))
    }

    /// Manual p.6, control 8: once ×4, again ×16, a third time back to normal.
    func testMultiCyclesFourThenSixteenThenOff() {
        var block = AVE5Wipe()
        var seen: [AVE5Wipe.Multi] = []
        for _ in 0..<4 {
            block.press(.multi)
            seen.append(block.multi)
        }
        XCTAssertEqual(seen, [.x4, .x16, .off, .x4])
    }

    /// Manual p.8, control 53: Normal → Border → Soft → Normal.
    func testWipeKeyCyclesNormalBorderSoft() {
        var block = AVE5Wipe()
        var seen: [AVE5Wipe.EdgeMode] = []
        for _ in 0..<3 {
            block.press(.wipe)
            seen.append(block.edge)
        }
        XCTAssertEqual(seen, [.border, .soft, .normal])
    }

    /// Manual p.5, control 5: eight colours, stepped by pressing.
    func testBackColourStepsThroughAllEightAndWraps() {
        var block = AVE5Wipe()
        var seen: [AVE5Wipe.BackColour] = [block.backColour]
        for _ in 0..<8 {
            block.press(.backColour)
            seen.append(block.backColour)
        }
        XCTAssertEqual(seen, [.white, .yellow, .cyan, .green, .magenta, .red, .blue, .black, .white])
    }

    func testOneWayAndReverseAreToggles() {
        var block = AVE5Wipe()
        block.press(.oneWay)
        block.press(.reverse)
        XCTAssertTrue(block.oneWay && block.reverse)
        block.press(.oneWay)
        block.press(.reverse)
        XCTAssertFalse(block.oneWay || block.reverse)
    }

    /// The shapes, one row of the manual's table at a time.
    func testTheKeysMakeTheShapesInTheManualsTable() {
        let rows: [(AVE5Wipe.PatternKeys, AVE5Wipe.Shape)] = [
            ([], .cut),
            (.fromRight, .edge),
            (.fromTop, .edge),
            ([.fromRight, .fromLeft], .split),
            ([.fromBottom, .fromTop], .split),
            ([.fromRight, .fromBottom], .cornerBox),
            ([.fromLeft, .fromTop], .cornerBox),
            ([.fromRight, .fromBottom, .fromTop], .edgeBox),
            ([.fromRight, .fromLeft, .fromTop], .edgeBox),
            (.allEdges, .centreBox),
            (.circle, .circle),
            ([.fromRight, .fromTop, .circle], .diagonal),
            ([.fromRight, .circle], .chevron),
            ([.fromTop, .circle], .chevron),
            ([.fromRight, .fromBottom, .fromTop, .circle], .triangle),
            ([.fromRight, .fromLeft, .fromBottom, .circle], .triangle),
            ([.allEdges, .circle], .diamond),
            ([.fromRight, .fromLeft, .circle], .textured),
            ([.fromBottom, .fromTop, .circle], .textured)
        ]
        for (keys, shape) in rows {
            XCTAssertEqual(AVE5Wipe(keys: keys).shape, shape, "keys \(keys.rawValue)")
        }
    }

    /// The table marks exactly three patterns Ⓟ: the box, the circle, the diamond.
    func testOnlyTheThreePMarkedPatternsFollowTheJoystick() {
        var positionable: [Int] = []
        for mask in 0..<32 where AVE5Wipe(keys: .init(rawValue: mask)).isPositionable {
            positionable.append(mask)
        }
        XCTAssertEqual(positionable.sorted(), [
            AVE5Wipe.PatternKeys.allEdges.rawValue,
            AVE5Wipe.PatternKeys.circle.rawValue,
            AVE5Wipe.PatternKeys([.allEdges, .circle]).rawValue
        ].sorted())
    }

    func testEveryStateRoundTripsThroughItsParameters() {
        for mask in 0..<32 {
            for multi in AVE5Wipe.Multi.allCases {
                for edge in AVE5Wipe.EdgeMode.allCases {
                    let block = AVE5Wipe(
                        keys: .init(rawValue: mask), multi: multi, edge: edge,
                        oneWay: mask % 2 == 0, reverse: mask % 3 == 0,
                        backColour: AVE5Wipe.BackColour(rawValue: mask % 8) ?? .white,
                        positionX: 0.25, positionY: 0.75)
                    let values = Dictionary(uniqueKeysWithValues: block.parameterValues)
                    XCTAssertEqual(AVE5Wipe(values: { values[$0] }), block)
                }
            }
        }
    }

    func testEveryKeyHasItsOwnPressCode() {
        let codes = AVE5Wipe.Key.allCases.map(\.triggerCode)
        XCTAssertEqual(Set(codes).count, codes.count)
        for code in codes {
            XCTAssertNotNil(ParamCode(rawValue: code.rawValue), "\(code) must be in the table")
        }
    }

    func testTheNodeRegistersAndReadsTheBlock() {
        let node = CrossfadeNode(identifier: "test.ave5", positionCode: .crossfadeAB, context: nil)
        let registry = ParamRegistry()
        registry.register(slot: node.identifier, parameters: node.parameters)
        var block = AVE5Wipe(keys: [.circle], multi: .x16, edge: .soft, positionX: 0.2)
        block.press(.backColour)
        for (code, value) in block.parameterValues {
            _ = registry.setValue(value, slot: node.identifier, code: code)
        }
        node.applyParameters(from: registry)
        XCTAssertEqual(node.ave5, block)
        for key in AVE5Wipe.Key.allCases {
            XCTAssertNotNil(registry.value(slot: node.identifier, code: key.triggerCode),
                            "a learned \(key.legend) key needs somewhere to land")
        }
    }

    /// ONE-WAY latches at the ENDS of travel: the trip back from B draws reversed,
    /// and wobbling mid-travel does not flip it.
    func testOneWayLatchesAtTheEndsOfTravel() {
        let node = CrossfadeNode(identifier: "test.ave5", positionCode: .crossfadeAB, context: nil)
        node.ave5 = AVE5Wipe(oneWay: true)
        node.position = 0.4
        node.updateOneWayLatch()
        XCTAssertFalse(node.ave5DrawsReversed, "on the way to B")
        node.position = 1
        node.updateOneWayLatch()
        node.position = 0.6
        node.updateOneWayLatch()
        XCTAssertTrue(node.ave5DrawsReversed, "on the way back from B")
        node.position = 0.7
        node.updateOneWayLatch()
        XCTAssertTrue(node.ave5DrawsReversed, "a wobble mid-travel does not flip it")
        node.position = 0
        node.updateOneWayLatch()
        XCTAssertFalse(node.ave5DrawsReversed, "back at A, the next trip is forward")

        node.ave5.reverse = true
        node.position = 1
        node.updateOneWayLatch()
        XCTAssertFalse(node.ave5DrawsReversed, "REVERSE and ONE-WAY's return cancel out")
    }

    // MARK: - The picture: ends of travel

    /// Every combination of keys, every MULTI and edge, REVERSE on and off, the
    /// joystick off-centre: both ends of the fader are the pure sources, every pixel.
    func testFaderEndsArePureForEveryCombination() throws {
        for mask in 0..<32 {
            for multi in AVE5Wipe.Multi.allCases {
                for edge in AVE5Wipe.EdgeMode.allCases {
                    for reverse in [false, true] {
                        let block = AVE5Wipe(
                            keys: .init(rawValue: mask), multi: multi, edge: edge,
                            reverse: reverse, backColour: .green,
                            positionX: 0.1, positionY: 0.85)
                        for (position, expected) in [(0.0, red), (1.0, blue)] {
                            let image = try render(block, position: position)
                            try assertEveryPixel(image, is: expected,
                                "keys \(mask) \(multi) \(edge) reverse \(reverse) at \(position)")
                        }
                    }
                }
            }
        }
    }

    /// The shader against its CPU twin, every combination of keys and MULTI, with
    /// the joystick off-centre, REVERSE on and off.
    func testTheShaderMatchesTheCPUFieldForEveryCombination() throws {
        for mask in 0..<32 {
            for multi in AVE5Wipe.Multi.allCases {
                for reverse in [false, true] {
                    let block = AVE5Wipe(
                        keys: .init(rawValue: mask), multi: multi, reverse: reverse,
                        positionX: 0.3, positionY: 0.6)
                    let image = try render(block, position: 0.4)
                    var disagreements = 0
                    for y in 0..<height {
                        for x in 0..<width {
                            // Pixel centres, as the fragment shader samples them.
                            let u = (Double(x) + 0.5) / Double(width)
                            let v = (Double(y) + 0.5) / Double(height)
                            let expected = block.arrives(
                                u: u, v: v, progress: 0.4,
                                aspect: Double(width) / Double(height), reversed: reverse,
                                pixel: (Double(x) + 0.5, Double(y) + 0.5))
                            let isBlue = image.pixel(x: x, y: y).b > 100
                            if isBlue != expected { disagreements += 1 }
                        }
                    }
                    // The slack is for a float tie exactly on an edge, which GPU and
                    // CPU may round differently.
                    XCTAssertLessThanOrEqual(disagreements, 3,
                        "keys \(mask) \(multi) reverse \(reverse): \(disagreements) pixels disagree")
                }
            }
        }
    }

    // MARK: - The picture: geometry at the midpoint

    func testEdgeKeysBringBInFromTheirSide() throws {
        let right = try render(AVE5Wipe(keys: .fromRight), position: 0.5)
        assertPixel(right, width - 3, height / 2, is: blue, "A|B: B on the right")
        assertPixel(right, 2, height / 2, is: red, "A|B: A still on the left")

        let left = try render(AVE5Wipe(keys: .fromLeft), position: 0.5)
        assertPixel(left, 2, height / 2, is: blue, "B|A: B on the left")

        let bottom = try render(AVE5Wipe(keys: .fromBottom), position: 0.5)
        assertPixel(bottom, width / 2, height - 3, is: blue, "A/B: B at the bottom")
        assertPixel(bottom, width / 2, 2, is: red, "A/B: A still at the top")

        let top = try render(AVE5Wipe(keys: .fromTop), position: 0.5)
        assertPixel(top, width / 2, 2, is: blue, "B/A: B at the top")
    }

    func testBothKeysOfAnAxisOpenFromTheCentre() throws {
        let split = try render(AVE5Wipe(keys: [.fromRight, .fromLeft]), position: 0.4)
        assertPixel(split, width / 2, height / 2, is: blue, "B opens in the middle")
        assertPixel(split, 1, height / 2, is: red, "A stays at the left edge")
        assertPixel(split, width - 2, height / 2, is: red, "and at the right")
    }

    func testOneKeyPerAxisIsACornerBoxAndTheCircleMakesItADiagonal() throws {
        let box = try render(AVE5Wipe(keys: [.fromRight, .fromBottom]), position: 0.4)
        assertPixel(box, width - 3, height - 3, is: blue, "box: B in the bottom-right corner")
        assertPixel(box, width - 3, 2, is: red, "box: top-right still A")
        assertPixel(box, 2, height - 3, is: red, "box: bottom-left still A")

        let diagonal = try render(AVE5Wipe(keys: [.fromRight, .fromBottom, .circle]), position: 0.5)
        assertPixel(diagonal, width - 3, height - 3, is: blue, "diagonal: bottom-right is B")
        assertPixel(diagonal, 2, 2, is: red, "diagonal: top-left is A")
        // The midpoint of a diagonal is its anti-diagonal: top-right and bottom-left
        // are exactly on the edge, so check just inside each side instead.
        assertPixel(diagonal, width * 3 / 4, height * 3 / 4, is: blue, "diagonal: below the line is B")
        assertPixel(diagonal, width / 4, height / 4, is: red, "diagonal: above the line is A")
    }

    func testCentreBoxCircleAndDiamondOpenFromTheCentre() throws {
        for keys: AVE5Wipe.PatternKeys in [.allEdges, .circle, [.allEdges, .circle]] {
            let image = try render(AVE5Wipe(keys: keys), position: 0.3)
            assertPixel(image, width / 2, height / 2, is: blue, "keys \(keys.rawValue): centre is B")
            for (x, y) in corners {
                assertPixel(image, x, y, is: red, "keys \(keys.rawValue): corner (\(x),\(y)) is A")
            }
        }
    }

    /// The joystick moves the three Ⓟ patterns and nothing else.
    func testTheJoystickMovesOnlyThePMarkedPatterns() throws {
        let moved = try render(AVE5Wipe(keys: .circle, positionX: 0.2, positionY: 0.25), position: 0.15)
        assertPixel(moved, width / 5, height / 4, is: blue, "the circle follows the stick")
        assertPixel(moved, width / 2, height / 2, is: red, "and has left the centre")

        let edge = try render(AVE5Wipe(keys: .fromRight, positionX: 0.05), position: 0.5)
        assertPixel(edge, width - 3, height / 2, is: blue, "an edge wipe ignores the stick")
        assertPixel(edge, 2, height / 2, is: red, "an edge wipe ignores the stick")
    }

    /// Manual p.13, 8-1: no pattern key is a cut at the middle of the travel.
    func testNoPatternKeysIsACutAtTheMiddle() throws {
        let before = try render(AVE5Wipe(keys: []), position: 0.45)
        let after = try render(AVE5Wipe(keys: []), position: 0.55)
        try assertEveryPixel(before, is: red, "before the middle")
        try assertEveryPixel(after, is: blue, "after the middle")
    }

    func testMultiTilesThePattern() throws {
        let x4 = try render(AVE5Wipe(keys: .fromRight, multi: .x4), position: 0.5)
        // Each of the two columns of tiles is its own A|B wipe.
        assertPixel(x4, width / 8, height / 4, is: red, "left of the first tile is A")
        assertPixel(x4, width * 3 / 8 + 2, height / 4, is: blue, "right of the first tile is B")
        assertPixel(x4, width * 5 / 8, height * 3 / 4, is: red, "left of the second tile is A")
        assertPixel(x4, width - 3, height * 3 / 4, is: blue, "right of the second tile is B")

        let x16 = try render(AVE5Wipe(keys: .circle, multi: .x16), position: 0.3)
        for column in 0..<4 {
            for row in 0..<4 {
                let x = width * (2 * column + 1) / 8
                let y = height * (2 * row + 1) / 8
                assertPixel(x16, x, y, is: blue, "×16: circle \(column),\(row) has opened")
            }
        }
    }

    /// Manual p.13, 5: the pictures change places.
    func testReversePutsBWhereAWouldHaveStayed() throws {
        let image = try render(AVE5Wipe(keys: .fromRight, reverse: true), position: 0.3)
        assertPixel(image, 2, height / 2, is: blue, "reversed A|B: B comes in from the left")
        assertPixel(image, width - 3, height / 2, is: red, "and A holds the right")
    }

    func testBorderDrawsTheBackColourAlongTheEdge() throws {
        let block = AVE5Wipe(keys: .fromRight, edge: .border, backColour: .green)
        let image = try render(block, position: 0.5)
        var sawBorder = false
        for x in 0..<width {
            let pixel = image.pixel(x: x, y: height / 2)
            if pixel.g > 200 && pixel.r < 30 && pixel.b < 30 { sawBorder = true }
        }
        XCTAssertTrue(sawBorder, "a green band crosses the middle row")
        assertPixel(image, 1, height / 2, is: red, "A beyond the border")
        assertPixel(image, width - 2, height / 2, is: blue, "B inside it")
    }

    func testSoftEdgeHasInBetweenPixels() throws {
        let image = try render(AVE5Wipe(keys: .fromRight, edge: .soft), position: 0.5)
        var sawMix = false
        for x in 0..<width {
            let pixel = image.pixel(x: x, y: height / 2)
            if pixel.r > 30 && pixel.b > 30 { sawMix = true }
        }
        XCTAssertTrue(sawMix, "somewhere across the middle row is part A, part B")
    }

    /// The trip back from B under ONE-WAY (manual p.13, 6): the edge keeps going the
    /// same way. A|B's edge travels right to left as B comes in from the right, so on
    /// the way back it is A that comes in from the right, and the edge still travels
    /// right to left — rather than B retreating the way it came.
    func testOneWayReturnTripDrawsReversed() throws {
        guard let metal = MetalContext.shared else { throw XCTSkip("no Metal device") }
        let node = CrossfadeNode(identifier: "test.ave5", positionCode: .crossfadeAB, context: metal)
        node.transition = .ave5
        node.ave5 = AVE5Wipe(keys: .fromRight, oneWay: true)
        node.position = 1
        _ = try render(node)
        node.position = 0.7
        let image = try render(node)
        assertPixel(image, width - 3, height / 2, is: red, "A returns from the right")
        assertPixel(image, 2, height / 2, is: blue, "B still holds the left")

        node.ave5.oneWay = false
        let retraced = try render(node)
        assertPixel(retraced, width - 3, height / 2, is: blue, "without ONE-WAY, B retreats right")
        assertPixel(retraced, 2, height / 2, is: red, "and A comes back from the left")
    }

    // MARK: - Helpers

    private typealias RGB = (UInt8, UInt8, UInt8)
    private let red: RGB = (200, 0, 0)
    private let blue: RGB = (0, 0, 200)
    private var corners: [(Int, Int)] {
        [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]
    }

    private func render(_ block: AVE5Wipe, position: Double) throws -> ImageBuffer {
        guard let metal = MetalContext.shared else { throw XCTSkip("no Metal device") }
        let node = CrossfadeNode(identifier: "test.ave5", positionCode: .crossfadeAB, context: metal)
        node.transition = .ave5
        node.ave5 = block
        node.position = position
        return try render(node)
    }

    private func render(_ node: CrossfadeNode) throws -> ImageBuffer {
        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        let baseImage = ImageBuffer(width: width, height: height, r: red.0, g: red.1, b: red.2)
        let blendImage = ImageBuffer(width: width, height: height, r: blue.0, g: blue.1, b: blue.2)
        guard let baseTexture = metal.makeTexture(from: baseImage, label: "base"),
              let blendTexture = metal.makeTexture(from: blendImage, label: "blend") else {
            throw XCTSkip("could not upload test images")
        }
        let context = RenderContext(
            frameIndex: 0, presentationTime: 0, musicalPosition: nil, width: width, height: height)
        guard let output = node.render(inputs: [baseTexture, blendTexture], context: context),
              let result = renderer.readback(output) else {
            throw XCTSkip("the transition produced nothing")
        }
        return result
    }

    private func assertEveryPixel(
        _ image: ImageBuffer, is expected: RGB, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for y in 0..<height {
            for x in 0..<width {
                let pixel = image.pixel(x: x, y: y)
                let close = abs(Int(pixel.r) - Int(expected.0)) <= 3
                    && abs(Int(pixel.g) - Int(expected.1)) <= 3
                    && abs(Int(pixel.b) - Int(expected.2)) <= 3
                if !close {
                    XCTFail("\(message): pixel (\(x),\(y)) is (\(pixel.r),\(pixel.g),\(pixel.b))",
                            file: file, line: line)
                    return
                }
            }
        }
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

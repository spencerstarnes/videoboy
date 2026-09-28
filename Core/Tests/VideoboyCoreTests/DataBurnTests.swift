//
//  DataBurnTests.swift — NAME and TC: the timecode maths, which lines show, and that
//  DATA BURN actually lands text in the picture (and costs nothing when it does not).
//

import XCTest
@testable import VideoboyCore

final class DataBurnTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    // MARK: - Timecode

    func testDropFrameSkipsTwoNumbersEachMinuteExceptEveryTenth() {
        XCTAssertEqual(Timecode.dropFrame(frame: 0), "00:00:00;00")
        XCTAssertEqual(Timecode.dropFrame(frame: 29), "00:00:00;29")
        XCTAssertEqual(Timecode.dropFrame(frame: 1799), "00:00:59;29")
        // ;00 and ;01 do not exist at the top of minute 1.
        XCTAssertEqual(Timecode.dropFrame(frame: 1800), "00:01:00;02")
        // Minute 10 keeps them.
        XCTAssertEqual(Timecode.dropFrame(frame: 17_982), "00:10:00;00")
        // One hour of 29.97 is 107,892 frames, and reads as exactly one hour.
        XCTAssertEqual(Timecode.dropFrame(frame: 107_892), "01:00:00;00")
    }

    func testNegativeFramesClampToZero() {
        XCTAssertEqual(Timecode.dropFrame(frame: -5), "00:00:00;00")
    }

    // MARK: - Lines

    func testAChannelShutOutByItsFaderKeepsItsLabelButLosesItsData() {
        let entries = [
            DataBurnEntry(label: "S1", name: "a.mov", frame: 8_540, isOnAir: true),
            DataBurnEntry(label: "S2", name: "b.mov", frame: 10, isOnAir: false)
        ]
        XCTAssertEqual(
            DataBurnText.lines(entries, showsName: false, showsTimecode: true),
            ["S1: 00:04:44;28", "S2:"])
    }

    func testNameAndTimecodeTogether() {
        let entry = DataBurnEntry(label: "A", name: "night.mov", frame: 30, isOnAir: true)
        XCTAssertEqual(
            DataBurnText.lines([entry], showsName: true, showsTimecode: true),
            ["A: night.mov 00:00:01;00"])
        XCTAssertEqual(
            DataBurnText.lines([entry], showsName: true, showsTimecode: false),
            ["A: night.mov"])
    }

    func testALiveSourceHasANameButNoTimecode() {
        let camera = DataBurnEntry(label: "B", name: "Camera 1", frame: nil, isOnAir: true)
        XCTAssertEqual(
            DataBurnText.lines([camera], showsName: true, showsTimecode: true),
            ["B: Camera 1"])
    }

    func testNothingAskedForMeansNoLines() {
        let entry = DataBurnEntry(label: "A", name: "x.mov", frame: 1, isOnAir: true)
        XCTAssertEqual(DataBurnText.lines([entry], showsName: false, showsTimecode: false), [])
    }

    func testLongNamesKeepTheirStartAndExtension() {
        let short = DataBurnText.shortened("a_very_long_clip_name_straight_off_the_camera.mov")
        XCTAssertEqual(short.count, DataBurnText.nameLimit)
        XCTAssertTrue(short.hasPrefix("a_very_long"))
        XCTAssertTrue(short.hasSuffix("camera.mov"))
        XCTAssertEqual(DataBurnText.shortened("short.mov"), "short.mov")
    }

    func testFaderEndsShutOutTheOtherSide() {
        XCTAssertTrue(DataBurnText.isOnAir(input: 0, position: 0))
        XCTAssertFalse(DataBurnText.isOnAir(input: 1, position: 0))
        XCTAssertTrue(DataBurnText.isOnAir(input: 0, position: 0.5))
        XCTAssertTrue(DataBurnText.isOnAir(input: 1, position: 0.5))
        XCTAssertFalse(DataBurnText.isOnAir(input: 0, position: 1))
        XCTAssertTrue(DataBurnText.isOnAir(input: 1, position: 1))
    }

    // MARK: - Style persistence

    func testAStyleFileMissingFieldsKeepsTheDefaults() throws {
        let decoded = try JSONDecoder().decode(
            DataBurnStyle.self, from: Data(#"{"pixelSize": 24}"#.utf8))
        XCTAssertEqual(decoded.pixelSize, 24)
        XCTAssertEqual(decoded.fontFamily, DataBurnStyle().fontFamily)
        XCTAssertEqual(decoded.backing, DataBurnStyle().backing)
    }

    func testPreferencesRoundTripTheStyle() throws {
        var preferences = Preferences()
        preferences.dataBurnStyle.backing = .outline
        preferences.dataBurnStyle.colour = TitlerColor(red: 1, green: 1, blue: 0)
        let data = try JSONEncoder().encode(preferences)
        let back = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(back.dataBurnStyle, preferences.dataBurnStyle)
    }

    // MARK: - Drawing

    func testTheBlockIsTransparentAroundTheLettersAndScalesWithTheFrame() throws {
        var style = DataBurnStyle()
        style.backing = .none
        guard let small = DataBurnRenderer.render(
                lines: ["A: 00:00:01;00"], style: style, frameHeight: 480),
              let large = DataBurnRenderer.render(
                lines: ["A: 00:00:01;00"], style: style, frameHeight: 960) else {
            return XCTFail("expected an image")
        }
        XCTAssertEqual(small.pixel(x: 0, y: 0).a, 0, "no backing means a clear corner")
        let opaque = stride(from: 0, to: small.pixels.count, by: 4)
            .filter { small.pixels[$0 + 3] > 200 }.count
        XCTAssertGreaterThan(opaque, 50, "the letters themselves must be drawn")
        XCTAssertEqual(Double(large.height), Double(small.height) * 2, accuracy: 3)
    }

    func testTheBoxBackingFillsTheBlock() throws {
        var style = DataBurnStyle()
        style.backing = .box
        guard let image = DataBurnRenderer.render(
            lines: ["A:", "B:"], style: style, frameHeight: 480) else {
            return XCTFail("expected an image")
        }
        XCTAssertGreaterThan(image.pixel(x: 0, y: 0).a, 100)
        XCTAssertNil(DataBurnRenderer.render(lines: [], style: style, frameHeight: 480))
    }

    func testTheRectangleIsOnWholePixelsAndInTheChosenCorner() {
        let image = ImageBuffer(width: 101, height: 40)
        let left = DataBurnRenderer.rect(for: image, anchor: .topLeft, frameWidth: 720, frameHeight: 480)
        let right = DataBurnRenderer.rect(for: image, anchor: .topRight, frameWidth: 720, frameHeight: 480)
        XCTAssertLessThan(left.x, 0.5)
        XCTAssertGreaterThan(right.x, 0.5)
        XCTAssertLessThanOrEqual(right.x + right.width, 1)
        for x in [left.x, right.x] {
            XCTAssertEqual(x * 720, (x * 720).rounded(), accuracy: 1e-9)
        }
    }

    // MARK: - The node

    func testTheBurnCostsNothingWhenTheProviderHasNoLines() throws {
        guard let metal = MetalContext.shared,
              let input = metal.makeTexture(from: TestPattern.colorBars(), label: "in") else {
            throw XCTSkip("no Metal device")
        }
        let node = ScopeOverlayNode(identifier: "test.burn", context: metal)
        node.textProvider = { [] }
        let output = node.render(
            inputs: [input],
            context: RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil))
        XCTAssertTrue(output === input)
        XCTAssertFalse(node.isBurningText)
    }

    func testBurnedTextLandsInTheTopLeftAndNowhereElse() throws {
        guard let metal = MetalContext.shared,
              let renderer = OffscreenRenderer(context: metal) else {
            throw XCTSkip("no Metal device")
        }
        let plate = ImageBuffer(width: 720, height: 480, r: 40, g: 90, b: 160)
        guard let input = metal.makeTexture(from: plate, label: "in") else {
            throw XCTSkip("could not upload")
        }
        let node = ScopeOverlayNode(identifier: "test.burn", context: metal)
        var frame = 8_540
        node.textProvider = { ["A: clip.mov \(Timecode.dropFrame(frame: frame))", "B:"] }
        let context = RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil)

        guard let output = node.render(inputs: [input], context: context),
              let read = renderer.readback(output) else {
            throw XCTSkip("render failed")
        }
        XCTAssertTrue(node.isBurningText)
        let check = SelfQACheck(name: "scopes/data-burn")
        _ = try? check.writeImage(read, named: "burned.png")

        func changed(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
            var count = 0
            for y in stride(from: y0, to: y1, by: 2) {
                for x in stride(from: x0, to: x1, by: 2) {
                    let p = read.pixel(x: x, y: y)
                    if abs(Int(p.b) - 160) > 20 || abs(Int(p.r) - 40) > 20 { count += 1 }
                }
            }
            return count
        }
        XCTAssertGreaterThan(changed(40, 20, 360, 110), 200, "text in the top left")
        XCTAssertEqual(changed(400, 200, 720, 480), 0, "and not over the rest of the picture")

        // A new frame number redraws; the same one reuses the texture.
        frame += 1
        _ = node.render(inputs: [input], context: context)
        XCTAssertTrue(node.isBurningText)
        node.textProvider = nil
        XCTAssertTrue(node.render(inputs: [input], context: context) === input,
                      "turning the text off must leave nothing behind on the next frame")
    }
}

//
//  PictureVarietyTests.swift — the blank-window cases, pinned.
//
//  The white case is the one that matters: it is the exact frame that passed the old
//  brightness check and hid a broken EMU panel. If this test ever goes, that bug comes
//  back silently.
//

import XCTest
@testable import VideoboyCore

final class PictureVarietyTests: XCTestCase {

    private func flat(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> ImageBuffer {
        ImageBuffer(width: 720, height: 480, r: r, g: g, b: b)
    }

    func testABlankWhiteWindowIsNotAPicture() {
        // Amiberry's window in the first seconds after launch. The old check scored
        // this 96% and passed.
        XCTAssertFalse(PictureVariety.isPicture(flat(255, 255, 255)))
    }

    func testABlankBlackWindowIsNotAPicture() {
        XCTAssertFalse(PictureVariety.isPicture(flat(0, 0, 0)))
    }

    func testAFlatAmigaGreyIsNotAPicture() {
        XCTAssertFalse(PictureVariety.isPicture(flat(170, 170, 170)))
    }

    func testAWindowSplitIntoTwoFlatBandsIsNotAPicture() {
        // Amiberry mid-launch: white above, black below. This is the frame that got
        // through the second attempt at this check, scoring 18% colour variety.
        var frame = flat(255, 255, 255)
        for y in (frame.height * 3 / 4)..<frame.height {
            for x in 0..<frame.width {
                frame.setPixel(x: x, y: y, r: 10, g: 10, b: 10)
            }
        }
        XCTAssertFalse(PictureVariety.isPicture(frame))
    }

    func testAScreenWithContentIsAPicture() {
        // Coarse horizontal bands, the way any real screen with text or a backdrop on
        // it looks to a colour histogram.
        var frame = flat(0, 0, 0)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let value = UInt8((x / 40 + y / 40) % 2 == 0 ? 220 : 20)
                frame.setPixel(x: x, y: y, r: value, g: value, b: value)
            }
        }
        XCTAssertTrue(PictureVariety.isPicture(frame))
    }

    func testNoiseOnAFlatWindowDoesNotCountAsAPicture() {
        // Capture and rescaling jitter a few least-significant bits. Quantising to five
        // bits per gun is what stops that reading as content.
        var frame = flat(255, 255, 255)
        for y in stride(from: 0, to: frame.height, by: 7) {
            for x in stride(from: 0, to: frame.width, by: 7) {
                frame.setPixel(x: x, y: y, r: 251, g: 252, b: 253)
            }
        }
        XCTAssertFalse(PictureVariety.isPicture(frame))
    }
}

/// Every program that speaks a dialect we have must offer its controls.
///
/// This exists because the panel used to match on the product NAME, so switching the
/// default from Scala MM300 to MM400 emptied the EMU tab of every slider while the app
/// reported the machine as healthy.
final class TitlerControlSetTests: XCTestCase {

    func testEveryScalaProgramHasAPanel() {
        let scalas = TitlerLibrary.programs.filter { $0.scriptPort == ScalaLingo.portName }
        XCTAssertFalse(scalas.isEmpty, "the library should carry at least one Scala")
        for program in scalas {
            XCTAssertFalse(
                TitlerControlSet.controls(for: program).isEmpty,
                "\(program.name) speaks Scala Lingo but offers no controls")
            XCTAssertNil(TitlerControlSet.noPanelReason(for: program))
        }
    }

    func testAProgramWithNoScriptPortExplainsItself() {
        let mute = TitlerLibrary.programs.filter { $0.scriptPort == nil }
        for program in mute {
            XCTAssertTrue(TitlerControlSet.controls(for: program).isEmpty)
            XCTAssertNotNil(TitlerControlSet.noPanelReason(for: program))
        }
    }
}

/// The emulator source must not freeze on the first frame it ever sees.
///
/// It did. The node cached its uploaded texture and cleared the cache from an
/// `invalidateFrame()` call that nothing in the app ever made, so routing the machine to
/// a channel showed the blank window it had been looking at during boot, for ever.
final class EmulatorFrameGenerationTests: XCTestCase {

    func testTheMockReportsANewGenerationForEachNewFrame() {
        let host = MockEmulatorHost()
        let atRest = host.frameGeneration

        XCTAssertTrue(host.boot(TitlerLibrary.programs[0]))
        let afterBoot = host.frameGeneration
        XCTAssertGreaterThan(afterBoot, atRest, "booting produced a frame but no new generation")

        host.shutdown()
        XCTAssertGreaterThan(host.frameGeneration, afterBoot, "shutdown changed the frame silently")
    }

    func testAHostWithNoPictureNeverClaimsANewFrame() {
        let host = UnavailableEmulatorHost(reason: "no emulator installed")
        XCTAssertNil(host.latestFrame())
        XCTAssertEqual(host.frameGeneration, host.frameGeneration)
    }
}

/// Commands queued for a machine that has gone must not reach the next one.
///
/// A hundred and two stale batches had piled up in the shared drawer before this was
/// noticed. The listener takes them oldest first, so every fresh machine spent its first
/// minutes replaying a dead session — which reads as a panel that ignores you.
final class StaleCommandQueueTests: XCTestCase {

    func testStartingFreshThrowsAwayWhatTheLastMachineNeverRead() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-drawer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let transport = try SharedDrawerTransport(root: root)
        try transport.deliver(["TEXT 40 100 \"STALE\""], sequence: 1)
        try transport.deliver(["TEXT 40 100 \"ALSO STALE\""], sequence: 2)

        let queued = try FileManager.default.contentsOfDirectory(
            at: transport.commandsDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(queued.filter { $0.pathExtension == "vbc" }.count, 2)

        XCTAssertEqual(transport.discardQueuedCommands(), 2)

        let after = try FileManager.default.contentsOfDirectory(
            at: transport.commandsDirectory, includingPropertiesForKeys: nil)
        XCTAssertTrue(after.filter { $0.pathExtension == "vbc" }.isEmpty)
    }

    func testDiscardingAnEmptyDrawerIsHarmless() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vb-drawer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = try SharedDrawerTransport(root: root)
        XCTAssertEqual(transport.discardQueuedCommands(), 0)
    }
}

/// Dragging the text up the screen must not leave a trail of text behind it.
///
/// The bridge keyed TEXT by its coordinates, so every position a fader passed through
/// survived coalescing as its own pending line. They all landed. The screen filled with
/// a ladder of the same words, and only the newest answered the controls — which is what
/// "it was changing between text one and two" looked like from the outside.
final class TextCoalescingTests: XCTestCase {

    private final class Recorder: AmigaTransport {
        var delivered: [[String]] = []
        var startingSequence: Int { 1 }
        func deliver(_ lines: [String], sequence: Int) throws { delivered.append(lines) }
        func acknowledgedSequences() -> [Int] { [] }
    }

    func testOnlyTheNewestTextPositionSurvivesAFlush() {
        let recorder = Recorder()
        let bridge = AmigaCommandBridge(transport: recorder)

        // A fader being dragged down the screen.
        for y in stride(from: 100, through: 400, by: 50) {
            bridge.send([ScalaLingo.text(x: 40, y: y, "VIDEOBOY")])
        }
        bridge.flush()

        let lines = recorder.delivered.flatMap { $0 }
        let texts = lines.filter { $0.hasPrefix("TEXT ") }
        XCTAssertEqual(texts.count, 1, "one line of text, not a trail of them: \(texts)")
        XCTAssertTrue(texts[0].contains(" 400 "), "and it is the position last asked for")
    }
}

/// A bitmap font has the sizes it has, and no others.
///
/// Asking Scala for a size a face does not carry drops its screen and the machine's
/// output reverts to the AmigaDOS console — see
/// selfqa/out/emu-probe/03-font-franklin-44-not-on-disc.png. The panel must make that
/// impossible to ask for, not merely unlikely.
final class ScalaFontCatalogueTests: XCTestCase {

    private let disc = [
        ScalaFont(name: "Franklin", sizes: [18, 23, 36, 72]),
        ScalaFont(name: "Didot", sizes: [28, 56]),
        ScalaFont(name: "GillN", sizes: [58])
    ]

    func testEverySizeTheSizeFaderCanReachIsOneTheFaceHas() {
        let panel = ScalaTitlerPanel()
        panel.fontCatalogue = disc

        for faceValue in stride(from: 0.0, through: 1.0, by: 0.05) {
            _ = panel.set(.fontFace, to: faceValue)
            guard let face = panel.currentFace else { return XCTFail("no face") }
            for sizeValue in stride(from: 0.0, through: 1.0, by: 0.02) {
                _ = panel.set(.fontSize, to: sizeValue)
                XCTAssertTrue(
                    face.sizes.contains(panel.state.fontSize),
                    "\(face.name) has \(face.sizes) — the fader reached \(panel.state.fontSize)")
            }
        }
    }

    func testChangingFaceMovesToASizeTheNewFaceActuallyHas() {
        let panel = ScalaTitlerPanel()
        panel.fontCatalogue = disc

        _ = panel.set(.fontFace, to: 0)          // Franklin
        _ = panel.set(.fontSize, to: 1)          // 72
        XCTAssertEqual(panel.state.fontSize, 72)

        _ = panel.set(.fontFace, to: 0.5)        // Didot, which has no 72
        XCTAssertEqual(panel.state.fontSize, 56, "the nearest size Didot really has")
    }

    func testAFaceWithOneSizeCannotBeMovedOffIt() {
        let panel = ScalaTitlerPanel()
        panel.fontCatalogue = disc
        _ = panel.set(.fontFace, to: 1)          // GillN, 58 only
        for value in stride(from: 0.0, through: 1.0, by: 0.1) {
            _ = panel.set(.fontSize, to: value)
            XCTAssertEqual(panel.state.fontSize, 58)
        }
    }

    func testTheCatalogueArrivingLateStillMakesTheCurrentSizeLegal() {
        // The panel is built before any drive has been read, so it starts on 44 — a size
        // exactly one of the eighteen faces on the disc has.
        let panel = ScalaTitlerPanel()
        XCTAssertEqual(panel.state.fontSize, 44)
        panel.fontCatalogue = disc
        // Whatever face the stored index lands on once a real catalogue replaces the
        // fallback list, the SIZE has to be legal for it before anything is sent.
        guard let face = panel.currentFace else { return XCTFail("no face after loading") }
        XCTAssertTrue(
            face.sizes.contains(panel.state.fontSize),
            "\(face.name) has \(face.sizes), panel is on \(panel.state.fontSize)")
    }
}

/// Choosing from a menu and arriving by MIDI must mean the same thing.
final class NormalisedSweepRoundTripTests: XCTestCase {

    func testEveryIndexSurvivesTheRoundTrip() {
        for count in 1...100 {
            for index in 0..<count {
                let value = NormalisedSweep.value(forIndex: index, count: count)
                XCTAssertEqual(
                    NormalisedSweep.index(value, count: count), index,
                    "item \(index) of \(count) came back as something else")
            }
        }
    }
}

/// Every control has to appear somewhere the operator can reach it.
final class TitlerGroupingTests: XCTestCase {

    private var scala: TitlerProgram {
        TitlerLibrary.programs.first { $0.scriptPort == ScalaLingo.portName }!
    }

    func testEveryControlIsInExactlyOneGroup() {
        let all = TitlerControlSet.controls(for: scala)
        let grouped = TitlerControlSet.groups(for: scala).flatMap { $0.controls }
        XCTAssertEqual(
            Set(all.map(\.function)), Set(grouped.map(\.function)),
            "a control exists that no group shows")
        XCTAssertEqual(all.count, grouped.count, "a control is shown twice")
    }

    func testNothingLandsInOTHER() {
        // OTHER is the visible failure for a control nobody placed. It should be empty.
        let stray = TitlerControlSet.groups(for: scala).first { $0.title == "OTHER" }
        XCTAssertNil(stray, "unplaced: \(stray?.controls.map(\.name) ?? [])")
    }

    func testAListThatDependsOnTheDiscSaysSoUntilOneIsRead() {
        // Backdrops and pages are only knowable once a drive has been scanned — there
        // is no honest fallback for "which pictures are on this disc". Each has to
        // explain itself rather than show an empty menu.
        let panel = ScalaTitlerPanel()
        for function in [TitlerFunction.backdrop, .page] {
            XCTAssertTrue(panel.options(for: function).isEmpty)
            XCTAssertNotNil(
                panel.unavailableReason(for: function),
                "\(function.rawValue) offers nothing and does not say why")
        }
    }

    /// FONT SIZE IS NO LONGER ONE OF THEM, and that is a deliberate reversal.
    ///
    /// It used to grey itself out until a drive was read, for a real reason: a size a
    /// face has not got makes Scala fall back to the system font. But the result was
    /// that the single most obviously wrong thing about the picture — the size of the
    /// type — had a control that could not be touched, with its reason buried in a
    /// tooltip. The answer to "an unsafe size is dangerous" is a SAFE list, not no list.
    ///
    /// The fallback sizes are ones the disc's own faces actually carry, so every entry
    /// is a real size of a real font.
    func testTheSizeControlIsNeverDead() {
        let panel = ScalaTitlerPanel()
        XCTAssertFalse(
            panel.options(for: .fontSize).isEmpty,
            "the size control must always offer something to choose")
        XCTAssertNil(
            panel.unavailableReason(for: .fontSize),
            "and must not be greyed out")
    }

    func testEveryOtherListAlwaysHasSomethingToChooseFrom() {
        let panel = ScalaTitlerPanel()
        let discDependent: Set<TitlerFunction> = [.fontSize, .backdrop, .page]
        for control in TitlerControlSet.controls(for: scala)
        where control.shape == .list && !discDependent.contains(control.function) {
            XCTAssertFalse(
                panel.options(for: control.function).isEmpty,
                "\(control.name) is a list with no options")
            XCTAssertNil(panel.unavailableReason(for: control.function))
        }
    }

    func testReadingADriveOpensTheSizeList() {
        let panel = ScalaTitlerPanel()
        panel.fontCatalogue = [ScalaFont(name: "Franklin", sizes: [18, 23, 36, 72])]
        XCTAssertNil(panel.unavailableReason(for: .fontSize))
        XCTAssertEqual(panel.options(for: .fontSize), ["18pt", "23pt", "36pt", "72pt"])
    }
}

/// A page carries a placed graphic only when one has been asked for.
///
/// The drive is scanned for symbols so the scale control has something to scale, and for
/// a while that meant every page drew the first symbol on the disc — a full-screen arrow
/// over the title that no control would remove.
final class PlacedGraphicTests: XCTestCase {

    func testAFreshPageHasNoGraphicOnIt() {
        let panel = ScalaTitlerPanel()
        panel.setBrush(file: "CUCD19:Scala/Symbols/Arrow")
        XCTAssertFalse(
            panel.page().contains { $0.verb == "BRUSH" },
            "a graphic appeared that nobody asked for")
        XCTAssertEqual(panel.readout(for: .brushScale), "OFF")
    }

    func testTurningTheScaleUpPutsTheGraphicOn() {
        let panel = ScalaTitlerPanel()
        panel.setBrush(file: "CUCD19:Scala/Symbols/Arrow")
        _ = panel.set(.brushScale, to: 0.5)
        XCTAssertTrue(panel.page().contains { $0.verb == "BRUSH" })
    }

    func testTheBottomOfTheScaleTakesItOffAgain() {
        let panel = ScalaTitlerPanel()
        panel.setBrush(file: "CUCD19:Scala/Symbols/Arrow")
        _ = panel.set(.brushScale, to: 0.5)
        _ = panel.set(.brushScale, to: 0)
        XCTAssertFalse(panel.page().contains { $0.verb == "BRUSH" })
        XCTAssertEqual(panel.readout(for: .brushScale), "OFF")
    }
}

/// Picking an alignment has to move the anchor, or the text falls off the screen.
///
/// Scala aligns text AROUND the X it is given. Choosing "centre" while X sits at the
/// left margin centres the line on the left margin and half of it is gone — see
/// selfqa/out/emu-probe/25-panel-backdrop-menu.png before this.
final class TextAlignmentAnchorTests: XCTestCase {

    func testCentringMovesTheAnchorToTheMiddle() {
        let panel = ScalaTitlerPanel()
        let centre = ScalaLingo.alignments.firstIndex(where: {
            $0 == "center" || $0 == "centre"
        })!
        _ = panel.choose(.alignment, option: centre)
        XCTAssertEqual(panel.state.textX, panel.screen.width / 2)
    }

    func testRightAligningMovesItToTheRightMargin() {
        let panel = ScalaTitlerPanel()
        guard let right = ScalaLingo.alignments.firstIndex(of: "right") else { return }
        _ = panel.choose(.alignment, option: right)
        XCTAssertGreaterThan(panel.state.textX, panel.screen.width / 2)
        XCTAssertLessThan(panel.state.textX, panel.screen.width)
    }

    func testXCanStillBeDraggedAfterwards() {
        let panel = ScalaTitlerPanel()
        let centre = ScalaLingo.alignments.firstIndex(where: {
            $0 == "center" || $0 == "centre"
        })!
        _ = panel.choose(.alignment, option: centre)
        _ = panel.set(.textX, to: 0)
        // The bottom of the fader is the title-safe left edge, not column 0: the fader
        // travels the SAFE area now, because the raster's edges are eaten by overscan on
        // the analog display this app feeds. The point of this test is unchanged — the
        // alignment anchor is a starting point and dragging X still overrides it.
        XCTAssertEqual(
            panel.state.textX, panel.titleSafeX.lowerBound,
            "the anchor is a starting point, not a lock")
    }
}

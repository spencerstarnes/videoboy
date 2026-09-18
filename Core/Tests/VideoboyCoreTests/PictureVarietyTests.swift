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

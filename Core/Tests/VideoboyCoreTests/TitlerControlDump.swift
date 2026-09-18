//
//  TitlerControlDump.swift — what the translation layer actually sends.
//
//  These exist because the panel's failure mode is silence: a control that emits
//  nothing, or emits something Scala ignores, looks identical to one that works until
//  you are watching the machine. So rather than test the state, these test the LINES.
//

import XCTest
@testable import VideoboyCore

final class TitlerControlDump: XCTestCase {

    private func panel() -> ScalaTitlerPanel {
        Log.echoesToStandardError = false
        let panel = ScalaTitlerPanel()
        panel.backdrops = ["CUCD19:Scala/Backgrounds/Fabrics001"]
        panel.pageNames = ["Page1", "Page2"]
        return panel
    }

    /// THE FADE BUG. Every control that redraws ends in SHOW, and SHOW performs the
    /// WIPE — so with the wipe defaulting to `fade`, moving any of the fourteen
    /// controls that emit a page faded the whole screen out and back in. On a titler
    /// that is on air that is an unrequested transition in the middle of a show.
    func testEditingNeverAnimates() {
        let panel = self.panel()
        // Dial the wipe to something unmistakably animated first.
        _ = panel.set(.wipe, to: 0.4)

        for function in TitlerFunction.allCases {
            let commands = panel.set(function, to: 0.6)
            guard let wipe = commands.first(where: { $0.verb == "WIPE" }) else { continue }
            XCTAssertTrue(
                wipe.line.contains(ScalaLingo.instantWipe),
                "\(function.rawValue) redraws with '\(wipe.line)' — editing a page must "
                    + "cut, not run a transition nobody asked for")
        }
    }

    /// And the converse: a deliberate take is the one thing that SHOULD use the wipe,
    /// or the control is decorative.
    func testTakingUsesTheChosenWipe() {
        let panel = self.panel()
        _ = panel.set(.wipe, to: 0.4)
        let taken = panel.take()
        guard let wipe = taken.first(where: { $0.verb == "WIPE" }) else {
            return XCTFail("a take must carry a WIPE")
        }
        XCTAssertFalse(
            wipe.line.contains(" \(ScalaLingo.instantWipe) "),
            "take() must use the dialled wipe, not cut — got '\(wipe.line)'")
    }

    /// Every control either does something or says why it cannot. A control that
    /// silently emits nothing is the exact failure this layer exists to prevent.
    func testNoControlIsSilentlyInert() {
        let panel = self.panel()
        for function in TitlerFunction.allCases {
            let commands = panel.set(function, to: 0.5)
            if commands.isEmpty {
                XCTAssertNotNil(
                    panel.unavailableReason(for: function),
                    "\(function.rawValue) emitted nothing and gives no reason — that is "
                        + "a dead control that looks alive")
            }
        }
    }
}

// MARK: - Title safety

extension TitlerControlDump {

    /// The output of this app goes to an analog SD display, where the edges of the
    /// raster are eaten by overscan. Faders that travel the whole raster put captions
    /// where a television cannot show them — and the preview looks perfectly fine,
    /// which is what makes it a trap rather than an obvious mistake.
    func testTextCannotBePlacedIntoOverscan() {
        let panel = self.panel()
        for extreme in [0.0, 1.0] {
            _ = panel.set(.textX, to: extreme)
            _ = panel.set(.textY, to: extreme)
            let page = panel.page()
            guard let text = page.first(where: { $0.verb == "TEXT" }) else {
                return XCTFail("a page must carry TEXT")
            }
            let parts = text.line.split(separator: " ")
            guard parts.count >= 3, let x = Int(parts[1]), let y = Int(parts[2]) else {
                return XCTFail("could not read the position out of '\(text.line)'")
            }
            XCTAssertTrue(
                panel.titleSafeX.contains(x),
                "x=\(x) at fader \(extreme) is outside title-safe \(panel.titleSafeX)")
            XCTAssertTrue(
                panel.titleSafeY.contains(y),
                "y=\(y) at fader \(extreme) is outside title-safe \(panel.titleSafeY)")
        }
    }
}

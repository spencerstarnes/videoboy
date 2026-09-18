//
//  EmuProbe.swift — ask the real Amiga what each control actually does.
//
//  Purpose : Drives one control at a time on a running machine and photographs the
//            result, so the panel can be designed from what Scala DOES rather than from
//            what its manual implies. Every question answered here was previously
//            answered by reading command names and guessing.
//  Inputs   : a set-up machine (scripts/amiga.sh setup) and an installed emulator.
//  Outputs  : selfqa/out/emu-probe/<nn>-<name>.png, one per step, plus a written log.
//  Connects : EmulatorController (the machine), ScalaTitlerPanel (the translation
//             layer being probed), SelfQARunner.
//  Extend   : add a step to `plan()`. A step is a label, some commands, and how long to
//            let the machine settle — nothing else, because a probe that needs its own
//            abstractions stops being a probe.
//
//  NOT A PASS/FAIL CHECK. It answers questions; a person reads the pictures. It is
//  opt-in for the same reasons the emu check is: real process, real window, real
//  permission.
//

import AppKit
import VideoboyCore

enum EmuProbe {

    /// One thing to try, and how long to let the machine finish doing it.
    struct Step {
        let label: String
        let commands: [TitlerCommand]
        var settle: TimeInterval = 2.5
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "emu-probe")

        guard AmiberryInstallation.isInstalled() || FSUAEInstallation.isInstalled() else {
            check.record(AssertionResult(
                name: "an emulator is installed", passed: false,
                detail: AmiberryInstallation.installationHint))
            return check.finish()
        }

        let controller = EmulatorController()
        guard controller.isSetUp, controller.start() else {
            check.record(AssertionResult(
                name: "the machine starts", passed: false,
                detail: controller.host.unavailableReason ?? "run scripts/amiga.sh setup"))
            return check.finish()
        }
        defer { controller.stop() }

        // Wait for the port, not for a fixed time: the boot is around twenty seconds and
        // varies with what else the Mac is doing.
        let ready = Date().addingTimeInterval(90)
        while Date() < ready, controller.machineStatus == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        guard controller.machineStatus != nil else {
            check.record(AssertionResult(
                name: "the machine answers", passed: false, detail: "no heartbeat in 90s"))
            return check.finish()
        }
        check.record(AssertionResult(
            name: "the machine answers", passed: true, detail: controller.machineStatus ?? ""))

        var previous: ImageBuffer?
        var changed = 0
        var inert: [String] = []

        check.note("fonts on this drive: " + controller.panel.fontCatalogue
            .map { "\($0.name) \($0.sizes.map(String.init).joined(separator: "/"))" }
            .joined(separator: ", "))

        for (index, step) in plan(controller.panel).enumerated() {
            controller.send(step.commands)
            let until = Date().addingTimeInterval(step.settle)
            while Date() < until {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }

            guard let frame = controller.host.latestFrame() else {
                check.note(String(format: "%02d %@ — NO FRAME", index, step.label))
                continue
            }
            let name = String(format: "%02d-%@.png", index, slug(step.label))
            _ = try? check.writeImage(frame, named: name)

            // Did anything happen at all? A control that never changes the picture is
            // either wired to nothing or is not a control — and either way the panel
            // should not be offering it as one.
            let moved = previous.map { FrameAssertions.differingPixelFraction($0, frame) } ?? 1
            if moved > 0.0005 { changed += 1 } else { inert.append(step.label) }
            // The frame COUNT as well as the picture. "Nothing changed" has two very
            // different causes — the machine stopped drawing, or the capture stopped
            // delivering — and without this they are indistinguishable.
            check.note(String(format: "%02d %@ — %.3f moved, %d frames captured → %@",
                              index, step.label, moved,
                              controller.host.capturedFrameCount, name))
            previous = frame
        }

        check.record(AssertionResult(
            name: "the probe reached the machine",
            passed: changed > 0,
            detail: "\(changed) steps changed the picture"))
        if !inert.isEmpty {
            check.note("steps that changed NOTHING: " + inert.joined(separator: ", "))
        }
        return check.finish()
    }

    /// The questions, each asked against the same baseline.
    ///
    /// Measured against a FIXED baseline rather than against the previous step, because
    /// a chain of deltas cannot tell "this control does nothing" from "the control
    /// before it left the machine somewhere odd" — which is how the first run of this
    /// probe reported forty dead controls that were fine.
    private static func plan(_ panel: ScalaTitlerPanel) -> [Step] {
        var steps: [Step] = []

        /// A complete, known page. Everything is stated; nothing is inherited.
        func page(
            font: String = "Franklin", size: Int = 36,
            text: String = "SIZE TEST", at point: (x: Int, y: Int) = (40, 100),
            palette: [ScalaColour] = [.black, .white],
            extra: [TitlerCommand] = []
        ) -> [TitlerCommand] {
            [
                ScalaLingo.screen(width: 640, height: 512, interlaced: true),
                ScalaLingo.palette(palette),
                ScalaLingo.colour(fill: 1),
                ScalaLingo.font(font, size: size),
                ScalaLingo.attributes(["left"]),
                ScalaLingo.wipe("cut", direction: nil, speed: 1),
                ScalaLingo.textWipe("dump", speed: 1)
            ] + extra + [
                ScalaLingo.text(x: point.x, y: point.y, text),
                ScalaLingo.show()
            ]
        }

        func ask(_ label: String, _ commands: [TitlerCommand], settle: TimeInterval = 3) {
            steps.append(Step(label: label, commands: commands, settle: settle))
        }

        // ── Q1. Does a size the font actually HAS look different from one it does not?
        //
        // Amiga fonts are bitmaps. Franklin exists at 18, 23, 36 and 72 and at no other
        // size. The panel offers a continuous 12...114 fader and defaults to 44, which
        // only BetonC has. This asks what Scala does with a size that is not there.
        ask("font franklin 18", page(size: 18))
        ask("font franklin 36", page(size: 36))
        ask("font franklin 72", page(size: 72))
        ask("font franklin 44 NOT ON DISC", page(size: 44))
        ask("font newsgothic 56", page(font: "NewsGothic", size: 56))
        ask("font newsgothic 44 NOT ON DISC", page(font: "NewsGothic", size: 44))

        // ── Q2. Do TEXT's coordinates actually move the text?
        ask("text at 40,100", page(at: (40, 100)))
        ask("text at 300,300", page(at: (300, 300)))
        ask("text at 40,400", page(at: (40, 400)))

        // ── Q3. Does PALETTE reach the text and the ground behind it?
        ask("palette white on black", page(palette: [.black, .white]))
        ask("palette red on black", page(palette: [.black, ScalaColour(red: 1, green: 0, blue: 0)]))
        ask("palette black on yellow", page(
            palette: [ScalaColour(red: 1, green: 1, blue: 0), .black]))

        // ── Q4. Does a backdrop appear, and is the app's path right?
        if let backdrop = panel.backdrops.first {
            ask("backdrop " + backdrop, page(extra: [ScalaLingo.picture(backdrop)]), settle: 6)
        } else {
            steps.append(Step(label: "NO BACKDROPS KNOWN", commands: [], settle: 0))
        }

        // ── Q5. Two TEXTs on one page: does the second replace the first or join it?
        //
        // This is the behaviour behind "it was changing between text one and two, and
        // text two seemed to be the one that was editable".
        ask("two texts on one page", page(
            text: "SECOND", at: (40, 300),
            extra: [ScalaLingo.text(x: 40, y: 100, "FIRST")]))
        ask("one text again", page(text: "ONLY", at: (40, 100)))

        // ── Q6. A bar behind the text.
        ask("box behind the text", page(
            extra: [ScalaLingo.box(x1: 0, y1: 80, x2: 639, y2: 160)]))

        // ── Q7. THE PANEL'S OWN PATH ────────────────────────────────────────────────
        //
        // Everything above sends hand-written Lingo, which proves what Scala does and
        // nothing about what the panel does. These go through `choose` and `setText` —
        // the exact calls a menu and a text field make — so a picture here is a picture
        // of the control working, not of the dialect working.
        _ = panel.setText("LOWER THIRD", line: 0)
        ask("panel: two lines through setText", panel.setText("SECOND LINE", line: 1),
            settle: 5)

        if let face = panel.fontCatalogue.firstIndex(where: { $0.name == "FuturaB" }) {
            ask("panel: FONT menu to FuturaB", panel.choose(.fontFace, option: face))
            // Its real sizes, chosen the way the size menu chooses them.
            for size in 0..<panel.faceSizes.count {
                ask("panel: SIZE menu item \(size) — \(panel.faceSizes[size])pt",
                    panel.choose(.fontSize, option: size))
            }
        }
        ask("panel: ALIGN menu to centre", panel.choose(.alignment, option: 1))
        ask("panel: EDGE menu to bevel", panel.choose(.decoration, option: 3))
        ask("panel: ITALIC switch on", panel.set(.italic, to: 1))
        ask("panel: BACKDROP menu", panel.choose(.backdrop, option: 3), settle: 6)

        return steps
    }

    /// Forces a page to appear at once rather than wiping in.
    ///
    /// Probing what a control LOOKS like and probing how long it takes to get there are
    /// two different questions, and asking them together answers neither.
    private static func instantly(_ commands: [TitlerCommand]) -> [TitlerCommand] {
        commands.map { command in
            if command.line.hasPrefix("WIPE ") {
                return ScalaLingo.wipe("cut", direction: nil, speed: 1)
            }
            if command.line.hasPrefix("TEXTWIPE ") {
                return ScalaLingo.textWipe("dump", speed: 1)
            }
            return command
        }
    }

    private static func slug(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}

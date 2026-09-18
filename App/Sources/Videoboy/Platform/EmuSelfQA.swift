//
//  EmuSelfQA.swift — does the emulated machine's picture actually reach us?
//
//  Purpose : Starts the emulator, waits for the capture, and writes what came back.
//            This is the one part of the EMU path that cannot be checked headlessly:
//            it needs a real process, a real window and Screen Recording permission.
//  Inputs   : whatever machine `scripts/amiga.sh setup` has built.
//  Outputs  : PASS/FAIL plus captured frames in selfqa/out/phase-4/emu-capture/.
//  Connects : SelfQARunner, EmulatorController, FSUAEHost.
//  Extend   : anything about DRIVING the machine is checked in Core, headlessly, with
//            a mock. This is only about whether pixels arrive.
//
//  OPT-IN, like the DVC100 loopback, and for the same reason: it launches another
//  application and needs a permission the app cannot grant itself. It is not in
//  `verify.sh` and must never be — a check that fails on a machine with no emulator
//  installed is a check that stops being read.
//

import AppKit
import VideoboyCore

enum EmuSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "phase-4/emu-capture")

        // 1. Is there an emulator at all?
        let amiberry = AmiberryInstallation.isInstalled()
        let fsuae = FSUAEInstallation.isInstalled()
        check.record(AssertionResult(
            name: "an emulator is installed",
            passed: amiberry || fsuae,
            detail: amiberry ? "Amiberry" : (fsuae ? "FS-UAE (Amiberry preferred)" : "none")
        ))
        guard amiberry || fsuae else {
            check.record(AssertionResult(
                name: "blocked", passed: false,
                detail: AmiberryInstallation.installationHint))
            return check.finish()
        }

        // 2. Has a machine been built?
        let controller = EmulatorController()
        check.record(AssertionResult(
            name: "a machine has been set up",
            passed: controller.isSetUp,
            detail: controller.isSetUp
                ? EmulatorController.workspace.path
                : "run scripts/amiga.sh setup"
        ))
        guard controller.isSetUp else { return check.finish() }

        // 3. Start it and wait for pixels.
        let started = controller.start()
        check.record(AssertionResult(
            name: "the emulator starts",
            passed: started,
            detail: started ? "running" : (controller.host.unavailableReason ?? "unknown")
        ))
        guard started else { return check.finish() }
        defer { controller.stop() }

        // Generous, and it waits for a picture rather than for A picture: an Amiga
        // takes a while to put anything on screen, and the first frames captured are of
        // a window that has not drawn yet. Asserting on those is how a check passes
        // while the machine is still black.
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(60)
        var frame: ImageBuffer?
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            guard let candidate = controller.host.latestFrame() else { continue }
            frame = candidate
            if PictureVariety.isPicture(candidate) { break }
        }

        guard let frame else {
            check.record(AssertionResult(
                name: "frames arrive from the machine",
                passed: false,
                detail: controller.host.unavailableReason
                    ?? "no frame in 45 seconds — Screen Recording permission is the "
                        + "usual cause; System Settings > Privacy & Security"
            ))
            return check.finish()
        }

        let waited = Date().timeIntervalSince(startedAt)
        check.record(AssertionResult(
            name: "frames arrive from the machine",
            passed: true,
            detail: String(format: "%d captured in %.0fs",
                           controller.host.capturedFrameCount, waited)))

        check.record(AssertionResult(
            name: "the picture is the project's geometry",
            passed: frame.width == StandardDefinition.width
                && frame.height == StandardDefinition.height,
            detail: "\(frame.width)x\(frame.height)"))

        // Variety, NOT brightness. This assertion used to measure how much of the
        // picture was above a luminance floor, which was written to catch a machine
        // still showing black and did not catch white. Amiberry's window is blank white
        // for the first seconds after launch: it scored 96%, passed, and the check
        // reported a working machine — with a captured PNG of an empty rectangle —
        // while the operator pressed START and watched nothing happen. See
        // PictureVariety for the measure and the cases pinned around it.
        let variety = PictureVariety.score(of: frame)
        check.record(AssertionResult(
            name: "the machine has actually drawn something",
            passed: variety > PictureVariety.readyThreshold,
            detail: variety > PictureVariety.readyThreshold
                ? String(format: "%.1f%% of the picture carries detail", variety * 100)
                : String(format: "the window is still blank — %.2f%% detail after %.0fs",
                         variety * 100, waited)))

        _ = try? check.writeImage(frame, named: "captured.png")

        // 4. And does the command link answer?
        let deadline2 = Date().addingTimeInterval(30)
        while Date() < deadline2, controller.machineStatus == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        check.record(AssertionResult(
            name: "the machine answers the command link",
            passed: controller.machineStatus != nil,
            detail: controller.machineStatus ?? "no heartbeat in 30 seconds"))

        // The frame above is whatever was on screen the moment pixels first arrived,
        // which on a cold boot is the AmigaDOS console. Useful, but it is not what the
        // operator is waiting for. Once the link answers, drive the titler and save the
        // result: a PNG of Scala with text on it is the only evidence that the whole
        // path — command out, Amiga, capture back — actually closes.
        if controller.machineStatus != nil {
            controller.synchronise()
            let settled = Date().addingTimeInterval(20)
            while Date() < settled {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
            if let titled = controller.host.latestFrame() {
                let detail = PictureVariety.score(of: titled)
                // NOT `isPicture`. That asks "has this window drawn anything at all",
                // which is the right question about a blank emulator and the wrong one
                // about a TITLE CARD: white text on a black field is what Scala is for,
                // and it legitimately carries under 1% local detail — measured at 0.9%
                // against a 1.0% threshold, so the check failed on a picture that was
                // demonstrably correct in the PNG beside it.
                //
                // What actually proves the titler is up is that the command CHANGED the
                // screen, and the "machine redrew after the text changed" assertion
                // below tests exactly that. This one records what is on screen and only
                // fails when nothing arrived at all.
                check.record(AssertionResult(
                    name: "the titler is up and taking commands",
                    passed: detail > 0,
                    detail: String(format: "%.1f%% detail — see titled.png", detail * 100)))
                _ = try? check.writeImage(titled, named: "titled.png")
            }

            // AND DOES IT REACH PROGRAM. Everything above proves the machine draws and
            // that Videoboy can capture it; none of it proves the picture survives the
            // trip through the graph to the output the operator is actually looking at.
            // It did not: the source node cached its uploaded texture and cleared that
            // cache from a call nothing made, so a channel pointed at the Amiga showed
            // the blank boot window for ever.
            renderCheck: do {
                guard let metal = MetalContext.shared,
                      let renderer = OffscreenRenderer(context: metal) else {
                    check.record(AssertionResult(
                        name: "the machine reaches PROGRAM", passed: false,
                        detail: "no Metal device"))
                    break renderCheck
                }

                let engine = Engine()
                engine.emulator?.host = controller.host
                engine.setChannelSource(.emulator, channel: "A")
                // A fully to PROGRAM, so what comes out is the machine and nothing else.
                engine.registry.setValue(0, slot: GraphTopology.primary, code: .crossfadeOneTwo)
                engine.registry.setValue(0, slot: GraphTopology.subMixOne, code: .crossfadeAB)

                func renderProgram(frameIndex: Int) -> ImageBuffer? {
                    let context = RenderContext(
                        frameIndex: frameIndex,
                        presentationTime: Double(frameIndex) / 29.97,
                        musicalPosition: nil)
                    let produced = engine.evaluateGraph(context: context)
                    guard let texture = produced[Engine.outputSlot]
                        ?? produced[GraphTopology.primary] else { return nil }
                    return renderer.readback(texture)
                }

                guard let onProgram = renderProgram(frameIndex: 1) else {
                    check.record(AssertionResult(
                        name: "the machine reaches PROGRAM", passed: false,
                        detail: "PROGRAM produced no frame at all"))
                    break renderCheck
                }
                // THE QUESTION IS WHETHER THE PICTURE SURVIVED THE GRAPH, and that is a
                // comparison, not a threshold. Asking `isPicture` of the programme
                // output asks how detailed the Amiga's screen happens to be — so a
                // title card, which is the thing this machine exists to produce, failed
                // a check named "the machine reaches PROGRAM" while reaching PROGRAM
                // perfectly (0.9% against a 1.0% threshold, with the correct picture in
                // on-program.png).
                //
                // Measured against the HOST frame instead: whatever the machine is
                // showing, near enough of it has to come out the other end. That still
                // catches the failure this check was written for — the source node
                // caching a texture and never updating it, which produces a programme
                // output with nothing of the machine in it — and it stops depending on
                // what the Amiga chose to draw.
                let detail = PictureVariety.score(of: onProgram)
                let hostDetail = controller.host.latestFrame().map(PictureVariety.score) ?? 0
                let survived = hostDetail <= 0 || detail >= hostDetail * 0.7
                check.record(AssertionResult(
                    name: "the machine reaches PROGRAM",
                    passed: survived,
                    detail: String(
                        format: "%.1f%% detail on the programme output, host has %.1f%%",
                        detail * 100, hostDetail * 100)))
                _ = try? check.writeImage(onProgram, named: "on-program.png")

                // And it must still be MOVING. A frozen source passes every test above,
                // because a still picture of a title is a perfectly good picture.
                let hostBefore = controller.host.latestFrame()
                // Through the ordinary path a typed character takes. Anything else
                // would prove the machine can redraw without proving the app can make
                // it, which is the distinction that mattered here.
                controller.setText("SECOND LINE")
                let moved = Date().addingTimeInterval(20)
                while Date() < moved {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                }
                // Captured from the HOST as well as from PROGRAM, because "the picture
                // did not change" has two completely different causes — the machine did
                // not redraw, or our pipeline froze — and they are fixed in different
                // places. Comparing both says which.
                if let hostBefore, let hostAfter = controller.host.latestFrame() {
                    check.record(FrameAssertions.framesDiffer(
                        hostBefore, hostAfter, minimumFraction: 0.001,
                        name: "the machine itself redrew after the text changed"))
                    _ = try? check.writeImage(hostAfter, named: "host-after-text.png")
                }
                if let later = renderProgram(frameIndex: 2) {
                    check.record(FrameAssertions.framesDiffer(
                        onProgram, later, minimumFraction: 0.001,
                        name: "the picture on PROGRAM is live, not the first frame frozen"))
                    _ = try? check.writeImage(later, named: "on-program-changed.png")
                }
            }
        }

        return check.finish()
    }
}

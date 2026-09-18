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
                check.record(AssertionResult(
                    name: "the titler is up and taking commands",
                    passed: PictureVariety.isPicture(titled),
                    detail: String(format: "%.1f%% detail — see titled.png", detail * 100)))
                _ = try? check.writeImage(titled, named: "titled.png")
            }
        }

        return check.finish()
    }
}

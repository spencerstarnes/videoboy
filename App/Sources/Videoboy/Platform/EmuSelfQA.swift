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

    /// How much of the PICTURE is lit, ignoring the outer eighth.
    ///
    /// The outer band is where window chrome and letterboxing live, and both are
    /// present whether or not the machine has drawn anything.
    static func contentFraction(of frame: ImageBuffer) -> Double {
        let insetX = frame.width / 8
        let insetY = frame.height / 8
        var lit = 0
        var total = 0
        for y in stride(from: insetY, to: frame.height - insetY, by: 4) {
            for x in stride(from: insetX, to: frame.width - insetX, by: 4) {
                let pixel = frame.pixel(x: x, y: y)
                total += 1
                if Int(pixel.r) + Int(pixel.g) + Int(pixel.b) > 60 { lit += 1 }
            }
        }
        return total > 0 ? Double(lit) / Double(total) : 0
    }

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
        let deadline = Date().addingTimeInterval(60)
        var frame: ImageBuffer?
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            guard let candidate = controller.host.latestFrame() else { continue }
            frame = candidate
            if Self.contentFraction(of: candidate) > 0.02 { break }
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

        check.record(AssertionResult(
            name: "frames arrive from the machine",
            passed: true,
            detail: "\(controller.host.capturedFrameCount) captured"))

        check.record(AssertionResult(
            name: "the picture is the project's geometry",
            passed: frame.width == StandardDefinition.width
                && frame.height == StandardDefinition.height,
            detail: "\(frame.width)x\(frame.height)"))

        // Measured over the MIDDLE of the frame only. A window capture used to include
        // the title bar, and grey chrome made this pass at 76% while the machine itself
        // was still solid black — a check that passes for the wrong reason is worse
        // than one that fails.
        let lit = Self.contentFraction(of: frame)
        check.record(AssertionResult(
            name: "the machine has actually drawn something",
            passed: lit > 0.02,
            detail: String(format: "%.1f%% of the picture area is lit", lit * 100)))

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

        return check.finish()
    }
}

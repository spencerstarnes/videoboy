//
//  SelfQARunner.swift — runs a self-QA check from inside the app bundle.
//
//  Purpose : Some checks can only run here. Camera permission is granted to a bundle
//            identifier, and display enumeration needs a real NSApplication, so the
//            loopback and display checks live in the app rather than in a unit test.
//  Inputs  : a check name, from `Videoboy --selfqa <check>`.
//  Outputs : artifacts under selfqa/out/<check>/ and a process exit code —
//            0 for pass or blocked, 1 for fail.
//  Connects: AVFoundationCaptureSource (frames), DisplayRouter (what mode we claim),
//            Core's SelfQACheck/FrameAssertions (verdict and artifacts).
//  Extend  : add a case to `run(check:)` and a matching function. Environmental
//            problems must call `finish(blockedReason:)`, never record a failure.
//

import AppKit
import Foundation
import VideoboyCore

/// Entry point for `--selfqa`.
enum SelfQARunner {

    /// Runs one named check. Returns a process exit code.
    static func run(check: String) -> Int32 {
        Log.info(.selfqa, "running self-QA check '\(check)'")
        let verdict: SelfQAVerdict
        switch check {
        case "loopback":
            verdict = runLoopback()
        case "displays":
            verdict = runDisplays()
        case "ui":
            verdict = UISelfQA.run()
        default:
            Log.error(.selfqa, "unknown check '\(check)' (try: loopback, displays, ui)")
            return 2
        }
        // Blocked is not a failure: absent hardware must never fail a build.
        return verdict == .fail ? 1 : 0
    }

    // MARK: - Displays

    /// Records what displays exist and which one output would go to. No hardware
    /// assertions — this is provenance for the loopback check that follows it.
    private static func runDisplays() -> SelfQAVerdict {
        let check = SelfQACheck(name: "phase-2/displays")
        let config = DeviceConfig.load()
        let displays = DisplayRouter.availableDisplays()

        check.note("displays seen: \(displays.count)")
        for display in displays {
            check.note("  '\(display.name)' \(display.modeDescription)\(display.isMain ? " [main]" : "")")
        }

        guard let target = DisplayRouter.preferredOutputDisplay(config: config) else {
            check.record(AssertionResult(
                name: "an output display exists", passed: false, detail: "no displays enumerated"))
            return check.finish()
        }
        let negotiated = DisplayRouter.negotiate(display: target, requested: config.requestedMode)
        check.note("output target: '\(target.name)' negotiated \(negotiated)")
        check.record(AssertionResult(
            name: "an output display exists",
            passed: true,
            detail: "'\(target.name)' at \(negotiated)"
        ))
        return check.finish()
    }

    // MARK: - Loopback

    /// The DVC100 loopback: capture the real analog-facing signal and measure it.
    ///
    /// Assertions follow BUILD-PLAN Phase 2: a stable SD rate with no runaway drops,
    /// a logged mode recorded alongside the captured one, and frames carrying picture.
    private static func runLoopback() -> SelfQAVerdict {
        let check = SelfQACheck(name: "phase-2/loopback")
        let config = DeviceConfig.load()

        guard let deviceName = config.loopbackCapture?.name else {
            return check.finish(blockedReason:
                "config/devices.json has no loopback_capture.name — cannot tell which device is the DVC100")
        }

        // What the app believes it is emitting, carried into metrics.json for
        // comparison with what the grabber actually received.
        let loggedOutputMode: String
        if let target = DisplayRouter.preferredOutputDisplay(config: config) {
            loggedOutputMode = DisplayRouter.negotiate(display: target, requested: config.requestedMode)
            check.note("output display: '\(target.name)'")
        } else {
            loggedOutputMode = "no display"
            check.note("no output display could be resolved")
        }

        let expectedFormat = config.loopbackCapture?.expectedFormat
        let expectedFps = expectedFormat?.fps ?? StandardDefinition.frameRate

        let source = AVFoundationCaptureSource()
        check.note("capture devices visible: \(source.enumerateDeviceNames().joined(separator: ", "))")

        let request = CaptureRequest(
            deviceNameContains: deviceName,
            frameCount: 120,
            expectedFrameRate: expectedFps,
            loggedOutputMode: loggedOutputMode
        )

        let sequence: CapturedSequence
        do {
            sequence = try source.capture(request)
        } catch let error as CaptureError {
            if error.isEnvironmental {
                return check.finish(blockedReason: error.description)
            }
            check.record(AssertionResult(name: "capture", passed: false, detail: error.description))
            return check.finish()
        } catch {
            check.record(AssertionResult(name: "capture", passed: false, detail: "\(error)"))
            return check.finish()
        }

        // Evidence first, assertions second: if an assertion trips, the PNGs and
        // metrics are already on disk to debug from.
        do {
            try sequence.metrics.write(to: check.artifactURL("metrics.json"))
            // Sample across the sequence rather than the first few frames, so a
            // signal that degrades partway through is visible.
            let stride = max(sequence.frames.count / 4, 1)
            for (index, position) in Swift.stride(from: 0, to: sequence.frames.count, by: stride).enumerated() {
                try check.writeImage(sequence.frames[position].image, named: String(format: "frame-%02d.png", index))
            }
        } catch {
            Log.error(.selfqa, "could not write loopback artifacts: \(error)")
        }

        let metrics = sequence.metrics
        check.note("captured \(metrics.frameCount) frames from '\(metrics.deviceName)'")
        check.note("app logged output mode: \(metrics.loggedOutputMode)")
        check.note("combing score: \(String(format: "%.4f", metrics.combingScore))")

        // (a) a stable SD frame rate within tolerance, no runaway drops
        check.record(FrameAssertions.frameRateWithinTolerance(
            measured: metrics.effectiveFps, expected: expectedFps, tolerance: 2.0))
        // A handful of drops over 120 frames is ordinary USB jitter; a flood is not.
        check.record(AssertionResult(
            name: "no runaway drops",
            passed: metrics.droppedFrames <= max(metrics.frameCount / 20, 2),
            detail: "\(metrics.droppedFrames) dropped of \(metrics.frameCount)"
        ))
        // A live signal must not be a frozen picture repeated.
        check.record(AssertionResult(
            name: "signal is live",
            passed: metrics.duplicateFrames < metrics.frameCount / 2,
            detail: "\(metrics.duplicateFrames) duplicate frames of \(metrics.frameCount)"
        ))
        // (b) the captured geometry matches what the device was expected to deliver
        if let expectedFormat {
            check.record(AssertionResult(
                name: "captured geometry",
                passed: metrics.capturedWidth == expectedFormat.width
                    && metrics.capturedHeight == expectedFormat.height,
                detail: "captured \(metrics.capturedWidth)x\(metrics.capturedHeight), expected \(expectedFormat.width)x\(expectedFormat.height)"
            ))
        }
        // (c) captured frames show actual content
        check.record(AssertionResult(
            name: "signal present",
            passed: metrics.signalPresent,
            detail: "luminance variance over threshold in at least one sampled frame"
        ))

        return check.finish()
    }
}

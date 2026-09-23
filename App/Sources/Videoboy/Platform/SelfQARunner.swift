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
import Metal
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
        case "beat":
            verdict = BeatSelfQA.run()
        case "ui":
            verdict = UISelfQA.run()
        case "playback":
            verdict = PlaybackSelfQA.run()
        case "output":
            verdict = OutputSelfQA.run()
        case "analog":
            verdict = AnalogChainSelfQA.run()
        case "calibrate":
            verdict = CalibrationSelfQA.run()
        case "blend":
            verdict = BlendSelfQA.run()
        case "emu":
            verdict = EmuSelfQA.run()
        case "emu-probe":
            verdict = EmuProbe.run()
        case "record":
            verdict = RecordSelfQA.run()
        case "stream":
            verdict = StreamSelfQA.run()
        case "audit":
            verdict = ControlAuditSelfQA.run()
        case "stress":
            verdict = StressSelfQA.run()
        case "mosh":
            verdict = MoshSelfQA.run()
        case "shaders":
            verdict = ShadersSelfQA.run()
        default:
            Log.error(.selfqa, "unknown check '\(check)' (try: loopback, displays, ui, playback, output, analog, calibrate, blend, stream, record, audit, shaders, stress, mosh)")
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
        DisplayRouter.logAvailableModes(for: target, requested: config.requestedMode)
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

        guard let captureConfig = config.loopbackCapture else {
            return check.finish(blockedReason:
                "config/devices.json has no loopback_capture section — cannot tell which device closes the loop")
        }

        let expectedFormat = captureConfig.expectedFormat
        let expectedFps = expectedFormat.fps

        // Close the loop properly: put a KNOWN picture on the HDMI card first, then
        // capture. Without this the check would only measure whatever the card
        // happened to be showing, which proves nothing about Videoboy's output.
        let engine = Engine()
        let bars = RepoPaths.samples.appendingPathComponent("bars.dv")
        guard FileManager.default.fileExists(atPath: bars.path),
              engine.load(url: bars, intoChannel: "B") else {
            return check.finish(blockedReason:
                "samples/bars.dv is missing — run scripts/make-fixtures.sh")
        }
        // Fader hard over to B so PRIMARY is the colour bars.
        engine.registry.setValue(1.0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        engine.registry.setValue(0.0, slot: GraphTopology.primary, code: .crossfadeOneTwo)
        engine.subMixOne.applyParameters(from: engine.registry)
        engine.primary.applyParameters(from: engine.registry)

        var produced: [String: MTLTexture] = [:]
        let renderContext = RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil)
        for identifier in engine.graph.evaluationOrder(from: GraphTopology.primary) {
            guard let node = engine.graph.nodes[identifier] else { continue }
            let inputs = engine.graph.inputs(of: identifier).compactMap { produced[$0] }
            if let texture = node.render(inputs: inputs, context: renderContext) {
                produced[identifier] = texture
            }
        }
        guard let program = produced[GraphTopology.primary] else {
            check.record(AssertionResult(
                name: "PRIMARY renders", passed: false, detail: "the graph produced no program texture"))
            return check.finish()
        }

        let loggedOutputMode: String
        var outputWindow: OutputWindowController?
        if let target = DisplayRouter.preferredOutputDisplay(config: config) {
            let window = OutputWindowController(display: target, requestedMode: config.requestedMode)
            window.present()
            window.present(texture: program)
            outputWindow = window
            loggedOutputMode = window.negotiatedMode
            check.note("sending colour bars to '\(target.name)' at \(window.negotiatedMode)")
            // Give the window server time to composite and scan out the frame before
            // the grabber starts sampling it.
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        } else {
            loggedOutputMode = "no display"
            check.note("no output display could be resolved")
        }
        defer { outputWindow?.dismiss() }

        // Two routes to the loopback, tried in order of fidelity:
        //   1. the dvc100 tool, which speaks to the DVC100's vendor-specific USB
        //      interface directly and yields untouched 720x480 YUYV — the real
        //      analog-facing signal, run out-of-process because it is GPL.
        //   2. AVFoundation, for any UVC device (or a virtual camera republishing
        //      the DVC100 from an app that can read it).
        let directSource = DVC100CaptureSource(connector: captureConfig.connector)
        let avSource = AVFoundationCaptureSource()
        check.note("AVFoundation capture devices visible: \(avSource.enumerateDeviceNames().joined(separator: ", "))")
        check.note("dvc100 tool: \(DVC100CaptureSource.toolPath ?? "not installed"), input '\(captureConfig.connector)'")

        // Try the preferred device, then any configured alternates. The DVC100 is not
        // addressable by macOS directly, so the alternate route is how the loop can
        // still be closed — see docs/BLOCKED.md.
        var sequence: CapturedSequence?
        var lastEnvironmentalProblem: String?

        // Route 1: the DVC100 directly.
        if DVC100CaptureSource.toolPath != nil {
            let request = CaptureRequest(
                deviceNameContains: "DVC100",
                frameCount: 120,
                expectedFrameRate: expectedFps,
                loggedOutputMode: loggedOutputMode
            )
            do {
                sequence = try directSource.capture(request)
                check.note("captured the DVC100 directly through the dvc100 tool")
            } catch let error as CaptureError {
                lastEnvironmentalProblem = error.description
                check.note("dvc100 tool: \(error.description)")
            } catch {
                lastEnvironmentalProblem = "\(error)"
                check.note("dvc100 tool: \(error)")
            }
        }

        // Route 2: anything AVFoundation can see.
        for candidate in (sequence == nil ? captureConfig.candidateNames : []) {
            let request = CaptureRequest(
                deviceNameContains: candidate,
                frameCount: 120,
                expectedFrameRate: expectedFps,
                loggedOutputMode: loggedOutputMode
            )
            do {
                sequence = try avSource.capture(request)
                check.note("captured through '\(candidate)'")
                break
            } catch let error as CaptureError {
                if error.isEnvironmental {
                    lastEnvironmentalProblem = error.description
                    check.note("\(candidate): \(error.description)")
                    continue
                }
                check.record(AssertionResult(name: "capture", passed: false, detail: error.description))
                return check.finish()
            } catch {
                check.record(AssertionResult(name: "capture", passed: false, detail: "\(error)"))
                return check.finish()
            }
        }

        guard let sequence else {
            return check.finish(blockedReason:
                lastEnvironmentalProblem ?? "no configured capture device is attached")
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

        // A device delivering the same picture over and over is switched on but
        // carrying no signal — an OBS virtual camera with nothing running behind it,
        // or a grabber with no input. That is an environment condition, not a defect
        // in Videoboy, so it blocks rather than fails.
        if metrics.frameCount > 4, metrics.duplicateFrames >= metrics.frameCount - 2 {
            do {
                try sequence.metrics.write(to: check.artifactURL("metrics.json"))
                try check.writeImage(sequence.frames[0].image, named: "frozen-frame.png")
            } catch {
                Log.error(.selfqa, "could not write loopback artifacts: \(error)")
            }
            return check.finish(blockedReason: """
                '\(metrics.deviceName)' delivered \(metrics.frameCount) frames but \(metrics.duplicateFrames) \
                of them were identical — it is producing a frozen image, not a live signal. \
                See docs/BLOCKED.md for how to put the DVC100's picture on this device.
                """)
        }
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
        do {
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

        // (c) the captured frames must show what was sent. bars.dv is generated from
        // TestPattern.colorBars, so the analog round-trip can be checked by colour.
        // Tolerance is wide on purpose: composite encoding, the HDMI-to-RCA converter
        // and the SAA7113's digitisation all shift levels legitimately.
        // Sample a frame from the middle of the sequence: the first frames can catch
        // the grabber still locking to the incoming signal.
        if let sample = sequence.frames[safe: sequence.frames.count / 2]?.image {
            check.record(FrameAssertions.containsColorBarHues(
                sample, name: "captured picture matches what was sent"))
        }

        // Interlace: the DVC100 digitises NTSC as 480 interlaced lines, so a real
        // captured signal carries combing. Reported rather than asserted — a static
        // picture legitimately has none, and this is the number to watch in Phase 3.
        check.note("combing score \(String(format: "%.4f", metrics.combingScore)) (interlace indicator)")

        return check.finish()
    }
}

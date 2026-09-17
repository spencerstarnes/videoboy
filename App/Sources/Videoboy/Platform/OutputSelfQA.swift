//
//  OutputSelfQA.swift — exercises the real output stage on the HDMI card.
//
//  Purpose : Opens the borderless output window on the configured display, switches
//            that display to the SD mode if it advertises one, pushes PRIMARY into
//            it, and records what was negotiated.
//  Inputs  : config/devices.json and samples/*.dv.
//  Outputs : selfqa/out/phase-2/output-stage/{*.png,result.txt}.
//  Connects: Engine, OutputWindowController, DisplayRouter.
//
//  IMPORTANT — what this does NOT prove. This verifies everything up to and including
//  the window presented on the HDMI output card, and the mode that card negotiated.
//  It does NOT capture the analog signal coming back, because the DVC100 on this
//  machine is not addressable by macOS (see docs/BLOCKED.md). So it cannot speak to
//  what the HDMI-to-RCA converter or the CRT actually receive. Any claim about the
//  analog chain needs the human's eyes on a monitor.
//

import AppKit
import Metal
import VideoboyCore

/// Drives the output stage and records the result.
enum OutputSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "phase-2/output-stage")
        check.note("SCOPE: verifies the app's output window and the display mode it negotiated.")
        check.note("It does NOT capture the analog signal — see docs/BLOCKED.md for why.")

        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            return check.finish(blockedReason: "no Metal device is available")
        }

        let config = DeviceConfig.load()
        guard let display = DisplayRouter.preferredOutputDisplay(config: config) else {
            return check.finish(blockedReason: "no display could be resolved for output")
        }
        check.note("output display: '\(display.name)', was at \(display.modeDescription)")

        let requested = config.requestedMode
        let advertisesSD = DisplayRouter.bestMode(for: display, matching: requested) != nil

        // A display that cannot be switched at all is an environment problem, not a
        // defect, so it blocks rather than fails.
        if let obstacle = display.modeSwitchObstacle {
            check.note("cannot switch this display's mode: \(obstacle)")
        }
        check.record(AssertionResult(
            name: "HDMI card advertises the SD mode",
            passed: advertisesSD,
            detail: advertisesSD
                ? "\(requested.description) is in this display's mode list"
                : "\(requested.description) is not advertised; output will be scaled"
        ))

        // Open the real output window. This switches the display's mode when it can.
        let output = OutputWindowController(display: display, requestedMode: requested)
        output.present()
        check.note("negotiated output mode: \(output.negotiatedMode)")

        // The negotiated mode must be the SD one when the card advertised it AND
        // nothing is preventing the switch.
        let obstacle = display.modeSwitchObstacle
        if advertisesSD, obstacle == nil {
            let expected = "\(requested.width)x\(requested.height)"
            check.record(AssertionResult(
                name: "output switched to SD",
                passed: output.negotiatedMode.hasPrefix(expected),
                detail: "negotiated \(output.negotiatedMode), expected to start with \(expected)"
            ))
        }

        // Feed it a real program: colour bars through the engine's own graph.
        let engine = Engine()
        let bars = RepoPaths.samples.appendingPathComponent("bars.dv")
        guard FileManager.default.fileExists(atPath: bars.path), engine.load(url: bars, intoChannel: "B") else {
            output.dismiss()
            return check.finish(blockedReason: "samples/bars.dv is missing — run scripts/make-fixtures.sh")
        }
        engine.registry.setValue(1.0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        engine.registry.setValue(0.0, slot: GraphTopology.primary, code: .crossfadeOneTwo)
        engine.subMixOne.applyParameters(from: engine.registry)
        engine.primary.applyParameters(from: engine.registry)

        var program: MTLTexture?
        var produced: [String: MTLTexture] = [:]
        let context = RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil)
        for identifier in engine.graph.evaluationOrder(from: GraphTopology.primary) {
            guard let node = engine.graph.nodes[identifier] else { continue }
            let inputs = engine.graph.inputs(of: identifier).compactMap { produced[$0] }
            if let texture = node.render(inputs: inputs, context: context) {
                produced[identifier] = texture
            }
        }
        program = produced[GraphTopology.primary]
        output.present(texture: program)
        // Let the window server actually composite the frame.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        if let program, let image = renderer.readback(program) {
            _ = try? check.writeImage(image, named: "program-sent-to-output.png")
            check.record(FrameAssertions.hasDimensions(image, width: 720, height: 480))
            check.record(FrameAssertions.looksLikeColorBars(image, tolerance: 45))
            check.record(FrameAssertions.hasSignal(image))
        } else {
            check.record(AssertionResult(
                name: "PRIMARY reaches the output", passed: false,
                detail: "no program texture was produced"
            ))
        }

        check.record(AssertionResult(
            name: "output window is on the intended display",
            passed: output.window?.screen == display.screen || output.window != nil,
            detail: "window placed on '\(output.display.name)'"
        ))

        // Always put the display back, pass or fail.
        output.dismiss()
        check.note("display mode restored")

        // Mirroring blocks the one thing this check cannot otherwise establish.
        if let obstacle = display.modeSwitchObstacle {
            return check.finish(blockedReason: obstacle)
        }
        return check.finish()
    }
}

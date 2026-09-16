//
//  PlaybackSelfQA.swift — drives the real engine and photographs what it produces.
//
//  Purpose : Core's tests prove the DV path in isolation. This proves the *app's*
//            path: the graph the Engine builds, the Metal crossfade the mixer runs,
//            and the PRIMARY texture the output window would present. It renders
//            through exactly the pipelines the live app uses, so a pass here means
//            the running app is producing these pixels.
//  Inputs  : samples/*.dv.
//  Outputs : selfqa/out/phase-2/playback/{*.png,result.txt}.
//  Connects: Engine, OffscreenRenderer (readback), FrameAssertions.
//  Extend  : add a stage to `run()` and assert on the texture it produces.
//

import AppKit
import Metal
import VideoboyCore

/// Renders the live graph offscreen and asserts on the result.
enum PlaybackSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "phase-2/playback")

        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            return check.finish(blockedReason: "no Metal device is available on this machine")
        }

        let samples = RepoPaths.samples
        let fileA = samples.appendingPathComponent("motion.dv")
        let fileB = samples.appendingPathComponent("bars.dv")
        for file in [fileA, fileB] where !FileManager.default.fileExists(atPath: file.path) {
            return check.finish(blockedReason: "\(file.lastPathComponent) is missing — run scripts/make-fixtures.sh")
        }

        let engine = Engine()
        guard engine.load(url: fileA, intoChannel: "A"), engine.load(url: fileB, intoChannel: "B") else {
            check.record(AssertionResult(
                name: "sources load", passed: false, detail: "a DV file failed to load into the engine"))
            return check.finish()
        }
        check.note("A = motion.dv, B = bars.dv, through the engine's own graph")

        // This check is about the mixer and the wedge, so the bus effects are held
        // bypassed. The analog chain has its own check (phase-3/analog-chain); left
        // engaged here it would change what PRIMARY looks like and this would be
        // measuring two things at once.
        for slot in [Engine.compositeSlot, Engine.echoSlot, Engine.feedbackSlot] {
            engine.registry.setValue(0, slot: slot, code: .wetDry)
        }

        // Four sources, three mixers, three bus effects, capture and test pattern.
        let expectedNodes = 12
        check.record(AssertionResult(
            name: "graph shape", passed: engine.graph.nodeCount == expectedNodes,
            detail: "\(engine.graph.nodeCount) nodes, expected \(expectedNodes)"
        ))

        /// Renders one frame through the engine's own traversal and reads PRIMARY back.
        func renderFrame(_ frameIndex: Int) -> ImageBuffer? {
            let context = RenderContext(
                frameIndex: frameIndex,
                presentationTime: Double(frameIndex) / StandardDefinition.frameRate,
                musicalPosition: nil
            )
            guard let primary = engine.evaluateGraph(context: context)[GraphTopology.primary] else {
                return nil
            }
            return renderer.readback(primary)
        }

        // 1. The fader hard over to A: PRIMARY must be motion.dv.
        engine.registry.setValue(0.0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        engine.registry.setValue(0.0, slot: GraphTopology.primary, code: .crossfadeOneTwo)
        guard let atA = renderFrame(0) else {
            check.record(AssertionResult(name: "PRIMARY renders", passed: false, detail: "no texture came back"))
            return check.finish()
        }
        try? check.writeImage(atA, named: "01-fader-at-A.png")
        check.record(FrameAssertions.hasDimensions(atA, width: 720, height: 480))
        check.record(FrameAssertions.hasSignal(atA))

        // 2. The fader hard over to B: PRIMARY must become the colour bars, and since
        //    bars.dv is generated from TestPattern.colorBars this can be asserted by
        //    actual colour — the end-to-end proof that the mixer routes correctly.
        engine.registry.setValue(1.0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        guard let atB = renderFrame(1) else {
            check.record(AssertionResult(name: "fader to B renders", passed: false, detail: "no texture"))
            return check.finish()
        }
        try? check.writeImage(atB, named: "02-fader-at-B.png")
        let bars = FrameAssertions.looksLikeColorBars(atB, tolerance: 45)
        check.record(AssertionResult(
            name: "fader at B shows source B",
            passed: bars.passed,
            detail: bars.detail
        ))
        check.record(FrameAssertions.framesDiffer(
            atA, atB, minimumFraction: 0.2, name: "moving the fader changes PRIMARY"))

        // 3. Halfway: a genuine blend, not a snap to one side.
        engine.registry.setValue(0.5, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        guard let atMiddle = renderFrame(2) else {
            check.record(AssertionResult(name: "mid-fade renders", passed: false, detail: "no texture"))
            return check.finish()
        }
        try? check.writeImage(atMiddle, named: "03-fader-midpoint.png")
        check.record(AssertionResult(
            name: "mid-fade is a blend of both",
            passed: FrameAssertions.differingPixelFraction(atMiddle, atA) > 0.05
                && FrameAssertions.differingPixelFraction(atMiddle, atB) > 0.05,
            detail: "differs from A by \(String(format: "%.2f", FrameAssertions.differingPixelFraction(atMiddle, atA))) and from B by \(String(format: "%.2f", FrameAssertions.differingPixelFraction(atMiddle, atB)))"
        ))

        // 4. Playback advances: the picture must change over time.
        engine.registry.setValue(0.0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        engine.setPlaying(true, channel: "A")
        let first = renderFrame(3)
        for frame in 4..<34 { _ = renderFrame(frame) }
        let later = renderFrame(34)
        if let first, let later {
            try? check.writeImage(later, named: "04-after-30-frames.png")
            check.record(FrameAssertions.framesDiffer(
                first, later, minimumFraction: 0.05, name: "playback advances the picture"))
        } else {
            check.record(AssertionResult(
                name: "playback advances", passed: false, detail: "a frame failed to render"))
        }
        engine.setPlaying(false, channel: "A")

        // 5. The wedge, through the live graph: corruption visibly damages PRIMARY.
        let beforeCorruption = renderFrame(35)
        engine.registry.setValue(0.9, slot: GraphTopology.sourceA, code: .corruptAmount)
        engine.registry.setValue(0.0, slot: GraphTopology.sourceA, code: .corruptMode)
        let afterCorruption = renderFrame(35)
        if let beforeCorruption, let afterCorruption {
            try? check.writeImage(beforeCorruption, named: "05-clean.png")
            try? check.writeImage(afterCorruption, named: "06-corrupted.png")
            check.record(FrameAssertions.framesDiffer(
                beforeCorruption, afterCorruption,
                minimumFraction: 0.05,
                name: "the corruptor damages PRIMARY through the live graph"
            ))
            check.record(FrameAssertions.hasSignal(afterCorruption))
        } else {
            check.record(AssertionResult(
                name: "corruption renders", passed: false, detail: "a frame failed to render"))
        }

        check.note("all frames rendered through the engine's own nodes and Metal pipelines")
        return check.finish()
    }
}

//
//  AnalogChainSelfQA.swift — Phase 3's evidence, through the live engine.
//
//  Purpose : Core's tests exercise the composite codec and the feedback nodes in
//            isolation. This drives them where they actually live — on the ONE bus
//            of the engine's own graph — and photographs the result, so a pass here
//            means the running app produces these pixels.
//  Inputs  : samples/*.dv.
//  Outputs : selfqa/out/phase-3/analog-chain/{*.png,result.txt}.
//  Connects: Engine, CompositeCodecNode, EchoNode, FeedbackNode, CRTGeometry.
//

import AppKit
import Metal
import VideoboyCore

/// Renders the ONE bus with the analog chain engaged and asserts on the result.
enum AnalogChainSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "phase-3/analog-chain")

        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            return check.finish(blockedReason: "no Metal device is available")
        }

        let bars = RepoPaths.samples.appendingPathComponent("bars.dv")
        guard FileManager.default.fileExists(atPath: bars.path) else {
            return check.finish(blockedReason: "samples/bars.dv is missing — run scripts/make-fixtures.sh")
        }

        let engine = Engine()
        guard engine.load(url: bars, intoChannel: "A") else {
            check.record(AssertionResult(
                name: "source loads", passed: false, detail: "bars.dv failed to load"))
            return check.finish()
        }
        // Fader hard to A so the bus carries the bars.
        engine.registry.setValue(0.0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        engine.registry.setValue(0.0, slot: GraphTopology.primary, code: .crossfadeOneTwo)
        check.note("A = bars.dv, through the engine's ONE bus: composite -> echo -> feedback")

        /// Renders one frame through the engine's own traversal and reads a node back.
        func render(_ frameIndex: Int, node identifier: String) -> ImageBuffer? {
            let context = RenderContext(
                frameIndex: frameIndex,
                presentationTime: Double(frameIndex) / StandardDefinition.frameRate,
                musicalPosition: nil
            )
            guard let texture = engine.evaluateGraph(context: context)[identifier] else { return nil }
            return renderer.readback(texture)
        }

        // 1. The bus before the analog chain touches it.
        guard let clean = render(0, node: GraphTopology.subMixOne) else {
            check.record(AssertionResult(name: "ONE renders", passed: false, detail: "no texture"))
            return check.finish()
        }
        try? check.writeImage(clean, named: "01-sub-mix-one-clean.png")
        check.record(FrameAssertions.hasDimensions(clean, width: 720, height: 480))

        // 2. The composite codec, on its default VHS-ish settings.
        engine.registry.setValue(1.0, slot: Engine.compositeSlot, code: .wetDry)
        guard let composited = render(1, node: Engine.compositeSlot) else {
            check.record(AssertionResult(name: "composite renders", passed: false, detail: "no texture"))
            return check.finish()
        }
        try? check.writeImage(composited, named: "02-after-composite-codec.png")
        check.record(FrameAssertions.framesDiffer(
            clean, composited, minimumFraction: 0.05,
            name: "the composite codec changes the picture"))
        check.record(FrameAssertions.hasSignal(composited))
        // The picture must survive the codec, not be destroyed by it: the bars should
        // still be identifiable as bars afterwards.
        check.record(FrameAssertions.containsColorBarHues(
            composited, name: "bars survive the composite codec"))

        // 3. S-Video must be measurably cleaner than composite.
        engine.registry.setValue(1.0, slot: Engine.compositeSlot, code: .compositePath)
        guard let sVideo = render(2, node: Engine.compositeSlot) else {
            check.record(AssertionResult(name: "s-video renders", passed: false, detail: "no texture"))
            return check.finish()
        }
        try? check.writeImage(sVideo, named: "03-s-video-path.png")
        let compositeDeparture = FrameAssertions.differingPixelFraction(clean, composited)
        let sVideoDeparture = FrameAssertions.differingPixelFraction(clean, sVideo)
        check.record(AssertionResult(
            name: "S-Video is cleaner than composite",
            passed: sVideoDeparture < compositeDeparture,
            detail: "composite departs by \(String(format: "%.3f", compositeDeparture)), S-Video by \(String(format: "%.3f", sVideoDeparture))"
        ))
        engine.registry.setValue(0.0, slot: Engine.compositeSlot, code: .compositePath)

        // 4. Feedback: an inward-zooming loop must carry light toward the centre over
        //    successive frames, which a single frame cannot show.
        engine.registry.setValue(0.85, slot: Engine.feedbackSlot, code: .feedbackGain)
        engine.registry.setValue(1.08, slot: Engine.feedbackSlot, code: .feedbackZoom)
        engine.registry.setValue(1.0, slot: Engine.feedbackSlot, code: .feedbackDelayFrames)
        var lastFeedback: ImageBuffer?
        for frame in 3..<25 { lastFeedback = render(frame, node: Engine.feedbackSlot) }
        if let lastFeedback {
            try? check.writeImage(lastFeedback, named: "04-feedback-tunnel.png")
            check.record(FrameAssertions.hasSignal(lastFeedback))
            check.record(FrameAssertions.framesDiffer(
                composited, lastFeedback, minimumFraction: 0.05,
                name: "feedback changes the picture"))
            // ...and must not destroy it. A loop that saturates to flat white after a
            // second has lost the image, which is a bug rather than a look, so the
            // result has to still carry structure.
            let detail = FrameAssertions.horizontalDetail(lastFeedback)
            check.record(AssertionResult(
                name: "feedback does not blow out to flat white",
                passed: detail > 1.0,
                detail: "horizontal detail after 22 frames of feedback is \(String(format: "%.2f", detail))"
            ))
        } else {
            check.record(AssertionResult(
                name: "feedback renders", passed: false, detail: "no texture"))
        }

        // 5. Generation loss: four passes must cost detail relative to one.
        engine.registry.setValue(0.0, slot: Engine.feedbackSlot, code: .feedbackGain)
        engine.registry.setValue(1.0, slot: Engine.compositeSlot, code: .compositeGeneration)
        let firstGeneration = render(30, node: Engine.compositeSlot)
        engine.registry.setValue(4.0, slot: Engine.compositeSlot, code: .compositeGeneration)
        let fourthGeneration = render(31, node: Engine.compositeSlot)
        if let firstGeneration, let fourthGeneration {
            try? check.writeImage(fourthGeneration, named: "05-fourth-generation.png")
            let firstDetail = FrameAssertions.horizontalDetail(firstGeneration)
            let fourthDetail = FrameAssertions.horizontalDetail(fourthGeneration)
            check.record(AssertionResult(
                name: "each generation costs detail",
                passed: fourthDetail < firstDetail,
                detail: "1st generation detail \(String(format: "%.2f", firstDetail)), 4th \(String(format: "%.2f", fourthDetail))"
            ))
        }

        // 6. The CRT geometry the overlays and the output both read from.
        let action = CRTGeometry.actionSafe.inPixels(width: 720, height: 480)
        check.note("action-safe at SD: \(action.width)x\(action.height) at (\(action.x), \(action.y))")
        check.record(AssertionResult(
            name: "safe zones are the standard fractions",
            passed: action.width == 648 && action.height == 432,
            detail: "action-safe is \(action.width)x\(action.height), expected 648x432"
        ))

        check.note("all frames rendered through the engine's own nodes and Metal pipelines")
        return check.finish()
    }
}

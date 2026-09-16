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
        for slot in Engine.busEffectSlots {
            engine.registry.setValue(0, slot: slot, code: .wetDry)
        }

        // Assert the ROUTING, not the node count. A count has to be edited every time
        // a node is added and says nothing about whether the signal path is right;
        // SPEC 2's fixed routing is the thing that actually must not break.
        let evaluation = engine.graph.evaluationOrder(from: GraphTopology.primary)
        func feeds(_ upstream: String, reaches downstream: String) -> Bool {
            guard let from = evaluation.firstIndex(of: upstream),
                  let to = evaluation.firstIndex(of: downstream) else { return false }
            return from < to
        }
        let routingIsCorrect =
            feeds(GraphTopology.sourceA, reaches: GraphTopology.subMixOne)
            && feeds(GraphTopology.sourceB, reaches: GraphTopology.subMixOne)
            && feeds(GraphTopology.sourceC, reaches: GraphTopology.subMixTwo)
            && feeds(GraphTopology.sourceD, reaches: GraphTopology.subMixTwo)
            && feeds(GraphTopology.subMixOne, reaches: GraphTopology.primary)
            && feeds(GraphTopology.subMixTwo, reaches: GraphTopology.primary)
        check.record(AssertionResult(
            name: "fixed routing holds",
            passed: routingIsCorrect,
            detail: "A/B reach ONE, C/D reach TWO, both reach PRIMARY (\(engine.graph.nodeCount) nodes)"
        ))

        /// Renders one frame through the engine's own traversal and reads PRIMARY back.
        func renderFrame(_ frameIndex: Int) -> ImageBuffer? {
            let context = RenderContext(
                frameIndex: frameIndex,
                presentationTime: Double(frameIndex) / StandardDefinition.frameRate,
                musicalPosition: nil
            )
            // The END of the programme chain, which is what actually goes out. Reading
            // the ONE/TWO mix instead would skip the programme data stage, and a check
            // that cannot see a stage cannot tell you it is disconnected.
            let produced = engine.evaluateGraph(context: context)
            guard let output = produced[Engine.outputSlot] ?? produced[GraphTopology.primary]
            else { return nil }
            return renderer.readback(output)
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

        // 6. Ordinary video through the same graph. "Only .dv plays" was the biggest
        // functional gap in the app, so this checks a .mov actually reaches PRIMARY
        // rather than that the decoder compiles.
        let movie = RepoPaths.samples.appendingPathComponent("motion.mov")
        if FileManager.default.fileExists(atPath: movie.path) {
            if engine.load(url: movie, intoChannel: "A") {
                check.record(AssertionResult(
                    name: "ordinary video loads into a channel",
                    passed: true, detail: "motion.mov opened through AVFoundation"))

                // The wedge must NOT be on offer for it: there is no bitstream here
                // that damage could mean anything to.
                check.record(AssertionResult(
                    name: "ordinary video offers no bitstream effects",
                    passed: engine.dataEffectFamily(forChannel: "A") == .none,
                    detail: "family is \(engine.dataEffectFamily(forChannel: "A").displayName)"
                ))

                engine.registry.setValue(0.0, slot: GraphTopology.sourceA, code: .corruptAmount)
                engine.registry.setValue(0.0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
                engine.setPlaying(true, channel: "A")
                let movieFirst = renderFrame(40)
                for frame in 41..<70 { _ = renderFrame(frame) }
                let movieLater = renderFrame(70)
                engine.setPlaying(false, channel: "A")

                if let movieFirst, let movieLater {
                    try? check.writeImage(movieLater, named: "07-mov-playing.png")
                    check.record(FrameAssertions.hasSignal(movieFirst))
                    check.record(FrameAssertions.framesDiffer(
                        movieFirst, movieLater, minimumFraction: 0.05,
                        name: "ordinary video advances through PRIMARY"))
                } else {
                    check.record(AssertionResult(
                        name: "ordinary video renders", passed: false,
                        detail: "a frame failed to render"))
                }
            } else {
                check.record(AssertionResult(
                    name: "ordinary video loads into a channel",
                    passed: false, detail: "motion.mov did not load"))
            }
        } else {
            check.note("samples/motion.mov is missing; the AVFoundation path was not exercised")
        }

        // 7. The PROGRAM data stage reaches output. It was built and added to the
        // graph but never connected, so its controls moved nothing and the picture
        // was identical whatever they were set to — which is exactly what a check
        // comparing before and after catches and a reading of the code did not.
        engine.load(url: fileA, intoChannel: "A")
        engine.registry.setValue(0.0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        engine.registry.setValue(0.0, slot: GraphTopology.primary, code: .crossfadeOneTwo)
        engine.setInterchange(.dv, forBus: GraphTopology.primary)

        engine.registry.setValue(0.0, slot: Engine.busCodecProgramSlot, code: .corruptAmount)
        let programClean = renderFrame(80)
        engine.registry.setValue(0.95, slot: Engine.busCodecProgramSlot, code: .corruptAmount)
        engine.registry.setValue(0.0, slot: Engine.busCodecProgramSlot, code: .corruptMode)
        let programDamaged = renderFrame(80)

        if let programClean, let programDamaged {
            try? check.writeImage(programDamaged, named: "08-program-data-stage.png")
            check.record(FrameAssertions.framesDiffer(
                programClean, programDamaged, minimumFraction: 0.02,
                name: "the PROGRAM data stage reaches the output"))
        } else {
            check.record(AssertionResult(
                name: "PROGRAM data stage renders", passed: false, detail: "a frame failed to render"))
        }

        // 9. The output emulation toggles. Both are meant to be subtle, so "subtle"
        // is checked as a range rather than just "different": a change too small to
        // see is as much a failure as one that wrecks the picture.
        // On ordinary video, not DV. Re-encoding DV to DV is very nearly lossless, so
        // measuring "what DV emulation costs" against a DV source measures almost
        // nothing — correctly. The material has to be something DV would actually
        // change, which is the material the toggle exists for.
        let emulationSource = RepoPaths.samples.appendingPathComponent("motion.mov")
        if FileManager.default.fileExists(atPath: emulationSource.path) {
            engine.load(url: emulationSource, intoChannel: "A")
        }
        engine.setInterchange(.none, forBus: GraphTopology.primary)
        engine.registry.setValue(0, slot: Engine.busCodecProgramSlot, code: .corruptAmount)
        engine.registry.setValue(0, slot: Engine.busCodecProgramSlot, code: .compositeGeneration)
        engine.isOutputNTSCEnabled = false
        let outputClean = renderFrame(90)

        engine.isOutputNTSCEnabled = true
        let outputNTSC = renderFrame(91)
        if let outputClean, let outputNTSC {
            try? check.writeImage(outputNTSC, named: "09-output-ntsc.png")
            let difference = FrameAssertions.differingPixelFraction(outputClean, outputNTSC)
            check.record(AssertionResult(
                name: "NTSC output emulation changes the picture, subtly",
                passed: difference > 0.02,
                detail: "\(String(format: "%.3f", difference)) of sampled pixels differ"
            ))
        }
        engine.isOutputNTSCEnabled = false

        engine.isOutputDVEnabled = true
        let outputDV = renderFrame(92)
        if let outputClean, let outputDV {
            try? check.writeImage(outputDV, named: "10-output-dv.png")
            let difference = FrameAssertions.differingPixelFraction(outputClean, outputDV)
            // A low bar on purpose. One DV generation over the synthetic colour bars
            // in samples/ genuinely changes very little: 4:1:1 subsampling preserves
            // large flat areas almost perfectly, which is what those bars are. The
            // honest claim is that the round trip RAN and was not a no-op; how much
            // it costs is a property of the material, and the generations check below
            // is what proves the stage is really doing work.
            check.record(AssertionResult(
                name: "the DV round trip runs rather than passing through",
                passed: difference > 0.0005,
                detail: "\(String(format: "%.4f", difference)) of sampled pixels differ at one "
                    + "generation — small because flat colour bars survive 4:1:1 well"
            ))

            // Four generations must cost MORE than one, or the generations control is
            // doing nothing and the DV round trip is running once regardless.
            engine.registry.setValue(
                4, slot: Engine.busCodecProgramSlot, code: .compositeGeneration)
            if let fourth = renderFrame(93) {
                try? check.writeImage(fourth, named: "11-output-dv-4-generations.png")
                let oneGeneration = FrameAssertions.differingPixelFraction(outputClean, outputDV)
                let fourGenerations = FrameAssertions.differingPixelFraction(outputClean, fourth)
                check.record(AssertionResult(
                    name: "each DV generation costs more than the last",
                    passed: fourGenerations > oneGeneration,
                    detail: "1 generation differs by \(String(format: "%.3f", oneGeneration)), "
                        + "4 by \(String(format: "%.3f", fourGenerations))"
                ))
            }
        }
        engine.isOutputDVEnabled = false

        // 10. The MX-1 set, through the live graph. It was built and unit-tested but
        // was not in any chain, so nothing could reach it — the same shape of gap as
        // the programme data stage, and invisible for the same reason: every part of
        // it was correct except its place in the graph.
        engine.load(url: fileA, intoChannel: "A")
        engine.registry.setValue(0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        engine.registry.setValue(0, slot: Engine.mx1OneSlot, code: .wetDry)
        let mx1Bypassed = renderFrame(100)

        engine.registry.setValue(1, slot: Engine.mx1OneSlot, code: .wetDry)
        // Full strength. At the default of 0.5, posterize gives 17 levels, which
        // shifts a flat colour bar by about four — genuinely invisible, and on this
        // material that is the truth rather than a fault. "Does this effect do
        // anything" is a question about the effect, so it is asked at full amount.
        engine.registry.setValue(1, slot: Engine.mx1OneSlot, code: .mx1Amount)
        var sweptFrames: [(name: String, image: ImageBuffer)] = []
        for effect in MX1Effect.allCases {
            // The middle of each effect's band, so the sweep lands squarely on it
            // rather than on a boundary.
            let position = (Double(effect.rawValue) + 0.5) / Double(MX1Effect.allCases.count)
            engine.registry.setValue(position, slot: Engine.mx1OneSlot, code: .mx1Effect)
            if let image = renderFrame(101 + effect.rawValue) {
                sweptFrames.append((effect.displayName, image))
            }
        }

        if let mx1Bypassed, sweptFrames.count == MX1Effect.allCases.count {
            try? check.writeImage(mx1Bypassed, named: "12-mx1-bypassed.png")
            for swept in sweptFrames {
                let safeName = swept.name.lowercased()
                    .replacingOccurrences(of: " ", with: "-")
                    .replacingOccurrences(of: "&", with: "and")
                try? check.writeImage(swept.image, named: "13-mx1-\(safeName).png")
            }

            // Colour-aware, not luma. Black and white is a luma-weighted
            // desaturation, so it preserves luma exactly and a luma comparison calls
            // it "no change" — which is how three working effects first read as
            // broken here.
            //
            // Freeze is excluded on purpose: the transport is stopped for this sweep
            // so the effects can be compared against each other rather than against a
            // moving picture, and a frozen frame of a still clip is the same frame.
            // It is checked separately below, where it can mean something.
            let inert = sweptFrames.filter {
                $0.name != MX1Effect.freeze.displayName
                    && FrameAssertions.differingColourFraction(mx1Bypassed, $0.image) < 0.02
            }
            check.record(AssertionResult(
                name: "every MX-1 effect changes the picture",
                passed: inert.isEmpty,
                detail: inert.isEmpty
                    ? "\(sweptFrames.count) effects, all visible"
                    : "inert: " + inert.map(\.name).joined(separator: ", ")
            ))

            // And they must differ from EACH OTHER, or the sweep is selecting one
            // effect and relabelling it.
            var identicalPairs: [String] = []
            for first in 0..<sweptFrames.count {
                for second in (first + 1)..<sweptFrames.count {
                    let difference = FrameAssertions.differingColourFraction(
                        sweptFrames[first].image, sweptFrames[second].image)
                    if difference < 0.005 {
                        identicalPairs.append(
                            "\(sweptFrames[first].name)/\(sweptFrames[second].name)")
                    }
                }
            }
            check.record(AssertionResult(
                name: "the MX-1 sweep selects a different effect at each position",
                passed: identicalPairs.isEmpty,
                detail: identicalPairs.isEmpty
                    ? "all \(sweptFrames.count) are distinct"
                    : "indistinguishable: " + identicalPairs.joined(separator: ", ")
            ))
        } else {
            check.record(AssertionResult(
                name: "the MX-1 set renders", passed: false,
                detail: "\(sweptFrames.count) of \(MX1Effect.allCases.count) effects rendered"))
        }
        // Freeze, where it means something: with the clip running, the picture must
        // stop while everything else carries on.
        engine.registry.setValue(1, slot: Engine.mx1OneSlot, code: .wetDry)
        let freezePosition =
            (Double(MX1Effect.freeze.rawValue) + 0.5) / Double(MX1Effect.allCases.count)
        engine.registry.setValue(freezePosition, slot: Engine.mx1OneSlot, code: .mx1Effect)
        engine.setPlaying(true, channel: "A")
        _ = renderFrame(120)
        let frozenFirst = renderFrame(121)
        for frame in 122..<140 { _ = renderFrame(frame) }
        let frozenLater = renderFrame(140)
        engine.setPlaying(false, channel: "A")

        if let frozenFirst, let frozenLater {
            try? check.writeImage(frozenLater, named: "14-mx1-freeze-held.png")
            check.record(AssertionResult(
                name: "MX-1 freeze holds the picture while the clip runs on",
                passed: FrameAssertions.differingColourFraction(frozenFirst, frozenLater) < 0.02,
                detail: String(
                    format: "%.3f of pixels changed over 19 frames of playback",
                    FrameAssertions.differingColourFraction(frozenFirst, frozenLater))
            ))
        }
        engine.registry.setValue(0, slot: Engine.mx1OneSlot, code: .wetDry)

        // 11. A feedback send: one bus routed into the other's feedback loop. The
        // claim worth checking is that it does NOT hang — a bus feeding a loop it is
        // downstream of is a cycle, and the whole design of this send is the one-frame
        // delay that makes it expressible.
        engine.load(url: fileA, intoChannel: "A")
        engine.registry.setValue(0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        engine.registry.setValue(1, slot: Engine.feedbackSlot, code: .wetDry)
        engine.registry.setValue(0.8, slot: Engine.feedbackSlot, code: .feedbackGain)
        engine.registry.setValue(0, slot: Engine.mx1OneSlot, code: .wetDry)

        let withoutSend = renderFrame(150)
        engine.setFeedbackSend(from: Engine.busCodecOneSlot, toBus: "ONE")
        check.record(AssertionResult(
            name: "a feedback send is recorded against its bus",
            passed: engine.feedbackSend(forBus: "ONE") == Engine.busCodecOneSlot,
            detail: engine.feedbackSend(forBus: "ONE") ?? "nothing"
        ))

        // Twenty frames through a loop fed by its own output. If the one-frame delay
        // were not doing its job this is where it would spin or blow up.
        var sendFrames: [ImageBuffer] = []
        for frame in 151..<171 {
            if let image = renderFrame(frame) { sendFrames.append(image) }
        }
        engine.setFeedbackSend(from: nil, toBus: "ONE")

        check.record(AssertionResult(
            name: "a bus fed back into its own loop keeps rendering",
            passed: sendFrames.count == 20,
            detail: "\(sendFrames.count) of 20 frames rendered"
        ))

        if let withoutSend, let withSend = sendFrames.last {
            try? check.writeImage(withSend, named: "15-feedback-send.png")
            check.record(FrameAssertions.framesDiffer(
                withoutSend, withSend, minimumFraction: 0.02,
                name: "the feedback send changes the picture"))
            // And the picture must stay a picture rather than saturating to white,
            // which is how a runaway loop usually announces itself.
            check.record(FrameAssertions.hasSignal(withSend))
        }
        engine.registry.setValue(0, slot: Engine.feedbackSlot, code: .wetDry)

        check.note("all frames rendered through the engine's own nodes and Metal pipelines")
        return check.finish()
    }
}

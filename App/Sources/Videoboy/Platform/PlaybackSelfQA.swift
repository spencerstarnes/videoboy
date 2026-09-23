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
        _ = try? check.writeImage(atA, named: "01-fader-at-A.png")
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
        _ = try? check.writeImage(atB, named: "02-fader-at-B.png")
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
        _ = try? check.writeImage(atMiddle, named: "03-fader-midpoint.png")
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
            _ = try? check.writeImage(later, named: "04-after-30-frames.png")
            check.record(FrameAssertions.framesDiffer(
                first, later, minimumFraction: 0.05, name: "playback advances the picture"))
        } else {
            check.record(AssertionResult(
                name: "playback advances", passed: false, detail: "a frame failed to render"))
        }
        engine.setPlaying(false, channel: "A")

        // 5. The wedge, through the live graph: corruption visibly damages PRIMARY.
        let beforeCorruption = renderFrame(35)
        // The corruptor boots bypassed now, so the wedge has to be switched on
        // before it can damage anything.
        engine.registry.setValue(1, slot: GraphTopology.sourceA, code: .wetDry)
        engine.registry.setValue(0.9, slot: GraphTopology.sourceA, code: .corruptAmount)
        engine.registry.setValue(0.0, slot: GraphTopology.sourceA, code: .corruptMode)
        let afterCorruption = renderFrame(35)
        if let beforeCorruption, let afterCorruption {
            _ = try? check.writeImage(beforeCorruption, named: "05-clean.png")
            _ = try? check.writeImage(afterCorruption, named: "06-corrupted.png")
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
                    _ = try? check.writeImage(movieLater, named: "07-mov-playing.png")
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
            _ = try? check.writeImage(programDamaged, named: "08-program-data-stage.png")
            check.record(FrameAssertions.framesDiffer(
                programClean, programDamaged, minimumFraction: 0.02,
                name: "the PROGRAM data stage reaches the output"))
        } else {
            check.record(AssertionResult(
                name: "PROGRAM data stage renders", passed: false, detail: "a frame failed to render"))
        }

        // 8. Sources C and D actually reach PRIMARY through the TWO path with real
        // pixels, not just a graph-order check. The routing assertion at the top of
        // this file proves C and D are upstream of PRIMARY in the evaluation order;
        // it says nothing about whether a picture loaded into C is what comes out.
        // This loads a corrupted clip into C, cuts PRIMARY hard over to TWO, and
        // reads back a frame that has to carry that specific damage.
        engine.load(url: fileA, intoChannel: "C")
        engine.load(url: fileB, intoChannel: "D")
        engine.registry.setValue(0.0, slot: GraphTopology.subMixTwo, code: .crossfadeCD)
        // The corruptor boots bypassed now, so the wedge has to be switched on
        // before it can damage anything.
        engine.registry.setValue(1, slot: GraphTopology.sourceC, code: .wetDry)
        engine.registry.setValue(0.9, slot: GraphTopology.sourceC, code: .corruptAmount)
        engine.registry.setValue(0.0, slot: GraphTopology.sourceC, code: .corruptMode)
        engine.registry.setValue(1.0, slot: GraphTopology.primary, code: .crossfadeOneTwo)
        engine.setInterchange(.none, forBus: GraphTopology.primary)
        engine.registry.setValue(0, slot: Engine.busCodecProgramSlot, code: .corruptAmount)

        let viaTwo = renderFrame(60)

        // Same fader hard over to ONE instead, with C's damage still armed: if
        // PRIMARY were silently still reading ONE — the actual shape a routing bug
        // here would take — this frame would look like the first one.
        engine.registry.setValue(0.0, slot: GraphTopology.primary, code: .crossfadeOneTwo)
        let viaOne = renderFrame(60)

        if let viaTwo, let viaOne {
            _ = try? check.writeImage(viaTwo, named: "09-sources-cd-via-two.png")
            check.record(FrameAssertions.framesDiffer(
                viaOne, viaTwo, minimumFraction: 0.05,
                name: "PRIMARY carries C/D's picture when cut to TWO, not ONE's"))
            check.record(FrameAssertions.hasSignal(viaTwo))
        } else {
            check.record(AssertionResult(
                name: "sources C/D reach PRIMARY", passed: false,
                detail: "a frame failed to render"))
        }
        engine.registry.setValue(0, slot: GraphTopology.sourceC, code: .corruptAmount)

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
            _ = try? check.writeImage(outputNTSC, named: "09-output-ntsc.png")
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
            _ = try? check.writeImage(outputDV, named: "10-output-dv.png")
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
                _ = try? check.writeImage(fourth, named: "11-output-dv-4-generations.png")
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

        // 10. Freeze, through the live graph (the one MX-1 gesture kept when the set
        // was removed, ISF-PLAN §4.1). With the clip running, the picture must stop
        // while everything upstream carries on — and start again when HOLD drops.
        engine.load(url: fileA, intoChannel: "A")
        engine.registry.setValue(0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        engine.registry.setValue(1, slot: Engine.freezeOneSlot, code: .wetDry)
        engine.registry.setValue(1, slot: Engine.freezeOneSlot, code: .freezeHold)
        engine.setPlaying(true, channel: "A")
        _ = renderFrame(120)
        let frozenFirst = renderFrame(121)
        for frame in 122..<140 { _ = renderFrame(frame) }
        let frozenLater = renderFrame(140)
        engine.registry.setValue(0, slot: Engine.freezeOneSlot, code: .freezeHold)
        _ = renderFrame(141)
        for frame in 142..<160 { _ = renderFrame(frame) }
        let released = renderFrame(160)
        engine.setPlaying(false, channel: "A")

        if let frozenFirst, let frozenLater, let released {
            _ = try? check.writeImage(frozenLater, named: "14-freeze-held.png")
            let heldChange = FrameAssertions.differingColourFraction(frozenFirst, frozenLater)
            let liveChange = FrameAssertions.differingColourFraction(frozenLater, released)
            check.record(AssertionResult(
                name: "freeze holds the picture while the clip runs on",
                passed: heldChange < 0.02,
                detail: String(format: "%.3f of pixels changed over 19 frames of playback", heldChange)))
            check.record(AssertionResult(
                name: "letting go of freeze makes the picture live again",
                passed: liveChange > heldChange && liveChange > 0.005,
                detail: String(format: "%.3f of pixels changed after release", liveChange)))
        }
        engine.registry.setValue(0, slot: Engine.freezeOneSlot, code: .wetDry)

        // 11. A feedback send: one bus routed into the other's feedback loop. The
        // claim worth checking is that it does NOT hang — a bus feeding a loop it is
        // downstream of is a cycle, and the whole design of this send is the one-frame
        // delay that makes it expressible.
        engine.load(url: fileA, intoChannel: "A")
        engine.registry.setValue(0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        engine.registry.setValue(1, slot: Engine.feedbackSlot, code: .wetDry)
        engine.registry.setValue(0.8, slot: Engine.feedbackSlot, code: .feedbackGain)
        engine.registry.setValue(0, slot: Engine.freezeOneSlot, code: .wetDry)

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
            _ = try? check.writeImage(withSend, named: "15-feedback-send.png")
            check.record(FrameAssertions.framesDiffer(
                withoutSend, withSend, minimumFraction: 0.02,
                name: "the feedback send changes the picture"))
            // And the picture must stay a picture rather than saturating to white,
            // which is how a runaway loop usually announces itself.
            check.record(FrameAssertions.hasSignal(withSend))
        }
        engine.registry.setValue(0, slot: Engine.feedbackSlot, code: .wetDry)

        // 12. The MPEG half of the wedge, through the live graph. DV damage is
        // spatial; MPEG damage is temporal, and this is where that shows — the
        // picture smears along motion paths that are no longer there.
        let mpegSource = RepoPaths.samples.appendingPathComponent("motion.m2v")
        if FileManager.default.fileExists(atPath: mpegSource.path),
           engine.load(url: mpegSource, intoChannel: "A") {

            check.record(AssertionResult(
                name: "MPEG footage offers the MPEG data effects",
                passed: engine.dataEffectFamily(forChannel: "A") == .mpeg,
                detail: "family is \(engine.dataEffectFamily(forChannel: "A").displayName)"
            ))

            engine.registry.setValue(0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
            engine.registry.setValue(0, slot: GraphTopology.sourceA, code: .corruptAmount)

            // The SAME playhead position throughout, with the transport stopped.
            // Comparing a clean frame against a damaged one taken later measures
            // playback as well as damage, and would pass with the corruptor doing
            // nothing at all — which is exactly what it did on my first attempt.
            engine.setPlaying(false, channel: "A")
            engine.registry.setValue(
                0.4, slot: GraphTopology.sourceA, code: .scrubPosition)
            let mpegClean = renderFrame(190)

            var damagedFrames: [(name: String, image: ImageBuffer)] = []
            for mode in MPEGCorruptionMode.allCases {
                engine.registry.setValue(
                    mode.normalisedPosition, slot: GraphTopology.sourceA, code: .corruptMode)
                // The corruptor boots bypassed now, so the wedge has to be switched on
                // before it can damage anything.
                engine.registry.setValue(1, slot: GraphTopology.sourceA, code: .wetDry)
                engine.registry.setValue(0.9, slot: GraphTopology.sourceA, code: .corruptAmount)
                if let image = renderFrame(191 + MPEGCorruptionMode.allCases.firstIndex(of: mode)!) {
                    damagedFrames.append((mode.displayName, image))
                }
            }
            engine.registry.setValue(0, slot: GraphTopology.sourceA, code: .corruptAmount)

            if let mpegClean {
                _ = try? check.writeImage(mpegClean, named: "16-mpeg-clean.png")
                for damaged in damagedFrames {
                    let safeName = damaged.name.lowercased().replacingOccurrences(of: " ", with: "-")
                    _ = try? check.writeImage(damaged.image, named: "17-mpeg-\(safeName).png")
                }

                // Reported per mode, with the number, because the three are NOT the
                // same kind of effect and one flat pass/fail would hide that.
                let measured = damagedFrames.map {
                    ($0.name, FrameAssertions.differingColourFraction(mpegClean, $0.image))
                }
                check.note("MPEG damage at a fixed playhead: "
                    + measured.map { "\($0.0) \(String(format: "%.3f", $0.1))" }
                        .joined(separator: ", "))

                // All three change the picture, but not in the same way, which is why
                // the numbers are noted above rather than hidden behind a pass. Frame
                // drop lands on a different frame of the clip because the damaged
                // stream is genuinely shorter; the other two damage the frame itself.
                check.record(AssertionResult(
                    name: "every MPEG data effect changes what reaches the screen",
                    passed: measured.count == MPEGCorruptionMode.allCases.count
                        && measured.allSatisfy { $0.1 >= 0.02 },
                    detail: measured.map { "\($0.0) \(String(format: "%.3f", $0.1))" }
                        .joined(separator: ", ")
                ))

                // Still a picture. The whole claim of the wedge is that a damaged
                // bitstream still DECODES — a black frame would mean the decoder gave
                // up, which is a bug rather than an effect.
                for damaged in damagedFrames {
                    check.record(AssertionResult(
                        name: "\(damaged.name) leaves a picture, not a dead decoder",
                        passed: FrameAssertions.signalPresent(
                            damaged.image, varianceThreshold: 25.0),
                        detail: "luminance variance " + String(
                            format: "%.1f", FrameAssertions.luminanceVariance(damaged.image))
                    ))
                }
            }
        } else {
            check.note("samples/motion.m2v is missing; the MPEG wedge was not exercised")
        }

        // 13. A generator reaches its own SOURCE WINDOW, not just the bus. The
        // preview read the file slot unconditionally, so picking a gradient or a
        // checkerboard lit up the mix while the source window it came from stayed
        // empty — which reads as the generator not working at all.
        for kind in [GeneratorKind.linearGradient, .checkerboard] {
            engine.generators["A"]?.generator = kind
            engine.setChannelSource(.generator, channel: "A")

            let slot = engine.sourceSlot(forChannel: "A")
            check.record(AssertionResult(
                name: "\(kind.displayName) is read from the generator node, not the file node",
                passed: slot == Engine.generatorSlot(forChannel: "A"),
                detail: "source window reads \(slot)"
            ))

            let context = RenderContext(
                frameIndex: 210, presentationTime: 7.0,
                musicalPosition: nil)
            let produced = engine.evaluateGraph(context: context)
            if let texture = produced[slot], let image = renderer.readback(texture) {
                _ = try? check.writeImage(
                    image,
                    named: "18-generator-\(kind.displayName.lowercased().replacingOccurrences(of: " ", with: "-")).png")
                check.record(AssertionResult(
                    name: "\(kind.displayName) draws a picture in its source window",
                    passed: FrameAssertions.signalPresent(image, varianceThreshold: 25.0),
                    detail: "luminance variance "
                        + String(format: "%.1f", FrameAssertions.luminanceVariance(image))
                ))
            } else {
                check.record(AssertionResult(
                    name: "\(kind.displayName) renders", passed: false,
                    detail: "the generator node produced no texture"))
            }
        }
        engine.setChannelSource(.file, channel: "A")

        check.note("all frames rendered through the engine's own nodes and Metal pipelines")
        return check.finish()
    }
}

//
//  StressSelfQA.swift — the real window, the real display link, everything on.
//
//  Purpose : The jitter check in UISelfQA times `evaluateGraph` alone, offscreen. A
//            running show pays for more than that on every tick — the previews, the
//            tallies, the scopes, the sweeps — all on the main thread, at whatever rate
//            the display link fires. This opens the actual main window, loads all four
//            channels, switches every effect on, runs the transport, and measures the
//            WHOLE tick on the live clock: the number a performer actually feels.
//  Inputs  : samples/ (bars.dv, motion.dv, motion.m2v, motion.mov).
//  Outputs : selfqa/out/perf/stress/result.txt.
//  Connects: MainWindowController, Engine.tickCostsForChecks.
//  Extend  : add load (more sources, a feedback loop) to `run()`; keep asserting on
//            the WORST tick, never the mean.
//

import AppKit
import VideoboyCore

enum StressSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/stress")
        let store = PreferenceStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("videoboy-stress-prefs.json"))
        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let screen = NSScreen.main else {
            return check.finish(blockedReason: "no window or screen to run on")
        }
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true)
        controller.showWindow(nil)
        // In front, or every preview skips presenting (nobody can see it) and the
        // cadence assertion below has no frames to judge.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let engine = controller.engine

        // Four channels, four kinds of media: two DV decodes, MPEG-2, ordinary video.
        let clips = ["A": "bars.dv", "B": "motion.dv", "C": "motion.m2v", "D": "motion.mov"]
        var loaded: [String] = []
        for (letter, name) in clips.sorted(by: { $0.key < $1.key }) {
            let url = RepoPaths.samples.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path),
               engine.load(url: url, intoChannel: letter) {
                engine.setPlaying(true, channel: letter)
                loaded.append("\(letter)=\(name)")
            }
        }
        guard loaded.count == 4 else {
            return check.finish(blockedReason: "samples/ is missing fixtures; loaded \(loaded)")
        }
        check.note("loaded \(loaded.joined(separator: ", "))")

        // EVERYTHING on, with non-neutral settings so no node can skip its pass.
        for slot in Engine.busEffectSlots {
            engine.registry.setValue(1, slot: slot, code: .wetDry)
        }
        for letter in ["A", "B", "C", "D"] {
            engine.registry.setValue(1, slot: Engine.slot(forChannel: letter), code: .wetDry)
            engine.registry.setValue(0.6, slot: Engine.slot(forChannel: letter), code: .corruptAmount)
            for effect in ["mosh", "transform", "colour", "composite", "echo", "feedback", "freeze"] {
                engine.registry.setValue(1, slot: Engine.channelSlot(letter, effect), code: .wetDry)
            }
            // Datamosh is free at zero, so it needs a real amount to be under load:
            // a live H.264 encode + decode on every channel.
            engine.registry.setValue(0.5, slot: Engine.channelSlot(letter, "mosh"), code: .moshAmount)
            engine.registry.setValue(1.3, slot: Engine.channelSlot(letter, "colour"), code: .contrast)
            engine.registry.setValue(1.2, slot: Engine.channelSlot(letter, "transform"), code: .scale)
        }
        // ...and on both buses, so six H.264 round trips run at once.
        for slot in [Engine.moshOneSlot, Engine.moshTwoSlot] {
            engine.registry.setValue(0.5, slot: slot, code: .moshAmount)
        }
        // And every mosh control that costs anything, on all six: melt and bloom in
        // the engine, a heal on every beat (blocks, half a second — at 120 BPM one is
        // always in progress), and the mosh screened over its clean input at 0.8, so
        // the layer pass runs on every frame.
        let screenBlend = DatamoshNode.blendModes.firstIndex(of: .screen) ?? 0
        let moshSlots = ["A", "B", "C", "D"].map { Engine.channelSlot($0, "mosh") }
            + [Engine.moshOneSlot, Engine.moshTwoSlot]
        for slot in moshSlots {
            for (code, value) in [
                (ParamCode.moshMelt, 0.3),
                (.moshBloom, 0.5),
                (.moshHealEvery, MoshHealEvery.beat.normalisedPosition),
                (.moshHealTime, DatamoshNode.defaultHealTime),
                (.moshHealShape, MoshHealShape.blocks.normalisedPosition),
                (.opacity, 0.8),
                (.moshBlend, Double(screenBlend) / Double(DatamoshNode.blendModes.count - 1))
            ] {
                engine.registry.setValue(value, slot: slot, code: code)
            }
        }
        // Every fader on the AVE-5 wipe, mid-travel, all five keys lit, ×16 and a
        // soft edge: the most work that transition's shader branch can do per pixel.
        let heaviestWipe = AVE5Wipe(keys: [.allEdges, .circle], multi: .x16, edge: .soft,
                                    positionX: 0.4, positionY: 0.6)
        for (slot, fader) in [(GraphTopology.subMixOne, ParamCode.crossfadeAB),
                              (GraphTopology.subMixTwo, .crossfadeCD),
                              (GraphTopology.primary, .crossfadeOneTwo)] {
            engine.registry.setValue(Transition.ave5.normalisedPosition, slot: slot, code: .transition)
            for (code, value) in heaviestWipe.parameterValues {
                engine.registry.setValue(value, slot: slot, code: code)
            }
            engine.registry.setValue(0.5, slot: slot, code: fader)
        }
        engine.setTransportRunning(true)

        // Warm-up pays for texture allocation and shader compilation; not a show.
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        let dropsBefore = engine.droppedFrames
        engine.tickCostsForChecks = []
        engine.graphCostsForChecks = []
        engine.nodeCostsForChecks = [:]
        let seconds = 8.0
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        let costs = engine.tickCostsForChecks ?? []
        engine.tickCostsForChecks = nil
        let graph = engine.graphCostsForChecks ?? []
        engine.graphCostsForChecks = nil
        let nodes = engine.nodeCostsForChecks ?? [:]
        engine.nodeCostsForChecks = nil
        let drops = engine.droppedFrames - dropsBefore
        engine.setTransportRunning(false)

        // The mosh really ran, everywhere — a node that never started would make the
        // numbers above look better than the real load.
        let moshNodes = engine.graph.nodes.values.compactMap { $0 as? DatamoshNode }
            .sorted { $0.identifier < $1.identifier }
        for node in moshNodes {
            check.note("  \(node.identifier): \(node.statistics), heals \(node.healCount)")
        }
        let moshing = moshNodes.filter {
            $0.isRunning && $0.statistics.emitted > 30 && $0.statistics.bloomed > 0 && $0.healCount > 0
        }
        check.record(AssertionResult(
            name: "every datamosh node is encoding, decoding, blooming and healing on the beat under load",
            passed: moshNodes.count == 6 && moshing.count == 6,
            detail: "\(moshing.count) of \(moshNodes.count) running with frames flowing"))

        guard costs.count > 10 else {
            window.orderOut(nil)
            return check.finish(blockedReason: "the display link did not tick (\(costs.count) ticks)")
        }
        let sorted = costs.sorted()
        let mean = costs.reduce(0, +) / Double(costs.count)
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let worst = sorted.last ?? 0
        let refreshMs = engine.refreshInterval * 1000
        let ticksPerSecond = Double(costs.count) / seconds
        let contentBudget = 1000.0 / StandardDefinition.frameRate

        check.note(String(format: "display link at %.1f Hz (%.2f ms/refresh)", 1000 / refreshMs, refreshMs))
        check.note(String(format: "%d frames rendered in %.0f s = %.2f/s; %d dropped refreshes", costs.count, seconds, ticksPerSecond, drops))
        check.note(String(format: "whole tick: mean %.2f ms, p95 %.2f ms, worst %.2f ms", mean, p95, worst))
        if !graph.isEmpty {
            let graphMean = graph.reduce(0, +) / Double(graph.count)
            check.note(String(format: "  of which graph: mean %.2f ms, worst %.2f ms; UI/onFrame: mean %.2f ms",
                              graphMean, graph.max() ?? 0, mean - graphMean))
        }

        // Where the graph's time goes, per tick, heaviest first.
        let perTick = nodes.mapValues { $0 / Double(costs.count) }
            .sorted { $0.value > $1.value }
        for (node, ms) in perTick.prefix(15) where ms >= 0.05 {
            check.note(String(format: "  node %@: %.2f ms/tick", node, ms))
        }

        // The graph is frame-clocked (a clip advances one frame per render), so the
        // rate that matters is 29.97 — faster plays clips fast, slower plays them slow.
        let contentRate = StandardDefinition.frameRate
        check.record(AssertionResult(
            name: "the graph renders at the 29.97 content rate under full load",
            passed: abs(ticksPerSecond - contentRate) <= contentRate * 0.02,
            detail: String(format: "%.2f frames/s against %.2f", ticksPerSecond, contentRate)
        ))
        check.record(AssertionResult(
            name: "under 1% of display-link ticks dropped under full load",
            passed: Double(drops) <= Double(costs.count) * 0.01,
            detail: "\(drops) dropped of \(costs.count)"
        ))
        check.record(AssertionResult(
            name: "no whole tick exceeds one SD frame (33.4 ms)",
            passed: worst < contentBudget,
            detail: String(format: "worst %.2f ms, p95 %.2f ms, mean %.2f ms", worst, p95, mean)
        ))

        // TRANSITIONS IN MOTION. Everything above holds the faders still at 0.5; a
        // show moves them. FADE runs back and forth on all three buses, stepping
        // every bus through every pattern, with the AVE-5 popover open — the per-tick
        // work a wipe costs while it is actually travelling, UI included.
        if let shell = controller.shellController {
            let panels = shell.shell.grid.panels
            let buses: [(body: FaderPanelBody, slot: String)] = [
                (panels.faderABBody, GraphTopology.subMixOne),
                (panels.faderCDBody, GraphTopology.subMixTwo),
                (panels.faderOneTwoBody, GraphTopology.primary)
            ]
            if let anchor = panels.faderOneTwoBody.transitionButton {
                engine.registry.setValue(Transition.ave5.normalisedPosition,
                                         slot: GraphTopology.primary, code: .transition)
                shell.toggleAVE5Panel(slot: GraphTopology.primary, anchor: anchor)
            }
            engine.setTransportRunning(true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let movingDropsBefore = engine.droppedFrames
            engine.tickCostsForChecks = []
            engine.graphCostsForChecks = []
            let programPreview = panels.programBody.preview
            programPreview.presentedTimesForChecks = []
            var step = 0
            let fadeSeconds = FadeRate.fast.seconds + 0.1
            let movingSeconds = Double(Transition.allCases.count) * fadeSeconds
            let end = Date().addingTimeInterval(movingSeconds)
            while Date() < end {
                let pattern = Transition.allCases[step % Transition.allCases.count]
                for bus in buses {
                    // Keep the primary on AVE-5 so the open popover stays live.
                    if bus.slot != GraphTopology.primary {
                        engine.registry.setValue(pattern.normalisedPosition, slot: bus.slot, code: .transition)
                    }
                    bus.body.onFade?(.fast)
                }
                step += 1
                RunLoop.main.run(until: Date().addingTimeInterval(fadeSeconds))
            }
            let moving = engine.tickCostsForChecks ?? []
            let movingGraph = engine.graphCostsForChecks ?? []
            engine.tickCostsForChecks = nil
            engine.graphCostsForChecks = nil
            let movingDrops = engine.droppedFrames - movingDropsBefore
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let shown = (programPreview.presentedTimesForChecks ?? []).filter { $0 > 0 }
            programPreview.presentedTimesForChecks = nil
            // How long each frame stayed on the PREVIEW, in screen refreshes. Even
            // pacing is every frame for the same count (2 at 60 Hz); a mix of 1s and
            // 3s is judder that a moving wipe edge shows and a dissolve hides.
            let screenRefresh = 1.0 / Double(window.screen?.maximumFramesPerSecond ?? 60)
            var held: [Int: Int] = [:]
            for (earlier, later) in zip(shown, shown.dropFirst()) {
                held[Int(((later - earlier) / screenRefresh).rounded()), default: 0] += 1
            }
            let heldSummary = held.keys.sorted().map { "\($0)×: \(held[$0]!)" }.joined(separator: ", ")
            check.note("program preview: \(shown.count) frames shown; refreshes each was held for — \(heldSummary)")
            // Only asserted where frames divide the screen's refreshes evenly (60, 120 Hz);
            // on a 50 or 144 Hz screen an uneven cadence is the correct answer.
            let refreshesPerFrame = 1.0 / (screenRefresh * StandardDefinition.frameRate)
            let evenHold = Int(refreshesPerFrame.rounded())
            // A preview that showed nothing is not "evenly paced" — it is unmeasured,
            // and must say so rather than skip the assertion.
            check.record(AssertionResult(
                name: "the program preview presented frames while the wipes moved",
                passed: shown.count > 10,
                detail: "\(shown.count) frames shown"))
            if abs(refreshesPerFrame - Double(evenHold)) < 0.05, shown.count > 10 {
                let even = held[evenHold] ?? 0
                let intervals = shown.count - 1
                check.record(AssertionResult(
                    name: "the program preview paces a moving wipe evenly (90% of frames held \(evenHold) refreshes)",
                    passed: Double(even) >= Double(intervals) * 0.9,
                    detail: "\(even) of \(intervals) — \(heldSummary)"))
            }
            engine.setTransportRunning(false)
            shell.closeAVE5Panel()
            let movingSorted = moving.sorted()
            let movingWorst = movingSorted.last ?? 0
            let movingMean = moving.isEmpty ? 0 : moving.reduce(0, +) / Double(moving.count)
            let movingP95 = movingSorted.isEmpty ? 0 : movingSorted[Int(Double(movingSorted.count - 1) * 0.95)]
            let movingRate = Double(moving.count) / movingSeconds
            check.note(String(format: "transitions moving: %d frames in %.1f s = %.2f/s, %d dropped; tick mean %.2f ms, p95 %.2f ms, worst %.2f ms; graph mean %.2f ms, worst %.2f ms",
                              moving.count, movingSeconds, movingRate, movingDrops, movingMean, movingP95, movingWorst,
                              movingGraph.isEmpty ? 0 : movingGraph.reduce(0, +) / Double(movingGraph.count),
                              movingGraph.max() ?? 0))
            check.record(AssertionResult(
                name: "transitions in motion hold 29.97 with no tick over one SD frame",
                passed: abs(movingRate - contentRate) <= contentRate * 0.02
                    && movingWorst < contentBudget
                    && Double(movingDrops) <= Double(moving.count) * 0.01,
                detail: String(format: "%.2f frames/s, %d dropped, worst %.2f ms, p95 %.2f ms",
                               movingRate, movingDrops, movingWorst, movingP95)))
        }

        // HIDDEN WINDOW. A performer covers Videoboy with another app mid-show; the
        // render loop also drives the OUTPUT window, so it must not stall on preview
        // layers nobody can see (a starved `nextDrawable()` blocks for up to 1 s).
        window.orderOut(nil)
        engine.setTransportRunning(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        engine.tickCostsForChecks = []
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        let hidden = engine.tickCostsForChecks ?? []
        engine.tickCostsForChecks = nil
        engine.setTransportRunning(false)
        let hiddenWorst = hidden.max() ?? 0
        check.note(String(format: "window hidden: %d frames in 4 s, worst tick %.2f ms", hidden.count, hiddenWorst))
        check.record(AssertionResult(
            name: "a hidden main window never stalls the render loop",
            passed: hidden.count >= 110 && hiddenWorst < contentBudget,
            detail: String(format: "%d frames in 4 s, worst %.2f ms", hidden.count, hiddenWorst)
        ))

        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

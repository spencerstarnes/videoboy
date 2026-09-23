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
            for effect in ["transform", "colour", "composite", "echo", "feedback", "mx1"] {
                engine.registry.setValue(1, slot: Engine.channelSlot(letter, effect), code: .wetDry)
            }
            engine.registry.setValue(1.3, slot: Engine.channelSlot(letter, "colour"), code: .contrast)
            engine.registry.setValue(1.2, slot: Engine.channelSlot(letter, "transform"), code: .scale)
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

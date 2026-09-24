//
//  PushFadeSelfQA.swift — a push transition on the centre fader, automated, measured.
//
//  Purpose : A push moves the WHOLE picture by the fader's step each frame, so any
//            unevenness in those steps is visible across the entire screen — far
//            more than a wipe's single edge, and not at all under a dissolve. This
//            loads two clips (A and C), puts the centre fader on Push Horizontal and
//            automates it end to end through the same keys the performer presses
//            (FADE at each rate, and a sweep between marks), then measures what was
//            actually rendered: the fader position of every frame, how evenly it
//            advanced, the tick cost, and how evenly the program preview was shown.
//  Inputs  : samples/motion.dv, samples/motion.mov.
//  Outputs : selfqa/out/perf/push-fade/result.txt.
//  Connects: MainWindowController, ShellController's fader wiring, Engine.onFrame.
//  Extend  : add another automation route as another `measure` call.
//

import AppKit
import VideoboyCore

enum PushFadeSelfQA {

    /// One rendered frame: when it was meant to be seen and where the fader was.
    private struct Sample {
        let shownAt: CFTimeInterval
        let position: Double
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/push-fade")
        let store = PreferenceStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("videoboy-pushfade-prefs.json"))
        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let screen = NSScreen.main,
              let shell = controller.shellController else {
            return check.finish(blockedReason: "no window or screen to run on")
        }
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true)
        controller.showWindow(nil)
        // In front, or the previews skip presenting (nobody can see them) and the
        // cadence measure below has nothing to measure.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let engine = controller.engine

        // The performer's setup: one clip in A, another in C, nothing else.
        for (letter, name) in [("A", "motion.dv"), ("C", "motion.mov")] {
            let url = RepoPaths.samples.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                  engine.load(url: url, intoChannel: letter) else {
                return check.finish(blockedReason: "samples/\(name) is missing")
            }
            engine.setPlaying(true, channel: letter)
        }

        // Push Horizontal on the centre fader, chosen through the panel's own closure.
        let centre = shell.shell.grid.panels.faderOneTwoBody
        centre.onTransitionChanged?(.pushHorizontal)
        centre.onFaderMoved?(0)
        centre.setPosition(0)
        engine.setTransportRunning(true)
        RunLoop.main.run(until: Date().addingTimeInterval(2))

        // Record the position every rendered frame actually used.
        var samples: [Sample] = []
        let original = engine.onFrame
        engine.onFrame = { engine in
            samples.append(Sample(shownAt: engine.framePresentationTime,
                                  position: engine.primary.position))
            original?(engine)
        }
        let preview = shell.shell.grid.panels.programBody.preview

        var allSteady = true
        var cadence = Cadence()
        for rate in FadeRate.allCases {
            for (from, to) in [(0.0, 1.0), (1.0, 0.0)] {
                centre.onFaderMoved?(from)
                centre.setPosition(from)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                samples = []
                engine.tickCostsForChecks = []
                preview.presentedTimesForChecks = []
                // The fade the key starts, rebuilt here from the same press time, is
                // the truth every rendered frame is compared with.
                let truth = FadeAutomation(from: from, to: to, duration: rate.seconds,
                                           startedAt: CACurrentMediaTime())
                centre.onFade?(rate)
                RunLoop.main.run(until: Date().addingTimeInterval(rate.seconds + 0.3))
                allSteady = measure("FADE \(rate.displayName) \(Int(from))→\(Int(to))",
                                    samples: samples, truth: { truth.position(atHostTime: $0) },
                                    engine: engine, preview: preview, window: window, check: check,
                                    cadence: &cadence)
                    && allSteady
            }
        }

        // A sweep between marks at the two ends, at the fader's default rate.
        centre.fader.markSweepForChecks(first: 0, second: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        samples = []
        engine.tickCostsForChecks = []
        preview.presentedTimesForChecks = []
        RunLoop.main.run(until: Date().addingTimeInterval(4))
        if let sweep = centre.fader.sweep {
            allSteady = measure("SWEEP 0↔1 over \(sweep.beatsPerCycle) beats", samples: samples,
                                truth: { sweep.value(atBeats: engine.transport.beats(atHostTime: $0)) },
                                engine: engine, preview: preview, window: window, check: check,
                                cadence: &cadence)
                && allSteady
        } else {
            check.note("SWEEP: the marks did not arm a sweep")
            allSteady = false
        }
        centre.fader.clearSweep()

        engine.onFrame = original
        engine.tickCostsForChecks = nil
        preview.presentedTimesForChecks = nil
        engine.setTransportRunning(false)
        check.record(AssertionResult(
            name: "every automated push is on its curve at each frame's display time (within 0.5 px)",
            passed: allSteady, detail: "see the per-run notes"))
        // And the picture reaches the screen as evenly as it is rendered. Only
        // asserted where frames divide the refreshes evenly (60, 120 Hz).
        let refreshesPerFrame = Double(window.screen?.maximumFramesPerSecond ?? 60)
            / StandardDefinition.frameRate
        let evenHold = Int(refreshesPerFrame.rounded())
        if abs(refreshesPerFrame - Double(evenHold)) < 0.05 {
            let even = cadence.held[evenHold] ?? 0
            check.record(AssertionResult(
                name: "the program preview shows a moving push evenly (95% of frames held \(evenHold) refreshes)",
                passed: cadence.intervals > 100 && Double(even) >= Double(cadence.intervals) * 0.95,
                detail: "\(even) of \(cadence.intervals) — \(cadence.summary)"))
        }
        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }

    /// How long each frame stayed on the program preview, in refreshes, over every run.
    private struct Cadence {
        var held: [Int: Int] = [:]
        var intervals: Int { held.values.reduce(0, +) }
        var summary: String {
            held.keys.sorted().map { "\($0)×: \(held[$0]!)" }.joined(separator: ", ")
        }
    }

    /// Reports how closely one automated move followed its curve, frame by frame.
    ///
    /// The truth for each frame is the automation's own curve at the moment that
    /// frame is SHOWN. The error is how far the rendered position was from it, in
    /// pixels of picture travel across 720 — the distance a push visibly jumps. An
    /// error that changes from frame to frame is exactly what reads as stutter.
    private static func measure(
        _ label: String, samples: [Sample], truth: (CFTimeInterval) -> Double,
        engine: Engine, preview: MetalPreviewView, window: NSWindow, check: SelfQACheck,
        cadence: inout Cadence
    ) -> Bool {
        let width = Double(StandardDefinition.width)
        // Only frames where the picture is actually travelling.
        let moving = samples.filter { $0.position > 0.001 && $0.position < 0.999 }
        guard moving.count > 3 else {
            check.note("\(label): only \(moving.count) moving frames")
            return false
        }
        let steps = zip(moving, moving.dropFirst()).map { abs($1.position - $0.position) * width }
        let errors = moving.map { abs(truth($0.shownAt) - $0.position) * width }
        let worstError = errors.max() ?? 0

        let costs = engine.tickCostsForChecks ?? []
        let shown = (preview.presentedTimesForChecks ?? []).filter { $0 > 0 }
        let refresh = 1.0 / Double(window.screen?.maximumFramesPerSecond ?? 60)
        var held: [Int: Int] = [:]
        for (earlier, later) in zip(shown, shown.dropFirst()) {
            let count = Int(((later - earlier) / refresh).rounded())
            held[count, default: 0] += 1
            cadence.held[count, default: 0] += 1
        }
        let heldSummary = held.keys.sorted().map { "\($0)×: \(held[$0]!)" }.joined(separator: ", ")
        check.note(String(
            format: "%@: %d moving frames; worst off-curve %.2f px; step %.1f–%.1f px; worst tick %.1f ms; preview held %@",
            label, moving.count, worstError, steps.min() ?? 0, steps.max() ?? 0,
            costs.max() ?? 0, heldSummary.isEmpty ? "(none reported)" : heldSummary))
        check.note("  steps px: " + steps.map { String(format: "%.1f", $0) }.joined(separator: " "))
        // Half a pixel: below what a push can show, far below the 10+ px jumps that
        // sampling after the previous render produced.
        return worstError < 0.5
    }
}

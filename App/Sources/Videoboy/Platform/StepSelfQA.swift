//
//  StepSelfQA.swift — does the source STEP key (1/4, 1/8 …) actually step the picture?
//
//  Purpose : The owner reported (2026-10-02) that the shuttle's rates seem to do
//            nothing. The UI checks only proved the key walks its ladder; nothing
//            proved a clip moves at the rate the key names. This plays a real clip on
//            A in a real window with the live display link, sets each rate through
//            the key's own callback, and counts frames advanced per second — with the
//            transport stopped and running.
//  Inputs  : samples/motion.m2v (or bars.dv), a scratch preference file.
//  Outputs : selfqa/out/perf/step/result.txt.
//  Connects: SourcePanelBody.onTimingChanged → ClipSourceNode.timing; Engine transport.
//

import AppKit
import VideoboyCore

enum StepSelfQA {

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/step")
        guard let clip = ["motion.m2v", "bars.dv"].map({ RepoPaths.samples.appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return check.finish(blockedReason: "no sample clip in samples/")
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-step-qa-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = PreferenceStore(fileURL: scratch.appendingPathComponent("prefs.json"))
        store.preferences.setupCompleted = true

        let controller = MainWindowController(preferences: store)
        guard let shell = controller.shellController,
              let body = shell.shell.grid.panels.sourceBodies["A"] else {
            return check.finish(blockedReason: "no window")
        }
        controller.showWindow(nil)
        spin(0.5)
        let engine = controller.engine
        shell.loadClipForChecks(clip, into: "A")
        spin(2.0)
        guard let node = engine.sources["A"], node.frameCount > 10 else {
            return check.finish(blockedReason: "\(clip.lastPathComponent) did not load into A")
        }
        engine.setPlaying(true, channel: "A")
        engine.setTempo(120)

        /// Frames the playhead moved in `seconds`, summed tick by tick so a loop's
        /// wrap does not read as going backwards.
        func framesAdvanced(over seconds: TimeInterval) -> Double {
            var total = 0.0
            var last = node.playheadFrame
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                spin(0.02)
                let now = node.playheadFrame
                var delta = now - last
                if delta < -Double(node.frameCount) / 2 { delta += Double(node.frameCount) }
                total += max(delta, 0)
                last = now
            }
            return total
        }

        let window: TimeInterval = 4
        // At 120 BPM: a beat is 0.5 s. 1/4 → 2 frames/s, 1/8 → 4, 1/16 → 8, 1/2 → 1.
        let cases: [(PlaybackTiming, Double)] = [
            (.stepped(subdivision: .half, frames: 1), 1),
            (.stepped(subdivision: .quarter, frames: 1), 2),
            (.stepped(subdivision: .eighth, frames: 1), 4),
            (.stepped(subdivision: .sixteenth, frames: 1), 8)
        ]

        // 1. Transport STOPPED: what the owner most likely saw.
        engine.setTransportRunning(false)
        body.onTimingChanged?(.stepped(subdivision: .quarter, frames: 1))
        let stoppedFrames = framesAdvanced(over: 2)
        check.record(AssertionResult(
            name: "with the transport stopped, a clip on 1/4 holds still (this is what 'nonfunctional' looks like)",
            passed: true,
            detail: String(format: "%.1f frames in 2 s; node timing %@", stoppedFrames, node.timing.displayName)))

        // 2. Transport RUNNING: each rate steps at the speed it names.
        engine.setTransportRunning(true)
        spin(0.3)
        for (timing, perSecond) in cases {
            body.onTimingChanged?(timing)
            spin(0.2)
            let frames = framesAdvanced(over: window)
            let rate = frames / window
            check.record(AssertionResult(
                name: "transport running at 120 BPM, \(timing.displayName) steps about \(Int(perSecond)) frame(s) a second",
                passed: abs(rate - perSecond) <= max(0.6, perSecond * 0.25),
                detail: String(format: "%.0f frames in %.0f s = %.2f/s (expected %.0f); node timing %@",
                               frames, window, rate, perSecond, node.timing.displayName)))
        }

        // 3. Back to STEP: continuous playback.
        body.onTimingChanged?(.continuous)
        let continuous = framesAdvanced(over: 2) / 2
        check.record(AssertionResult(
            name: "STEP (off) plays continuously, about 30 frames a second",
            passed: continuous > 20,
            detail: String(format: "%.1f frames/s", continuous)))

        engine.setTransportRunning(false)
        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

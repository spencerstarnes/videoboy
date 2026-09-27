//
//  SoakSelfQA.swift — a long show under full load, watching for drift and leaks.
//
//  Purpose : `stress` proves eight seconds are clean. A show is hours, and the things
//            that end a show late — memory that creeps, GPU allocations that are never
//            returned, threads or file handles left behind by a clip swap, a tick that
//            gets slower every minute — are invisible in eight seconds. This runs the
//            real window at full load for minutes while doing what a performer does
//            (drop clips on every channel, eject, swap, cut, fade, flip effects), and
//            samples the process every 30 s.
//  Inputs  : samples/ (bars.dv, motion.dv, motion.m2v, motion.mov).
//            VIDEOBOY_SOAK_MINUTES (default 10).
//  Outputs : selfqa/out/perf/soak/{result.txt, samples.csv, actions.csv}.
//  Connects: MainWindowController, ShellController panel callbacks, Engine.
//  Extend  : add a performer action to `actions`; it is timed and counted like the
//            rest. Keep asserting on WORST tick and on growth, never the mean.
//

import AppKit
import Darwin
import Metal
import VideoboyCore

enum SoakSelfQA {

    /// One 30-second window of the soak.
    private struct Sample {
        var minute: Double
        var footprintMB: Double
        var gpuMB: Double
        var threads: Int
        var fileDescriptors: Int
        var frames: Int
        var dropped: Int
        var meanMs: Double
        var p99Ms: Double
        var worstMs: Double
        var over16: Int
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/soak")
        let minutes = Double(ProcessInfo.processInfo.environment["VIDEOBOY_SOAK_MINUTES"] ?? "") ?? 10
        let store = PreferenceStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("videoboy-soak-prefs.json"))
        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let screen = NSScreen.main,
              let shell = controller.shellController else {
            return check.finish(blockedReason: "no window, screen or shell to run on")
        }
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let engine = controller.engine
        let panels = shell.shell.grid.panels

        // VIDEOBOY_SOAK_CLIPS (four colon-separated paths) swaps the SD fixtures for
        // real footage — the fixtures are small and cost far less to decode.
        let clips: [URL]
        if let custom = ProcessInfo.processInfo.environment["VIDEOBOY_SOAK_CLIPS"],
           case let paths = custom.split(separator: ":").map(String.init), paths.count == 4 {
            clips = paths.map { URL(fileURLWithPath: $0) }
        } else {
            clips = ["bars.dv", "motion.dv", "motion.m2v", "motion.mov"]
                .map { RepoPaths.samples.appendingPathComponent($0) }
        }
        check.note("clips: " + clips.map(\.lastPathComponent).joined(separator: ", "))
        guard clips.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            return check.finish(blockedReason: "samples/ is missing fixtures")
        }
        let letters = ["A", "B", "C", "D"]
        // Loaded through the panel's drop handler — the path a dragged clip takes.
        for (letter, url) in zip(letters, clips) {
            panels.sourceBodies[letter]?.onClipDropped?(url, nil)
            engine.setPlaying(true, channel: letter)
        }

        // The same full load as `stress`: every effect on, mosh everywhere.
        for slot in Engine.busEffectSlots { engine.registry.setValue(1, slot: slot, code: .wetDry) }
        for letter in letters {
            engine.registry.setValue(1, slot: Engine.slot(forChannel: letter), code: .wetDry)
            engine.registry.setValue(0.6, slot: Engine.slot(forChannel: letter), code: .corruptAmount)
            for effect in ["mosh", "transform", "colour", "composite", "echo", "feedback", "freeze"] {
                engine.registry.setValue(1, slot: Engine.channelSlot(letter, effect), code: .wetDry)
            }
            engine.registry.setValue(0.5, slot: Engine.channelSlot(letter, "mosh"), code: .moshAmount)
        }
        for slot in [Engine.moshOneSlot, Engine.moshTwoSlot] {
            engine.registry.setValue(0.5, slot: slot, code: .moshAmount)
        }
        engine.setTransportRunning(true)

        // WHAT A PERFORMER DOES, round-robin, one every two seconds. Each is timed as a
        // synchronous main-thread call: anything that runs longer than the tick's
        // headroom delays the next frame whether or not the tick itself is slow.
        var clipCursor = 0
        let faders = [panels.faderABBody, panels.faderCDBody, panels.faderOneTwoBody]
        let actions: [(name: String, run: () -> Void)] = [
            ("drop clip", {
                let letter = letters[clipCursor % 4]
                let url = clips[(clipCursor / 4 + clipCursor) % 4]
                clipCursor += 1
                panels.sourceBodies[letter]?.onClipDropped?(url, nil)
                engine.setPlaying(true, channel: letter)
            }),
            ("cut", { faders[clipCursor % 3].onCutRequested?() }),
            ("fade", { faders[clipCursor % 3].onFade?(.fast) }),
            ("effect off/on", {
                let slot = Engine.channelSlot(letters[clipCursor % 4], "echo")
                let on = engine.registry.value(slot: slot, code: .wetDry) ?? 0
                engine.registry.setValue(on > 0 ? 0 : 1, slot: slot, code: .wetDry)
            }),
            ("eject + reload", {
                let letter = letters[(clipCursor + 2) % 4]
                panels.sourceBodies[letter]?.onEjectRequested?()
                panels.sourceBodies[letter]?.onClipDropped?(clips[clipCursor % 4], nil)
                engine.setPlaying(true, channel: letter)
            }),
            ("swap A/B", { engine.swapChannels("A", "B") }),
            ("scope key", {
                panels.programBody.onScopeKeyPressed?(.kind(.waveform))
            })
        ]
        // VIDEOBOY_SOAK_ONLY runs a single action (by name), to find which one a
        // growth comes from.
        let only = ProcessInfo.processInfo.environment["VIDEOBOY_SOAK_ONLY"]
        let chosen = only.map { name in actions.filter { $0.name == name } } ?? actions
        guard !chosen.isEmpty else { return check.finish(blockedReason: "no action named \(only ?? "")") }
        var actionCosts: [String: [Double]] = [:]

        // Warm-up: shader compiles, pools filling. Not a show.
        RunLoop.main.run(until: Date().addingTimeInterval(5))

        // A REPLACED Source Controls card must be freed. Every clip change rebuilds it;
        // one that stays alive leaks a card of controls per load (found 0.4.7).
        // Inside autorelease pools, as NSApplication's event loop runs each event: this
        // harness drives the run loop itself, and without a pool anything autoreleased
        // on the main thread lives until the check ends.
        // Steady state: the card built at launch was made outside any pool, so the one
        // tracked is a card built by a clip change, then replaced by another.
        weak var replacedCard: NSView?
        autoreleasepool { panels.sourceBodies["A"]?.onClipDropped?(clips[2], nil) }
        autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        autoreleasepool { replacedCard = panels.effectsOneBody.sourceCardViewForChecks }
        autoreleasepool { panels.sourceBodies["A"]?.onClipDropped?(clips[1], nil) }
        autoreleasepool { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
        check.record(AssertionResult(
            name: "a replaced Source Controls card is freed",
            passed: replacedCard == nil,
            detail: replacedCard == nil ? "freed" : "still alive after its replacement: \(String(describing: replacedCard))"))
        panels.sourceBodies["A"]?.onClipDropped?(clips[0], nil)
        engine.setPlaying(true, channel: "A")

        func viewCount(_ view: NSView) -> Int { 1 + view.subviews.reduce(0) { $0 + viewCount($1) } }
        let viewsAtStart = window.contentView.map(viewCount) ?? 0

        var samples: [Sample] = []
        let start = Date()
        let end = start.addingTimeInterval(minutes * 60)
        let sampleEvery = 30.0
        var nextSample = start.addingTimeInterval(sampleEvery)
        var nextAction = start.addingTimeInterval(2)
        var actionIndex = 0
        engine.tickCostsForChecks = []
        engine.spikesForChecks = []
        var dropsAtWindow = engine.droppedFrames
        samples.append(snapshot(at: 0, engine: engine, ticks: [], dropped: 0))

        // Each slice and each action in its own autorelease pool, as NSApplication's
        // event loop runs each event. Without them this harness — which drives the run
        // loop itself — kept every autoreleased object for the whole soak, and the
        // growth looked like a leak in the app (0.4.7).
        while Date() < end {
            autoreleasepool { RunLoop.main.run(until: min(nextAction, nextSample)) }
            let now = Date()
            if now >= nextAction {
                let action = chosen[actionIndex % chosen.count]
                let began = CACurrentMediaTime()
                autoreleasepool { action.run() }
                actionCosts[action.name, default: []].append((CACurrentMediaTime() - began) * 1000)
                actionIndex += 1
                nextAction = now.addingTimeInterval(2)
            }
            if now >= nextSample {
                let ticks = engine.tickCostsForChecks ?? []
                engine.tickCostsForChecks = []
                let drops = engine.droppedFrames - dropsAtWindow
                dropsAtWindow = engine.droppedFrames
                samples.append(snapshot(at: now.timeIntervalSince(start) / 60,
                                        engine: engine, ticks: ticks, dropped: drops))
                let last = samples[samples.count - 1]
                Log.info(.selfqa, String(format: "soak %.1f min: %.0f MB, gpu %.0f MB, %d thr, %d fd, %d fr, worst %.1f ms",
                                         last.minute, last.footprintMB, last.gpuMB, last.threads,
                                         last.fileDescriptors, last.frames, last.worstMs))
                nextSample = now.addingTimeInterval(sampleEvery)
            }
        }
        engine.tickCostsForChecks = nil
        let spikes = engine.spikesForChecks ?? []
        engine.spikesForChecks = nil
        engine.setTransportRunning(false)

        // WHERE THE SLOW TICKS WENT: every tick over the threshold, blamed on its
        // single costliest part, then the ten worst in full.
        var blame: [String: Int] = [:]
        for spike in spikes { blame[spike.parts.first?.0 ?? "?", default: 0] += 1 }
        check.note(String(format: "%d ticks over %.0f ms; costliest part in each: ", spikes.count, engine.spikeThresholdForChecks)
            + blame.sorted { $0.value > $1.value }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
        for spike in spikes.sorted(by: { $0.tickMs > $1.tickMs }).prefix(10) {
            check.note(String(format: "  %.2f ms: ", spike.tickMs)
                + spike.parts.map { String(format: "%@ %.2f", $0.0, $0.1) }.joined(separator: ", "))
        }

        // EVIDENCE: the time series and the per-action costs, for plotting and diffing.
        var csv = "minute,footprint_mb,gpu_mb,threads,fds,frames,dropped,mean_ms,p99_ms,worst_ms,ticks_over_16ms\n"
        for s in samples {
            csv += String(format: "%.2f,%.1f,%.1f,%d,%d,%d,%d,%.2f,%.2f,%.2f,%d\n",
                          s.minute, s.footprintMB, s.gpuMB, s.threads, s.fileDescriptors,
                          s.frames, s.dropped, s.meanMs, s.p99Ms, s.worstMs, s.over16)
        }
        var actionsCSV = "action,count,mean_ms,worst_ms\n"
        for (name, costs) in actionCosts.sorted(by: { $0.key < $1.key }) {
            let mean = costs.reduce(0, +) / Double(costs.count)
            actionsCSV += String(format: "%@,%d,%.2f,%.2f\n", name, costs.count, mean, costs.max() ?? 0)
            check.note(String(format: "action %@: %d×, mean %.2f ms, worst %.2f ms", name, costs.count, mean, costs.max() ?? 0))
        }
        do {
            try csv.write(to: check.artifactURL("samples.csv"), atomically: true, encoding: .utf8)
            try actionsCSV.write(to: check.artifactURL("actions.csv"), atomically: true, encoding: .utf8)
        } catch {
            Log.error(.selfqa, "could not write soak artifacts: \(error)")
        }

        let windows = samples.dropFirst()
        guard windows.count >= 2, let first = samples.first, let last = samples.last else {
            return check.finish(blockedReason: "soak too short to judge (\(windows.count) windows)")
        }
        // Growth is judged from the end of minute 2, not from launch: the first
        // minutes legitimately fill texture pools, decoder caches and the thumbnail cache.
        let settled = samples.first(where: { $0.minute >= 2 }) ?? first
        let span = max(last.minute - settled.minute, 0.5)
        let footprintSlope = (last.footprintMB - settled.footprintMB) / span
        let gpuSlope = (last.gpuMB - settled.gpuMB) / span
        let totalFrames = windows.reduce(0) { $0 + $1.frames }
        let totalDropped = windows.reduce(0) { $0 + $1.dropped }
        let worst = windows.map(\.worstMs).max() ?? 0
        let over16 = windows.reduce(0) { $0 + $1.over16 }
        let rate = Double(totalFrames) / (last.minute * 60)
        let firstMean = windows.first?.meanMs ?? 0
        let lastMean = windows.last?.meanMs ?? 0

        check.note(String(format: "%.1f min, %d actions, %d frames = %.2f/s, %d dropped, %d ticks over 16 ms, worst %.2f ms",
                          last.minute, actionIndex, totalFrames, rate, totalDropped, over16, worst))
        check.note(String(format: "footprint %.0f → %.0f MB (settled %.0f, %+.2f MB/min); gpu %.0f → %.0f MB (%+.2f MB/min)",
                          first.footprintMB, last.footprintMB, settled.footprintMB, footprintSlope,
                          first.gpuMB, last.gpuMB, gpuSlope))
        check.note("threads \(first.threads) → \(last.threads) (max \(samples.map(\.threads).max() ?? 0)); "
            + "file descriptors \(first.fileDescriptors) → \(last.fileDescriptors) (max \(samples.map(\.fileDescriptors).max() ?? 0))")
        check.note(String(format: "tick mean first window %.2f ms, last window %.2f ms", firstMean, lastMean))

        let contentRate = StandardDefinition.frameRate
        let budget = 1000.0 / contentRate
        check.record(AssertionResult(
            name: "the soak holds the 29.97 content rate",
            passed: abs(rate - contentRate) <= contentRate * 0.02,
            detail: String(format: "%.2f frames/s", rate)))
        check.record(AssertionResult(
            name: "no tick over one SD frame in the whole soak",
            passed: worst < budget,
            detail: String(format: "worst %.2f ms, %d ticks over 16 ms", worst, over16)))
        check.record(AssertionResult(
            name: "under 0.1% of refreshes dropped across the soak",
            passed: Double(totalDropped) <= Double(totalFrames) * 0.001,
            detail: "\(totalDropped) of \(totalFrames)"))
        check.record(AssertionResult(
            name: "memory footprint is flat once settled (under 2 MB/min)",
            passed: footprintSlope < 2,
            detail: String(format: "%+.2f MB/min from minute %.1f", footprintSlope, settled.minute)))
        check.record(AssertionResult(
            name: "GPU allocation is flat once settled (under 1 MB/min)",
            passed: gpuSlope < 1,
            detail: String(format: "%+.2f MB/min", gpuSlope)))
        check.record(AssertionResult(
            name: "clip swaps leave no threads behind",
            passed: last.threads <= settled.threads + 4,
            detail: "\(settled.threads) settled → \(last.threads)"))
        check.record(AssertionResult(
            name: "clip swaps leave no file handles open",
            passed: last.fileDescriptors <= settled.fileDescriptors + 4,
            detail: "\(settled.fileDescriptors) settled → \(last.fileDescriptors)"))
        check.record(AssertionResult(
            name: "the tick does not get slower over the show",
            passed: lastMean <= firstMean * 1.25 + 0.5,
            detail: String(format: "%.2f → %.2f ms", firstMean, lastMean)))
        // The window must not accumulate views: a panel that rebuilds on a clip change
        // has to take its old views away, or every load leaves controls behind.
        let viewsAtEnd = window.contentView.map(viewCount) ?? 0
        check.record(AssertionResult(
            name: "the window's view count does not grow over the show",
            passed: viewsAtEnd <= viewsAtStart + 20,
            detail: "\(viewsAtStart) views at the start, \(viewsAtEnd) at the end"))
        let worstAction = actionCosts.mapValues { $0.max() ?? 0 }.max { $0.value < $1.value }
        check.record(AssertionResult(
            name: "no performer action blocks the main thread for longer than a frame",
            passed: (worstAction?.value ?? 0) < budget,
            detail: String(format: "worst: %@ %.2f ms", worstAction?.key ?? "none", worstAction?.value ?? 0)))

        // Hold the process for an external `leaks` pass when asked (see docs/AUDIT).
        if let hold = Double(ProcessInfo.processInfo.environment["VIDEOBOY_SOAK_HOLD_SECONDS"] ?? "") {
            Log.info(.selfqa, "soak holding \(Int(hold)) s for leaks, pid \(getpid())")
            RunLoop.main.run(until: Date().addingTimeInterval(hold))
        }
        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }

    private static func snapshot(at minute: Double, engine: Engine, ticks: [Double], dropped: Int) -> Sample {
        let sorted = ticks.sorted()
        return Sample(
            minute: minute,
            footprintMB: Double(physicalFootprint()) / 1_048_576,
            gpuMB: Double(MetalContext.shared?.device.currentAllocatedSize ?? 0) / 1_048_576,
            threads: threadCount(),
            fileDescriptors: (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1,
            frames: ticks.count,
            dropped: dropped,
            meanMs: ticks.isEmpty ? 0 : ticks.reduce(0, +) / Double(ticks.count),
            p99Ms: sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.99)],
            worstMs: sorted.last ?? 0,
            over16: ticks.filter { $0 > 16.7 }.count)
    }

    /// The number Activity Monitor calls "Memory": what the process costs the system.
    private static func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    private static func threadCount() -> Int {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return -1 }
        for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[index]) }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads),
                      vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        return Int(count)
    }
}

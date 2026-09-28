//
//  BeatSelfQA.swift — `Videoboy --selfqa beat`: the audio clock, end to end.
//
//  Purpose : The tracker's logic is unit-tested in Core against synthesized drums.
//            What those tests cannot see is the part a performer touches: the CLOCK
//            menu (which used to trap you in Audio), the toolbar staying put while
//            the sync readout changes, and whether a real system-audio tap actually
//            hears the Mac and locks. This checks all three in the running app —
//            the lock through the app's own AudioInput, so it measures whichever
//            tracker a performer gets (BeatNet unless VIDEOBOY_LEGACY_BEAT=1).
//  Inputs  : none. Plays its own 124 BPM drum loop through `afplay`, quietly.
//  Outputs : selfqa/out/phase-4/beat-detection/ — result.txt, toolbar PNGs, and the
//            tracker's report timeline.
//  Connects: ClockSourceMenu, TransportToolbarView, AudioInput (SystemAudioTap,
//            BeatNetTracker or BeatTracker).
//  Extend  : add a section as a function that records into `check`. Environmental
//            gaps (no permission, an OS too old for taps) end the check as BLOCKED,
//            never as a failure — and a section that cannot run skips, it does not
//            return early and hide the sections after it.
//

import AppKit
import AVFoundation
import Foundation
import VideoboyCore

enum BeatSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "phase-4/beat-detection")
        checkClockMenu(check)
        checkToolbarStaysPut(check)
        let blocked = checkSystemTap(check)
        return check.finish(blockedReason: blocked)
    }

    // MARK: - The CLOCK menu

    /// The menu must offer the way back to Internal from every state, and must not
    /// offer the unbuilt MIDI clock or Link that caused the trap.
    private static func checkClockMenu(_ check: SelfQACheck) {
        let states: [ClockSource] = [
            .internalTransport, .audio(.systemAudio), .audio(.inputDevice),
            .audio(.application(bundleID: "com.apple.Music", name: "Music"))
        ]
        for state in states {
            var chosen: ClockSource?
            let menu = ClockSourceMenu.makeMenu(current: state) { chosen = $0 }
            let titles = menu.items.map(\.title)
            let internalItem = menu.items.first { $0.title == "Internal Clock" }
            check.record(AssertionResult(
                name: "from \(state.displayName): Internal is offered and enabled",
                passed: internalItem?.isEnabled == true,
                detail: titles.filter { !$0.isEmpty }.joined(separator: " | ")))
            check.record(AssertionResult(
                name: "from \(state.displayName): no MIDI clock or Link choice",
                passed: !titles.contains { $0.localizedCaseInsensitiveContains("midi") || $0.contains("Link") },
                detail: "\(titles.count) items"))
            // Fire the Internal item the way a click would, and see where it goes.
            if let internalItem, let target = internalItem.target as? ClosureMenuTarget {
                target.fire()
            }
            check.record(AssertionResult(
                name: "from \(state.displayName): choosing Internal returns to Internal",
                passed: chosen == .internalTransport,
                detail: "handler received \(chosen.map { "\($0)" } ?? "nothing")"))
            let checked = menu.items.filter { $0.state == .on }.map(\.title)
            check.note("from \(state.displayName): checked = \(checked)")
        }
    }

    // MARK: - Nothing moves

    /// The cluster is centred; if the CLOCK value or the sync readout changed width,
    /// the tempo readout and the record/play keys would slide sideways every time
    /// detection changed state. They must not.
    private static func checkToolbarStaysPut(_ check: SelfQACheck) {
        let toolbar = TransportToolbarView(frame: NSRect(x: 0, y: 0, width: 1600, height: Theme.Metrics.toolbarHeight))
        let window = NSWindow(
            contentRect: toolbar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = toolbar
        toolbar.layoutSubtreeIfNeeded()

        func keyFrames() -> [NSRect] {
            [toolbar.display.frame, toolbar.recordButton.convert(toolbar.recordButton.bounds, to: toolbar)]
        }
        let reference = keyFrames()

        let clocks = ["Internal", "System", "Input", "Music", "Google Ch…", "Spotify"]
        let statuses: [SyncStatus] = SyncStatus.allTexts.map { SyncStatus(text: $0, tone: .dim) }
            + [SyncStatus(text: "locked 87%", tone: .locked), SyncStatus(text: "no signal", tone: .warning)]
        var moved: [String] = []
        for clock in clocks {
            for status in statuses {
                toolbar.setClockSource(clock)
                toolbar.setSyncStatus(status)
                toolbar.layoutSubtreeIfNeeded()
                if keyFrames() != reference { moved.append("\(clock)/\(status.text)") }
            }
        }
        check.record(AssertionResult(
            name: "clock and sync text changes move no control",
            passed: moved.isEmpty,
            detail: moved.isEmpty
                ? "\(clocks.count * statuses.count) combinations, cluster frame \(reference[0])"
                : "moved at: \(moved.prefix(6).joined(separator: ", "))"))

        // Evidence: the cluster as a performer would see it, locked and not.
        toolbar.setClockSource("Music")
        toolbar.setTempo(124.0)
        toolbar.setSyncStatus(SyncStatus(text: "locked 87%", tone: .locked))
        writePNG(of: toolbar.display, to: check.artifactURL("toolbar-locked.png"))
        toolbar.setClockSource("System")
        toolbar.setSyncStatus(SyncStatus(text: "no signal", tone: .warning))
        writePNG(of: toolbar.display, to: check.artifactURL("toolbar-no-signal.png"))
    }

    private static func writePNG(of view: NSView, to url: URL) {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        do {
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            Log.error(.selfqa, "could not write \(url.lastPathComponent): \(error)")
        }
    }

    // MARK: - A real system-audio tap

    /// Plays a known drum loop through `afplay`, listens with the same tap the CLOCK
    /// menu's System Audio uses, and requires a lock at the right tempo.
    ///
    /// - Returns: a blocked reason when the environment cannot run this, else nil.
    private static func checkSystemTap(_ check: SelfQACheck) -> String? {
        guard #available(macOS 14.2, *) else {
            return "system audio taps need macOS 14.2 or later"
        }
        let tempo = 124.0
        // The loop goes to a temporary file, not the evidence folder: the harness
        // only clears png/json/txt, and a stray WAV there would end up committed.
        let loopURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-beat-selfqa-124.wav")
        guard writeDrumLoop(beatsPerMinute: tempo, seconds: 20, to: loopURL) else {
            check.record(AssertionResult(
                name: "test loop written", passed: false, detail: loopURL.path))
            return nil
        }

        // The app's own input, exactly as the CLOCK menu's System Audio starts it.
        // Reports arrive on its analysis queue; the main thread reads the collected
        // results only after it has stopped.
        let collector = TapCollector()
        let input = AudioInput(source: .systemAudio)
        input.onFrame = { frame in collector.heard(frame) }
        input.onBeatReport = { report, _ in collector.add(report) }
        guard input.start() else {
            check.record(AssertionResult(name: "system audio tap starts", passed: false,
                                         detail: input.failureReason ?? "unknown reason"))
            return nil
        }
        check.record(AssertionResult(name: "system audio tap starts", passed: true, detail: "tap running"))

        // Quiet: this is a check, not a performance.
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.25", loopURL.path]
        do {
            try player.run()
        } catch {
            input.stop()
            return "could not run afplay to play the test loop: \(error)"
        }
        let started = Date()
        while player.isRunning, Date().timeIntervalSince(started) < 22 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if player.isRunning { player.terminate() }
        input.stop()
        // Let the analysis queue finish what it has, so the results are complete.
        Thread.sleep(forTimeInterval: 0.3)
        try? FileManager.default.removeItem(at: loopURL)

        let result = collector.snapshot()
        try? result.timeline.joined(separator: "\n").write(
            to: check.artifactURL("tracker-timeline.txt"), atomically: true, encoding: .utf8)
        check.note(String(format: "tap heard peak RMS %.4f over %.1f s of audio", result.peakRMS, result.secondsHeard))

        guard result.peakRMS > 0.001 else {
            return "the tap heard only silence. Allow Videoboy under System Settings ▸ Privacy & Security ▸ "
                + "Screen & System Audio Recording (System Audio Recording Only), and check the output is not muted"
        }
        let expected = ProcessInfo.processInfo.environment["VIDEOBOY_LEGACY_BEAT"] == "1" ? "onset" : "BeatNet"
        check.record(AssertionResult(
            name: "the live input uses the \(expected) tracker",
            passed: input.trackerInUse == expected,
            detail: "AudioInput used \(input.trackerInUse)"))
        check.record(AssertionResult(
            name: "tracker locks on the system audio",
            passed: result.lockedTempo != nil,
            detail: result.firstLockSeconds.map { String(format: "locked after %.1f s", $0) } ?? "never locked"))
        if let locked = result.lockedTempo {
            check.record(AssertionResult(
                name: "locked tempo matches the loop",
                passed: abs(locked - tempo) < 1.0,
                detail: String(format: "%.2f BPM for a %.0f BPM loop", locked, tempo)))
        }
        return nil
    }

    /// Gathers AudioInput's output on its analysis queue.
    private final class TapCollector: @unchecked Sendable {
        struct Result {
            var peakRMS = 0.0
            var secondsHeard = 0.0
            var lockedTempo: Double?
            var firstLockSeconds: Double?
            var timeline: [String] = []
        }
        private let lock = NSLock()
        private var result = Result()
        /// When the first audio arrived; times are measured from it by the clock, so
        /// they do not depend on the tap's sample rate.
        private var firstHeard: Date?

        func heard(_ frame: AudioFrame) {
            lock.lock(); defer { lock.unlock() }
            result.peakRMS = max(result.peakRMS, frame.rms)
            let now = Date()
            if firstHeard == nil { firstHeard = now }
            result.secondsHeard = now.timeIntervalSince(firstHeard ?? now)
        }

        func add(_ report: BeatTrackerReport) {
            lock.lock(); defer { lock.unlock() }
            let tempo = report.beatsPerMinute.map { String(format: "%6.2f", $0) } ?? "     -"
            let state = report.state.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
            let event = report.event.map { "  \($0)" } ?? ""
            result.timeline.append(String(format: "%6.2fs  ", result.secondsHeard) + state
                + "  " + tempo + String(format: "  conf %.2f", report.confidence) + event)
            if report.state == .locked {
                result.lockedTempo = report.beatsPerMinute
                if result.firstLockSeconds == nil { result.firstLockSeconds = result.secondsHeard }
            }
        }

        func snapshot() -> Result {
            lock.lock(); defer { lock.unlock() }
            return result
        }
    }

    /// Writes a kick/snare/hat loop at a known tempo as a 48 kHz mono WAV.
    private static func writeDrumLoop(beatsPerMinute: Double, seconds: Double, to url: URL) -> Bool {
        let sampleRate = 48_000.0
        let count = Int(seconds * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count { channel[index] = 0 }

        var noiseState: UInt32 = 0x1234_5678
        func noise() -> Float {
            noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: noiseState)) / Float(Int32.max)
        }
        let beat = 60.0 / beatsPerMinute
        var beatIndex = 0
        while Double(beatIndex) * beat < seconds {
            let start = Int(Double(beatIndex) * beat * sampleRate)
            let isKick = beatIndex % 2 == 0
            for offset in 0..<Int(0.3 * sampleRate) where start + offset < count {
                let t = Double(offset) / sampleRate
                let sample: Float = isKick
                    ? Float(0.9 * sin(2 * .pi * (50 + 90 * exp(-t / 0.03)) * t) * exp(-t / 0.12))
                    : noise() * Float(0.5 * exp(-t / 0.07))
                channel[start + offset] += sample
            }
            // Hats on the off-beat eighth.
            let hat = start + Int(beat * 0.5 * sampleRate)
            var previous: Float = 0
            for offset in 0..<Int(0.05 * sampleRate) where hat + offset < count {
                let value = noise()
                channel[hat + offset] += (value - previous) * Float(0.15 * exp(-Double(offset) / sampleRate / 0.015))
                previous = value
            }
            beatIndex += 1
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return true
        } catch {
            Log.error(.selfqa, "could not write the test loop: \(error)")
            return false
        }
    }
}

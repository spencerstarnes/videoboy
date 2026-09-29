//
//  ABRollSelfQA.swift — A/B ROLL and ADV, through the real keys (docs/specs/ab-roll-adv.md).
//
//  Purpose : Proves the four ROLL/ADV combinations by pressing CUT and FADE the way a
//            performer does, that a fade and a beat-delayed cut settle only when they
//            land, that Up Next wins over the library and the fallback is announced
//            once, that MIDI toggles the keys, that the keys moved nothing, and that
//            ADV cuts under live render drop no frames.
//  Inputs  : samples/ fixtures; scratch preferences; the library as seeded (samples/).
//  Outputs : selfqa/out/perf/ab-roll/result.txt.
//  Connects: ShellController (take hooks), FaderPanelBody (keys), Engine.
//

import AppKit
import VideoboyCore

enum ABRollSelfQA {

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/ab-roll")
        guard FeatureFlag.abRoll.isOn else { return check.finish(blockedReason: "FeatureFlag.abRoll is off") }
        let names = ["bars.dv", "motion.dv", "motion.mov", "motion.m2v"]
        let clips = names.map { RepoPaths.samples.appendingPathComponent($0) }
        guard clips.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            return check.finish(blockedReason: "samples/ is missing fixtures")
        }

        // 1. Layout (owner, 2026-09-27): ROLL and ADV sit in the performance row after
        // FADE, as tall as CUT; BEAT is gone; the rate control is narrower; nothing
        // overlaps — at a narrow and a wide panel.
        for width in [440.0, 640.0] {
            let body = FaderPanelBody(leftLabel: "A", rightLabel: "B", leftColor: Theme.Color.busOne,
                                      rightColor: Theme.Color.textSecondary, includesSwap: false,
                                      includesABRoll: true)
            body.frame = NSRect(x: 0, y: 0, width: width, height: 110)
            body.layoutSubtreeIfNeeded()
            var keys: [String: NSRect] = [:]
            var rate: NSRect?
            var others: [NSRect] = []
            var beatShown = false
            func walk(_ view: NSView) {
                if let key = view as? VBOptionButton, !key.isHiddenOrHasHiddenAncestor {
                    let frame = key.convert(key.bounds, to: body)
                    switch key.mappingCode {
                    case .cutTrigger?: keys["CUT"] = frame
                    case .fadeTrigger?: keys["FADE"] = frame
                    case .rollToggleTrigger?: keys["ROLL"] = frame
                    case .advanceToggleTrigger?: keys["ADV"] = frame
                    default: if key.mappingCode == nil, key.superview != nil { beatShown = beatShown || key.accessibilityTitle() == "BEAT" }
                    }
                }
                if let bus = view as? VBBusButton { others.append(bus.convert(bus.bounds, to: body)) }
                if let slide = view as? VBSlideToggle { rate = slide.convert(slide.bounds, to: body) }
                if view is VBBlendButton || view is VBTransitionButton { others.append(view.convert(view.bounds, to: body)) }
                view.subviews.forEach(walk)
            }
            walk(body)
            let order = ["CUT", "FADE", "ROLL", "ADV"].compactMap { keys[$0]?.minX }
            let inOrder = order.count == 4 && order == order.sorted() && (rate.map { $0.minX > order[3] } ?? false)
            let sameHeight = keys["ROLL"]?.height == keys["CUT"]?.height && keys["ADV"]?.height == keys["CUT"]?.height
            let all = Array(keys.values) + others + [rate].compactMap { $0 }
            var overlaps = 0
            for i in all.indices { for j in all.indices where j > i && all[i].intersects(all[j].insetBy(dx: 0.5, dy: 0.5)) { overlaps += 1 } }
            check.record(AssertionResult(
                name: "\(Int(width)) pt panel: A B CUT FADE ROLL ADV then the rate control, same height, nothing overlapping, no BEAT",
                passed: inOrder && sameHeight && overlaps == 0 && !beatShown && (rate?.width ?? 99) <= 60,
                detail: "order \(order.map { Int($0) }), rate x \(Int(rate?.minX ?? -1)) w \(Int(rate?.width ?? -1)), "
                    + "same height \(sameHeight), overlaps \(overlaps), BEAT shown \(beatShown)"))
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-abroll-qa-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = PreferenceStore(fileURL: scratch.appendingPathComponent("prefs.json"))
        store.preferences.playOnLoad = true
        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let screen = NSScreen.main,
              let shell = controller.shellController else {
            return check.finish(blockedReason: "no window")
        }
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let engine = controller.engine
        let panels = shell.shell.grid.panels
        let slot = GraphTopology.subMixOne
        let body = panels.faderABBody

        check.record(AssertionResult(
            name: "ROLL and ADV are on the A/B and C/D faders, not on PROGRAM",
            passed: body.rollButton != nil && body.advanceButton != nil
                && panels.faderCDBody.rollButton != nil && panels.faderOneTwoBody.rollButton == nil,
            detail: "A/B \(body.rollButton != nil), C/D \(panels.faderCDBody.rollButton != nil), "
                + "program \(panels.faderOneTwoBody.rollButton != nil)"))

        spin(0.5)
        let visibleAB = body.rollButton.map { !$0.isHiddenOrHasHiddenAncestor } ?? false
        let visibleCD = panels.faderCDBody.rollButton.map { !$0.isHiddenOrHasHiddenAncestor } ?? false
        check.record(AssertionResult(
            name: "at a normal window size the ROLL and ADV keys are shown, not squeezed out",
            passed: visibleAB && visibleCD,
            detail: "window \(Int(window.frame.width))×\(Int(window.frame.height)); A/B shown \(visibleAB), C/D shown \(visibleCD)"))
        // A real window capture (the offscreen renderer cannot draw layer-backed keys):
        // the whole window, for a person to look at the fader rows.
        let shot = RepoPaths.selfQAOutput.appendingPathComponent("perf/ab-roll/window.png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", shot.path]
        if (try? capture.run()) != nil {
            while capture.isRunning { spin(0.05) }
            check.note("window photo: \(shot.path)")
        }

        func source(_ channel: String) -> ClipSourceNode? { engine.sources[channel] }
        func name(_ channel: String) -> String { source(channel)?.mediaURL?.lastPathComponent ?? "none" }
        func playing(_ channel: String) -> Bool { source(channel)?.isPlaying ?? false }
        /// Loads A and B fresh, both paused, fader on A, ROLL/ADV as given.
        func reset(roll: Bool, advance: Bool) {
            shell.setRoll(false, on: slot)
            shell.setAdvance(false, on: slot)
            // Queues REPEAT by default, so a step's queued clip would otherwise still
            // be there for the next one.
            shell.clearQueueForChecks("A")
            shell.clearQueueForChecks("B")
            shell.loadForChecks(clips[0], channel: "A")
            shell.loadForChecks(clips[1], channel: "B")
            // Loads open off the main thread (F9); wait for both to be in.
            let deadline = Date().addingTimeInterval(5)
            while engine.loadsInFlight > 0, Date() < deadline { spin(0.02) }
            engine.setPlaying(false, channel: "A")
            engine.setPlaying(false, channel: "B")
            // Put the bus on A with a real key press, then settle.
            body.triggerLeftKey()
            spin(0.2)
            shell.setRoll(roll, on: slot)
            shell.setAdvance(advance, on: slot)
            spin(0.2)
        }
        func cut() { body.onCutRequested?(); spin(0.4) }

        // 2. off / off: today's behaviour.
        reset(roll: false, advance: false)
        cut()
        check.record(AssertionResult(
            name: "ROLL off, ADV off: a cut changes nothing but the picture",
            passed: name("A") == "bars.dv" && name("B") == "motion.dv" && !playing("A") && !playing("B"),
            detail: "A \(name("A")) playing \(playing("A")); B \(name("B")) playing \(playing("B"))"))

        // 3. ROLL only: B rolls on take; A pauses and re-cues to its head.
        reset(roll: true, advance: false)
        engine.setPlaying(true, channel: "A")
        spin(0.6)
        let aWasAt = source("A")?.playheadFrame ?? 0
        cut()
        check.record(AssertionResult(
            name: "ROLL on: the incoming source rolls; the outgoing one pauses on its head, same clip",
            passed: playing("B") && !playing("A") && (source("A")?.playheadFrame ?? 1) == 0 && aWasAt > 0
                && name("A") == "bars.dv",
            detail: "B playing \(playing("B")); A paused \(!playing("A")) at frame \(source("A")?.playheadFrame ?? -1) "
                + "(was \(aWasAt)); A \(name("A"))"))

        // 4. ADV only: Up Next first; AUTO (play on load) decides that it runs off air.
        reset(roll: false, advance: true)
        shell.queueForChecks(clips[2], channel: "A")
        cut()
        check.record(AssertionResult(
            name: "ADV on: the outgoing source loads its Up Next clip, and with AUTO on it plays off air",
            passed: name("A") == "motion.mov" && playing("A"),
            detail: "A \(name("A")) playing \(playing("A"))"))

        // 4b. Queue REPEAT (default on): the taken clip goes to the bottom, not away.
        // Off (pressed on the queue view's own key): it leaves the queue.
        let queueA = shell.queueStateForChecks("A")
        check.record(AssertionResult(
            name: "Up Next REPEAT is on by default: the clip ADV took is still queued, at the bottom",
            passed: queueA.repeats && queueA.items.map(\.displayName) == ["motion.mov"],
            detail: "repeats \(queueA.repeats); queue \(queueA.items.map(\.displayName))"))
        let repeatView = shell.shell.grid.panels.libraryOneBody.playlistViewForChecks("A")
        reset(roll: false, advance: true)
        repeatView?.toggleRepeatForChecks()
        shell.queueForChecks(clips[2], channel: "A")
        cut()
        let queueOff = shell.queueStateForChecks("A")
        check.record(AssertionResult(
            name: "Up Next REPEAT off (from the queue's key): the clip ADV took leaves the queue",
            passed: repeatView != nil && !queueOff.repeats && queueOff.isEmpty && name("A") == "motion.mov",
            detail: "view \(repeatView != nil); repeats \(queueOff.repeats); queue \(queueOff.items.map(\.displayName)); "
                + "A \(name("A"))"))
        repeatView?.toggleRepeatForChecks()
        check.record(AssertionResult(
            name: "Up Next REPEAT key and the queue agree after switching it back on",
            passed: shell.queueStateForChecks("A").repeats && repeatView?.repeatsForChecks == true,
            detail: "queue \(shell.queueStateForChecks("A").repeats); key \(repeatView?.repeatsForChecks ?? false)"))

        // 5. Both: queue empty → library fallback, paused at its head; announced once.
        reset(roll: true, advance: true)
        cut()                                   // to B: A leaves air
        let firstFallback = name("A")
        let noticeAfterFirst = shell.shell.statusBar.noticeTextForChecks ?? ""
        cut()                                   // back to A: A rolls, B leaves air
        let aRolled = playing("A")
        let bCued = name("B")
        let bPaused = !playing("B") && (source("B")?.playheadFrame ?? 1) == 0
        check.record(AssertionResult(
            name: "ROLL + ADV: the next clip waits paused at its head and rolls on take",
            passed: firstFallback != "bars.dv" && firstFallback != "none" && aRolled && bPaused
                && bCued != "motion.dv" && bCued != firstFallback,
            detail: "A cued \(firstFallback) then rolled \(aRolled); B cued \(bCued), paused at head \(bPaused)"))
        check.record(AssertionResult(
            name: "an empty Up Next falls back to the library and says so once, as information",
            passed: noticeAfterFirst.contains("Up Next A was empty") && !noticeAfterFirst.hasPrefix("⚠"),
            detail: noticeAfterFirst.isEmpty ? "no notice" : noticeAfterFirst))

        // 6. FADE: the incoming source rolls at the START; the outgoing one settles at the END.
        reset(roll: true, advance: true)
        body.onFade?(body.currentRate)
        spin(0.1)
        let midFadeIncoming = playing("B")
        let midFadeOutgoing = name("A")
        spin(4)
        check.record(AssertionResult(
            name: "FADE: the incoming source rolls as the fade starts; the outgoing one changes only after it",
            passed: midFadeIncoming && midFadeOutgoing == "bars.dv" && name("A") != "bars.dv",
            detail: "mid-fade B playing \(midFadeIncoming), A still \(midFadeOutgoing); after: A \(name("A"))"))

        // 7. BEAT: a beat-delayed cut takes when it lands, not when pressed.
        reset(roll: true, advance: true)
        engine.transport.beatsPerMinute = 30          // two seconds a beat: time to look
        engine.setTransportRunning(true)
        body.setBeatForChecks(true)
        spin(0.3)
        body.onCutRequested?()
        spin(0.05)
        let beforeBeat = (name("A"), playing("B"))
        spin(4.5)
        check.record(AssertionResult(
            name: "BEAT: nothing rolls or cues until the cut lands on the beat",
            passed: beforeBeat.0 == "bars.dv" && !beforeBeat.1 && playing("B") && name("A") != "bars.dv",
            detail: "just after the press: A \(beforeBeat.0), B playing \(beforeBeat.1); on the beat: "
                + "B playing \(playing("B")), A \(name("A"))"))
        body.setBeatForChecks(false)
        engine.setTransportRunning(false)
        engine.transport.beatsPerMinute = 120

        // 8. MIDI: the learned buttons toggle the keys.
        shell.setRoll(false, on: slot)
        shell.setAdvance(false, on: slot)
        engine.registry.setValue(1, slot: slot, code: .rollToggleTrigger)
        engine.registry.setValue(1, slot: slot, code: .advanceToggleTrigger)
        spin(0.3)
        let midi = shell.abRollStateForChecks(slot)
        check.record(AssertionResult(
            name: "a MIDI button toggles ROLL and ADV, and the keys light",
            passed: midi.roll && midi.advance && body.rollButton?.isOn == true && body.advanceButton?.isOn == true,
            detail: "roll \(midi.roll), adv \(midi.advance)"))

        // 9. Frame budget: ADV cuts under live render, against the same time without.
        for (letter, url) in zip(["C", "D"], [clips[2], clips[3]]) {
            shell.loadForChecks(url, channel: letter)
        }
        reset(roll: true, advance: true)
        engine.tickCostsForChecks = []
        let baseDrops = engine.droppedFrames
        spin(5)
        let dropsWithout = engine.droppedFrames - baseDrops
        engine.tickCostsForChecks = []
        let before = engine.droppedFrames
        for _ in 0..<10 { body.onCutRequested?(); spin(0.5) }
        let ticks = engine.tickCostsForChecks ?? []
        engine.tickCostsForChecks = nil
        let drops = engine.droppedFrames - before
        let worst = ticks.max() ?? 0
        check.record(AssertionResult(
            name: "10 ROLL + ADV cuts under live render: no tick over a frame, no extra dropped frames",
            passed: worst < 1000 / StandardDefinition.frameRate && drops <= max(dropsWithout, 0) && ticks.count > 100,
            detail: String(format: "worst tick %.2f ms of %d, %d dropped (%d in 5 s without cuts)",
                           worst, ticks.count, drops, dropsWithout)))

        // 10. ZERO-WAIT ADV on real HD / 4K: every take served from a clip opened in
        // advance; no dropped frame, no stall at the cut, and the incoming clip plays
        // from its first frames without holding.
        let hdNames = ["hd-h264-2997.mov", "hd-prores.mov", "uhd-hevc-hvc1.mov", "hd-h264-25.mov"]
        let hd = hdNames.map { RepoPaths.samples.appendingPathComponent($0) }
        if hd.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            reset(roll: true, advance: false)
            for letter in ["C", "D"] { engine.setPlaying(true, channel: letter) }
            for round in 0..<4 {
                shell.queueForChecks(hd[round % 4], channel: "A")
                shell.queueForChecks(hd[(round + 2) % 4], channel: "B")
            }
            shell.setAdvance(true, on: slot)
            spin(3)   // the first plan opens
            let before = shell.advanceCountsForChecks
            var awake = 0.0, worstStretch = 0.0
            var longSpans: [(start: CFTimeInterval, end: CFTimeInterval)] = []
            let sampler = ProcessInfo.processInfo.environment["VIDEOBOY_MAIN_SAMPLER"] == "1" ? MainThreadSampler() : nil
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                true, 0) { _, activity in
                let now = CACurrentMediaTime()
                if activity == .afterWaiting { awake = now } else if awake > 0 {
                    let ms = (now - awake) * 1000
                    worstStretch = max(worstStretch, ms)
                    if ms > 16 { longSpans.append((awake, now)) }
                }
            }
            engine.tickCostsForChecks = []
            let baseDrops = engine.droppedFrames
            spin(4)
            let dropsWithout = engine.droppedFrames - baseDrops
            engine.tickCostsForChecks = []
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            MainThreadCosts.byLabel = [:]
            sampler?.start()
            let dropsBefore = engine.droppedFrames
            var incomingHeld = 0
            var incomingStarted = 0
            var cuts = 0
            for interval in [1.5, 1.5, 1.5, 1.5, 1.0, 1.0, 1.0, 1.0] {
                let current = engine.registry.value(slot: slot, code: .crossfadeAB) ?? 0
                let incoming = current >= 0.5 ? "A" : "B"
                let heldBefore = engine.sources[incoming]?.heldFrames ?? 0
                body.onCutRequested?()
                cuts += 1
                spin(0.25)
                if let source = engine.sources[incoming], source.isPlaying, source.playheadFrame > 0 { incomingStarted += 1 }
                incomingHeld += (engine.sources[incoming]?.heldFrames ?? 0) - heldBefore
                spin(interval - 0.25)
            }
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            sampler?.stop()
            if let sampler {
                try? sampler.report(for: longSpans).write(
                    to: RepoPaths.selfQAOutput.appendingPathComponent("perf/ab-roll/main-sampler.txt"),
                    atomically: true, encoding: .utf8)
            }
            check.note("take costs, worst: " + (MainThreadCosts.byLabel ?? [:])
                .filter { $0.key.hasPrefix("adv.") }
                .map { String(format: "%@ %.2f ms", $0.key, $0.value.max() ?? 0) }.sorted().joined(separator: ", "))
            MainThreadCosts.byLabel = nil
            let ticks = engine.tickCostsForChecks ?? []
            engine.tickCostsForChecks = nil
            let drops = engine.droppedFrames - dropsBefore
            let after = shell.advanceCountsForChecks
            let instant = after.instant - before.instant, waited = after.waited - before.waited
            check.record(AssertionResult(
                name: "ADV on HD/4K: every take swaps in a clip that was already open (nothing opened at the cut)",
                passed: instant == cuts && waited == 0,
                detail: "\(instant) of \(cuts) takes instant, \(waited) opened at the take"))
            check.record(AssertionResult(
                name: "ADV on HD/4K: the incoming clip plays from its first frames without holding a picture",
                passed: incomingStarted == cuts && incomingHeld == 0,
                detail: "\(incomingStarted) of \(cuts) rolled at once; \(incomingHeld) held frames on the incoming side"))
            check.record(AssertionResult(
                name: "ADV on HD/4K: no dropped frame and no main-thread stall at the cuts",
                passed: drops <= dropsWithout && (ticks.max() ?? 0) < 1000 / StandardDefinition.frameRate
                    && worstStretch < 1000 / StandardDefinition.frameRate / 2,
                detail: String(format: "%d dropped (%d in 4 s without cuts), worst tick %.2f ms, longest main-thread stretch %.1f ms",
                               drops, dropsWithout, ticks.max() ?? 0, worstStretch)))
            shell.setAdvance(false, on: slot)
        } else {
            check.note("HD fixtures missing — run scripts/make-fixtures.sh; the zero-wait ADV section was skipped")
        }

        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

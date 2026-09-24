//
//  MoshSelfQA.swift — the Datamosh card, driven the way a performer drives it.
//
//  Purpose : Proves the live H.264 datamosh works through the controls a hand
//            touches, not just in Core. Opens the real main window, puts colour bars
//            on A and moving footage on B, then — with real mouse events sent
//            through the window, so hit-testing and first-click delivery are part of
//            the test — switches the A/B FX panel's Datamosh card on and pushes its
//            mosh fader. Cuts the A/B crossfader from A to B and captures the bus.
//            The classic transition mosh is B's motion smeared over A's bars.
//  Inputs  : samples/bars.dv, samples/motion.mov.
//            Then the controls added for a graceful exit: the HEAL key (clicked
//            through the window), a blocks-shaped heal caught half way, opacity and
//            blend over the clean picture, bloom's amount, heal on the beat, and the
//            eased release when the faders are let go.
//            Then the MOSH key, HELD through the window with every fader at zero,
//            and HEAL armed on the beat with Option-Command-click.
//  Outputs : selfqa/out/mosh/app/{result.txt, clean-cut.png, moshed-cut.png,
//            heal-mid-blocks.png, healed.png, opacity-half.png, blend-difference.png,
//            mosh-held.png, card.png, card-heal-armed.png}.
//  Connects: MainWindowController, the "Datamosh · H.264" card (PanelSet),
//            ShellController's routing, Engine's `fx.one.mosh` node.
//  Extend  : a new gesture (bloom, heal) is one more click and one more capture.
//

import AppKit
import ImageIO
import VideoboyCore

enum MoshSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "mosh/app")
        let store = PreferenceStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("videoboy-mosh-prefs.json"))
        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let screen = NSScreen.main,
              let shell = window.contentView as? ShellView else {
            return check.finish(blockedReason: "no window, screen or shell to run on")
        }
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let engine = controller.engine

        for (letter, name) in [("A", "bars.dv"), ("B", "motion.mov")] {
            let url = RepoPaths.samples.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path), engine.load(url: url, intoChannel: letter) else {
                return check.finish(blockedReason: "samples/\(name) is missing or would not load")
            }
            engine.setPlaying(true, channel: letter)
        }
        let crossfade: (Double) -> Void = { position in
            engine.registry.setValue(position, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        }
        crossfade(0)
        RunLoop.main.run(until: Date().addingTimeInterval(1))

        let panel = shell.grid.panels.effectsOneBody
        let cardName = PanelSet.datamoshCardName
        guard let toggle = find(NSSwitch.self, named: cardName, in: panel) else {
            return check.finish(blockedReason: "the Datamosh card's switch is not in the A/B FX panel")
        }

        // Existing cards must not have moved to make room (a performer's hands are
        // on them): the Datamosh card is appended at the END of the chain.
        let names = cardNames(in: panel)
        check.record(AssertionResult(
            name: "the Datamosh card is last in the chain, so no existing card moved",
            passed: names.last == cardName,
            detail: names.joined(separator: " → ")))

        // 1. The switch, with a real click routed through the window.
        let switchHit = click(toggle, at: 0.5, in: window, shell: shell)
        check.record(AssertionResult(
            name: "a click on the Datamosh switch lands on the switch",
            passed: switchHit, detail: switchHit ? "hitTest returns the switch" : "something covers it"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let wet = engine.registry.value(slot: Engine.moshOneSlot, code: .wetDry) ?? -1
        check.record(AssertionResult(
            name: "switching the card on reaches the bus mosh node",
            passed: toggle.state == .on && wet > 0.99,
            detail: String(format: "switch %@, fx.one.mosh wet/dry %.2f", toggle.state == .on ? "on" : "off", wet)))

        // Clean reference: the same cut with mosh at zero.
        let cleanCut = captureCut(engine: engine, crossfade: crossfade)

        // Looked up AFTER the switch: switching a card can rebuild its controls, and
        // a fader found before that would be a stale view nobody can click.
        guard let moshFader = find(VBFader.self, named: ParamCode.moshAmount.rawValue, in: panel) else {
            return check.finish(blockedReason: "the Datamosh card's mosh fader is not in the A/B FX panel")
        }
        check.note("mosh fader: enabled \(moshFader.isEnabled), in window \(moshFader.window != nil), value \(moshFader.value)")
        check.note("app active \(NSApp.isActive), window key \(window.isKeyWindow), fader accepts first mouse \(moshFader.acceptsFirstMouse(for: nil))")

        // 2. The mosh fader, clicked at 70% of its travel.
        crossfade(0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let faderHit = click(moshFader, at: 0.7, in: window, shell: shell)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check.note("after the click the fader reads \(moshFader.value)")
        let amount = engine.registry.value(slot: Engine.moshOneSlot, code: .moshAmount) ?? -1
        check.record(AssertionResult(
            name: "a click on the mosh fader lands on it and sets the bus node's amount",
            passed: faderHit && amount > 0.4,
            detail: String(format: "hit %@, fx.one.mosh 35B = %.2f", faderHit ? "yes" : "no", amount)))

        let node = engine.graph.nodes[Engine.moshOneSlot] as? DatamoshNode
        RunLoop.main.run(until: Date().addingTimeInterval(1))   // encoder warm-up, on A
        let before = node?.statistics ?? MoshStatistics()
        let moshedCut = captureCut(engine: engine, crossfade: crossfade)
        let after = node?.statistics ?? MoshStatistics()
        check.note("fx.one.mosh over the cut: \(after)")

        check.record(AssertionResult(
            name: "the bus mosh node is running and dropped the cut",
            passed: node?.isRunning == true && after.droppedCuts + after.droppedKeyframes > before.droppedCuts + before.droppedKeyframes,
            detail: "running \(node?.isRunning == true), cut frames kept from the decoder: "
                + "\(after.droppedCuts + after.droppedKeyframes - before.droppedCuts - before.droppedKeyframes)"))

        guard let clean = cleanCut, let moshed = moshedCut else {
            window.orderOut(nil)
            return check.finish(blockedReason: "could not read the bus back")
        }
        _ = try? check.writeImage(clean.output, named: "clean-cut.png")
        _ = try? check.writeImage(moshed.output, named: "moshed-cut.png")
        _ = try? check.writeImage(moshed.input, named: "input-b.png")
        let cleanDiff = meanDifference(clean.output, clean.input)
        let moshDiff = meanDifference(moshed.output, moshed.input)
        check.record(AssertionResult(
            name: "after the cut, clean shows B and moshed shows something else",
            passed: cleanDiff < 6 && moshDiff > cleanDiff * 3 && moshDiff > 8,
            detail: String(format: "mean |Δ| from B's own picture: clean %.1f, moshed %.1f", cleanDiff, moshDiff)))

        let set: (Double, ParamCode) -> Void = { value, code in
            engine.registry.setValue(value, slot: Engine.moshOneSlot, code: code)
        }

        // 3. The card: heal is a key now, and the new controls are all there.
        let triggerID = "trigger|\(ParamCode.moshHeal.rawValue)|\(cardName)"
        let healKey = find(VBOptionButton.self, named: triggerID, in: panel)
        let healFader = find(VBFader.self, named: ParamCode.moshHeal.rawValue, in: panel)
        let newCodes: [ParamCode] = [.moshMelt, .moshLoop, .moshHealEvery, .moshHealTime, .moshHealShape, .opacity, .moshBlend]
        let missing = newCodes.filter { find(VBFader.self, named: $0.rawValue, in: panel) == nil }
        check.record(AssertionResult(
            name: "heal is a key, not a fader, and the new controls are on the card",
            passed: healKey != nil && healFader == nil && missing.isEmpty,
            detail: "HEAL key \(healKey != nil), heal fader \(healFader != nil), missing faders: "
                + (missing.isEmpty ? "none" : missing.map(\.rawValue).joined(separator: ", "))))
        if let healKey, let card = cardView(containing: healKey) {
            writePNG(of: card, to: check.artifactURL("card.png"))
            check.note("card: \(Int(card.bounds.width))×\(Int(card.bounds.height)) pt")
        }
        if let healKey {
            check.note("HEAL key: mapping slot \(healKey.mappingSlot ?? "nil"), code \(healKey.mappingCode?.rawValue ?? "nil")")
            check.record(AssertionResult(
                name: "the HEAL key can be learned to MIDI (Shift-click), addressed to the bus node",
                passed: healKey.mappingSlot == Engine.moshOneSlot && healKey.mappingCode == .moshHeal,
                detail: "slot \(healKey.mappingSlot ?? "nil")"))
        }

        // 4. A heal from the key, clicked through the window: blocks, over two
        //    seconds, caught half way; then the keyframe lands and the picture is clean.
        set(1, .moshHealTime)
        set(MoshHealShape.blocks.normalisedPosition, .moshHealShape)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let healsBefore = node?.healCount ?? 0
        let keyHit = healKey.map { click($0, at: 0.5, in: window, shell: shell) } ?? false
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let midProgress = node?.healProgress ?? 0
        let mid = captureTexture(engine, Engine.moshOneSlot)
        let midInput = captureTexture(engine, GraphTopology.subMixOne)
        check.record(AssertionResult(
            name: "a click on HEAL lands on it and starts an eased heal (not a jump)",
            passed: keyHit && (node?.healCount ?? 0) == healsBefore + 1 && midProgress > 0.2 && midProgress < 0.8,
            detail: String(format: "hit %@, heals %d → %d, clean %.2f one second into a two-second heal",
                           keyHit ? "yes" : "no", healsBefore, node?.healCount ?? 0, midProgress)))
        if let mid { _ = try? check.writeImage(mid, named: "heal-mid-blocks.png") }
        RunLoop.main.run(until: Date().addingTimeInterval(1.8))
        let healed = captureTexture(engine, Engine.moshOneSlot)
        let healedInput = captureTexture(engine, GraphTopology.subMixOne)
        if let healed { _ = try? check.writeImage(healed, named: "healed.png") }
        let midDiff = (mid != nil && midInput != nil) ? meanDifference(mid!, midInput!) : 255
        let healedDiff = (healed != nil && healedInput != nil) ? meanDifference(healed!, healedInput!) : 255
        check.record(AssertionResult(
            name: "after the heal the keyframe has landed: the fade is gone and the picture is B again",
            // Not zero: while running, the output trails the input by one frame
            // (declared latency) and B is moving footage. Moshed is ~110.
            passed: node?.healProgress == 0 && healedDiff < 12 && healedDiff < moshDiff / 5,
            detail: String(format: "clean %.2f; mean |Δ| from B: moshed %.1f, half way %.1f, healed %.1f",
                           node?.healProgress ?? -1, moshDiff, midDiff, healedDiff)))
        set(DatamoshNode.defaultHealTime, .moshHealTime)
        set(0, .moshHealShape)

        // 5. Opacity and blend over the clean picture, on a fresh mosh.
        let full = captureCut(engine: engine, crossfade: crossfade)?.output
        set(0, .opacity)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let none = captureTexture(engine, Engine.moshOneSlot)
        let noneInput = captureTexture(engine, GraphTopology.subMixOne)
        set(0.5, .opacity)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let half = captureTexture(engine, Engine.moshOneSlot)
        let halfInput = captureTexture(engine, GraphTopology.subMixOne)
        set(1, .opacity)
        let differenceIndex = DatamoshNode.blendModes.firstIndex(of: .difference) ?? 0
        set(Double(differenceIndex) / Double(DatamoshNode.blendModes.count - 1), .moshBlend)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let difference = captureTexture(engine, Engine.moshOneSlot)
        set(0, .moshBlend)
        if let half { _ = try? check.writeImage(half, named: "opacity-half.png") }
        if let difference { _ = try? check.writeImage(difference, named: "blend-difference.png") }
        let noneDiff = (none != nil && noneInput != nil) ? meanDifference(none!, noneInput!) : 255
        let halfDiff = (half != nil && halfInput != nil) ? meanDifference(half!, halfInput!) : 255
        let fullDiff = (full != nil && noneInput != nil) ? meanDifference(full!, noneInput!) : 0
        let differenceFromMosh = (difference != nil && full != nil) ? meanDifference(difference!, full!) : 0
        let differenceLevel = difference.map(meanLevel) ?? -1
        check.record(AssertionResult(
            name: "opacity 0 is the clean input, 0.5 sits between, Difference is its own picture",
            passed: noneDiff < 2 && halfDiff > 2 && halfDiff < fullDiff && differenceFromMosh > 8,
            detail: String(format: "mean |Δ| from B: opacity 1 %.1f, 0.5 %.1f, 0 %.1f; "
                           + "Difference vs the plain mosh %.1f (mean level %.0f)",
                           fullDiff, halfDiff, noneDiff, differenceFromMosh, differenceLevel)))

        // 6. Bloom's amount does something all the way down: replays per second fall.
        set(0.2, .moshLoop)
        func bloomRate(_ amount: Double) -> Int {
            set(amount, .moshBloom)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let start = node?.statistics.bloomed ?? 0
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            return (node?.statistics.bloomed ?? 0) - start
        }
        let fullBloom = bloomRate(1)
        let lowBloom = bloomRate(0.3)
        set(0, .moshBloom)
        check.record(AssertionResult(
            name: "pulling bloom down slows the stream rather than doing nothing",
            passed: fullBloom > 15 && lowBloom > 0 && Double(lowBloom) < Double(fullBloom) * 0.5,
            detail: "replays per second: bloom 1.0 → \(fullBloom), bloom 0.3 → \(lowBloom)"))

        // 7. Heal on the beat: every beat, transport running at 120.
        set(MoshHealEvery.beat.normalisedPosition, .moshHealEvery)
        engine.setTransportRunning(true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let beatStart = node?.healCount ?? 0
        RunLoop.main.run(until: Date().addingTimeInterval(2.0))
        let beatHeals = (node?.healCount ?? 0) - beatStart
        engine.setTransportRunning(false)
        set(0, .moshHealEvery)
        check.record(AssertionResult(
            name: "heal every 1 beat heals on the beat (about four in two seconds at 120)",
            passed: (3...5).contains(beatHeals),
            detail: "\(beatHeals) heals in 2.0 s"))

        // 8. Letting go eases out over the heal time (0.5 s by default), then the
        //    encoder is released.
        set(0, .moshAmount)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let easing = node?.isRunning == true && (node?.healProgress ?? 0) > 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        check.record(AssertionResult(
            name: "pulling mosh to zero fades back to clean, then releases the encoder",
            passed: easing && node?.isRunning == false,
            detail: "easing after 0.15 s \(easing), running after 0.95 s \(node?.isRunning == true)"))

        // 9. The MOSH key: on HEAL's row, and HELD through the window with every
        //    fader at zero — the key alone makes the mosh, on continuous footage.
        let moshKey = find(VBOptionButton.self,
                           named: "trigger|\(ParamCode.moshHold.rawValue)|\(cardName)", in: panel)
        if let moshKey, let healKey {
            check.record(AssertionResult(
                name: "the MOSH key sits on HEAL's row, left of it: no row added, nothing below moved",
                passed: moshKey.superview === healKey.superview && moshKey.frame.maxX <= healKey.frame.minX,
                detail: "MOSH \(NSStringFromRect(moshKey.frame)), HEAL \(NSStringFromRect(healKey.frame))"))
            check.record(AssertionResult(
                name: "the MOSH key can be learned to MIDI (Shift-click), addressed to the bus node",
                passed: moshKey.mappingSlot == Engine.moshOneSlot && moshKey.mappingCode == .moshHold,
                detail: "slot \(moshKey.mappingSlot ?? "nil"), code \(moshKey.mappingCode?.rawValue ?? "nil")"))
            if let card = cardView(containing: healKey) {
                writePNG(of: card, to: check.artifactURL("card.png"))
            }

            var duringHold = (running: false, bloomed: 0, difference: 0.0)
            var heldPicture: ImageBuffer?
            let wasRunning = node?.isRunning == true
            let held = hold(moshKey, for: 1.5, sampleAfter: 1.2, in: window, shell: shell) {
                let output = captureTexture(engine, Engine.moshOneSlot)
                let input = captureTexture(engine, GraphTopology.subMixOne)
                heldPicture = output
                duringHold = (node?.isRunning == true, node?.statistics.bloomed ?? 0,
                              (output != nil && input != nil) ? meanDifference(output!, input!) : 0)
            }
            if let heldPicture { _ = try? check.writeImage(heldPicture, named: "mosh-held.png") }
            check.record(AssertionResult(
                name: "holding MOSH (every fader at zero) moshes moving footage with no cut",
                passed: held && !wasRunning && duringHold.running && duringHold.bloomed > 15
                    && duringHold.difference > 8,
                detail: String(format: "hit %@, idle before %@, 1.2 s in: running %@, %d replays, mean |Δ| from B %.1f",
                               held ? "yes" : "no", wasRunning ? "no" : "yes",
                               duringHold.running ? "yes" : "no", duringHold.bloomed, duringHold.difference)))
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            let releaseEasing = node?.isRunning == true && (node?.healProgress ?? 0) > 0
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            let holdValue = engine.registry.value(slot: Engine.moshOneSlot, code: .moshHold) ?? -1
            check.record(AssertionResult(
                name: "letting go of MOSH eases back to clean, then releases the encoder",
                passed: holdValue == 0 && releaseEasing && node?.isRunning == false,
                detail: "key value \(holdValue), easing after 0.15 s \(releaseEasing), "
                    + "running after 1.05 s \(node?.isRunning == true)"))
        } else {
            check.record(AssertionResult(
                name: "the MOSH key is on the Datamosh card", passed: false,
                detail: "MOSH \(moshKey != nil), HEAL \(healKey != nil)"))
        }

        // 10. HEAL armed on the beat: Option-Command-click, through the window.
        let healEveryFader = find(VBFader.self, named: ParamCode.moshHealEvery.rawValue, in: panel)
        if let healKey, let healEveryFader {
            let everyNow: () -> MoshHealEvery = {
                MoshHealEvery.from(normalised: engine.registry.value(
                    slot: Engine.moshOneSlot, code: .moshHealEvery) ?? 0)
            }
            let detect = controller.shellController?.detectSession
            detect?.setSweepArming(true)
            let pulsing = healKey.isSweepArming && !(moshKey?.isSweepArming ?? false)
            detect?.setSweepArming(false)
            check.record(AssertionResult(
                name: "holding ⌥⌘ pulses HEAL (it can be armed) and not MOSH",
                passed: pulsing,
                detail: "HEAL \(healKey.isSweepArming || pulsing), MOSH \(moshKey?.isSweepArming ?? false)"))

            let healsBefore = node?.healCount ?? 0
            let armHit = click(healKey, at: 0.5, in: window, shell: shell, modifiers: [.command, .option])
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let armedEvery = everyNow()
            check.record(AssertionResult(
                name: "⌥⌘-click on HEAL arms heal every at 1 beat, lights the outline, and does not heal",
                passed: armHit && armedEvery == .beat && healKey.isArmedOnBeat
                    && (node?.healCount ?? 0) == healsBefore
                    && MoshHealEvery.from(normalised: healEveryFader.value) == .beat,
                detail: "hit \(armHit ? "yes" : "no"), heal every \(armedEvery.displayName), "
                    + "outline \(healKey.isArmedOnBeat), fader \(MoshHealEvery.from(normalised: healEveryFader.value).displayName), "
                    + "heals \(healsBefore) → \(node?.healCount ?? 0)"))

            if let card = cardView(containing: healKey) {
                writePNG(of: card, to: check.artifactURL("card-heal-armed.png"))
            }

            set(0.5, .moshAmount)
            engine.setTransportRunning(true)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            let beatStart = node?.healCount ?? 0
            RunLoop.main.run(until: Date().addingTimeInterval(2.0))
            let armedHeals = (node?.healCount ?? 0) - beatStart
            engine.setTransportRunning(false)
            check.record(AssertionResult(
                name: "armed, the mosh heals on every beat (about four in two seconds at 120)",
                passed: (3...5).contains(armedHeals), detail: "\(armedHeals) heals in 2.0 s"))

            // The performer picks a slower rate on the card's own fader, disarms, and
            // arms again: it comes back at the rate they chose.
            healEveryFader.value = MoshHealEvery.bar.normalisedPosition
            healEveryFader.sendAction(healEveryFader.action, to: healEveryFader.target)
            let outlineAtBar = healKey.isArmedOnBeat
            let disarmHit = click(healKey, at: 0.5, in: window, shell: shell, modifiers: [.command, .option])
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let disarmed = everyNow()
            let outlineOff = !healKey.isArmedOnBeat
            let rearmHit = click(healKey, at: 0.5, in: window, shell: shell, modifiers: [.command, .option])
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let rearmed = everyNow()
            check.record(AssertionResult(
                name: "⌥⌘-click again disarms (heal every off, outline off); again re-arms at the rate last chosen",
                passed: outlineAtBar && disarmHit && disarmed == .off && outlineOff
                    && rearmHit && rearmed == .bar && healKey.isArmedOnBeat,
                detail: "outline at 1 bar \(outlineAtBar); disarmed → \(disarmed.displayName), outline off \(outlineOff); "
                    + "re-armed → \(rearmed.displayName), outline \(healKey.isArmedOnBeat)"))

            // A plain click still heals once, right away — arming did not take it over.
            let plainBefore = node?.healCount ?? 0
            _ = click(healKey, at: 0.5, in: window, shell: shell)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            check.record(AssertionResult(
                name: "a plain click on an armed HEAL still heals once, at once",
                passed: (node?.healCount ?? 0) == plainBefore + 1,
                detail: "heals \(plainBefore) → \(node?.healCount ?? 0)"))
            _ = click(healKey, at: 0.5, in: window, shell: shell, modifiers: [.command, .option])
            set(0, .moshAmount)
        } else {
            check.record(AssertionResult(
                name: "HEAL and its heal-every fader are on the card", passed: false,
                detail: "HEAL \(healKey != nil), heal every \(healEveryFader != nil)"))
        }

        window.orderOut(nil)
        return check.finish()
    }

    // MARK: - Helpers

    /// Cuts A→B and returns, from the SAME tick, the bus mosh node's output 1.5 s
    /// later and the mix feeding it (B's own picture).
    private static func captureCut(engine: Engine, crossfade: (Double) -> Void) -> (output: ImageBuffer, input: ImageBuffer)? {
        crossfade(0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        crossfade(1)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        guard let output = captureTexture(engine, Engine.moshOneSlot),
              let input = captureTexture(engine, GraphTopology.subMixOne) else { return nil }
        return (output, input)
    }

    private static func captureTexture(_ engine: Engine, _ slot: String) -> ImageBuffer? {
        guard let texture = engine.texture(for: slot) else { return nil }
        return OffscreenRenderer()?.readback(texture)
    }

    /// Holds a real mouse down on `view`'s centre for `seconds`, running `during` part
    /// way through. Returns whether hit-testing delivered it to `view`.
    ///
    /// The mouse-up is posted by a timer in the COMMON modes, so it fires inside the
    /// key's own tracking loop — as does the render clock (a `.common` display link),
    /// which is what keeps the picture moving while a key is held.
    private static func hold(
        _ view: NSView, for seconds: TimeInterval, sampleAfter: TimeInterval,
        in window: NSWindow, shell: ShellView, during: @escaping () -> Void
    ) -> Bool {
        view.scrollToVisible(view.bounds)
        shell.layoutSubtreeIfNeeded()
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let hit = shell.hitTest(shell.convert(point, from: nil)),
              hit === view || hit.isDescendant(of: view) else { return false }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        let sample = Timer(timeInterval: sampleAfter, repeats: false) { _ in during() }
        let release = Timer(timeInterval: seconds, repeats: false) { _ in
            NSApp.postEvent(up, atStart: false)
        }
        RunLoop.main.add(sample, forMode: .common)
        RunLoop.main.add(release, forMode: .common)
        window.sendEvent(down)   // returns when the key's tracking loop sees the up
        return true
    }

    /// Sends a real mouse down/up through the window at `fraction` across `view`.
    /// Returns whether hit-testing delivered it to `view` (or a view inside it).
    private static func click(
        _ view: NSView, at fraction: CGFloat, in window: NSWindow, shell: ShellView,
        modifiers: NSEvent.ModifierFlags = []
    ) -> Bool {
        view.scrollToVisible(view.bounds)
        shell.layoutSubtreeIfNeeded()
        let local = NSPoint(x: view.bounds.minX + view.bounds.width * fraction, y: view.bounds.midY)
        let point = view.convert(local, to: nil)
        guard let hit = shell.hitTest(shell.convert(point, from: nil)),
              hit === view || hit.isDescendant(of: view) else { return false }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        // The up is queued FIRST: controls that track the drag in their own loop
        // (VBFader, NSSwitch) pull it from the queue and finish the gesture.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        return true
    }

    private static func find<T: NSView>(_ type: T.Type, named identifier: String, in view: NSView) -> T? {
        if let match = view as? T, match.identifier?.rawValue == identifier { return match }
        for subview in view.subviews {
            if let found = find(type, named: identifier, in: subview) { return found }
        }
        return nil
    }

    /// Card names in on-screen order, top to bottom, read from their switches.
    private static func cardNames(in panel: NSView) -> [String] {
        var switches: [NSSwitch] = []
        func collect(_ view: NSView) {
            if let toggle = view as? NSSwitch, toggle.identifier != nil { switches.append(toggle) }
            view.subviews.forEach(collect)
        }
        collect(panel)
        return switches
            .map { ($0.identifier!.rawValue, $0.convert(NSPoint.zero, to: panel).y) }
            .sorted { panel.isFlipped ? $0.1 < $1.1 : $0.1 > $1.1 }
            .map(\.0)
    }

    /// The effect card a control sits on: the OUTERMOST ancestor that is an arranged
    /// view of a vertical stack (the chain's). The card's own column is a vertical
    /// stack too, so the first match is only the control's row.
    private static func cardView(containing view: NSView) -> NSView? {
        var current: NSView? = view
        var card: NSView?
        while let candidate = current {
            if let stack = candidate.superview as? NSStackView, stack.arrangedSubviews.contains(candidate),
               stack.orientation == .vertical {
                card = candidate
            }
            current = candidate.superview
        }
        return card
    }

    /// The view as it is on screen, cropped from `screencapture` of its WINDOW.
    ///
    /// The real pixels, because both offscreen routes fail on this panel:
    /// `cacheDisplay` and `CALayer.render` each came back white with no text, no
    /// card fill and no HEAL key. The window rather than a screen rectangle, so
    /// anything else covering it (the performer is often using the Mac while this
    /// runs) is not what gets captured. Needs Screen Recording for the app; without
    /// it the PNG is blank and the note says to look at it with that in mind.
    private static func writePNG(of view: NSView, to url: URL) {
        view.scrollToVisible(view.bounds)
        guard let window = view.window else { return }
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let whole = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoboy-window-\(window.windowNumber).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", whole.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.error(.selfqa, "could not capture \(url.lastPathComponent): \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: whole) }
        guard let source = CGImageSourceCreateWithURL(whole as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Log.error(.selfqa, "could not read the window capture for \(url.lastPathComponent)")
            return
        }
        // The capture is the window's frame at its backing scale; crop to the view,
        // measured from the frame's top-left (window coordinates are bottom-left).
        let scale = CGFloat(image.width) / window.frame.width
        let inWindow = view.convert(view.bounds, to: nil)
        let crop = CGRect(x: inWindow.minX * scale,
                          y: (window.frame.height - inWindow.maxY) * scale,
                          width: inWindow.width * scale, height: inWindow.height * scale)
        guard let card = image.cropping(to: crop.integral),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            Log.error(.selfqa, "could not crop \(url.lastPathComponent)")
            return
        }
        CGImageDestinationAddImage(destination, card, nil)
        CGImageDestinationFinalize(destination)
    }

    /// Mean of R, G and B over the picture: 0 black, 255 white.
    private static func meanLevel(_ image: ImageBuffer) -> Double {
        var total = 0
        for index in stride(from: 0, to: image.pixels.count, by: 4) {
            for channel in 0..<3 { total += Int(image.pixels[index + channel]) }
        }
        return Double(total) / Double(max(image.width * image.height * 3, 1))
    }

    private static func meanDifference(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        guard a.width == b.width, a.height == b.height else { return 255 }
        var total = 0
        for index in stride(from: 0, to: a.pixels.count, by: 4) {
            for channel in 0..<3 { total += abs(Int(a.pixels[index + channel]) - Int(b.pixels[index + channel])) }
        }
        return Double(total) / Double(a.width * a.height * 3)
    }
}

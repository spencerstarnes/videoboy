//
//  LockSelfQA.swift — LOCK, in a real window (setlist plan §7, phase 1 gate).
//
//  Purpose : Proves what the plan's gate asks: every A/B control refuses while
//            locked, reached by a real hit-test; Program still takes; the picture
//            keeps running; nothing in the bar moves except the pads. Also MIDI (a
//            locked side's knob does nothing, the LOCK note unlocks), loads (a drop on
//            a locked source is refused), undo (⌘Z will not reach into a locked side),
//            keys typed into a locked fader, and Shift-click learn still getting through.
//  Inputs  : a scratch preference file; samples/ for a clip to drop.
//  Outputs : selfqa/out/perf/lock/{result.txt, toolbar-*.png, window-locked.png}.
//  Connects: BankLockController (the route every click and key takes), LockStrip,
//            ShellController (loads, undo), ParamRegistry (MIDI).
//

import AppKit
import VideoboyCore

enum LockSelfQA {

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func all<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        root.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] } + root.subviews.flatMap { all(type, in: $0) }
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/lock")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-lock-qa-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = PreferenceStore(fileURL: scratch.appendingPathComponent("prefs.json"))
        store.preferences.setupCompleted = true

        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let shell = controller.shellController,
              let locks = shell.bankLock, let content = window.contentView else {
            return check.finish(blockedReason: "no window, shell or lock controller")
        }
        window.setFrame(NSRect(x: 40, y: 40, width: 1800, height: 1000), display: true)
        controller.showWindow(nil)
        spin(0.6)
        content.layoutSubtreeIfNeeded()
        let engine = controller.engine
        let panels = shell.shell.grid.panels
        let toolbar = shell.shell.toolbar

        func centre(_ view: NSView) -> NSPoint {
            view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }
        func hit(_ point: NSPoint) -> NSView? {
            content.hitTest(content.superview?.convert(point, from: nil) ?? point)
        }
        func reachable(_ view: NSView) -> Bool {
            guard !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 2, view.bounds.height > 2,
                  let found = hit(centre(view)) else { return false }
            return found === view || found.isDescendant(of: view)
        }
        func mouse(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        /// A click the way the app receives one: the LOCK monitor's question first,
        /// then (if allowed) the hit-tested view's mouseDown. True if LOCK swallowed it.
        @discardableResult
        func click(_ view: NSView) -> Bool {
            let point = centre(view)
            guard let down = mouse(.leftMouseDown, at: point) else { return false }
            if locks.refuses(down) { return true }
            // To whatever the hit-test finds, directly: a bare self-QA binary is never
            // the active app, so the window would spend the click on activating.
            if let up = mouse(.leftMouseUp, at: point) { window.postEvent(up, atStart: true) }
            hit(point)?.mouseDown(with: down)
            spin(0.15)
            return false
        }

        // 1. The bar: LOCK strips between the pads and the cluster, reachable, the pads
        //    outside them; nothing overlapping.
        let display = toolbar.display
        let frame = { (view: NSView) in view.convert(view.bounds, to: toolbar) }
        func barIsSound() -> (ok: Bool, detail: String) {
            let l = frame(toolbar.leftLock), r = frame(toolbar.rightLock), d = frame(display)
            let lp = frame(toolbar.leftPads), rp = frame(toolbar.rightPads)
            let padsOK = toolbar.leftPads.isHidden || (lp.maxX <= l.minX && rp.minX >= r.maxX)
            let ok = l.maxX <= d.minX && r.minX >= d.maxX && padsOK
                && reachable(toolbar.leftLock.lockButton) && reachable(toolbar.rightLock.lockButton)
            return (ok, "lock strips \(Int(l.width))/\(Int(r.width)) pt, pads \(toolbar.leftPads.isHidden ? "hidden" : "shown")")
        }
        let wideBar = barIsSound()
        writePNG(of: toolbar, to: check.artifactURL("toolbar-unlocked.png"))
        // How narrow the window can go before the pads give way — and LOCK stays.
        var padsHideBelow = 0
        for width in stride(from: 2000, through: 1000, by: -25) {
            window.setFrame(NSRect(x: 40, y: 40, width: CGFloat(width), height: 1000), display: true)
            content.layoutSubtreeIfNeeded()
            if toolbar.leftPads.isHidden { padsHideBelow = width + 25; break }
        }
        window.setFrame(NSRect(x: 40, y: 40, width: 1100, height: 1000), display: true)
        content.layoutSubtreeIfNeeded()
        let narrowBar = barIsSound()
        window.setFrame(NSRect(x: 40, y: 40, width: 1800, height: 1000), display: true)
        content.layoutSubtreeIfNeeded()
        spin(0.2)
        check.record(AssertionResult(
            name: "LOCK sits between each side's pads and the cluster, reachable; the pads hide first, LOCK never",
            passed: wideBar.ok && narrowBar.ok && !toolbar.leftLock.isHidden && padsHideBelow > 0,
            detail: "1800 pt: \(wideBar.detail); 1100 pt: \(narrowBar.detail); pads hide below ~\(padsHideBelow) pt"))

        // 2. Click LOCK A/B: red, padlocks on its four panels and none on C/D's — and
        //    nothing in the bar moves (the pads are under someone's fingers).
        let keyWasReachable = reachable(toolbar.leftLock.lockButton)
        func barFrames() -> [NSRect] {
            ([toolbar.leftPads, toolbar.rightPads, toolbar.leftLock, toolbar.rightLock, display,
              toolbar.hotPunchButton] as [NSView]).map(frame)
        }
        let framesUnlocked = barFrames()
        click(toolbar.leftLock.lockButton)
        content.layoutSubtreeIfNeeded()
        let framesLocked = barFrames()
        writePNG(of: content, to: check.artifactURL("window-locked.png"))
        check.record(AssertionResult(
            name: "locking moves nothing in the bar: pads, LOCK strips, cluster and Punch stay exactly put",
            passed: framesUnlocked == framesLocked,
            detail: zip(framesUnlocked, framesLocked).filter { $0 != $1 }
                .map { "\(Int($0.minX))→\(Int($1.minX))" }.joined(separator: ", ").ifEmpty("no movement")))
        let padlocks = [panels.sourceA, panels.sourceB, panels.faderAB, panels.effectsOne].map(\.showsPadlock)
        let otherPadlocks = [panels.sourceC, panels.sourceD, panels.faderCD, panels.effectsTwo].map(\.showsPadlock)
        check.record(AssertionResult(
            name: "clicking LOCK A/B locks that side: the key reads locked, its panels show a padlock, C/D's do not",
            passed: keyWasReachable && locks.lock.isLocked(.ab) && !locks.lock.isLocked(.cd)
                && toolbar.leftLock.isLocked && padlocks.allSatisfy { $0 } && !otherPadlocks.contains(true),
            detail: "locked \(locks.lock.locked.map(\.rawValue)), A/B padlocks \(padlocks), C/D padlocks \(otherPadlocks)"))
        writePNG(of: toolbar, to: check.artifactURL("toolbar-locked.png"))

        // 3. EVERY control on the A/B side refuses a real click; every one on C/D
        //    gets through. Controls found by type, reached by hit-test.
        func controls(in roots: [NSView]) -> [NSView] {
            roots.flatMap { root -> [NSView] in
                (all(NSControl.self, in: root) as [NSView]) + (all(ClipPadView.self, in: root) as [NSView])
                    + ((root as? NSControl).map { [$0] } ?? [])
            }.filter { view in
                reachable(view) && !panelsCollapse.contains { $0 === view || view.isDescendant(of: $0) }
            }
        }
        let panelsCollapse = [panels.sourceA, panels.sourceB, panels.faderAB, panels.effectsOne,
                              panels.sourceC, panels.sourceD, panels.faderCD, panels.effectsTwo].map(\.collapseControl)
        let abRoots: [NSView] = [panels.sourceA, panels.sourceB, panels.faderAB, panels.effectsOne,
                                 panels.swapAB, toolbar.leftPads]
        let cdRoots: [NSView] = [panels.sourceC, panels.sourceD, panels.faderCD, panels.effectsTwo,
                                 panels.swapCD, toolbar.rightPads]
        let abControls = controls(in: abRoots)
        let cdControls = controls(in: cdRoots)
        func asks(_ view: NSView) -> Bool {
            guard let down = mouse(.leftMouseDown, at: centre(view)) else { return false }
            return locks.refuses(down)
        }
        let blinksBefore = toolbar.leftLock.blinkCount
        let abLetThrough = abControls.filter { !asks($0) }.map { String(describing: type(of: $0)) }
        let blinks = toolbar.leftLock.blinkCount - blinksBefore
        let cdRefused = cdControls.filter { asks($0) }.map { String(describing: type(of: $0)) }
        check.record(AssertionResult(
            name: "every reachable A/B control refuses a click and blinks LOCK A/B; every C/D control still works",
            passed: abControls.count >= 20 && abLetThrough.isEmpty && blinks == abControls.count
                && cdControls.count >= 20 && cdRefused.isEmpty,
            detail: "\(abControls.count) A/B controls, let through: \(abLetThrough); blinks \(blinks); "
                + "\(cdControls.count) C/D controls, refused: \(cdRefused)"))

        // 4. The values really do not move: a card fader and the A/B CUT key, clicked.
        let abFader = all(VBFader.self, in: panels.effectsOneBody).first { reachable($0) }
        let faderSlot = abFader?.mappingSlot, faderCode = abFader?.mappingCode
        let faderBefore = faderSlot.flatMap { s in faderCode.flatMap { engine.registry.value(slot: s, code: $0) } }
        let abKey = all(VBBusButton.self, in: panels.faderABBody).first { reachable($0) }
        let mixBefore = engine.registry.value(slot: GraphTopology.subMixOne, code: .crossfadeAB)
        let faderRefused = abFader.map(click) ?? false
        let keyRefused = abKey.map(click) ?? false
        spin(0.3)
        let faderAfter = faderSlot.flatMap { s in faderCode.flatMap { engine.registry.value(slot: s, code: $0) } }
        let mixAfter = engine.registry.value(slot: GraphTopology.subMixOne, code: .crossfadeAB)
        check.record(AssertionResult(
            name: "a click on an A/B card fader and on an A/B bus key changes nothing",
            passed: abFader != nil && abKey != nil && faderRefused && keyRefused
                && faderBefore == faderAfter && mixBefore == mixAfter,
            detail: "fader \(faderSlot ?? "?")/\(faderCode?.rawValue ?? "?") \(faderBefore ?? -1) → \(faderAfter ?? -1), "
                + "A/B mix \(mixBefore ?? -1) → \(mixAfter ?? -1)"))

        // 5. Program still takes, and the picture keeps running.
        let programKeys = all(VBBusButton.self, in: panels.faderOneTwoBody).filter { reachable($0) }
        let programBefore = engine.registry.value(slot: GraphTopology.primary, code: .crossfadeOneTwo) ?? -1
        let framesBefore = engine.frameIndex
        var programRefused = false
        var programSeen: [String] = []
        for key in programKeys {
            programRefused = programRefused || click(key)
            spin(0.4)
            programSeen.append("\(key.mappingCode?.rawValue ?? "-")→\(engine.registry.value(slot: GraphTopology.primary, code: .crossfadeOneTwo) ?? -1)/\(panels.faderOneTwoBody.faderValueForChecks)")
        }
        let programAfter = engine.registry.value(slot: GraphTopology.primary, code: .crossfadeOneTwo) ?? -1
        spin(0.5)
        let frames = engine.frameIndex - framesBefore
        check.record(AssertionResult(
            name: "with A/B locked, Program's bus keys still cut, and the picture keeps rendering",
            passed: !programKeys.isEmpty && !programRefused && programAfter != programBefore && frames > 10,
            detail: "\(programKeys.count) Program keys \(programSeen), Program \(programBefore) → \(programAfter), "
                + "\(frames) frames rendered in ~1.3 s"))

        // 6. MIDI: a knob on an A/B card and on A/B's CUT does nothing; on C/D it works.
        let abCard = engine.chains[.one]?.displayOrder.first.map { EffectChain.targetedSlot(of: $0, bus: .one) }
        let cdCard = engine.chains[.two]?.displayOrder.first.map { EffectChain.targetedSlot(of: $0, bus: .two) }
        let knobAB = ControlSource.midiControlChange(channel: 0, controller: 101)
        let knobCD = ControlSource.midiControlChange(channel: 0, controller: 102)
        if let abCard, let cdCard {
            engine.registry.bind(ControlBinding(source: knobAB, slot: abCard, code: .wetDry))
            engine.registry.bind(ControlBinding(source: knobCD, slot: cdCard, code: .wetDry))
            let abWet = engine.registry.value(slot: abCard, code: .wetDry)
            engine.midi.handle(event: ControlEvent(source: knobAB, value: 0.77))
            engine.midi.handle(event: ControlEvent(source: knobCD, value: 0.77))
            spin(0.1)
            check.record(AssertionResult(
                name: "MIDI: a knob mapped to the locked side does nothing; one on C/D still moves its card",
                passed: engine.registry.value(slot: abCard, code: .wetDry) == abWet
                    && engine.registry.value(slot: cdCard, code: .wetDry) == 0.77,
                detail: "\(abCard) \(abWet ?? -1) → \(engine.registry.value(slot: abCard, code: .wetDry) ?? -1), "
                    + "\(cdCard) → \(engine.registry.value(slot: cdCard, code: .wetDry) ?? -1)"))
            engine.registry.unbind(source: knobAB)
            engine.registry.unbind(source: knobCD)
        } else {
            check.note("a chain is empty; the MIDI knob check was skipped")
        }

        // 7. A clip dropped on Source A is refused; on Source C it loads.
        let clip = ["motion.m2v", "bars.dv"].map { RepoPaths.samples.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        if let clip {
            panels.sourceBodies["A"]?.onClipDropped?(clip, nil)
            panels.sourceBodies["C"]?.onClipDropped?(clip, nil)
            spin(2.0)
            let a = engine.sources["A"]?.mediaURL?.lastPathComponent
            let c = engine.sources["C"]?.mediaURL?.lastPathComponent
            check.record(AssertionResult(
                name: "a clip dropped on locked Source A is refused; the same drop on Source C loads",
                passed: a == nil && c == clip.lastPathComponent,
                detail: "A holds \(a ?? "nothing"), C holds \(c ?? "nothing")"))
        } else {
            check.note("no sample clip; the drop check was skipped")
        }

        // 8. ⌘Z will not reach into the locked side.
        if let abCard {
            locks.setLocked(false, .ab)
            shell.undoHistory.clear()
            let before = engine.registry.value(slot: abCard, code: .wetDry) ?? 0
            let card = engine.chains[.one]?.displayOrder.first.flatMap { engine.catalog.module($0.moduleID)?.name }
            panels.effectsOneBody.onParameterChanged?(card ?? "", ParamCode.wetDry.rawValue, before > 0.5 ? 0.1 : 0.9)
            let edited = engine.registry.value(slot: abCard, code: .wetDry)
            locks.setLocked(true, .ab)
            let undone = shell.undoEdit()
            let after = engine.registry.value(slot: abCard, code: .wetDry)
            check.record(AssertionResult(
                name: "⌘Z will not take back an edit on a locked side (the step waits until it is unlocked)",
                passed: edited != before && undone == nil && after == edited && shell.undoHistory.canUndo,
                detail: "wet/dry \(before) → \(edited ?? -1), undo \(undone ?? "refused"), now \(after ?? -1)"))
        }

        // 9. A key typed into a focused A/B fader is refused; ⌘-keys are not.
        if let abFader {
            window.makeFirstResponder(abFader)
            let arrow = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil,
                                         characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
                                         isARepeat: false, keyCode: 126)
            let commandZ = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: "z", charactersIgnoringModifiers: "z",
                                            isARepeat: false, keyCode: 6)
            let arrowRefused = arrow.map(locks.refuses) ?? false
            let commandPassed = !(commandZ.map(locks.refuses) ?? true)
            window.makeFirstResponder(nil)
            check.record(AssertionResult(
                name: "an arrow key on a focused A/B fader is refused; ⌘Z is left to the menu",
                passed: window.firstResponder != nil && arrowRefused && commandPassed,
                detail: "arrow refused \(arrowRefused), ⌘Z passed \(commandPassed)"))
        }

        // 10. Shift-click learn still reaches a locked control.
        if let abFader, let detect = shell.detectSession {
            detect.setArmed(true)
            let learnAllowed = !asks(abFader)
            detect.setArmed(false)
            check.record(AssertionResult(
                name: "with Shift held (Detect armed), a click on a locked control gets through to learn it",
                passed: learnAllowed, detail: "allowed \(learnAllowed)"))
        }

        // 11. The LOCK note unlocks from the controller.
        let note = ControlSource.midiNote(channel: 0, note: 60)
        engine.registry.bind(ControlBinding(source: note, slot: BankLock.slot, code: .bankLockAB))
        engine.midi.handle(event: ControlEvent(source: note, value: 1))
        spin(0.3)
        writePNG(of: content, to: check.artifactURL("window-after-midi-unlock.png"))
        check.record(AssertionResult(
            name: "a note learned to LOCK A/B (6CJ) toggles it off from the controller; padlocks go",
            passed: !locks.lock.isLocked(.ab) && !toolbar.leftLock.isLocked && !panels.sourceA.showsPadlock,
            detail: "locked \(locks.lock.locked.map(\.rawValue)), key \(toolbar.leftLock.isLocked)"))
        engine.registry.unbind(source: note)

        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }

    private static func writePNG(of view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

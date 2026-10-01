//
//  UndoSelfQA.swift — everything that can be done can be taken back.
//
//  Purpose : The owner's recurring complaint (2026-09-28): eject took long to settle,
//            MIDI mappings could not be undone, automation undid spottily, and a
//            datamosh stuck until reset. This drives the real paths for taking things
//            back: Eject while a clip is still opening, a generator chosen while one
//            is opening, a MIDI learn cancelled with Esc, a mapping removed with ⌫, and
//            an effect's badges staying lit through a card rebuild, and ⌘Z / ⇧⌘Z /
//            File ▸ Undo History over hand edits (2026-10-01). The mosh watchdog
//            and LFO/audio restore are proven in Core (DatamoshTests, LFOTests,
//            AudioTests).
//  Inputs  : samples/uhd-hevc-hvc1.mov (the slowest open), a scratch preference file.
//  Outputs : selfqa/out/perf/undo/result.txt.
//  Connects: ShellController (eject, learn keys, unmapping), Engine, DetectSession.
//

import AppKit
import VideoboyCore

enum UndoSelfQA {

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/undo")
        let slow = RepoPaths.samples.appendingPathComponent("uhd-hevc-hvc1.mov")
        guard FileManager.default.fileExists(atPath: slow.path) else {
            return check.finish(blockedReason: "samples/uhd-hevc-hvc1.mov missing — run scripts/make-fixtures.sh")
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-undo-qa-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = PreferenceStore(fileURL: scratch.appendingPathComponent("prefs.json"))
        store.preferences.setupCompleted = true

        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let shell = controller.shellController,
              let detect = shell.detectSession else {
            return check.finish(blockedReason: "no window or no detect session")
        }
        controller.showWindow(nil)
        spin(0.5)
        let engine = controller.engine
        let panels = shell.shell.grid.panels

        // 1. Eject while a 4K clip is still opening: the channel stays empty.
        shell.loadClip(slow, into: "A", range: nil) { _ in }
        let inFlight = engine.loadsInFlight > 0
        panels.sourceBodies["A"]?.onEjectRequested?()      // the Eject button's own path
        spin(2.0)
        let aHolds = engine.sources["A"]?.mediaURL?.lastPathComponent
        check.record(AssertionResult(
            name: "Eject while a clip is still opening leaves the channel empty — the clip never lands",
            passed: inFlight && aHolds == nil && engine.loadsInFlight == 0,
            detail: "load was in flight \(inFlight), A holds \(aHolds ?? "nothing") 2 s later"))

        // 2. A generator chosen while a clip is opening keeps the channel on the generator.
        shell.loadClip(slow, into: "B", range: nil) { _ in }
        engine.setChannelSource(.generator, channel: "B")
        spin(2.0)
        let bKind = engine.channelSourceKinds["B"]
        let bHolds = engine.sources["B"]?.mediaURL?.lastPathComponent
        check.record(AssertionResult(
            name: "choosing a generator while a clip is opening keeps the generator; the clip is dropped",
            passed: bKind == .generator && bHolds == nil,
            detail: "B shows \(String(describing: bKind)), file node holds \(bHolds ?? "nothing")"))

        // 3. MIDI learn, then Esc: nothing is mapped.
        func key(_ code: UInt16, _ characters: String) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        }
        let slot = GraphTopology.subMixOne, code = ParamCode.crossfadeAB
        let knob = ControlSource.midiControlChange(channel: 0, controller: 77)
        func mapped() -> Bool { engine.registry.bindings.contains { $0.slot == slot && $0.code == code } }
        func shiftClick() { detect.onDetectRequested?(slot, code, .anything) }  // what Shift-click calls

        shiftClick()
        let armed = shell.pendingLearn != nil
        let escTaken = key(53, "\u{1b}").map { shell.handleLearnKey($0) } ?? false
        engine.midi.handle(event: ControlEvent(source: knob, value: 0.3))
        check.record(AssertionResult(
            name: "Esc cancels an armed MIDI learn: the next knob moved maps nothing",
            passed: armed && escTaken && shell.pendingLearn == nil && !mapped(),
            detail: "armed \(armed), Esc taken \(escTaken), still armed \(shell.pendingLearn != nil), mapped \(mapped())"))

        // 4. Learn for real, then Shift-click it again and ⌫: the mapping is gone.
        shiftClick()
        engine.midi.handle(event: ControlEvent(source: knob, value: 0.4))
        let learned = mapped() && shell.pendingLearn == nil
        shiftClick()
        let deleteTaken = key(51, "\u{7f}").map { shell.handleLearnKey($0) } ?? false
        let before = engine.registry.value(slot: slot, code: code)
        engine.midi.handle(event: ControlEvent(source: knob, value: 0.9))
        let after = engine.registry.value(slot: slot, code: code)
        check.record(AssertionResult(
            name: "Shift-click a mapped control and press ⌫: its mapping is removed and the knob no longer moves it",
            passed: learned && deleteTaken && !mapped() && shell.pendingLearn == nil && before == after,
            detail: "learned \(learned), ⌫ taken \(deleteTaken), still mapped \(mapped()), "
                + "value \(before ?? -1) → \(after ?? -1) after the knob moved"))

        // 5. A card's badges survive the panel rebuilding its cards.
        if let entry = engine.chains[.one]?.displayOrder.first,
           let name = engine.catalog.module(entry.moduleID)?.name {
            let cardSlot = EffectChain.targetedSlot(of: entry, bus: .one)
            engine.lfos.assign(LFOBank.Assignment(
                lfo: LFO(shape: .sine, rate: .subdivision(.quarter)), slot: cardSlot, code: .wetDry))
            shell.mappingsChangedElsewhere()                   // rebuilds both panels' cards
            let badge = allSubviews(of: panels.effectsOneBody).compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "\(name)|\(ModulationSource.lfo.badge)" }
            let lit = badge?.contentTintColor == Theme.Color.accent
            engine.lfos.remove(slot: cardSlot, code: .wetDry, restoringIn: engine.registry)
            check.record(AssertionResult(
                name: "an effect's LFO badge stays lit when the panel rebuilds its cards",
                passed: lit,
                detail: "\(name): badge found \(badge != nil), lit \(lit)"))
        } else {
            check.note("bus ONE has no chain entry; the badge check was skipped")
        }

        // 6–11. ⌘Z / ⇧⌘Z and File ▸ Undo History, through the real menu items.
        checkEditHistory(check: check, shell: shell, engine: engine, store: store, window: window)

        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }

    /// Hand edits made through the panels' own callbacks, taken back with ⌘Z pressed
    /// through the delegate's real Edit menu.
    private static func checkEditHistory(check: SelfQACheck, shell: ShellController, engine: Engine,
                                         store: PreferenceStore, window: NSWindow) {
        let panels = shell.shell.grid.panels
        guard let entry = engine.chains[.one]?.displayOrder.first,
              let name = engine.catalog.module(entry.moduleID)?.name else {
            check.note("bus ONE has no chain entry; the undo history checks were skipped")
            return
        }
        let cardSlot = EffectChain.targetedSlot(of: entry, bus: .one)
        let mixSlot = GraphTopology.subMixOne
        let history = shell.undoHistory
        history.clear()

        let delegate = AppDelegate()
        delegate.undoShellForChecks = shell
        let savedMenu = NSApp.mainMenu
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        editItem.submenu = AppDelegate.makeEditMenu(undoTarget: delegate)
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
        defer { NSApp.mainMenu = savedMenu }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)

        func press(_ shift: Bool) -> Bool {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift ? [.command, .shift] : .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: shift ? "Z" : "z",
                charactersIgnoringModifiers: shift ? "Z" : "z", isARepeat: false, keyCode: 6) else { return false }
            return mainMenu.performKeyEquivalent(with: event)
        }
        let wet = { engine.registry.value(slot: cardSlot, code: .wetDry) ?? -1 }
        let blend = { engine.registry.value(slot: mixSlot, code: .blendMode) ?? -1 }

        // 6. A drag (twenty fader events) is ONE step; a blend change is another.
        let wetBefore = wet(), blendBefore = blend()
        for i in 1...20 {
            panels.effectsOneBody.onParameterChanged?(name, ParamCode.wetDry.rawValue, Double(i) / 25)
        }
        let wetAfter = wet()
        let target: BlendMode = BlendMode.from(normalised: blendBefore) == .screen ? .multiply : .screen
        panels.faderABBody.onBlendModeChanged?(target)
        check.record(AssertionResult(
            name: "a card fader dragged through twenty values is one undo step; a blend change is a second",
            passed: history.steps.count == 2 && wetAfter != wetBefore,
            detail: "steps \(history.steps.map(\.name)), wet/dry \(wetBefore) → \(wetAfter)"))

        // 7. ⌘Z through the Edit menu takes them back newest first, named in the menu.
        let undoItem = editItem.submenu?.items.first
        editItem.submenu?.update()
        let undoTitle = undoItem?.title ?? ""
        let firstUndo = press(false)
        let blendRestored = blend() == blendBefore && wet() == wetAfter
        let secondUndo = press(false)
        let wetRestored = wet() == wetBefore
        check.record(AssertionResult(
            name: "⌘Z (the real Edit menu item) undoes the blend, then the whole drag; the item names the step",
            passed: firstUndo && secondUndo && blendRestored && wetRestored && undoTitle == "Undo Blend Mode"
                && !history.canUndo,
            detail: "menu said \"\(undoTitle)\", blend restored \(blendRestored), wet/dry back to \(wet()) "
                + "(was \(wetBefore))"))

        // 8. ⇧⌘Z puts both back, and applying a step records nothing new.
        _ = press(true); _ = press(true)
        check.record(AssertionResult(
            name: "⇧⌘Z redoes both, and applying steps adds no steps of its own",
            passed: wet() == wetAfter && blend() == target.normalisedPosition && history.steps.count == 2
                && history.position == 2,
            detail: "wet/dry \(wet()), blend \(blend()), steps \(history.steps.count) at \(history.position)"))

        // 9. ⌘Z while a text field is being typed in is the text's undo, not the show's.
        // The route asks the KEY window; a bare self-QA binary is never frontmost, so
        // the delegate falls back to this window through `undoShellForChecks`.
        let field = NSTextField(string: "")
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        (window.firstResponder as? NSTextView)?.insertText("120", replacementRange: NSRange(location: NSNotFound, length: 0))
        let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        _ = press(false)
        let typingKept = history.position == 2 && wet() == wetAfter
        window.makeFirstResponder(window.contentView)
        field.removeFromSuperview()
        check.record(AssertionResult(
            name: "⌘Z in a text field being edited leaves the show's history alone",
            passed: typingKept,
            detail: "history at \(history.position) of \(history.steps.count), first responder \(responder)"))

        // 10. File ▸ Undo History: Opened, each step, the current one ticked, and the
        //     link to the setting at the very bottom. Choosing "Opened" reverts both.
        delegate.menuNeedsUpdate(delegate.undoHistoryMenu)
        let items = delegate.undoHistoryMenu.items
        let titles = items.filter { !$0.isSeparatorItem }.map(\.title)
        let last = items.last
        let ticked = items.first { $0.state == .on }?.tag
        if let opened = items.first(where: { $0.title == "Opened" }) {
            delegate.undoHistoryEntryChosen(opened)
        }
        check.record(AssertionResult(
            name: "File ▸ Undo History lists Opened and each step, ticks the current one, ends with the "
                + "Undo Settings link, and choosing Opened reverts everything",
            passed: titles.first == "Opened" && titles.count == 5 && ticked == 2
                && last?.action == #selector(AppDelegate.showUndoSettings(_:))
                && (last?.title.hasPrefix("Undo Settings…") ?? false)
                && wet() == wetBefore && blend() == blendBefore && history.position == 0,
            detail: "items \(titles), ticked \(ticked ?? -1), wet/dry \(wet()), blend \(blend())"))

        // 11. The setting reaches the live history, and lowering it trims.
        for i in 0..<15 {
            history.record("qa \(i)", changes: [ParameterChange(slot: cardSlot, code: .wetDry,
                                                                  before: Double(i), after: Double(i + 1))],
                           now: Date().addingTimeInterval(Double(i) * 5))
        }
        store.preferences.undoLimit = 10
        check.record(AssertionResult(
            name: "Settings ▸ Defaults' undo limit applies to the open show at once and trims the oldest",
            passed: history.limit == 10 && history.steps.count == 10,
            detail: "limit \(history.limit), steps \(history.steps.count)"))
        history.clear()
    }

    private static func allSubviews(of root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap { allSubviews(of: $0) }
    }
}

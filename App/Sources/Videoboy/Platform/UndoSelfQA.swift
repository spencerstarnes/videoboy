//
//  UndoSelfQA.swift — everything that can be done can be taken back.
//
//  Purpose : The owner's recurring complaint (2026-09-28): eject took long to settle,
//            MIDI mappings could not be undone, automation undid spottily, and a
//            datamosh stuck until reset. This drives the real paths for taking things
//            back: Eject while a clip is still opening, a generator chosen while one
//            is opening, a MIDI learn cancelled with Esc, a mapping removed with ⌫, and
//            an effect's badges staying lit through a card rebuild. The mosh watchdog
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

        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }

    private static func allSubviews(of root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap { allSubviews(of: $0) }
    }
}

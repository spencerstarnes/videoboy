//
//  FXFocusSelfQA.swift — one A · B · MIX focus for each FX panel, not one per card.
//
//  Purpose : The owner asked (2026-09-28) for the per-card A/B toggles to go and one
//            master at the top to switch the whole card sheet; MIX is the sub-mix
//            (the bus copy, after the crossfader). This proves it through the real
//            window: the control sits in the panel's title bar and a click reaches
//            it; no card keeps a selector; a focus change points every card at that
//            copy (a drag lands there, the switches read that copy's bypass); MIX
//            edits the sub-mix; Source Controls follows A/B and holds on MIX; a new
//            card takes the focus; and nothing on air changes when focus moves.
//  Inputs  : samples/motion.mov (a clip for B), a scratch preference file.
//  Outputs : selfqa/out/perf/fx-focus/{result.txt,header.png}.
//  Connects: EffectChainPanelBody (focusControl), ShellController (setFXFocus), Engine.
//

import AppKit
import VideoboyCore

enum FXFocusSelfQA {

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func all<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        root.subviews.compactMap { $0 as? T } + root.subviews.flatMap { all(type, in: $0) }
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/fx-focus")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-fx-focus-qa-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = PreferenceStore(fileURL: scratch.appendingPathComponent("prefs.json"))
        store.preferences.setupCompleted = true

        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let screen = NSScreen.main,
              let shell = controller.shellController, let content = window.contentView else {
            return check.finish(blockedReason: "no window")
        }
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true)
        controller.showWindow(nil)
        spin(0.5)
        let engine = controller.engine
        let panels = shell.shell.grid.panels
        let body = panels.effectsOneBody
        let focus = body.focusControl

        // 1. In the title bar, reachable, and the cards carry no selector of their own.
        content.layoutSubtreeIfNeeded()
        let centre = content.convert(NSPoint(x: focus.bounds.midX, y: focus.bounds.midY), from: focus)
        let hit = content.hitTest(centre)
        let reachable = hit === focus || hit?.isDescendant(of: focus) == true
        let inHeader = !focus.isDescendant(of: body) && focus.isDescendant(of: panels.effectsOne)
        let labels = (0..<focus.segmentCount).map { focus.label(forSegment: $0) ?? "" }
        let leftover = all(NSSegmentedControl.self, in: body).count
            + all(NSSegmentedControl.self, in: panels.effectsTwoBody).count
        check.record(AssertionResult(
            name: "each FX panel has one A · B · MIX focus in its title bar, a click reaches it, and no card has its own",
            passed: reachable && inHeader && labels == ["A", "B", "MIX"]
                && panels.effectsTwoBody.focusControl.segmentCount == 3 && leftover == 0,
            detail: "reachable \(reachable), in header \(inHeader), labels \(labels), selectors left on cards \(leftover)"))
        if let header = focus.superview, let image = UISelfQA.render(view: header) {
            _ = try? check.writeImage(image, named: "header.png")
        }

        func pick(_ segment: Int) {
            focus.selectedSegment = segment
            _ = focus.target?.perform(focus.action, with: focus)
            spin(0.1)
        }
        func targets() -> Set<Int> { Set(engine.chains[.one]?.entries.map(\.target) ?? []) }
        func onAir() -> [Double] {
            (engine.chains[.one]?.entries ?? []).flatMap { entry in
                EffectChain.slots(instanceID: entry.instanceID, bus: .one)
                    .map { engine.registry.value(slot: $0, code: .wetDry) ?? -1 }
            }
        }
        guard let colour = engine.chains[.one]?.entry("colour"),
              let colourName = engine.catalog.module(colour.moduleID)?.name,
              let firstCode = engine.catalog.module(colour.moduleID)?.controls.first?.code else {
            return check.finish(blockedReason: "bus ONE has no Colour card")
        }
        let slotA = EffectChain.slot(instanceID: "colour", lane: "A")
        let slotB = EffectChain.slot(instanceID: "colour", lane: "B")
        let slotMix = EffectChain.slot(instanceID: "colour", lane: ChainBus.one.lane)
        let colourSwitch = all(NSSwitch.self, in: body).first { $0.identifier?.rawValue == colourName }
        func subtitle() -> String {
            all(NSTextField.self, in: body)
                .first { $0.identifier?.rawValue == "subtitle|\(EffectChainPanelBody.sourceCardName)" }?.stringValue ?? ""
        }

        // 2. B: every card, the switch reads B's own bypass, a drag lands on B's copy,
        //    Source Controls shows B — and nothing on air moved.
        engine.registry.setValue(0, slot: slotA, code: .wetDry)
        engine.registry.setValue(1, slot: slotB, code: .wetDry)
        let before = onAir()
        pick(1)
        body.onParameterChanged?(colourName, firstCode.rawValue, 0.8)   // a drag's own path
        let landedOnB = engine.registry.parameter(slot: slotB, code: firstCode).map {
            abs((engine.registry.value(slot: slotB, code: firstCode) ?? -1) - $0.denormalise(0.8)) < 1e-6
        } ?? false
        check.record(AssertionResult(
            name: "B: every card edits B's copy — a drag lands there, the switch shows B's bypass, Source Controls shows B",
            passed: targets() == [1] && landedOnB && colourSwitch?.state == .on && subtitle().hasPrefix("B")
                && shell.abFXFocusForChecks == 1,
            detail: "targets \(targets().sorted()), drag on B \(landedOnB), switch \(colourSwitch?.state == .on ? "on" : "off"), "
                + "Source Controls \"\(subtitle())\""))
        check.record(AssertionResult(
            name: "changing focus changes nothing on air: every copy keeps its own on/off",
            passed: onAir() == before,
            detail: onAir() == before ? "all \(before.count) copies unchanged" : "before \(before), after \(onAir())"))

        // 3. MIX: the sub-mix's copy; Source Controls keeps B (a mix has no source).
        pick(2)
        body.onParameterChanged?(colourName, firstCode.rawValue, 0.3)
        let landedOnMix = engine.registry.parameter(slot: slotMix, code: firstCode).map {
            abs((engine.registry.value(slot: slotMix, code: firstCode) ?? -1) - $0.denormalise(0.3)) < 1e-6
        } ?? false
        check.record(AssertionResult(
            name: "MIX: every card edits the A/B sub-mix's copy; Source Controls stays on B",
            passed: targets() == [ChainEntry.both] && landedOnMix && subtitle().hasPrefix("B"),
            detail: "targets \(targets().sorted()), drag on the sub-mix \(landedOnMix), Source Controls \"\(subtitle())\""))

        // 4. A card added now takes the focus.
        let inChain = Set(engine.chains[.one]?.entries.map(\.moduleID) ?? [])
        let added = engine.catalog.modules.first { $0.isAvailable && !inChain.contains($0.id) }
        if let added {
            body.onEffectAdded?(added.id)
            spin(0.1)
            let newest = engine.chains[.one]?.entries.first
            check.record(AssertionResult(
                name: "a card added while MIX is in focus edits MIX too",
                passed: newest?.moduleID == added.id && newest?.target == ChainEntry.both,
                detail: "\(added.name): target \(newest?.target ?? -1)"))
        } else {
            check.note("every module is already in the chain; the add check was skipped")
        }

        // 5. A load into B while A is in focus leaves the sheet on A.
        pick(0)
        let clip = RepoPaths.samples.appendingPathComponent("motion.mov")
        if FileManager.default.fileExists(atPath: clip.path) {
            shell.loadClipForChecks(clip, into: "B")
            UISelfQA.waitForLoads(engine)
            spin(0.2)
            check.record(AssertionResult(
                name: "loading into B while A is in focus leaves the whole sheet on A",
                passed: subtitle().hasPrefix("A") && targets() == [0],
                detail: "Source Controls \"\(subtitle())\", targets \(targets().sorted())"))
        }

        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

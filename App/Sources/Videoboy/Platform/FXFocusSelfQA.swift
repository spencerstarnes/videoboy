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
//  Outputs : selfqa/out/perf/fx-focus/{result.txt,panel.png}.
//  Connects: EffectChainPanelBody (focusKeys), ShellController (setFXFocus), Engine.
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
        let keys = body.focusKeys

        // 1. Three tall keys across the top of the panel, above Source Controls, each
        //    reached by a real hit-test; A lit; no card keeps a selector of its own.
        content.layoutSubtreeIfNeeded()
        let unreachable = keys.filter { key in
            let centre = content.convert(NSPoint(x: key.bounds.midX, y: key.bounds.midY), from: key)
            let hit = content.hitTest(centre)
            return !(hit === key || hit?.isDescendant(of: key) == true)
        }.map(\.title)
        let labels = keys.map(\.title)
        let frames = keys.map { $0.convert($0.bounds, to: body) }
        let rowWidth = (frames.last?.maxX ?? 0) - (frames.first?.minX ?? 0)
        let height = frames.first?.height ?? 0
        let atTop = frames.allSatisfy { abs($0.maxY - body.bounds.maxY) <= 6 }
        let lit = keys.map(\.isOn)
        let leftover = all(NSSegmentedControl.self, in: body).count
            + all(NSSegmentedControl.self, in: panels.effectsTwoBody).count
        check.record(AssertionResult(
            name: "each FX panel has A · B · MIX focus keys across its top — tall, full width, reachable, A lit — and no card has its own",
            passed: unreachable.isEmpty && labels == ["A", "B", "MIX"] && atTop && lit == [true, false, false]
                && rowWidth >= body.bounds.width - 12 && height >= 22
                && panels.effectsTwoBody.focusKeys.map(\.title) == ["C", "D", "MIX"] && leftover == 0,
            detail: "labels \(labels), unreachable \(unreachable), at top \(atTop), lit \(lit), "
                + "row \(Int(rowWidth)) of \(Int(body.bounds.width)) pt, \(Int(height)) pt tall, selectors left on cards \(leftover)"))

        // A REAL click on B: through the key's own mouse tracking (its mouse-up queued
        // first, as a finger would release it).
        func realClick(_ key: VBOptionButton) {
            let point = key.convert(NSPoint(x: key.bounds.midX, y: key.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let up = event(.leftMouseUp) { window.postEvent(up, atStart: true) }
            if let down = event(.leftMouseDown) { key.mouseDown(with: down) }
            spin(0.1)
        }

        func pick(_ segment: Int) {
            body.pickFocusForChecks(segment)
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
        realClick(keys[1])
        let litAfterClick = keys.map(\.isOn)
        body.onParameterChanged?(colourName, firstCode.rawValue, 0.8)   // a drag's own path
        let landedOnB = engine.registry.parameter(slot: slotB, code: firstCode).map {
            abs((engine.registry.value(slot: slotB, code: firstCode) ?? -1) - $0.denormalise(0.8)) < 1e-6
        } ?? false
        check.record(AssertionResult(
            name: "a real click on B lights B alone; every card edits B's copy — a drag lands there, the switch shows B's bypass, Source Controls shows B",
            passed: targets() == [1] && landedOnB && colourSwitch?.state == .on && subtitle().hasPrefix("B")
                && shell.abFXFocusForChecks == 1 && litAfterClick == [false, true, false],
            detail: "a real click on B lit \(litAfterClick); targets \(targets().sorted()), drag on B \(landedOnB), "
                + "switch \(colourSwitch?.state == .on ? "on" : "off"), "
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

        // A real screen photo of the panel (an offscreen render draws no key colour).
        let shot = RepoPaths.selfQAOutput.appendingPathComponent("perf/fx-focus/window.png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", shot.path]
        if (try? capture.run()) != nil {
            while capture.isRunning { spin(0.05) }
            check.note("window photo: \(shot.path)")
        }

        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

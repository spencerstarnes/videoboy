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
//  Outputs : selfqa/out/mosh/app/{result.txt, clean-cut.png, moshed-cut.png}.
//  Connects: MainWindowController, the "Datamosh · H.264" card (PanelSet),
//            ShellController's routing, Engine's `fx.one.mosh` node.
//  Extend  : a new gesture (bloom, heal) is one more click and one more capture.
//

import AppKit
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

        // 3. Letting go heals at once: mosh back to zero and the node lets go.
        engine.registry.setValue(0, slot: Engine.moshOneSlot, code: .moshAmount)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        check.record(AssertionResult(
            name: "pulling mosh to zero releases the encoder",
            passed: node?.isRunning == false,
            detail: "running \(node?.isRunning == true)"))

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

    /// Sends a real mouse down/up through the window at `fraction` across `view`.
    /// Returns whether hit-testing delivered it to `view` (or a view inside it).
    private static func click(_ view: NSView, at fraction: CGFloat, in window: NSWindow, shell: ShellView) -> Bool {
        view.scrollToVisible(view.bounds)
        shell.layoutSubtreeIfNeeded()
        let local = NSPoint(x: view.bounds.minX + view.bounds.width * fraction, y: view.bounds.midY)
        let point = view.convert(local, to: nil)
        guard let hit = shell.hitTest(shell.convert(point, from: nil)),
              hit === view || hit.isDescendant(of: view) else { return false }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
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

    private static func meanDifference(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        guard a.width == b.width, a.height == b.height else { return 255 }
        var total = 0
        for index in stride(from: 0, to: a.pixels.count, by: 4) {
            for channel in 0..<3 { total += abs(Int(a.pixels[index + channel]) - Int(b.pixels[index + channel])) }
        }
        return Double(total) / Double(a.width * a.height * 3)
    }
}

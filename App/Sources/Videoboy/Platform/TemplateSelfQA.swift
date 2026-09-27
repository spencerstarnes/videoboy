//
//  TemplateSelfQA.swift — the show survives Save, New and Open (audit L1).
//
//  Purpose : Builds a distinctive show — a trimmed clip in ping-pong playing in A, a
//            generator in C, an extra effect card, a moved crossfader and effect
//            fader, a MIDI mapping, a tempo — saves it, clears everything with New,
//            opens the file again, and checks each thing came back: in the engine AND
//            on the controls a performer sees.
//  Inputs  : samples/motion.mov; scratch preferences and template file.
//  Outputs : selfqa/out/perf/template/result.txt and the saved template.
//  Connects: ShellController (captureTemplate / saveTemplate / openTemplate /
//            newTemplate), TemplateDocument, Engine, ParamRegistry.
//

import AppKit
import VideoboyCore

enum TemplateSelfQA {

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/template")
        let clip = RepoPaths.samples.appendingPathComponent("motion.mov")
        guard FileManager.default.fileExists(atPath: clip.path) else {
            return check.finish(blockedReason: "samples/motion.mov is missing")
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-template-qa-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = PreferenceStore(fileURL: scratch.appendingPathComponent("prefs.json"))
        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let screen = NSScreen.main,
              let shell = controller.shellController else { return check.finish(blockedReason: "no window") }
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true)
        controller.showWindow(nil)
        let engine = controller.engine
        let registry = engine.registry
        let panels = shell.shell.grid.panels
        spin(1)

        // THE SHOW.
        shell.loadForChecks(clip, channel: "A")
        UISelfQA.waitForLoads(engine)
        engine.sources["A"]?.playbackRange = 0.2...0.7
        engine.sources["A"]?.loopMode = .pingPong
        engine.setPlaying(true, channel: "A")
        panels.sourceBodies["C"]?.onReferenceDropped?("generator:\(GeneratorKind.checkerboard.rawValue)")
        let chainBefore = engine.chains[.one]?.entries.count ?? 0
        if let module = engine.chains[.one]?.entries.first?.moduleID { _ = engine.addModule(module, to: .one) }
        let chainCount = engine.chains[.one]?.entries.count ?? 0
        registry.setValue(0.8, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        // One effect parameter on a live chain card, moved away from its default.
        let colourSlot = Engine.colourSlot
        let colourParameter = engine.graph.nodes[colourSlot]?.parameters.first { $0.code != .wetDry }
        let movedValue = colourParameter.map { $0.range.lowerBound + ($0.range.upperBound - $0.range.lowerBound) * 0.83 }
        if let colourParameter, let movedValue { registry.setValue(movedValue, slot: colourSlot, code: colourParameter.code) }
        let mapping = ControlBinding(source: .midiControlChange(channel: 0, controller: 21),
                                     slot: GraphTopology.subMixOne, code: .crossfadeAB)
        registry.bind(mapping)
        engine.setTempo(97)
        spin(0.5)

        // SAVE.
        let file = scratch.appendingPathComponent("QA Show.vbt")
        var saved = true
        do { try shell.saveTemplate(to: file) } catch { saved = false }
        check.record(AssertionResult(
            name: "the show saves to a template file",
            passed: saved && FileManager.default.fileExists(atPath: file.path) && window.subtitle == "QA Show.vbt",
            detail: "file \(FileManager.default.fileExists(atPath: file.path)), window subtitle '\(window.subtitle)'"))
        let evidence = RepoPaths.selfQAOutput.appendingPathComponent("perf/template", isDirectory: true)
        try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: evidence.appendingPathComponent("QA Show.vbt"))
        try? FileManager.default.copyItem(at: file, to: evidence.appendingPathComponent("QA Show.vbt"))

        // NEW: everything goes.
        shell.newTemplate()
        spin(0.8)
        let cleared = engine.sources["A"]?.mediaURL == nil
            && (engine.channelSourceKinds["C"] ?? .file) == .file
            && engine.chains[.one]?.entries.count == chainBefore
            && registry.bindings.isEmpty
            && abs((registry.value(slot: GraphTopology.subMixOne, code: .crossfadeAB) ?? 0) - 0.8) > 0.01
        check.record(AssertionResult(
            name: "New clears the show back to how the app opened",
            passed: cleared && window.subtitle == "untitled.vbt",
            detail: "A empty \(engine.sources["A"]?.mediaURL == nil), C file \((engine.channelSourceKinds["C"] ?? .file) == .file), "
                + "chain \(engine.chains[.one]?.entries.count ?? -1)/\(chainBefore), mappings \(registry.bindings.count)"))

        // OPEN: everything comes back.
        guard let document = try? TemplateDocument.read(from: file) else {
            return check.finish(blockedReason: "the saved template did not read back")
        }
        shell.openTemplate(document, from: file)
        UISelfQA.waitForLoads(engine)
        spin(0.8)
        let a = engine.sources["A"]
        let restoredCrossfade = registry.value(slot: GraphTopology.subMixOne, code: .crossfadeAB) ?? -1
        let restoredColour = colourParameter.flatMap { registry.value(slot: colourSlot, code: $0.code) }
        check.record(AssertionResult(
            name: "Open brings back channel A: the clip, its marks, ping-pong, playing",
            passed: a?.mediaURL?.lastPathComponent == "motion.mov" && a?.playbackRange == 0.2...0.7
                && a?.loopMode == .pingPong && a?.isPlaying == true,
            detail: "\(a?.mediaURL?.lastPathComponent ?? "nothing"), range \(String(describing: a?.playbackRange)), "
                + "\(a?.loopMode.displayName ?? "-"), playing \(a?.isPlaying ?? false)"))
        check.record(AssertionResult(
            name: "Open brings back the generator in C",
            passed: engine.channelSourceKinds["C"] == .generator
                && engine.generators["C"]?.generator == .checkerboard,
            detail: "C is \(String(describing: engine.channelSourceKinds["C"]))"))
        check.record(AssertionResult(
            name: "Open brings back the effect chain, values, MIDI mapping and tempo",
            passed: engine.chains[.one]?.entries.count == chainCount && abs(restoredCrossfade - 0.8) < 0.001
                && restoredColour.map { abs($0 - (movedValue ?? -9)) < 0.001 } == true
                && registry.bindings.contains(mapping)
                && abs(engine.transport.beatsPerMinute - 97) < 0.01,
            detail: "chain \(engine.chains[.one]?.entries.count ?? -1)/\(chainCount), crossfade \(restoredCrossfade), "
                + "colour \(restoredColour.map { String(format: "%.3f", $0) } ?? "nil"), mapping \(registry.bindings.contains(mapping)), "
                + "tempo \(engine.transport.beatsPerMinute)"))

        // And the controls on screen show it — not only the engine.
        var shownFaderMatches = false
        func find(_ view: NSView) {
            if let fader = view as? VBFader, fader.mappingSlot == colourSlot, fader.mappingCode == colourParameter?.code,
               let colourParameter, let movedValue,
               abs(fader.value - colourParameter.normalise(movedValue)) < 0.01 { shownFaderMatches = true }
            view.subviews.forEach(find)
        }
        find(shell.shell)
        let crossfaderShown = panels.faderABBody.faderValueForChecks
        check.record(AssertionResult(
            name: "the controls on screen show the opened values (crossfader, effect fader)",
            passed: abs(crossfaderShown - 0.8) < 0.01 && shownFaderMatches,
            detail: String(format: "A/B crossfader shows %.2f; colour fader matches %@", crossfaderShown,
                           shownFaderMatches ? "yes" : "no")))

        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

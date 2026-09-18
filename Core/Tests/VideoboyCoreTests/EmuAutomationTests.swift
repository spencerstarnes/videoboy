//
//  EmuAutomationTests.swift — a MIDI knob and a mouse must be indistinguishable.
//
//  The point of routing the EMU controls through the param registry is that nothing in
//  the automation machinery has to know an emulator exists. A MIDI CC, an LFO, a
//  beat-synced sweep and a saved template all write a number to a slot and a code; the
//  node reads it and the translation layer turns it into the same command a fader move
//  would have produced. These check that, and the thing that would ruin it: a flood of
//  commands from a value that is not actually changing.
//

import XCTest
@testable import VideoboyCore

final class EmuAutomationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private func makeNode() -> (EmulatedTitlerNode, ParamRegistry, ScalaTitlerPanel) {
        let node = EmulatedTitlerNode(
            identifier: "source.emu", host: MockEmulatorHost(), context: nil)
        let panel = ScalaTitlerPanel()
        node.panel = panel
        let registry = ParamRegistry()
        registry.register(slot: node.identifier, parameters: node.parameters)
        // Prime the baseline, which is what the first frame does in the real app: every
        // control is registered with a default, and the node deliberately sends nothing
        // until it knows where they all started.
        node.applyParameters(from: registry)
        return (node, registry, panel)
    }

    func testEveryTitlerControlHasAStableCode() {
        // The codes are what a MIDI mapping and a saved template store, so two
        // functions sharing one would silently make one control drive the other.
        var seen: Set<ParamCode> = []
        for function in TitlerFunction.allCases {
            XCTAssertTrue(
                seen.insert(function.code).inserted,
                "\(function.rawValue) shares a code with another control")
            XCTAssertEqual(TitlerFunction.forCode(function.code), function)
        }
        XCTAssertEqual(seen.count, TitlerFunction.allCases.count)
    }

    func testTheNodeExposesEveryControlToTheRegistry() {
        // If a control is not registered it cannot be mapped, automated or saved — and
        // the fader would still move, which is the silent half of the failure.
        let (node, _, _) = makeNode()
        let codes = Set(node.parameters.map(\.code))
        for function in TitlerFunction.allCases {
            XCTAssertTrue(codes.contains(function.code), "\(function.rawValue) is unmappable")
        }
    }

    func testTheFirstPassSendsNothingAndOnlyRecordsWhereThingsAre() {
        // Every control is registered with a default. Without a baseline the first
        // frame would fire all fifteen at once, at the exact moment a machine that has
        // just started is least able to cope. Syncing is a deliberate act with its own
        // path (`fullState()`), not a side effect of the first render.
        let node = EmulatedTitlerNode(
            identifier: "source.emu", host: MockEmulatorHost(), context: nil)
        node.panel = ScalaTitlerPanel()
        let registry = ParamRegistry()
        registry.register(slot: node.identifier, parameters: node.parameters)

        var sent: [TitlerCommand] = []
        node.onCommands = { sent.append(contentsOf: $0) }
        node.applyParameters(from: registry)
        XCTAssertTrue(sent.isEmpty, "the first pass is a baseline, not a broadcast")
    }

    func testAValueWrittenToTheRegistryProducesRealCommands() {
        // THE test. A MIDI knob writes here; nothing else about this path differs from
        // a mouse.
        let (node, registry, _) = makeNode()
        var sent: [TitlerCommand] = []
        node.onCommands = { sent.append(contentsOf: $0) }

        registry.setValue(0.8, slot: node.identifier, code: .emuFontSize)
        node.applyParameters(from: registry)

        XCTAssertFalse(sent.isEmpty, "a registry write must reach the machine")
        XCTAssertTrue(
            sent.contains { $0.verb == "FONT" },
            "expected a FONT command, got \(sent.map(\.line))")
    }

    func testAKnobAndAMouseProduceTheSameCommand() {
        let (node, registry, _) = makeNode()
        var viaRegistry: [String] = []
        node.onCommands = { viaRegistry = $0.map(\.line) }
        registry.setValue(0.3, slot: node.identifier, code: .emuWipe)
        node.applyParameters(from: registry)

        let viaMouse = ScalaTitlerPanel().set(.wipe, to: 0.3).map(\.line)
        XCTAssertEqual(viaRegistry, viaMouse)
    }

    func testAStaticFaderSendsNOTHING() {
        // This runs once a frame. Without a change test, a fader sitting still would
        // send its value sixty times a second down a wire to a 68k — which would drown
        // the machine in commands that say nothing.
        let (node, registry, _) = makeNode()
        registry.setValue(0.5, slot: node.identifier, code: .emuFontSize)
        node.applyParameters(from: registry)

        var sentAfterSettling: [TitlerCommand] = []
        node.onCommands = { sentAfterSettling.append(contentsOf: $0) }
        for _ in 0..<60 { node.applyParameters(from: registry) }

        XCTAssertTrue(
            sentAfterSettling.isEmpty,
            "a value that is not changing must not be resent, got "
                + "\(sentAfterSettling.count) commands")
    }

    func testAnImperceptibleMoveIsIgnored() {
        // A MIDI CC is 128 steps and an LFO is continuous. A command per inaudible
        // move is the same flood by a different route.
        let (node, registry, _) = makeNode()
        registry.setValue(0.5, slot: node.identifier, code: .emuWipeSpeed)
        node.applyParameters(from: registry)

        var sent: [TitlerCommand] = []
        node.onCommands = { sent.append(contentsOf: $0) }
        registry.setValue(0.5005, slot: node.identifier, code: .emuWipeSpeed)
        node.applyParameters(from: registry)
        XCTAssertTrue(sent.isEmpty, "a move this small should not reach the machine")

        registry.setValue(0.75, slot: node.identifier, code: .emuWipeSpeed)
        node.applyParameters(from: registry)
        XCTAssertFalse(sent.isEmpty, "a real move should")
    }

    func testAnLFOSweepingAControlKeepsProducingCommands() {
        // A sweep is the case the deadband must NOT suppress: it moves continuously and
        // every step is meant.
        let (node, registry, _) = makeNode()
        var count = 0
        node.onCommands = { count += $0.count }

        let sweep = ParameterSweep(first: 0, second: 1, beatsPerCycle: 4)
        for step in 0..<32 {
            let beats = Double(step) / 4.0
            registry.setValue(
                sweep.value(atBeats: beats), slot: node.identifier, code: .emuTextY)
            node.applyParameters(from: registry)
        }
        XCTAssertGreaterThan(count, 10, "a sweep must keep reaching the machine")
    }

    func testAControlWithNothingBehindItStaysSilent() {
        // PAGE has no script loaded, so it has nothing to jump to. It must not invent a
        // command just because a knob moved.
        let (node, registry, _) = makeNode()
        var sent: [TitlerCommand] = []
        node.onCommands = { sent.append(contentsOf: $0) }

        registry.setValue(0.9, slot: node.identifier, code: .emuPage)
        node.applyParameters(from: registry)
        XCTAssertTrue(sent.isEmpty, "no script is loaded, so there is no page to reach")
    }

    func testWithNoPanelNothingHappensRatherThanCrashing() {
        // The node exists before a machine does — it is created at launch so its
        // parameters are registered and mappable whether or not anything is running.
        let node = EmulatedTitlerNode(
            identifier: "source.emu", host: UnavailableEmulatorHost(reason: "none"),
            context: nil)
        let registry = ParamRegistry()
        registry.register(slot: node.identifier, parameters: node.parameters)
        registry.setValue(0.5, slot: node.identifier, code: .emuFontSize)
        node.applyParameters(from: registry)   // must not trap
    }
}

/// The four controls added from the disc's own attribute vocabulary.
final class TitlerExtraControlTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    func testEdgingUsesScalasOwnWords() {
        // Counted from Scala's scripts: shadow 197, edge 40, bevel 14, none 3. All four
        // are words it really accepts; none of them is invented.
        XCTAssertEqual(ScalaLingo.edgeStyles, ["none", "shadow", "edge", "bevel"])

        let panel = ScalaTitlerPanel()
        var seen: Set<String> = []
        for step in 0...40 {
            _ = panel.set(.decoration, to: Double(step) / 40.0)
            seen.insert(panel.readout(for: .decoration))
        }
        XCTAssertEqual(seen.count, 4, "every edge style must be reachable")
    }

    func testAlignmentEdgeAndItalicsArriveAsONELine() {
        // Scala takes them together. Sent as three lines the last one wins and the
        // other two are silently discarded, which looks like two broken controls.
        let panel = ScalaTitlerPanel()
        _ = panel.set(.alignment, to: 1)      // right
        _ = panel.set(.decoration, to: 1)     // bevel
        let lines = panel.set(.italic, to: 1).map(\.line)

        guard let attributes = lines.first(where: { $0.hasPrefix("ATTRIBUTES") }) else {
            return XCTFail("expected an ATTRIBUTES line, got \(lines)")
        }
        XCTAssertTrue(attributes.contains("right"))
        XCTAssertTrue(attributes.contains("bevel"))
        XCTAssertTrue(attributes.contains("italics"))
        XCTAssertEqual(
            lines.filter { $0.hasPrefix("ATTRIBUTES") }.count, 1,
            "one line, not three")
    }

    func testNoneMeansNoEdgeWordAtAll() {
        // "none" is a real choice in Scala's scripts, and it is expressed by the word
        // being ABSENT rather than by sending "none".
        let panel = ScalaTitlerPanel()
        let lines = panel.set(.decoration, to: 0).map(\.line)
        let attributes = lines.first { $0.hasPrefix("ATTRIBUTES") } ?? ""
        XCTAssertFalse(attributes.contains("none"))
        XCTAssertFalse(attributes.contains("shadow"))
    }

    func testTheBarIsOffAtTheBottomOfItsFader() {
        // A bar of one pixel is not what "no bar" means, and a fader whose bottom is
        // "almost off" is one you cannot turn off.
        let panel = ScalaTitlerPanel()
        XCTAssertFalse(
            panel.set(.box, to: 0).contains { $0.verb == "BOX" },
            "the bottom of the fader must draw no bar at all")
        XCTAssertTrue(
            panel.set(.box, to: 0.6).contains { $0.verb == "BOX" },
            "and anywhere else must")
        XCTAssertEqual(panel.readout(for: .box), "60%")
    }

    func testABackdropIsUnavailableUntilTheDiscHasBeenRead() {
        // The rule this whole control set exists to enforce: a fader that picks between
        // names that are not there is worse than no fader.
        let panel = ScalaTitlerPanel()
        XCTAssertNotNil(panel.unavailableReason(for: .backdrop))
        XCTAssertTrue(panel.set(.backdrop, to: 0.5).isEmpty)

        panel.backdrops = ["CUCD19:Scala/Backgrounds/Stones005",
                           "CUCD19:Scala/Backgrounds/Fabrics001"]
        XCTAssertNil(panel.unavailableReason(for: .backdrop))
        let lines = panel.set(.backdrop, to: 0).map(\.line)
        XCTAssertEqual(lines.first, "PICTURE \"CUCD19:Scala/Backgrounds/Stones005\"")
        XCTAssertEqual(lines.last, "SHOW", "or the background changes on the next draw")
    }

    func testEveryControlStillReachesSomethingReal() {
        // The whole set, including the four new ones. A control that produces no
        // command and gives no reason is the failure mode this file guards.
        let panel = ScalaTitlerPanel()
        panel.backdrops = ["CUCD19:Scala/Backgrounds/Stones005"]
        panel.pageNames = ["Opening", "Titles"]
        panel.setBrush(file: "CUCD19:Scala/Symbols/Scala/MM300Stamp")

        for control in ScalaTitlerPanel.controls {
            if let reason = panel.unavailableReason(for: control.function) {
                XCTFail("\(control.name) is unavailable with everything loaded: \(reason)")
                continue
            }
            let commands = panel.set(control.function, to: 0.7)
            XCTAssertFalse(commands.isEmpty, "\(control.name) produced nothing")
            for command in commands {
                XCTAssertFalse(command.line.isEmpty)
                XCTAssertFalse(command.explanation.isEmpty)
            }
        }
    }
}

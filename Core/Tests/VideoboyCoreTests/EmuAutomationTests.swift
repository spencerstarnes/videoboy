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

//
//  MIDIDetectFilterTests.swift — a button learns a button.
//
//  Learning is done by touching the control you want, and on a controller that streams
//  — a knob being nudged, an LFO on a CC — the first message to arrive is very often
//  NOT the one you meant. Without a filter, arming a pad and reaching for it is a coin
//  toss against every knob you brush on the way.
//

import XCTest
@testable import VideoboyCore

final class MIDIDetectFilterTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    private func makeInput() -> (MIDIInput, ParamRegistry) {
        let registry = ParamRegistry()
        return (MIDIInput(registry: registry), registry)
    }

    func testAFaderLearnsAKnob() {
        let (midi, registry) = makeInput()
        midi.beginDetect(slot: "fx.a.colour", code: .brightness)
        midi.handle(event: ControlEvent(
            source: .midiControlChange(channel: 0, controller: 21), value: 0.5))
        XCTAssertEqual(registry.bindings.count, 1)
        XCTAssertFalse(midi.isDetecting)
    }

    func testAButtonIGNORESAKnob() {
        // THE case this exists for. A knob brushed on the way to the pad must not take
        // the mapping.
        let (midi, registry) = makeInput()
        midi.beginDetect(slot: "mix.primary", code: .cutTrigger, accepting: .notesOnly)

        midi.handle(event: ControlEvent(
            source: .midiControlChange(channel: 0, controller: 21), value: 0.5))
        XCTAssertTrue(registry.bindings.isEmpty, "a knob must not map to a button")
        XCTAssertTrue(midi.isDetecting, "and the learn must still be waiting")

        midi.handle(event: ControlEvent(
            source: .midiNote(channel: 0, note: 36), value: 1))
        XCTAssertEqual(registry.bindings.count, 1, "the pad takes it")
        XCTAssertEqual(registry.bindings.first?.source, .midiNote(channel: 0, note: 36))
        XCTAssertFalse(midi.isDetecting)
    }

    func testARejectedEventStillDoesItsOwnJob() {
        // The knob is ignored BY THE LEARN, not swallowed. If it is already mapped to
        // something it must keep driving it — otherwise arming a button silently
        // freezes half the controller.
        let (midi, registry) = makeInput()
        let knob = ControlSource.midiControlChange(channel: 0, controller: 21)
        registry.register(
            slot: "fx.a.colour",
            parameters: [Parameter(code: .brightness, range: 0...1, defaultValue: 0)])
        registry.bind(ControlBinding(source: knob, slot: "fx.a.colour", code: .brightness))

        midi.beginDetect(slot: "mix.primary", code: .cutTrigger, accepting: .notesOnly)
        midi.handle(event: ControlEvent(source: knob, value: 0.75))

        XCTAssertEqual(
            registry.value(slot: "fx.a.colour", code: .brightness) ?? 0, 0.75, accuracy: 0.001,
            "the knob still drives what it was already mapped to")
    }

    func testCancellingClearsTheFilterToo() {
        // A filter left set would make the NEXT learn — on a fader — silently refuse
        // knobs, which is the same bug pointing the other way.
        let (midi, registry) = makeInput()
        midi.beginDetect(slot: "mix.primary", code: .cutTrigger, accepting: .notesOnly)
        midi.cancelDetect()

        midi.beginDetect(slot: "fx.a.colour", code: .brightness)
        midi.handle(event: ControlEvent(
            source: .midiControlChange(channel: 0, controller: 21), value: 0.5))
        XCTAssertEqual(registry.bindings.count, 1)
    }

    func testCompletingClearsTheFilterToo() {
        let (midi, registry) = makeInput()
        midi.beginDetect(slot: "mix.primary", code: .cutTrigger, accepting: .notesOnly)
        midi.handle(event: ControlEvent(source: .midiNote(channel: 0, note: 36), value: 1))

        midi.beginDetect(slot: "fx.a.colour", code: .brightness)
        midi.handle(event: ControlEvent(
            source: .midiControlChange(channel: 0, controller: 21), value: 0.5))
        XCTAssertEqual(registry.bindings.count, 2, "the second learn accepted a knob")
    }

    func testEachFilterSaysWhatToDo() {
        // The status line shows this. "Press a button or pad" is the difference between
        // a learn that works first time and one where nobody knows why it did not.
        XCTAssertEqual(MIDIInput.DetectFilter.anything.prompt, "move a control")
        XCTAssertTrue(MIDIInput.DetectFilter.notesOnly.prompt.contains("button"))
    }
}

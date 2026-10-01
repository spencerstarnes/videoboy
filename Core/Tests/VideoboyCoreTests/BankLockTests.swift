//
//  BankLockTests.swift — that LOCK refuses exactly one side, and never Program.
//
//  The failures that matter: a locked side that still answers its controller, a
//  lock that also freezes Program (so the locked bank cannot be taken off air), a
//  lock that cannot be undone from the controller that set it, and a per-channel
//  node nobody told the lock about.
//

import XCTest
@testable import VideoboyCore

final class BankLockTests: XCTestCase {

    func testEverySlotOnASideBelongsToThatSide() {
        let ab = [
            GraphTopology.sourceA, GraphTopology.sourceB, GraphTopology.subMixOne, "mix.one.isf",
            "generator.a", "generator.b", "generator.isf.a", "generator.isf.b",
            "fx.a.colour", "fx.b.freeze", "fx.one.composite", "fx.one.isf-kaleido-2"
        ]
        let cd = [
            GraphTopology.sourceC, GraphTopology.sourceD, GraphTopology.subMixTwo, "mix.two.isf",
            "generator.c", "generator.isf.d", "fx.c.colour", "fx.d.freeze", "fx.two.transform"
        ]
        for slot in ab { XCTAssertEqual(BankLock.bank(forSlot: slot, code: .wetDry), .ab, slot) }
        for slot in cd { XCTAssertEqual(BankLock.bank(forSlot: slot, code: .wetDry), .cd, slot) }
    }

    func testProgramTransportSharedSourcesAndTheLockKeysBelongToNoSide() {
        for slot in [GraphTopology.primary, "mix.primary.isf", "source.emu", "source.capture.cam-1",
                     BankLock.slot, "transport", "fx.onefold.x"] {
            XCTAssertNil(BankLock.bank(forSlot: slot, code: .wetDry), slot)
        }
        XCTAssertNil(BankLock.bank(forSlot: BankLock.clipPadSlot, code: .clipPadHotPunch))
    }

    func testPadsSplitFourAndFour() {
        let lock = BankLock()
        lock.setLocked(true, .ab)
        XCTAssertTrue((0..<4).allSatisfy { lock.refuses(padIndex: $0) })
        XCTAssertFalse((4..<8).contains { lock.refuses(padIndex: $0) })
        XCTAssertTrue(lock.refuses(slot: BankLock.clipPadSlot, code: ParamCode.clipPadPresses[3]))
        XCTAssertTrue(lock.refuses(slot: BankLock.clipPadSlot, code: ParamCode.clipPadTakes[0]))
        XCTAssertTrue(lock.refuses(slot: BankLock.clipPadSlot, code: .clipPadLeftSide))
        XCTAssertFalse(lock.refuses(slot: BankLock.clipPadSlot, code: ParamCode.clipPadPresses[4]))
        XCTAssertFalse(lock.refuses(slot: BankLock.clipPadSlot, code: .clipPadRightSide))
        XCTAssertFalse(lock.refuses(slot: BankLock.clipPadSlot, code: .clipPadHotPunch))
    }

    func testChannelsFollowTheirSide() {
        let lock = BankLock()
        lock.setLocked(true, .cd)
        XCTAssertEqual(["A", "B", "C", "D"].map { lock.refuses(channel: $0) }, [false, false, true, true])
        lock.setLocked(false, .cd)
        XCTAssertFalse(lock.refuses(channel: "C"))
    }

    func testOnChangeFiresOnlyOnARealChange() {
        let lock = BankLock()
        var events: [(Bank, Bool)] = []
        lock.onChange = { events.append(($0, $1)) }
        lock.setLocked(true, .ab)
        lock.setLocked(true, .ab)
        lock.toggle(.ab)
        XCTAssertEqual(events.map(\.0), [.ab, .ab])
        XCTAssertEqual(events.map(\.1), [true, false])
    }

    /// The registry end to end: a locked side's knob does nothing, Program's still
    /// works, the LOCK key's own mapping still unlocks, and unlocking restores it.
    func testALockedSideIgnoresItsController() {
        let registry = ParamRegistry()
        let lock = BankLock()
        registry.refusesDelivery = { lock.refuses(slot: $0, code: $1) }
        registry.register(slot: "fx.a.colour", parameters: [Parameter(code: .wetDry)])
        registry.register(slot: GraphTopology.primary, parameters: [Parameter(code: .crossfadeOneTwo)])
        registry.register(slot: BankLock.slot, parameters: [Parameter(code: .bankLockAB)])
        let knob = ControlSource.midiControlChange(channel: 0, controller: 1)
        let programKnob = ControlSource.midiControlChange(channel: 0, controller: 2)
        let lockNote = ControlSource.midiControlChange(channel: 0, controller: 3)
        registry.bind(ControlBinding(source: knob, slot: "fx.a.colour", code: .wetDry))
        registry.bind(ControlBinding(source: programKnob, slot: GraphTopology.primary, code: .crossfadeOneTwo))
        registry.bind(ControlBinding(source: lockNote, slot: BankLock.slot, code: .bankLockAB))

        lock.setLocked(true, .ab)
        XCTAssertTrue(registry.deliver(normalisedValue: 0.7, from: knob).isEmpty)
        XCTAssertEqual(registry.value(slot: "fx.a.colour", code: .wetDry), 0)
        XCTAssertEqual(registry.deliver(normalisedValue: 0.6, from: programKnob).count, 1)
        XCTAssertEqual(registry.value(slot: GraphTopology.primary, code: .crossfadeOneTwo), 0.6)
        XCTAssertEqual(registry.deliver(normalisedValue: 1, from: lockNote).count, 1)

        lock.setLocked(false, .ab)
        registry.deliver(normalisedValue: 0.7, from: knob)
        XCTAssertEqual(registry.value(slot: "fx.a.colour", code: .wetDry), 0.7)
    }

    func testTheLockCodesAreInTheTable() {
        XCTAssertEqual(ParamCode(rawValue: "6CJ"), .bankLockAB)
        XCTAssertEqual(ParamCode(rawValue: "6DJ"), .bankLockCD)
        XCTAssertEqual(BankLock.code(for: .cd), .bankLockCD)
    }
}

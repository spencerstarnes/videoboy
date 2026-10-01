//
//  BankLock.swift — LOCK: which controls a locked bank refuses (setlist plan §7).
//
//  Purpose : A bank is one side of the mixer — A/B (sources A and B, their FX, the
//            A/B sub-mix, pads 1–4) or C/D. LOCK freezes everything that can change
//            that side's picture, so a bank that is on air, or about to be, cannot be
//            knocked by a stray click, key or controller. The picture itself keeps
//            running: clips play, LFOs and sweeps move, and Program can still take the
//            locked bank to air or away from it.
//  Inputs  : `setLocked` from the LOCK keys (click or MIDI 6CJ/6DJ).
//  Outputs : answers — `refuses(slot:code:)` for MIDI (ParamRegistry asks it before
//            delivering), `refuses(channel:)` for loads, `refuses(padIndex:)` for pads.
//  Connects: ParamRegistry.refusesDelivery, the App's BankLockController (clicks,
//            keys, loads, the padlocks), the slot names in GraphTopology and Engine.
//  Extend  : a new per-channel node needs its slot named in `bank(forSlot:code:)`,
//            with a test — otherwise LOCK will quietly let it through.
//
//  Never saved: Videoboy always launches unlocked, and a lock is never part of a
//  template or a Setlist.
//

import Foundation

/// One side of the mixer.
public enum Bank: String, CaseIterable, Sendable {
    case ab
    case cd

    /// The two channels it mixes.
    public var channels: [String] { self == .ab ? ["A", "B"] : ["C", "D"] }
    /// Its sub-mix slot.
    public var subMix: String { self == .ab ? GraphTopology.subMixOne : GraphTopology.subMixTwo }
    /// Its effect bus lane in slot names (`fx.one.*`, `fx.two.*`).
    var lane: String { self == .ab ? "one" : "two" }
    /// Its Clip Pads, 0-based: 1–4 or 5–8.
    public var padIndices: Range<Int> { self == .ab ? 0..<4 : 4..<8 }
    /// "A/B" or "C/D", as the window writes it.
    public var displayName: String { self == .ab ? "A/B" : "C/D" }

    /// The bank a channel letter belongs to.
    public static func containing(channel: String) -> Bank? {
        switch channel.uppercased() {
        case "A", "B": .ab
        case "C", "D": .cd
        default: nil
        }
    }
}

/// Which banks are locked, and what that refuses.
public final class BankLock {

    /// The registry slot the LOCK keys' own codes live on. Never refused, so a locked
    /// bank can always be unlocked from the controller that locked it.
    public static let slot = "bankLock"
    /// The Clip Pads' slot (`ClipPadController.slot` in the App) — pads belong to no node.
    public static let clipPadSlot = "clipPads"

    public private(set) var locked: Set<Bank> = []

    /// Called after a bank locks or unlocks.
    public var onChange: ((Bank, Bool) -> Void)?

    public init() {}

    public func isLocked(_ bank: Bank) -> Bool { locked.contains(bank) }

    public func setLocked(_ isLocked: Bool, _ bank: Bank) {
        guard isLocked != locked.contains(bank) else { return }
        if isLocked { locked.insert(bank) } else { locked.remove(bank) }
        Log.info(.param, "\(bank.displayName) \(isLocked ? "locked" : "unlocked")")
        onChange?(bank, isLocked)
    }

    public func toggle(_ bank: Bank) { setLocked(!isLocked(bank), bank) }

    /// The LOCK key's code for a bank: a press toggles it, like Hot Punch.
    public static func code(for bank: Bank) -> ParamCode {
        bank == .ab ? .bankLockAB : .bankLockCD
    }

    // MARK: - What a lock refuses

    /// Whether a write from a control (MIDI, OSC) to this parameter must be refused.
    public func refuses(slot: String, code: ParamCode) -> Bool {
        guard !locked.isEmpty, let bank = Self.bank(forSlot: slot, code: code) else { return false }
        return locked.contains(bank)
    }

    /// Whether loading into (or queueing for) this channel must be refused.
    public func refuses(channel: String) -> Bool {
        guard let bank = Bank.containing(channel: channel) else { return false }
        return locked.contains(bank)
    }

    /// Whether a Clip Pad (0-based) must ignore presses, drops and its side switch.
    public func refuses(padIndex: Int) -> Bool {
        locked.contains { $0.padIndices.contains(padIndex) }
    }

    /// Which bank a parameter belongs to, or nil for one no lock touches: Program,
    /// the transport, Hot Punch, the LOCK keys themselves, and sources two banks can
    /// share (the emulator, a camera).
    public static func bank(forSlot slot: String, code: ParamCode) -> Bank? {
        if slot == clipPadSlot { return bank(forPadCode: code) }
        for bank in Bank.allCases {
            let letters = bank.channels.map { $0.lowercased() }
            // The sub-mix, and its ISF transition (`mix.one.isf`).
            if slot == bank.subMix || slot.hasPrefix(bank.subMix + ".") { return bank }
            // The channels' file nodes and generators.
            for letter in letters {
                if slot == "source.\(letter)" || slot == "generator.\(letter)"
                    || slot == "generator.isf.\(letter)" { return bank }
            }
            // Effects: each channel's copy and the bus copy.
            for lane in letters + [bank.lane] where slot.hasPrefix("fx.\(lane).") { return bank }
        }
        return nil
    }

    /// The pad codes: presses and takes 1–4 / 5–8, and each side's switch.
    private static func bank(forPadCode code: ParamCode) -> Bank? {
        if code == .clipPadLeftSide { return .ab }
        if code == .clipPadRightSide { return .cd }
        if let index = ParamCode.clipPadPresses.firstIndex(of: code)
            ?? ParamCode.clipPadTakes.firstIndex(of: code) {
            return Bank.allCases.first { $0.padIndices.contains(index) }
        }
        return nil
    }
}

//
//  EffectChain.swift — a sub-mix's effect chain, as data (ISF-PLAN M5).
//
//  Purpose : The FX panel's cards ARE this list. Adding, removing and reordering a
//            card edits it, the engine rewires the graph from it, and a template
//            saves it. It used to be six hard-wired nodes per chain; the panel's
//            drag only reordered pictures of cards.
//  Inputs  : edits from the FX panel (add, remove, reorder, retarget).
//  Outputs : an ordered list of module instances, and the graph slot of each copy.
//  Connects: ModuleCatalog (what a module ID can make), Engine.rebuildChain (which
//            turns this into nodes and edges), TemplateDocument (saves it).
//  Extend  : new per-instance state (a preset name, a colour label) is a field on
//            `ChainEntry`; it is Codable, so templates carry it for free.
//
//  ORDER. `entries` is PROCESSING order: the first entry sees the picture first.
//  The panel shows it reversed, like Photoshop layers — the top card is applied last
//  (SPEC 14.2). `displayOrder` is the one place that inversion lives.
//
//  COPIES. One card is three nodes: one per channel of its sub-mix (A and B, or C
//  and D), upstream of the mix, and one on the bus, after it. The card's A / B /
//  BOTH selector (`target`) says which copy its controls edit; BOTH is the bus copy.
//  Every copy is in the graph whether or not it is targeted; an untargeted or
//  switched-off copy is bypassed and costs nothing.
//
//  SLOTS are `fx.<lane>.<instanceID>` — `fx.a.colour`, `fx.one.echo` — and the
//  default chain keeps exactly the instance IDs the hard-wired chain used, so every
//  template, mapping and LFO saved before this change still lands on the same slot.
//

import Foundation

/// One card in a chain: which module, and which copy its controls edit.
public struct ChainEntry: Codable, Equatable, Sendable {
    /// Unique within the chain; the last part of the slot name. Never reused while
    /// the instance exists, so a mapping to it cannot land on a different card.
    public var instanceID: String
    /// What it is: a `ModuleDescriptor.id`.
    public var moduleID: String
    /// 0 = the sub-mix's first channel, 1 = its second, 2 = BOTH (the bus copy).
    public var target: Int

    public init(instanceID: String, moduleID: String, target: Int = ChainEntry.both) {
        self.instanceID = instanceID
        self.moduleID = moduleID
        self.target = target
    }

    /// The `target` that means the bus copy.
    public static let both = 2
}

/// Which sub-mix a chain belongs to.
public enum ChainBus: String, Codable, CaseIterable, Sendable {
    case one
    case two

    /// The two channels that feed this sub-mix, in order.
    public var channels: [String] { self == .one ? ["A", "B"] : ["C", "D"] }
    /// The lane name of the bus copy in slot names.
    public var lane: String { rawValue }
}

/// An ordered chain of module instances.
public struct EffectChain: Codable, Equatable, Sendable {

    /// PROCESSING order: `entries[0]` sees the picture first.
    public var entries: [ChainEntry]

    public init(entries: [ChainEntry]) {
        self.entries = entries
    }

    /// The chain a fresh launch starts with: today's effects in today's signal order,
    /// MX-1 replaced by Freeze (ISF-PLAN D7). Instance IDs are the old slot suffixes.
    public static let standard = EffectChain(entries: [
        ChainEntry(instanceID: "mosh", moduleID: ModuleCatalog.ID.datamosh),
        ChainEntry(instanceID: "transform", moduleID: ModuleCatalog.ID.transform, target: 0),
        ChainEntry(instanceID: "colour", moduleID: ModuleCatalog.ID.colour),
        ChainEntry(instanceID: "composite", moduleID: ModuleCatalog.ID.composite, target: 0),
        ChainEntry(instanceID: "echo", moduleID: ModuleCatalog.ID.echo, target: 0),
        ChainEntry(instanceID: "feedback", moduleID: ModuleCatalog.ID.feedback, target: 0),
        ChainEntry(instanceID: "freeze", moduleID: ModuleCatalog.ID.freeze, target: 0)
    ])

    // MARK: - Reading

    /// The order the panel shows, top to bottom: the reverse of processing order.
    public var displayOrder: [ChainEntry] { entries.reversed() }

    public func entry(_ instanceID: String) -> ChainEntry? {
        entries.first { $0.instanceID == instanceID }
    }

    /// The graph slot of one copy of an instance. `lane` is a channel letter or the
    /// bus lane (`one` / `two`).
    public static func slot(instanceID: String, lane: String) -> String {
        "fx.\(lane.lowercased()).\(instanceID)"
    }

    /// Every slot an instance occupies on a bus: each channel's copy, then the bus copy.
    public static func slots(instanceID: String, bus: ChainBus) -> [String] {
        bus.channels.map { slot(instanceID: instanceID, lane: $0) } + [slot(instanceID: instanceID, lane: bus.lane)]
    }

    /// The slot a card's controls currently edit, from its target.
    public static func targetedSlot(of entry: ChainEntry, bus: ChainBus) -> String {
        let channels = bus.channels
        let lane = entry.target < channels.count ? channels[entry.target] : bus.lane
        return slot(instanceID: entry.instanceID, lane: lane)
    }

    // MARK: - Editing

    /// Adds an instance of a module FIRST in processing order — the bottom card —
    /// so adding never moves the cards already on screen. Returns the new entry.
    @discardableResult
    public mutating func add(moduleID: String, preferredID: String? = nil) -> ChainEntry {
        let entry = ChainEntry(instanceID: newInstanceID(for: moduleID, preferred: preferredID), moduleID: moduleID)
        entries.insert(entry, at: 0)
        return entry
    }

    /// Removes an instance. Returns whether it was there.
    @discardableResult
    public mutating func remove(_ instanceID: String) -> Bool {
        let before = entries.count
        entries.removeAll { $0.instanceID == instanceID }
        return entries.count != before
    }

    /// Reorders to match the panel's new TOP-TO-BOTTOM order. IDs not in the chain
    /// are ignored; entries the list leaves out follow the listed ones, in their
    /// previous on-screen order — so a stale drag can never drop a card.
    public mutating func reorder(displayOrder ids: [String]) {
        let listed = ids.compactMap { id in entries.first { $0.instanceID == id } }
        let listedIDs = Set(listed.map(\.instanceID))
        let rest = displayOrder.filter { !listedIDs.contains($0.instanceID) }
        entries = Array((listed + rest).reversed())
    }

    /// Points a card at a channel's copy or the bus copy.
    public mutating func setTarget(_ target: Int, of instanceID: String) {
        guard let index = entries.firstIndex(where: { $0.instanceID == instanceID }) else { return }
        entries[index].target = max(0, min(target, ChainEntry.both))
    }

    /// An instance ID not yet used in this chain: `preferred` if free, else the
    /// module's short name, then `-2`, `-3`…
    public func newInstanceID(for moduleID: String, preferred: String? = nil) -> String {
        let taken = Set(entries.map(\.instanceID))
        if let preferred, !taken.contains(preferred) { return preferred }
        let base = EffectChain.slug(moduleID)
        if !taken.contains(base) { return base }
        var number = 2
        while taken.contains("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }

    /// A module ID reduced to slot-safe characters: `isf.Bad TV` → `isf-bad-tv`.
    static func slug(_ moduleID: String) -> String {
        let lowered = moduleID.lowercased()
        var result = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "module" : result
    }
}

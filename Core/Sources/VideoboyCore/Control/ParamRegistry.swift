//
//  ParamRegistry.swift — resolves param codes to live parameters (SPEC 13).
//
//  Purpose : Holds the parameters a node currently exposes, and lets a mapping find
//            one by code. The critical property, which the tests pin down: swapping
//            the module in a slot preserves every mapping whose code still exists,
//            and quietly keeps (rather than deletes) the ones whose code does not.
//  Inputs  : node registrations; mappings; incoming control values.
//  Outputs : parameter values delivered to nodes.
//  Connects: ParamCode (the table), templates (which serialise mappings by code),
//            the control bus (MIDI/OSC/audio-reactivity all land here).
//  Extend  : a new control source becomes a new `ControlBinding.source`, not a new
//            registry.
//

import Foundation

/// A parameter a node exposes.
public struct Parameter {
    public let code: ParamCode
    /// Inclusive value range in natural units.
    public let range: ClosedRange<Double>
    /// Value when nothing has set it.
    public let defaultValue: Double

    public init(code: ParamCode, range: ClosedRange<Double> = 0...1, defaultValue: Double = 0) {
        self.code = code
        self.range = range
        self.defaultValue = defaultValue
    }

    /// Maps a normalised 0...1 control value into this parameter's range.
    public func denormalise(_ normalised: Double) -> Double {
        let clamped = min(max(normalised, 0), 1)
        return range.lowerBound + clamped * (range.upperBound - range.lowerBound)
    }
}

/// Where a mapped control value came from. Every source normalises to 0...1 here,
/// so the registry needs no per-source special cases (SPEC 7).
public enum ControlSource: Equatable, Codable, Sendable {
    /// A MIDI Control Change: channel 0...15, controller number 0...127.
    case midiControlChange(channel: UInt8, controller: UInt8)
    /// A MIDI Note, used as a momentary or toggle.
    case midiNote(channel: UInt8, note: UInt8)
    /// An OSC address pattern.
    case osc(address: String)
    /// An audio-reactivity tap: RMS, a frequency band, or onset flags.
    case audioReactivity(tap: String)

    /// Short text for the status bar and templates.
    public var description: String {
        switch self {
        case .midiControlChange(let channel, let controller): "midi cc \(channel + 1)/\(controller)"
        case .midiNote(let channel, let note): "midi note \(channel + 1)/\(note)"
        case .osc(let address): "osc \(address)"
        case .audioReactivity(let tap): "audio \(tap)"
        }
    }
}

/// One mapping: a control source bound to a parameter code on a named slot.
///
/// The slot is a stable name like "subMixOne.fx0", not a pointer. Slot plus code is
/// the whole address, which is what lets a module be swapped underneath it.
public struct ControlBinding: Equatable, Codable, Sendable {
    public let source: ControlSource
    public let slot: String
    public let code: ParamCode

    public init(source: ControlSource, slot: String, code: ParamCode) {
        self.source = source
        self.slot = slot
        self.code = code
    }
}

/// The registry: which slots exist, what parameters each exposes, and what is mapped.
public final class ParamRegistry {

    /// Parameters currently exposed by each slot.
    private var parametersBySlot: [String: [ParamCode: Parameter]] = [:]
    /// Current values, by slot and code.
    private var valuesBySlot: [String: [ParamCode: Double]] = [:]
    /// Every mapping, including ones whose code is not currently resolvable.
    private(set) public var bindings: [ControlBinding] = []

    public init() {}

    // MARK: - Slots

    /// Declares the parameters a slot exposes, replacing whatever was there.
    ///
    /// This is what a module swap calls. Values for codes that still exist are kept,
    /// so a swap does not reset the controls the performer has already set.
    public func register(slot: String, parameters: [Parameter]) {
        let previousValues = valuesBySlot[slot] ?? [:]
        var table: [ParamCode: Parameter] = [:]
        var values: [ParamCode: Double] = [:]
        for parameter in parameters {
            table[parameter.code] = parameter
            // Carry a previous value across the swap when the code survives.
            values[parameter.code] = previousValues[parameter.code] ?? parameter.defaultValue
        }
        parametersBySlot[slot] = table
        valuesBySlot[slot] = values

        let carried = previousValues.keys.filter { table[$0] != nil }.count
        let dropped = previousValues.keys.filter { table[$0] == nil }.count
        Log.info(.param, "slot '\(slot)' now exposes \(parameters.count) params (\(carried) values carried, \(dropped) dropped)")
    }

    /// Parameter codes a slot currently exposes.
    public func codes(inSlot slot: String) -> Set<ParamCode> {
        Set((parametersBySlot[slot] ?? [:]).keys)
    }

    // MARK: - Values

    /// Current value of a parameter, or nil if the slot does not expose that code.
    public func value(slot: String, code: ParamCode) -> Double? {
        valuesBySlot[slot]?[code]
    }

    /// Sets a parameter from a natural-units value. Ignored, with a warning, when the
    /// slot does not expose the code — a stale mapping must never crash a show.
    @discardableResult
    public func setValue(_ value: Double, slot: String, code: ParamCode) -> Bool {
        guard let parameter = parametersBySlot[slot]?[code] else {
            Log.warn(.param, "no parameter \(code.rawValue) in slot '\(slot)'; value ignored")
            return false
        }
        let clamped = min(max(value, parameter.range.lowerBound), parameter.range.upperBound)
        valuesBySlot[slot]?[code] = clamped
        return true
    }

    // MARK: - Mappings

    /// Adds a mapping, replacing any existing one for the same control source.
    ///
    /// One physical control drives one parameter: re-learning a knob moves it rather
    /// than stacking a second binding on it.
    public func bind(_ binding: ControlBinding) {
        bindings.removeAll { $0.source == binding.source }
        bindings.append(binding)
        Log.info(.param, "mapped \(binding.source.description) -> \(binding.slot)/\(binding.code.rawValue)")
    }

    /// Removes any mapping for a control source.
    public func unbind(source: ControlSource) {
        bindings.removeAll { $0.source == source }
    }

    /// Delivers a normalised 0...1 control value to whatever it is mapped to.
    ///
    /// - Returns: the bindings that actually resolved to a live parameter. A mapping
    ///   whose code is not currently exposed resolves to nothing and is skipped —
    ///   but it is *kept*, so swapping the module back restores it.
    @discardableResult
    public func deliver(normalisedValue: Double, from source: ControlSource) -> [ControlBinding] {
        var applied: [ControlBinding] = []
        for binding in bindings where binding.source == source {
            guard let parameter = parametersBySlot[binding.slot]?[binding.code] else { continue }
            setValue(parameter.denormalise(normalisedValue), slot: binding.slot, code: binding.code)
            applied.append(binding)
        }
        return applied
    }

    /// Mappings that currently resolve to a live parameter.
    public var resolvableBindings: [ControlBinding] {
        bindings.filter { parametersBySlot[$0.slot]?[$0.code] != nil }
    }

    /// Mappings kept but not currently resolvable, because the slot no longer exposes
    /// that code. Shown greyed in the UI rather than deleted (SPEC 16: unknown keys
    /// are preserved, not fatal).
    public var danglingBindings: [ControlBinding] {
        bindings.filter { parametersBySlot[$0.slot]?[$0.code] == nil }
    }
}

//
//  ISFControl.swift — an ISF input as controls the rest of Videoboy can address.
//
//  Purpose : An ISF input is a name and a type. A card needs faders, the registry
//            needs codes and ranges, MIDI and LFOs need something 0...1 to push.
//            This turns each input into controls: one per scalar, one per component
//            of a colour (R G B A) or a point (X Y), each with a stable param code.
//  Inputs  : a parsed `ISFDocument`.
//  Outputs : `[ISFControl]`, in file order.
//  Connects: ISFNode (declares them as its parameters and applies them), the FX
//            cards (one fader per control), ParamCode (the codes).
//  Extend  : a new input type is a case in `controls(for:)` and in `valueText`.
//
//  CODES (SPEC 13, ISF-PLAN §3.4): an input that declares `"VIDEOBOY_CODE"` uses
//  that code — this is how the built-in ports keep 51A, 11A… and with them every
//  saved template and mapping. Any other input gets `x:<NAME>`, and a component of a
//  colour or point `x:<NAME>.r` / `.x` and so on. Stable while the input keeps its
//  name, and shared by every module that has an input of that name.
//
//  EVERY TYPE IS A FADER. A bool is on above halfway, a `long` steps through its
//  VALUES, an event fires as the fader crosses halfway. One control type means MIDI
//  learn, LFOs, audio, beat sweeps and templates all work on every input with no
//  per-type code — and the readout says what the value MEANS (`valueText`).
//

import Foundation

/// One addressable control of an ISF input.
public struct ISFControl: Equatable, Sendable {
    public let code: ParamCode
    /// The ISF input this belongs to.
    public let inputName: String
    /// Which component of that input (0 for scalars).
    public let component: Int
    /// What the card shows: the input's LABEL (or NAME), plus the component.
    public let label: String
    public let type: ISFInputType
    public let range: ClosedRange<Double>
    public let defaultValue: Double
    /// For a `long`: the allowed values and what to call each one.
    public let choices: [Choice]

    public struct Choice: Equatable, Sendable {
        public let value: Double
        public let label: String
    }

    /// Every control a document declares, in file order.
    public static func controls(for document: ISFDocument) -> [ISFControl] {
        var result: [ISFControl] = []
        var seen: Set<ParamCode> = []
        for input in document.valueInputs {
            let base = input.label.isEmpty ? input.name : input.label
            switch input.type {
            case .float, .bool, .event, .long:
                let code = declaredCode(input) ?? .isolated(inputName: input.name)
                let choices: [Choice] = input.type == .long
                    ? input.values.enumerated().map { index, value in
                        Choice(value: Double(value),
                               label: index < input.labels.count ? input.labels[index] : "\(value)")
                    }
                    : []
                result.append(ISFControl(
                    code: code, inputName: input.name, component: 0, label: base, type: input.type,
                    range: ISFNode.range(of: input), defaultValue: input.defaultValue.first ?? 0,
                    choices: choices))
            case .color, .point2D:
                let names = input.type == .color ? ["r", "g", "b", "a"] : ["x", "y"]
                for (component, suffix) in names.enumerated() where component < input.componentCount {
                    let low = input.minimum?[safe: component] ?? 0
                    let fallbackHigh = input.type == .color ? 1.0 : max(1, (input.defaultValue[safe: component] ?? 0) * 2)
                    let high = input.maximum?[safe: component] ?? fallbackHigh
                    result.append(ISFControl(
                        code: .isolated(inputName: "\(input.name).\(suffix)"), inputName: input.name,
                        component: component, label: "\(base) \(suffix.uppercased())", type: input.type,
                        range: low...max(low, high),
                        defaultValue: input.defaultValue[safe: component] ?? 0, choices: []))
                }
            case .image, .audio, .audioFFT:
                continue
            }
        }
        // Two inputs claiming one code would make one of them unreachable; keep the
        // first and say so, rather than letting a fader silently drive the wrong input.
        return result.filter { control in
            guard seen.insert(control.code).inserted else {
                Log.warn(.isf, "'\(document.name)' declares \(control.code.rawValue) twice; '\(control.inputName)' is not addressable")
                return false
            }
            return true
        }
    }

    private static func declaredCode(_ input: ISFInput) -> ParamCode? {
        guard let raw = input.videoboyCode else { return nil }
        guard let code = ParamCode(rawValue: raw) else {
            Log.warn(.isf, "input '\(input.name)' declares unknown code \(raw); using x:\(input.name)")
            return nil
        }
        return code
    }

    /// A registry value made legal for this control: a `long` snaps to its nearest
    /// VALUE, a bool or event to 0 or 1.
    public func snapped(_ value: Double) -> Double {
        switch type {
        case .long:
            guard let nearest = choices.min(by: { abs($0.value - value) < abs($1.value - value) }) else { return value }
            return nearest.value
        case .bool, .event:
            return value > 0.5 ? 1 : 0
        default:
            return value
        }
    }

    /// What the readout shows for a value: "on", a choice's LABEL, or the number.
    public func valueText(_ value: Double) -> String {
        switch type {
        case .bool: return value > 0.5 ? "on" : "off"
        case .event: return value > 0.5 ? "fire" : "—"
        case .long:
            let target = snapped(value)
            return choices.first { $0.value == target }?.label ?? String(format: "%.0f", target)
        default:
            return String(format: "%.2f", value)
        }
    }
}

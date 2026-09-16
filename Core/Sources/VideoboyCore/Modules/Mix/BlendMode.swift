//
//  BlendMode.swift — the layer blend modes (SPEC 12).
//
//  Purpose : Every composite in the graph — ONE = A over B, TWO = C over D,
//            PRIMARY = ONE over TWO — carries one of these. The raw values are the
//            contract with the Metal shader and must not be reordered.
//  Inputs  : a 0...1 parameter, or a name from a template.
//  Outputs : a mode, and its shader index.
//  Connects: CrossfadeNode, MetalContext.blendPipeline, the blend popup in the UI.
//  Extend  : append a case AND add the matching branch to `blendChannelwise` in the
//            Metal source. Never renumber an existing one — a saved template stores
//            the index, and renumbering would silently change what old work looks like.
//

import Foundation

/// How a layer combines with the one beneath it.
public enum BlendMode: Int, CaseIterable, Codable, Sendable {
    case normal = 0
    case multiply = 1
    case screen = 2
    case overlay = 3
    case lighten = 4
    case darken = 5
    case difference = 6
    case add = 7
    case subtract = 8
    case colorDodge = 9
    case colorBurn = 10
    case hardLight = 11
    case softLight = 12

    /// Name shown in the blend popup and written into templates.
    public var displayName: String {
        switch self {
        case .normal: "Normal"
        case .multiply: "Multiply"
        case .screen: "Screen"
        case .overlay: "Overlay"
        case .lighten: "Lighten"
        case .darken: "Darken"
        case .difference: "Difference"
        case .add: "Add"
        case .subtract: "Subtract"
        case .colorDodge: "Color Dodge"
        case .colorBurn: "Color Burn"
        case .hardLight: "Hard Light"
        case .softLight: "Soft Light"
        }
    }

    /// Selects a mode from a 0...1 parameter (code `65A`).
    public static func from(normalised value: Double) -> BlendMode {
        let all = allCases
        let clamped = min(max(value, 0), 1)
        let index = Int((clamped * Double(all.count - 1)).rounded())
        return all[min(index, all.count - 1)]
    }

    /// Where this mode sits on a 0...1 parameter, for driving the UI from a value.
    public var normalisedPosition: Double {
        let all = BlendMode.allCases
        guard all.count > 1, let index = all.firstIndex(of: self) else { return 0 }
        return Double(index) / Double(all.count - 1)
    }
}

//
//  BlendMode.swift — the layer blend modes (SPEC 12).
//
//  Purpose : Every composite in the graph — ONE = A over B, TWO = C over D,
//            PRIMARY = ONE over TWO — carries one of these. The raw values are the
//            contract with the Metal shader and must not be reordered.
//  Inputs  : a 0...1 parameter, or a name from a template.
//  Outputs : a mode, and its shader index.
//  Connects: CrossfadeNode, MetalContext.blendPipeline, the blend popup in the UI.
//  Extend  : a plain colour-math mode is a case here plus a branch in
//            `blendChannelwise` in the Metal source. A mode that needs its own
//            parameters — as `.key` does, for a key colour/threshold/edge that do
//            not fit `blendChannelwise`'s (mode, base, blend) shape — gets its own
//            function instead, called from `composite_blend_fragment` ahead of
//            `blendChannelwise`, keyed off the same `p.mode`. Never renumber an
//            existing one — a saved template stores the index, and renumbering
//            would silently change what old work looks like.
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
    /// Genlock/chroma key: the blend layer's pixels near `keyColour` (6xE) drop out
    /// to reveal the base layer; everything else covers it. This is how the
    /// emulated titler (SPEC 18.2) and any other keyable source overlay onto video
    /// rather than replacing it. See `CrossfadeNode` and `keyComposite` in the
    /// Metal source for the actual maths.
    case key = 13

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
        case .key: "Key"
        }
    }

    /// The modes grouped the way Photoshop groups them, for the menu.
    ///
    /// ── WHY THIS ORDER IS DIFFERENT FROM `allCases` ─────────────────────────────
    ///
    /// Photoshop's blend menu is not alphabetical and not arbitrary: it is grouped by
    /// WHAT THE MODE DOES TO THE PICTURE, with a separator between each group —
    /// darkening modes together, lightening modes together, contrast modes together.
    /// Every compositing application since has copied it, so anyone who has used one
    /// already knows where to look. A flat list of thirteen names does not.
    ///
    /// The groups, in Photoshop's order:
    ///   1. Normal            — no interaction
    ///   2. Darken family     — the result is never lighter than what went in
    ///   3. Lighten family    — the result is never darker
    ///   4. Contrast family   — darkens the darks and lightens the lights
    ///   5. Comparative       — the difference between the two layers
    ///   6. Keying            — not a Photoshop group; this app's own addition,
    ///                          kept last and separate because a key does not
    ///                          combine colours like the other five, it selects
    ///                          between them per pixel
    ///
    /// THIS IS THE MENU'S ORDER ONLY. `allCases` keeps the declaration order because
    /// the raw values are the shader's mode IDs and go into saved templates, and
    /// because `from(normalised:)` maps a 0...1 parameter across `allCases` — so
    /// reordering that would silently change what every saved MIDI mapping and fader
    /// sweep resolves to.
    public static let menuGroups: [[BlendMode]] = [
        [.normal],
        [.darken, .multiply, .colorBurn],
        [.lighten, .screen, .colorDodge, .add],
        [.overlay, .softLight, .hardLight],
        [.difference, .subtract],
        [.key]
    ]

    /// Every mode in menu order, flattened.
    public static var menuOrder: [BlendMode] { menuGroups.flatMap { $0 } }

    /// Selects a mode from a 0...1 parameter (code `65A`).
    public static func from(normalised value: Double) -> BlendMode {
        let all = allCases
        return all[NormalisedSweep.index(value, count: all.count)]
    }

    /// Where this mode sits on a 0...1 parameter, for driving the UI from a value.
    public var normalisedPosition: Double {
        let all = BlendMode.allCases
        guard all.count > 1, let index = all.firstIndex(of: self) else { return 0 }
        return Double(index) / Double(all.count - 1)
    }
}

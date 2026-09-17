//
//  TitlerControls.swift — the modern panel that drives vintage software.
//
//  Purpose : The translation layer. A slider, a text box or a MIDI note on this side;
//            a real command to the software's script port on the other. This is the
//            part that makes a 1990s titler playable from a 2026 control surface.
//  Inputs  : values 0...1 (so anything that already produces one — a fader, a MIDI
//            CC, an LFO, the beat clock — can drive them).
//  Outputs : `TitlerCommand`s.
//  Connects: EmulatedTitlerNode (which sends them), the EMU panel.
//  Extend  : a new control is a case here plus a line in `command(for:)`. If the
//            software cannot actually do it, it does not belong here — a slider that
//            moves and changes nothing is worse than no slider.
//
//  EVERY CONTROL HERE MAPS TO SOMETHING THE SOFTWARE REALLY DOES. That is the rule
//  this file exists to enforce. It is easy to invent a panel of plausible-looking
//  knobs; the test is whether each one becomes a command the program understands, and
//  the ones below are built from Scala's own ARexx vocabulary rather than from what
//  would look good in a screenshot.
//

import Foundation

/// One control on the titler panel.
public struct TitlerControl: Equatable, Sendable, Identifiable {
    public var id: String { name }

    public let name: String
    /// What it does, for the tooltip — in terms of the SOFTWARE, not the widget.
    public let explanation: String
    /// How a 0...1 value becomes a command.
    public let kind: Kind

    public enum Kind: Equatable, Sendable {
        /// Picks one of a set of named options — a page, a font, a wipe.
        case choice(field: String, options: [String])
        /// A number in a range the software understands.
        case number(field: String, lowest: Int, highest: Int)
        /// An Amiga palette index, 0...31.
        case colour(field: String)
    }

    public init(name: String, explanation: String, kind: Kind) {
        self.name = name
        self.explanation = explanation
        self.kind = kind
    }

    /// The command this control produces for a 0...1 value.
    ///
    /// Takes 0...1 rather than a native value so that ANYTHING already producing one
    /// can drive it — a fader, a MIDI CC, an LFO, a fader sweep on the beat. That is
    /// the whole reason the panel is worth having rather than typing ARexx by hand.
    public func command(for value: Double) -> TitlerCommand {
        let clamped = NormalisedSweep.clamp(value)
        switch kind {
        case .choice(let field, let options):
            let index = NormalisedSweep.index(clamped, count: options.count)
            return .setText(field: field, value: options[index])
        case .number(let field, let lowest, let highest):
            let span = Double(highest - lowest)
            let scaled = lowest + Int((clamped * span).rounded())
            return .raw("SET \(field) \(scaled)")
        case .colour(let field):
            return .setColour(field: field, paletteIndex: NormalisedSweep.index(clamped, count: 32))
        }
    }
}

/// The controls offered for a given program.
public enum TitlerControlSet {

    /// Scala MM300's panel.
    ///
    /// Drawn from what Scala actually exposes: it is a page-based presentation system
    /// with wipes between pages, timed transitions and a palette — so the panel is
    /// pages, wipes, timing and colour, and not a set of invented graphics knobs.
    public static let scalaMM300: [TitlerControl] = [
        TitlerControl(
            name: "page",
            explanation: "Which Scala page is on screen. Scala is page-based, so this "
                + "is the closest thing it has to a 'go to this title' control.",
            kind: .number(field: "PAGE", lowest: 1, highest: 32)
        ),
        TitlerControl(
            name: "wipe",
            explanation: "The transition Scala uses when moving between pages.",
            kind: .choice(field: "WIPE", options: [
                "CUT", "FADE", "WIPELEFT", "WIPERIGHT", "WIPEUP", "WIPEDOWN",
                "IRIS", "VENETIAN", "SCROLL", "CURTAIN"
            ])
        ),
        TitlerControl(
            name: "speed",
            explanation: "How long a wipe takes, in Scala's own units. Mapped to a "
                + "fader so a transition can be taken on the beat.",
            kind: .number(field: "WIPESPEED", lowest: 1, highest: 20)
        ),
        TitlerControl(
            name: "text col",
            explanation: "Text colour, as an index into the Amiga palette — which is "
                + "how a machine with 32 colours thinks about colour.",
            kind: .colour(field: "TEXTCOLOUR")
        ),
        TitlerControl(
            name: "back col",
            explanation: "Background colour, likewise a palette index.",
            kind: .colour(field: "BACKCOLOUR")
        )
    ]

    /// The controls for a program, or none when it has no script port to drive.
    public static func controls(for program: TitlerProgram) -> [TitlerControl] {
        guard program.scriptPort != nil else { return [] }
        switch program.name {
        case "Scala MM300": return scalaMM300
        default: return []
        }
    }
}

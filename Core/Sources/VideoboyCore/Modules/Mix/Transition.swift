//
//  Transition.swift — the shape a crossfader's move takes (MX-1 style wipes).
//
//  Purpose : A blend mode says HOW the two layers combine; a transition says WHERE
//            on the screen the incoming layer appears as the fader travels. The
//            fader position is the transition's progress — 0 is entirely the left
//            source, 1 entirely the right, for every transition — so FADE, CUT, the
//            bus keys, sweeps and MIDI all drive a wipe exactly as they drive a
//            dissolve. Nothing about the fader changes.
//  Inputs  : a 0...1 parameter (code `61F`), or a name from the menu.
//  Outputs : a transition, and its shader index.
//  Connects: CrossfadeNode, `transitionMask` in MetalContext's blend shader, the
//            transition icon on each fader panel (VBTransitionButton).
//  Extend  : a new pattern is a case here plus a branch in `transitionMask` in the
//            Metal source, and a pictogram in VBTransitionButton. Never renumber an
//            existing one — the index is what a saved setting and a MIDI sweep
//            resolve to.
//
//  ── NAMING ──────────────────────────────────────────────────────────────────────
//
//  Every pattern comes as a pair, and the word names the direction of MOTION:
//  "Wipe Horizontal" is an edge travelling left to right, "Wipe Vertical" one
//  travelling top to bottom. Left-to-right and top-to-bottom because the fader
//  travels left to right: the picture moves the way the hand does.
//
//  ── HOW BLEND MODES STILL APPLY ─────────────────────────────────────────────────
//
//  Under a wipe the area the incoming layer has reached is combined with the base
//  through the blend mode, by the same triangle the dissolve uses — full effect at
//  the middle of the travel, none at either end. So Normal is a clean MX-1 wipe, a
//  Difference wipe draws its revealed area as the difference, and both ends of the
//  fader are still the two sources untouched.
//

import Foundation

/// The pattern a crossfader move follows.
public enum Transition: Int, CaseIterable, Codable, Sendable {
    /// The whole picture mixes at once. The default, and what the fader always did.
    case dissolve = 0
    /// A hard edge sweeps left to right, revealing the right source behind it.
    case wipeHorizontal = 1
    /// A hard edge sweeps top to bottom.
    case wipeVertical = 2
    /// The right source slides in from the left, over a still left source.
    case slideHorizontal = 3
    /// The right source slides in from the top, over a still left source.
    case slideVertical = 4
    /// The right source enters from the left and shoves the left source out.
    case pushHorizontal = 5
    /// The right source enters from the top and shoves the left source out.
    case pushVertical = 6
    /// A circle opens from the centre.
    case iris = 7
    /// Barn doors: a band opens from a vertical centre line outward to both sides.
    case splitHorizontal = 8
    /// Barn doors: a band opens from a horizontal centre line up and down.
    case splitVertical = 9
    /// Alternate scan lines wipe in opposite directions — even lines left to right,
    /// odd lines right to left. One field goes one way, the other field the other,
    /// which on an interlaced output is exactly the shimmer of the old mixers.
    case interlaceHorizontal = 10
    /// Alternate vertical bands wipe in opposite directions, down and up.
    case interlaceVertical = 11

    /// Name shown in the menu and the tooltip.
    public var displayName: String {
        switch self {
        case .dissolve: "Dissolve"
        case .wipeHorizontal: "Wipe Horizontal"
        case .wipeVertical: "Wipe Vertical"
        case .slideHorizontal: "Slide Horizontal"
        case .slideVertical: "Slide Vertical"
        case .pushHorizontal: "Push Horizontal"
        case .pushVertical: "Push Vertical"
        case .iris: "Iris"
        case .splitHorizontal: "Split Horizontal"
        case .splitVertical: "Split Vertical"
        case .interlaceHorizontal: "Interlace Horizontal"
        case .interlaceVertical: "Interlace Vertical"
        }
    }

    /// The patterns grouped by family for the menu, each pair together.
    ///
    /// The iris sits with the splits because they are the same idea — the incoming
    /// picture opening out from the middle — in a circle and in two straight bands.
    public static let menuGroups: [[Transition]] = [
        [.dissolve],
        [.wipeHorizontal, .wipeVertical],
        [.slideHorizontal, .slideVertical],
        [.pushHorizontal, .pushVertical],
        [.iris, .splitHorizontal, .splitVertical],
        [.interlaceHorizontal, .interlaceVertical]
    ]

    /// Selects a transition from a 0...1 parameter (code `61F`).
    public static func from(normalised value: Double) -> Transition {
        let all = allCases
        return all[NormalisedSweep.index(value, count: all.count)]
    }

    /// Where this transition sits on a 0...1 parameter, for driving it from the UI.
    public var normalisedPosition: Double {
        let all = Transition.allCases
        guard all.count > 1, let index = all.firstIndex(of: self) else { return 0 }
        return Double(index) / Double(all.count - 1)
    }
}

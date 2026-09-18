//
//  NormalisedSweep.swift — turning a 0...1 parameter into a choice from a small set.
//
//  Purpose : A dozen enums in this app are selected by sweeping a fader across them:
//            blend mode, MX-1 effect, corrupt mode, alignment, roll mode, generator
//            kind, LFO shape, chroma subsampling. Every one of them wrote the same
//            three lines, and every one of them had the same crash in it.
//  Inputs  : a parameter value, nominally 0...1 but in practice whatever a modulation
//            source produced.
//  Outputs : a clamped value, or an index into a set.
//  Connects: BlendMode, MX1Effect, DIFCorruptor, MPEGCorruptor, GeneratorKind,
//            TitlerAlignment, TitlerWeight, TitlerRollMode, LFOShape, CompositePath,
//            ChromaSubsampling, BlackFrameInsertion — the `from(normalised:)` on each.
//  Extend  : if a new sweep needs different rounding, add a parameter here rather
//            than writing the arithmetic out again at the call site.
//
//  WHY THIS EXISTS AT ALL. The old line was:
//
//      let index = Int((min(max(value, 0), 1) * Double(count - 1)).rounded())
//
//  which looks completely safe and is not. `min` and `max` do not sanitise NaN — a
//  comparison against NaN is false, so both hand it straight back — and `Int(Double)`
//  is a FATAL ERROR in Swift for NaN or infinity, not a nil and not a zero. So any
//  modulation path that ever divided by zero would take the whole app down at the
//  moment a fader was read. Tap tempo dividing by a zero interval and an audio
//  analyser seeing a silent buffer are both one division away from it.
//

import Foundation

/// Parameter values that are nominally 0...1, made safe to compute with.
public enum NormalisedSweep {

    /// Clamps to 0...1, mapping non-finite input to a defined value.
    ///
    /// NaN becomes 0 rather than anything cleverer: there is no position on a fader
    /// that "not a number" means, and the low end is the least surprising place for a
    /// parameter to fall back to — it is the identity blend, the unmodified picture,
    /// the first item of every set.
    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else {
            // -infinity is genuinely below the range; +infinity is genuinely above
            // it. Only NaN has no answer, and it takes the same fallback as the low
            // end.
            return value == .infinity ? 1 : 0
        }
        return min(max(value, 0), 1)
    }

    /// Picks an index into a set of `count` items from a 0...1 sweep.
    ///
    /// Returns 0 for an empty set rather than trapping on the negative count that
    /// `count - 1` would produce — a caller with nothing to choose from is a bug
    /// worth surviving, not one worth crashing on.
    public static func index(_ value: Double, count: Int) -> Int {
        guard count > 1 else { return 0 }
        let position = clamp(value) * Double(count - 1)
        return min(Int(position.rounded()), count - 1)
    }

    /// The 0...1 value that `index(_:count:)` maps back to `index`.
    ///
    /// The inverse, so a menu choosing item 7 and a MIDI knob landing on item 7 arrive
    /// at exactly the same number — which is what lets both share one path into the
    /// engine instead of each having its own.
    public static func value(forIndex index: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        let clamped = min(max(index, 0), count - 1)
        return Double(clamped) / Double(count - 1)
    }
}

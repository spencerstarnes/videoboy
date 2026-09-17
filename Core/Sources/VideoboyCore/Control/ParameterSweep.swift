//
//  ParameterSweep.swift — a fader that plays itself between two marks.
//
//  Purpose : Mark an IN and an OUT point on any mappable fader and it stops being a
//            control you hold and becomes one that moves on the clock, sweeping
//            between the two marks at a musical rate. It is the same idea as in and
//            out points on a clip, applied to a parameter instead of a playhead.
//  Inputs  : two bounds and a rate, plus the transport's beat position.
//  Outputs : the value the parameter should hold at that moment.
//  Connects: VBFader (which marks the points and draws the bar), ShellController
//            (which drives every armed sweep once a frame), PlaybackTiming (the rate
//            ladder, shared with the shuttle so there is one set of rungs in the app).
//  Extend  : a different shape belongs here as a case on `Shape`, not as a second
//            sweep type. Everything else about a sweep is the same whatever curve it
//            draws.
//
//  WHY A RAISED COSINE and not a triangle. A triangle reverses hard at each mark,
//  which reads as a mechanical flick at exactly the two moments the eye is drawn to.
//  A raised cosine eases into both ends and spends longer near them, which is what
//  "fade between these two points" means when a person says it out loud.
//

import Foundation

/// A parameter automated between two marks, on the musical clock.
public struct ParameterSweep: Equatable, Codable, Sendable {

    /// The first mark. Not necessarily the lower one — see `lower`/`upper`.
    public var first: Double
    /// The second mark.
    public var second: Double
    /// How long one complete there-and-back cycle takes, in beats.
    public var beatsPerCycle: Double

    public init(first: Double, second: Double, beatsPerCycle: Double) {
        self.first = first
        self.second = second
        self.beatsPerCycle = beatsPerCycle
    }

    /// The marks in order, so the maths never has to care which was clicked first.
    public var lower: Double { min(first, second) }
    public var upper: Double { max(first, second) }

    /// Midway between the marks — where the cap sits when the sweep is armed but the
    /// transport is not running, so an armed fader shows its centre rather than
    /// pretending to be at one end.
    public var midpoint: Double { (lower + upper) / 2 }

    /// Whether the two marks are far enough apart to be worth sweeping between.
    ///
    /// Two marks in the same place would produce a fader that moves imperceptibly and
    /// a yellow bar too thin to see, which reads as broken rather than as precise.
    public var isUsable: Bool { upper - lower > 0.001 }

    /// The value at a given musical position.
    ///
    /// Starts at `lower`, reaches `upper` halfway through the cycle, and returns —
    /// so one cycle is a complete there-and-back, not a one-way trip.
    public func value(atBeats beats: Double) -> Double {
        guard isUsable, beatsPerCycle > 0, beats.isFinite else { return midpoint }
        let phase = (beats / beatsPerCycle).truncatingRemainder(dividingBy: 1)
        let wrapped = phase < 0 ? phase + 1 : phase
        let eased = 0.5 - 0.5 * cos(2 * Double.pi * wrapped)
        return lower + (upper - lower) * eased
    }
}

/// How a sweep's rate is chosen, and what each rung means in beats.
///
/// Deliberately the SAME ladder the shuttle's STEP key walks, so the control reads
/// identically in both places — click for faster, control-click for slower, and the
/// rungs have the names a DJ deck would give them. The difference is only what the
/// rate applies to: frames there, a fade between two marks here.
public enum SweepRate {

    /// Every rung, slowest first.
    public static let ladder: [PlaybackTiming] =
        PlaybackTiming.slowLadder.reversed() + PlaybackTiming.fastLadder

    /// How many beats one complete cycle takes at this rung.
    ///
    /// Returns nil for `.continuous`, which on the shuttle means "not stepping" and
    /// here means "not sweeping" — the rung the ladder starts and ends on.
    public static func beatsPerCycle(_ timing: PlaybackTiming) -> Double? {
        switch timing {
        case .continuous:
            return nil
        case .stepped(let subdivision, _, let every):
            let beats = subdivision.beats * Double(max(every, 1))
            return beats > 0 ? beats : nil
        }
    }
}

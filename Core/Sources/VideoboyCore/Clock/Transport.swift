//
//  Transport.swift — the musical clock (SPEC 4b).
//
//  Purpose : Holds tempo and position, and converts between musical time (bars,
//            beats, ticks) and host time (seconds). It does not produce frames — the
//            render clock does that. This clock decides *when parameters change*.
//  Inputs  : a tempo, and host time advancing.
//  Outputs : `MusicalPosition` values, and the host time of any future beat.
//  Connects: Scheduler (which turns future beats into scheduled actions), the
//            toolbar (tempo readout and beat lights).
//  Extend  : additional tempo sources (MIDI clock, Ableton Link, audio detection)
//            set `beatsPerMinute` and call `resync`; they do not replace this type.
//

import Foundation

/// A position in musical time.
public struct MusicalPosition: Equatable, Sendable {
    /// Bars elapsed since the transport started, counted from 0.
    public let bar: Int
    /// Beat within the bar, counted from 0.
    public let beat: Int
    /// Fraction through the current beat, 0..<1.
    public let phase: Double
    /// Total beats elapsed, including fractional part. The canonical value.
    public let totalBeats: Double

    public init(bar: Int, beat: Int, phase: Double, totalBeats: Double) {
        self.bar = bar
        self.beat = beat
        self.phase = phase
        self.totalBeats = totalBeats
    }
}

/// A beat subdivision. Modules pick one and the scheduler hands them the right
/// timestamps (SPEC 4b).
public enum Subdivision: String, CaseIterable, Codable, Sendable {
    case whole = "1/1"
    case half = "1/2"
    case quarter = "1/4"
    case eighth = "1/8"
    case sixteenth = "1/16"
    case dottedEighth = "1/8."
    case tripletEighth = "1/8T"

    /// Length in beats. A quarter note is one beat, which is the reference.
    public var beats: Double {
        switch self {
        case .whole: 4.0
        case .half: 2.0
        case .quarter: 1.0
        case .eighth: 0.5
        case .sixteenth: 0.25
        // A dotted eighth is an eighth and a half: 0.5 * 1.5.
        case .dottedEighth: 0.75
        // Three triplet eighths fill one beat.
        case .tripletEighth: 1.0 / 3.0
        }
    }
}

/// The master transport: tempo, run state, and the musical/host time conversion.
///
/// Host time is a plain monotonic seconds value supplied by the caller, so this type
/// is fully testable with a fake clock and has no dependency on CoreAudio or AppKit.
public final class Transport {

    /// Beats per minute. Changing it while running re-anchors so the current position
    /// does not jump.
    public var beatsPerMinute: Double {
        didSet {
            guard beatsPerMinute > 0 else {
                Log.error(.clock, "tempo must be positive; keeping \(oldValue)")
                beatsPerMinute = oldValue
                return
            }
            if isRunning { reanchor(atHostTime: lastKnownHostTime) }
        }
    }

    /// Beats in a bar. 4/4 unless told otherwise.
    public var beatsPerBar: Int = 4

    /// Whether the transport is advancing.
    public private(set) var isRunning = false

    /// Host time the current tempo anchor was set at.
    private var anchorHostTime: Double = 0
    /// Beats elapsed at the anchor.
    private var anchorBeats: Double = 0
    /// Most recent host time seen, used when re-anchoring after a tempo change.
    private var lastKnownHostTime: Double = 0

    public init(beatsPerMinute: Double = 120.0) {
        self.beatsPerMinute = beatsPerMinute
    }

    /// Seconds per beat at the current tempo.
    public var secondsPerBeat: Double { 60.0 / beatsPerMinute }

    /// Starts the transport at `hostTime`, resetting to bar 0, beat 0.
    public func start(atHostTime hostTime: Double) {
        anchorHostTime = hostTime
        anchorBeats = 0
        lastKnownHostTime = hostTime
        isRunning = true
        Log.info(.clock, "transport started at \(String(format: "%.1f", beatsPerMinute)) BPM")
    }

    /// Stops the transport. Position is retained so resuming continues from here.
    public func stop(atHostTime hostTime: Double) {
        anchorBeats = beats(atHostTime: hostTime)
        anchorHostTime = hostTime
        isRunning = false
        Log.info(.clock, "transport stopped at beat \(String(format: "%.2f", anchorBeats))")
    }

    /// Re-anchors the beat/time relationship without moving the current position.
    /// Called after a tempo change so the beat count stays continuous.
    private func reanchor(atHostTime hostTime: Double) {
        anchorBeats = beats(atHostTime: hostTime)
        anchorHostTime = hostTime
    }

    /// Total beats elapsed at a host time. Frozen when stopped.
    public func beats(atHostTime hostTime: Double) -> Double {
        guard isRunning else { return anchorBeats }
        lastKnownHostTime = hostTime
        return anchorBeats + (hostTime - anchorHostTime) / secondsPerBeat
    }

    /// Musical position at a host time.
    public func position(atHostTime hostTime: Double) -> MusicalPosition {
        let totalBeats = beats(atHostTime: hostTime)
        // `floor` keeps this correct for the negative beat values a nudge can produce.
        let wholeBeats = Int(totalBeats.rounded(.down))
        let phase = totalBeats - Double(wholeBeats)
        let bar = Int((Double(wholeBeats) / Double(beatsPerBar)).rounded(.down))
        let beatInBar = wholeBeats - bar * beatsPerBar
        return MusicalPosition(bar: bar, beat: beatInBar, phase: phase, totalBeats: totalBeats)
    }

    /// Host time at which a given total-beat position occurs.
    ///
    /// This is the function the scheduler is built on: "beat N occurs at host time T".
    public func hostTime(forBeat totalBeats: Double) -> Double {
        anchorHostTime + (totalBeats - anchorBeats) * secondsPerBeat
    }

    /// The next instance of a subdivision boundary at or after `totalBeats`.
    ///
    /// Used to answer "when is the next 1/8 note?" without the caller doing modulo
    /// arithmetic on floating-point beats, which is easy to get subtly wrong.
    public func nextBoundary(after totalBeats: Double, subdivision: Subdivision) -> Double {
        let step = subdivision.beats
        guard step > 0 else { return totalBeats }
        // A small epsilon stops a boundary landing exactly on `totalBeats` from
        // being returned again and firing the same event twice.
        let epsilon = 1e-9
        let stepsElapsed = ((totalBeats + epsilon) / step).rounded(.down)
        return (stepsElapsed + 1) * step
    }
}

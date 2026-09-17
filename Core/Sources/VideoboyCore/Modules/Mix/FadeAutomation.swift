//
//  FadeAutomation.swift — timed fades and cuts that land on the beat (SPEC 12).
//
//  Purpose : A fader you can only move by hand is half a mixer. This runs a fade
//            over a duration, and schedules a cut so the picture changes ON the
//            beat rather than whenever the button was pressed.
//  Inputs  : a start and end position, a duration or a subdivision.
//  Outputs : a position per frame, and a signal when the move is done.
//  Connects: the fader panels; Transport and Scheduler for the beat-locked variants.
//  Extend  : add a curve to `FadeCurve`. Keep this type free of any node or view —
//            it is arithmetic over time, which is what makes it testable with a fake
//            clock and no graph at all.
//

import Foundation

/// The shape a fade follows.
public enum FadeCurve: String, CaseIterable, Codable, Sendable {
    /// Constant speed. Reads as mechanical, but it is what a manual fader does.
    case linear
    /// Eases in and out. The default, because it looks like a hand did it.
    case smooth
    /// Slow to start, quick to finish.
    case accelerate
    /// Quick to start, slow to settle.
    case decelerate

    public var displayName: String {
        switch self {
        case .linear: "Linear"
        case .smooth: "Smooth"
        case .accelerate: "Accelerate"
        case .decelerate: "Decelerate"
        }
    }

    /// Maps linear progress 0...1 to eased progress 0...1.
    public func apply(_ progress: Double) -> Double {
        let t = min(max(progress, 0), 1)
        switch self {
        case .linear:
            return t
        case .smooth:
            // Smoothstep: zero velocity at both ends.
            return t * t * (3.0 - 2.0 * t)
        case .accelerate:
            return t * t
        case .decelerate:
            return 1.0 - (1.0 - t) * (1.0 - t)
        }
    }
}

/// How fast an auto-fade runs.
///
/// Three positions rather than a continuous control: in a performance you want to
/// reach for "slow" without choosing a number, and the exact seconds matter far less
/// than the feel. Turtle at one end, rabbit at the other.
public enum FadeRate: String, CaseIterable, Codable, Sendable {
    case slow
    case medium
    case fast

    public var seconds: Double {
        switch self {
        case .slow: 4.0
        case .medium: 1.5
        case .fast: 0.4
        }
    }

    public var displayName: String {
        switch self {
        case .slow: "Slow"
        case .medium: "Medium"
        case .fast: "Fast"
        }
    }

    /// Selects from a three-position control's index.
    public static func from(index: Int) -> FadeRate {
        let all = allCases
        return all[min(max(index, 0), all.count - 1)]
    }
}

/// Runs one fade over time.
public struct FadeAutomation: Equatable {
    public let from: Double
    public let to: Double
    public let duration: Double
    public let curve: FadeCurve
    /// Host time the fade began.
    public let startedAt: Double

    public init(
        from: Double, to: Double, duration: Double,
        curve: FadeCurve = .smooth, startedAt: Double
    ) {
        self.from = from
        self.to = to
        self.duration = max(duration, 0.001)
        self.curve = curve
        self.startedAt = startedAt
    }

    /// The position at a host time.
    public func position(atHostTime hostTime: Double) -> Double {
        let elapsed = hostTime - startedAt
        guard elapsed > 0 else { return from }
        guard elapsed < duration else { return to }
        let eased = curve.apply(elapsed / duration)
        return from + (to - from) * eased
    }

    /// Whether the fade has reached its destination.
    public func isFinished(atHostTime hostTime: Double) -> Bool {
        hostTime - startedAt >= duration
    }
}

/// A cut waiting for a beat.
///
/// SPEC 21 requires that a cut-on-beat visibly lands on the beat, which means it must
/// be scheduled for `T − latency` like any other musical event — not fired when the
/// button was pressed and not fired when the beat arrives, but early enough that the
/// result is on screen at the beat.
public struct PendingCut: Equatable {
    /// Where the fader should end up.
    public let target: Double
    /// The musical position the move should be visible at.
    public let targetBeat: Double
    /// Host time to actually perform it — the beat's time, less the graph's latency.
    public let fireHostTime: Double

    /// How to travel when the moment arrives: nil cuts, a rate fades over that long.
    ///
    /// Waiting for the beat and cutting rather than fading are two different
    /// questions — WHEN and HOW — and one flag answering both is why pressing Fade
    /// with beat-sync on produced a hard cut.
    public let rate: FadeRate?

    public init(
        target: Double, targetBeat: Double, fireHostTime: Double, rate: FadeRate? = nil
    ) {
        self.target = target
        self.targetBeat = targetBeat
        self.fireHostTime = fireHostTime
        self.rate = rate
    }

    /// Whether it is time to perform the cut.
    public func isDue(atHostTime hostTime: Double) -> Bool {
        hostTime >= fireHostTime
    }

    /// Builds a cut scheduled for the next boundary of a subdivision.
    ///
    /// - Parameters:
    ///   - target: where the fader should land.
    ///   - transport: supplies the musical/host time conversion.
    ///   - subdivision: which boundary to land on.
    ///   - hostTime: now.
    ///   - latencyInFrames: the graph's worst-case latency, so the cut is taken early
    ///     enough for the result to be visible on the beat.
    ///   - frameRate: for converting that latency to seconds.
    ///   - rate: nil to cut when the moment comes, or a rate to start fading then.
    public static func scheduled(
        target: Double,
        transport: Transport,
        subdivision: Subdivision,
        hostTime: Double,
        latencyInFrames: Int,
        frameRate: Double = StandardDefinition.frameRate,
        rate: FadeRate? = nil
    ) -> PendingCut {
        let nowBeats = transport.beats(atHostTime: hostTime)
        let boundary = transport.nextBoundary(after: nowBeats, subdivision: subdivision)
        let boundaryHostTime = transport.hostTime(forBeat: boundary)
        let latencySeconds = frameRate > 0 ? Double(latencyInFrames) / frameRate : 0
        return PendingCut(
            target: target,
            targetBeat: boundary,
            fireHostTime: boundaryHostTime - latencySeconds,
            rate: rate
        )
    }
}

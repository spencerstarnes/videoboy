//
//  BeatTracker.swift — a steady tempo, and a beat to lock to, from live audio.
//
//  Purpose : TempoEstimator answers "what does the last eight seconds sound like?"
//            That answer wobbles from one moment to the next, and a clock that
//            follows every wobble is useless. This type decides when to believe it:
//            it locks onto a tempo once several estimates agree, follows small drift
//            smoothly, ignores a stray estimate at double or half speed, and only
//            jumps to a genuinely new tempo once that tempo has held for a while.
//  Inputs  : one `AudioFrame` per analysis window, from the audio thread.
//  Outputs : a `BeatTrackerReport` a few times a second (see `updateInterval`), which
//            carries the lock state, the tempo, and where the latest beat fell.
//  Connects: AudioAnalyzer (upstream), the App's AudioInput (which calls `add`), and
//            the Engine (which applies reports to the Transport and the UI).
//  Extend  : tune the numbers in `Tuning`. Keep this free of any audio-device or UI
//            concept, so it can be tested with synthetic envelopes and no hardware.
//
//  ── WHY THE UPDATES ARE RATIONED ────────────────────────────────────────────────
//
//  The first version re-estimated on every analysis window, 47 times a second, and
//  handed each result straight to the transport. That is where the "odd update
//  frequency" came from: the readout, the window flash and every beat-locked effect
//  all moved whenever one estimate differed from the last. Here the estimate runs
//  four times a second and the transport only moves when the tracker's opinion does.
//

import Foundation

/// How sure the tracker is about the tempo right now.
public enum BeatLockState: String, Equatable, Sendable {
    /// No audio arriving — the source is silent, muted, or not permitted.
    case silent
    /// Audio is arriving but no tempo has been locked yet.
    case listening
    /// Locked, and the latest estimates agree.
    case locked
    /// Was locked, but the pulse has gone unclear (a breakdown, a quiet intro). The
    /// last good tempo is kept rather than dropped — a breakdown is exactly when the
    /// visuals should keep time on their own.
    case holding
}

/// Something worth telling the performer about.
public enum BeatTrackerEvent: Equatable, Sendable {
    /// First lock since listening started.
    case locked(beatsPerMinute: Double)
    /// Moved to a genuinely different tempo (a new track, a tempo change).
    case relocked(from: Double, to: Double)
    /// Pulse went unclear; tempo held.
    case lost
    /// The input went quiet.
    case silenced
}

/// One update from the tracker.
public struct BeatTrackerReport: Equatable, Sendable {
    public let state: BeatLockState
    /// The tempo the tracker stands behind, or nil if it has never locked.
    public let beatsPerMinute: Double?
    /// The latest raw estimate's confidence, 0...1.
    public let confidence: Double
    /// Seconds between the most recent detected beat and the end of the newest
    /// analysed window, or nil when not locked.
    public let secondsSinceBeat: Double?
    /// Set only on the report where something changed.
    public let event: BeatTrackerEvent?
}

/// Turns a stream of analysis frames into a steady tempo with hysteresis.
public final class BeatTracker {

    /// The knobs. Grouped so they read as one decision.
    public struct Tuning: Sendable {
        /// Seconds between estimates.
        public var updateInterval = 0.25
        /// Below this confidence an estimate is not evidence of anything.
        public var minimumConfidence = 0.15
        /// Two tempos within this fraction of each other are "the same".
        public var agreement = 0.025
        /// Consecutive agreeing estimates before the first lock (~1 s).
        public var estimatesToLock = 4
        /// Consecutive agreeing estimates before abandoning a lock for a new tempo
        /// (~2 s). Longer than locking, because a wrong jump is worse than a late one.
        public var estimatesToRelock = 8
        /// How far each agreeing estimate pulls the locked tempo, 0...1.
        public var smoothing = 0.2
        /// Consecutive unclear estimates before a lock is reported as holding (~2 s).
        public var estimatesToHold = 8
        /// How close the locked tempo must score to the best candidate to be kept.
        /// See `TempoEstimator.estimate(current:stickiness:)`.
        public var stickiness = 0.8
        /// RMS below this counts as silence.
        public var silenceLevel = 0.0015
        /// Seconds of silence before the state reads silent.
        public var silenceSeconds = 1.0

        public init() {}
    }

    public var tuning: Tuning
    private let estimator: TempoEstimator
    private let windowsPerUpdate: Int
    private let windowsForSilence: Int

    private var windowsSinceUpdate = 0
    private var quietWindows = 0

    private(set) public var state: BeatLockState = .listening
    /// The tempo the tracker currently stands behind.
    private(set) public var lockedTempo: Double?

    /// The tempo being considered, and how many estimates in a row have agreed.
    private var candidate: Double?
    private var candidateCount = 0
    private var unclearCount = 0

    public init(sampleRate: Double = 48_000, tuning: Tuning = Tuning()) {
        self.tuning = tuning
        self.estimator = TempoEstimator(sampleRate: sampleRate)
        let windowsPerSecond = estimator.windowsPerSecond
        self.windowsPerUpdate = max(Int((tuning.updateInterval * windowsPerSecond).rounded()), 1)
        self.windowsForSilence = max(Int(tuning.silenceSeconds * windowsPerSecond), 1)
    }

    /// Forgets everything. Used when the source changes.
    public func reset() {
        estimator.reset()
        windowsSinceUpdate = 0
        quietWindows = 0
        state = .listening
        lockedTempo = nil
        candidate = nil
        candidateCount = 0
        unclearCount = 0
    }

    /// Adds one analysis window. Returns a report every `updateInterval`, nil between.
    public func add(_ frame: AudioFrame) -> BeatTrackerReport? {
        estimator.add(flux: frame.onsetStrength)
        quietWindows = frame.rms < tuning.silenceLevel ? quietWindows + 1 : 0

        windowsSinceUpdate += 1
        guard windowsSinceUpdate >= windowsPerUpdate else { return nil }
        windowsSinceUpdate = 0
        return update()
    }

    /// Whether two tempos are the same pulse. Double and half count: a tracker that
    /// flips between 87 and 174 on a drum & bass record has not found a new tempo.
    private func samePulse(_ a: Double, _ b: Double) -> (same: Bool, octave: Bool) {
        let ratio = a / b
        if abs(ratio - 1) < tuning.agreement { return (true, false) }
        if abs(ratio - 2) < tuning.agreement * 2 || abs(ratio - 0.5) < tuning.agreement {
            return (true, true)
        }
        return (false, false)
    }

    private func update() -> BeatTrackerReport {
        // Silence first: nothing else is meaningful without signal.
        if quietWindows >= windowsForSilence {
            let wasSilent = state == .silent
            state = .silent
            candidate = nil
            candidateCount = 0
            return BeatTrackerReport(
                state: .silent, beatsPerMinute: lockedTempo, confidence: 0,
                secondsSinceBeat: nil, event: wasSilent ? nil : .silenced)
        }
        if state == .silent { state = lockedTempo == nil ? .listening : .holding }

        let estimate = estimator.estimate(current: lockedTempo, stickiness: tuning.stickiness)
        let confidence = estimate?.confidence ?? 0
        var event: BeatTrackerEvent?

        if let estimate, estimate.confidence >= tuning.minimumConfidence {
            unclearCount = 0
            event = consider(estimate.beatsPerMinute)
        } else {
            unclearCount += 1
            if state == .locked && unclearCount >= tuning.estimatesToHold {
                state = .holding
                event = .lost
            }
        }

        var sinceBeat: Double?
        if state == .locked, let lockedTempo {
            sinceBeat = estimator.secondsSinceBeat(atBPM: lockedTempo)
        }
        return BeatTrackerReport(
            state: state, beatsPerMinute: lockedTempo, confidence: confidence,
            secondsSinceBeat: sinceBeat, event: event)
    }

    /// Weighs one confident estimate against the current lock.
    private func consider(_ tempo: Double) -> BeatTrackerEvent? {
        if let locked = lockedTempo {
            let relation = samePulse(tempo, locked)
            if relation.same {
                // The same pulse. Drift follows smoothly; an octave reading is
                // agreement, not a reason to move.
                if !relation.octave {
                    lockedTempo = locked + (tempo - locked) * tuning.smoothing
                }
                candidate = nil
                candidateCount = 0
                let wasHolding = state == .holding
                state = .locked
                return wasHolding ? .locked(beatsPerMinute: lockedTempo ?? locked) : nil
            }
            // A different tempo. Believe it only once it has held.
            track(candidate: tempo)
            guard candidateCount >= tuning.estimatesToRelock, let newTempo = candidate else {
                return nil
            }
            lockedTempo = newTempo
            candidate = nil
            candidateCount = 0
            state = .locked
            return .relocked(from: locked, to: newTempo)
        }

        // Not locked yet.
        track(candidate: tempo)
        guard candidateCount >= tuning.estimatesToLock, let newTempo = candidate else { return nil }
        lockedTempo = newTempo
        candidate = nil
        candidateCount = 0
        state = .locked
        return .locked(beatsPerMinute: newTempo)
    }

    /// How far to move a running clock so its beat lands on the music's.
    ///
    /// - Parameters:
    ///   - clockBeatsAtMusicBeat: the clock's total-beat position at the moment the
    ///     music's most recent beat fell. A whole number means already aligned.
    ///   - snap: correct all of it at once (a fresh lock) rather than a step.
    /// - Returns: beats to pass to `Transport.shiftPosition(byBeats:)`, or 0 when the
    ///   error is too small to be worth moving for.
    ///
    /// A step corrects a quarter of the error, capped at 0.08 beat. Reports arrive
    /// four times a second, so the clock converges in a second or two, and no single
    /// nudge is big enough to skip a scheduled boundary. The error is measured to the
    /// NEAREST beat: this aligns the beat, not the bar — which beat is "one" is not
    /// something the envelope can tell.
    public static func phaseCorrection(clockBeatsAtMusicBeat: Double, snap: Bool) -> Double {
        guard clockBeatsAtMusicBeat.isFinite else { return 0 }
        // Positive: the clock is ahead of the music.
        let error = clockBeatsAtMusicBeat - clockBeatsAtMusicBeat.rounded()
        let correction = snap ? -error : min(max(-error * 0.25, -0.08), 0.08)
        return abs(correction) > 0.004 ? correction : 0
    }

    /// Counts agreeing estimates for a would-be tempo, averaging as it goes.
    private func track(candidate tempo: Double) {
        if let current = candidate, samePulse(tempo, current) == (true, false) {
            candidateCount += 1
            candidate = current + (tempo - current) / Double(candidateCount)
        } else {
            candidate = tempo
            candidateCount = 1
        }
    }
}

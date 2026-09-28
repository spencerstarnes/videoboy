//
//  BeatNetTracker.swift — a steady tempo and beat phase, heard by BeatNet.
//
//  Purpose : Runs BeatNet's network on live audio — resample to 22,050 Hz, features,
//            network — and turns what it hears into what the transport needs: a
//            tempo precise to a fraction of a BPM, where the latest beat fell, and
//            whether to believe either.
//  Inputs  : mono samples at the device's rate, in order, any buffer size.
//  Outputs : `BeatTrackerReport`s, four a second — the same report the older
//            onset tracker makes, so the Engine applies either the same way.
//  Connects: App's AudioInput feeds it; BeatNetWeights/Features/Model do the
//            listening; BeatTracker or BeatNetParticleFilter do the counting.
//  Extend  : `Mode` picks how beats are counted; the lock rules are in the Tuning
//            of whichever does it. Keep this free of device and UI code.
//
//  ── TWO WAYS TO COUNT, AND WHY THE DEFAULT IS THE ONE IT IS ─────────────────────
//
//  BeatNet is two things: a network that says, every 20 ms, how beat-like the sound
//  is, and a particle filter that decides from that which instants are beats. Both
//  are ported exactly (BeatNetTests holds them to the Python). Scored on real music
//  (scripts/beat-eval.py, docs/BEATNET.md), they are not equally good at driving a
//  clock:
//
//  - `.activationTempo` (default) feeds the network's beat activation, in place of
//    the hand-made onset envelope, into the same autocorrelation tempo and phase
//    tracker the app already had (BeatTracker). The network hears beats far better
//    than spectral flux does; the autocorrelation holds a tempo far more steadily
//    than beat-by-beat decisions do. On six tracks it locked as often as the old
//    tracker and put more beats on the right video frame (77% against 69%).
//  - `.particleFilter` is BeatNet's own causal inference, its beats fitted to a
//    straight-line grid for sub-BPM tempo. Kept for evaluation: on the same tracks
//    it locked only 57% of the time.
//

import Foundation

/// BeatNet, end to end, as a beat clock.
public final class BeatNetTracker {

    /// How beats are counted from the network's activations. See the header.
    public enum Mode: Sendable {
        case activationTempo
        case particleFilter
    }

    /// The autocorrelation tracker's settings for the network's activations: it
    /// waits for eight agreeing estimates (2 s) before a first lock, not four. The
    /// activations make a 3:2 tempo look plausible for the first few seconds of
    /// some tracks, and a lock taken then took 15–25 s to undo. Chosen by
    /// scripts/beat-eval.py over the settings tried (docs/BEATNET.md).
    /// How far ahead of the beat the network's activation peaks. Its frames are
    /// 64 ms wide and centred, so a frame 20 ms before a kick already holds the
    /// kick's attack, and the peak lands a frame early. Measured on a signal whose
    /// beat times are known exactly (BeatNetTests); on real music it moves the
    /// beats from 10–15 ms before madmom's offline beats to 5–10 ms after.
    public static let activationLeadSeconds = 0.02

    public static var activationTempoTuning: BeatTracker.Tuning {
        var tuning = BeatTracker.Tuning()
        tuning.estimatesToLock = 8
        tuning.minimumConfidence = 0.25
        return tuning
    }

    /// The particle-filter mode's knobs, grouped so they read as one decision.
    public struct Tuning: Sendable {
        /// Seconds of audio between reports.
        public var reportInterval = 0.25
        /// How far back beats are fitted, in seconds.
        public var fitSeconds = 6.0
        /// Fewest on-grid beats before the first lock.
        public var beatsToLock = 6
        /// Confidence needed to lock, and below which a lock starts to slip.
        public var lockConfidence = 0.55
        public var holdConfidence = 0.3
        /// Consecutive weak reports before a lock is reported as holding (~2 s).
        public var reportsToHold = 8
        /// Two tempos within this fraction are the same pulse.
        public var agreement = 0.04
        /// Consecutive reports a different tempo must hold before a relock (~1.5 s).
        public var reportsToRelock = 6
        /// A beat further than this from the fitted line is left out, in seconds.
        public var outlierSeconds = 0.05
        /// RMS below this counts as silence, and for how long.
        public var silenceLevel: Float = 0.0015
        public var silenceSeconds = 1.0

        public init() {}
    }

    public var tuning: Tuning
    public let inputRate: Double
    public let mode: Mode

    private let resampler: StreamingResampler
    private let features: BeatNetFeatures
    private let model: BeatNetModel
    private var filter: BeatNetParticleFilter
    /// `.activationTempo`: the autocorrelation tracker the activations feed.
    private let tempoTracker: BeatTracker
    private var tempoReports: [BeatTrackerReport] = []

    /// Input samples seen; their count over `inputRate` is "now" in stream time.
    private var inputSamples = 0
    private var samplesSinceReport = 0
    private var quietSamples = 0

    /// Beat times, in stream seconds (frame centres), newest last.
    private(set) public var beatTimes: [Double] = []
    /// Every beat since the last reset, when `keepsAllBeats` is on (evaluation only).
    public var keepsAllBeats = false
    private(set) public var allBeatTimes: [Double] = []

    private(set) public var state: BeatLockState = .listening
    private(set) public var lockedTempo: Double?
    /// The fitted grid: one beat at `gridAnchor`, then every `gridPeriod` seconds.
    private var gridAnchor = 0.0
    private var gridPeriod = 0.0

    private var candidate: Double?
    private var candidateCount = 0
    private var weakCount = 0

    /// The newest network output, for meters and tests.
    private(set) public var lastActivation = BeatNetActivation(beat: 0, downbeat: 0)

    public init(weights: BeatNetWeights, inputRate: Double, mode: Mode = .activationTempo,
                tuning: Tuning = Tuning(),
                activationTempoTuning: BeatTracker.Tuning = BeatNetTracker.activationTempoTuning) {
        self.tuning = tuning
        self.inputRate = inputRate
        self.mode = mode
        tempoTracker = BeatTracker(sampleRate: BeatNetFeatures.sampleRate,
                                   windowSize: BeatNetFeatures.hopSize, tuning: activationTempoTuning)
        resampler = StreamingResampler(inputRate: inputRate, outputRate: BeatNetFeatures.sampleRate)
        features = BeatNetFeatures(weights: weights)
        model = BeatNetModel(weights: weights)
        filter = BeatNetParticleFilter()
    }

    /// Forgets everything; the next audio starts a new stream.
    public func reset() {
        features.reset()
        model.reset()
        filter = BeatNetParticleFilter()
        tempoTracker.reset()
        tempoReports.removeAll()
        inputSamples = 0
        samplesSinceReport = 0
        quietSamples = 0
        beatTimes.removeAll()
        state = .listening
        lockedTempo = nil
        candidate = nil
        candidateCount = 0
        weakCount = 0
    }

    /// Stream time of the end of the newest input sample.
    public var streamTime: Double { Double(inputSamples) / inputRate }

    /// Adds audio. Returns a report each time `reportInterval` of audio has passed —
    /// usually none or one per call. `secondsSinceBeat` in each is measured back
    /// from the end of this call's audio.
    public func add(_ samples: [Float]) -> [BeatTrackerReport] {
        var sumSquares: Float = 0
        for sample in samples { sumSquares += sample * sample }
        let rms = samples.isEmpty ? 0 : (sumSquares / Float(samples.count)).squareRoot()
        quietSamples = rms < tuning.silenceLevel ? quietSamples + samples.count : 0

        inputSamples += samples.count
        for frame in features.add(resampler.process(samples)) {
            let activation = model.process(frame)
            lastActivation = activation
            if mode == .activationTempo {
                // The activation stands in for the onset envelope, one value per frame.
                let envelope = AudioFrame(rms: Double(rms), peak: 0, bands: [], flux: 0, onset: false,
                                          onsetStrength: Double(activation.anyBeat))
                if let report = tempoTracker.add(envelope) {
                    // The tracker measures from this frame's centre, which is 32 ms and
                    // the resampler's latency behind the newest input. Callers measure
                    // from the newest input, so add the difference — less the lead of
                    // the activation over the real beat.
                    let frameTime = Double(features.nextFrame - 1) / BeatNetFeatures.framesPerSecond
                    let lag = streamTime - frameTime - Self.activationLeadSeconds
                    tempoReports.append(BeatTrackerReport(
                        state: report.state, beatsPerMinute: report.beatsPerMinute,
                        confidence: report.confidence,
                        secondsSinceBeat: report.secondsSinceBeat.map { $0 + lag }, event: report.event))
                }
                continue
            }
            if filter.process(activation) {
                let time = Double(filter.frameIndex) / BeatNetFeatures.framesPerSecond
                beatTimes.append(time)
                if keepsAllBeats { allBeatTimes.append(time) }
            }
        }
        // Old beats are never read again.
        let oldest = streamTime - tuning.fitSeconds * 2
        if let first = beatTimes.firstIndex(where: { $0 >= oldest }), first > 0 {
            beatTimes.removeFirst(first)
        }

        if mode == .activationTempo {
            defer { tempoReports.removeAll() }
            return tempoReports
        }
        samplesSinceReport += samples.count
        let reportSamples = Int(tuning.reportInterval * inputRate)
        var reports: [BeatTrackerReport] = []
        while samplesSinceReport >= reportSamples {
            samplesSinceReport -= reportSamples
            reports.append(update())
        }
        return reports
    }

    // MARK: - Grid

    /// A straight-line fit of beat number against time.
    struct GridFit {
        let period: Double
        let anchor: Double       // time of a beat on the line (the newest inlier)
        let inliers: Int
        let confidence: Double
    }

    /// Fits a grid through the recent beats, or nil when there are too few.
    func fitGrid(now: Double) -> GridFit? {
        let recent = beatTimes.filter { $0 >= now - tuning.fitSeconds }
        guard recent.count >= 4 else { return nil }

        // A first period: the median gap between consecutive beats, in range.
        let shortest = 60 / BeatNetParticleFilter.maximumBPM
        let longest = 60 / BeatNetParticleFilter.minimumBPM
        let gaps = zip(recent.dropFirst(), recent).map { $0 - $1 }.filter { $0 >= shortest && $0 <= longest }
        guard gaps.count >= 3 else { return nil }
        var period = gaps.sorted()[gaps.count / 2]
        let newest = recent[recent.count - 1]

        var members = recent
        var anchor = newest
        for _ in 0..<3 {
            // Number beats by elapsed time from the newest, so a missed beat is a gap.
            let numbered = members.map { (index: (($0 - anchor) / period).rounded(), time: $0) }
            guard let line = Self.leastSquares(numbered) else { return nil }
            period = line.slope
            anchor = line.intercept
            let kept = members.filter { time in
                let index = ((time - anchor) / period).rounded()
                return abs(anchor + index * period - time) <= tuning.outlierSeconds
            }
            if kept.count == members.count { break }
            members = kept
            guard members.count >= 4 else { return nil }
        }
        guard period >= shortest, period <= longest else { return nil }

        // Confidence: slots filled, times tightness.
        let span = now - max(now - tuning.fitSeconds, recent[0] - period / 2)
        let slots = max(span / period, 1)
        let filled = min(Double(members.count) / slots, 1)
        var squared = 0.0
        for time in members {
            let index = ((time - anchor) / period).rounded()
            let error = anchor + index * period - time
            squared += error * error
        }
        let rms = (squared / Double(members.count)).squareRoot()
        // A 20 ms frame grid alone leaves ~6 ms RMS; 30 ms RMS is a poor fit.
        let tightness = min(max(1 - (rms - 0.006) / 0.024, 0), 1)
        return GridFit(period: period, anchor: anchor, inliers: members.count,
                       confidence: filled * tightness)
    }

    /// Ordinary least squares of time against beat index. Intercept is at index 0.
    private static func leastSquares(_ points: [(index: Double, time: Double)]) -> (slope: Double, intercept: Double)? {
        let count = Double(points.count)
        let meanIndex = points.reduce(0) { $0 + $1.index } / count
        let meanTime = points.reduce(0) { $0 + $1.time } / count
        var covariance = 0.0, variance = 0.0
        for point in points {
            covariance += (point.index - meanIndex) * (point.time - meanTime)
            variance += (point.index - meanIndex) * (point.index - meanIndex)
        }
        guard variance > 0 else { return nil }
        let slope = covariance / variance
        return (slope, meanTime - slope * meanIndex)
    }

    // MARK: - Lock

    /// Whether two tempos are the same pulse; double and half count as the same.
    private func samePulse(_ a: Double, _ b: Double) -> (same: Bool, octave: Bool) {
        let ratio = a / b
        if abs(ratio - 1) < tuning.agreement { return (true, false) }
        if abs(ratio - 2) < tuning.agreement * 2 || abs(ratio - 0.5) < tuning.agreement {
            return (true, true)
        }
        return (false, false)
    }

    private func update() -> BeatTrackerReport {
        let now = streamTime
        if Double(quietSamples) >= tuning.silenceSeconds * inputRate {
            let wasSilent = state == .silent
            state = .silent
            candidate = nil
            candidateCount = 0
            return BeatTrackerReport(state: .silent, beatsPerMinute: lockedTempo, confidence: 0,
                                     secondsSinceBeat: nil, event: wasSilent ? nil : .silenced)
        }
        if state == .silent { state = lockedTempo == nil ? .listening : .holding }

        let fit = fitGrid(now: now)
        let confidence = fit?.confidence ?? 0
        var event: BeatTrackerEvent?

        if let fit, confidence >= (state == .locked ? tuning.holdConfidence : tuning.lockConfidence),
           fit.inliers >= (lockedTempo == nil ? tuning.beatsToLock : 4) {
            weakCount = 0
            event = consider(fit)
        } else {
            weakCount += 1
            if state == .locked && weakCount >= tuning.reportsToHold {
                state = .holding
                event = .lost
            }
        }

        var sinceBeat: Double?
        if state == .locked, gridPeriod > 0 {
            let beatsSince = ((now - gridAnchor) / gridPeriod).rounded(.down)
            sinceBeat = now - (gridAnchor + beatsSince * gridPeriod)
        }
        return BeatTrackerReport(state: state, beatsPerMinute: lockedTempo, confidence: confidence,
                                 secondsSinceBeat: sinceBeat, event: event)
    }

    /// Weighs a good fit against the current lock.
    private func consider(_ fit: GridFit) -> BeatTrackerEvent? {
        let tempo = 60 / fit.period
        if let locked = lockedTempo {
            let relation = samePulse(tempo, locked)
            if relation.same {
                candidate = nil
                candidateCount = 0
                if !relation.octave {
                    // The fit is already an average over several seconds; take it.
                    lockedTempo = tempo
                    gridPeriod = fit.period
                    gridAnchor = fit.anchor
                } else {
                    // Same pulse at double or half: keep the tempo, take the phase.
                    gridPeriod = 60 / locked
                    gridAnchor = fit.anchor
                }
                let wasHolding = state != .locked
                state = .locked
                return wasHolding ? .locked(beatsPerMinute: lockedTempo ?? locked) : nil
            }
            if let current = candidate, samePulse(tempo, current) == (true, false) {
                candidateCount += 1
            } else {
                candidateCount = 1
            }
            candidate = tempo
            guard candidateCount >= tuning.reportsToRelock else { return nil }
            lockedTempo = tempo
            gridPeriod = fit.period
            gridAnchor = fit.anchor
            candidate = nil
            candidateCount = 0
            state = .locked
            return .relocked(from: locked, to: tempo)
        }
        lockedTempo = tempo
        gridPeriod = fit.period
        gridAnchor = fit.anchor
        state = .locked
        return .locked(beatsPerMinute: tempo)
    }
}

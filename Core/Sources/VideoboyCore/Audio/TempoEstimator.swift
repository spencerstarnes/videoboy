//
//  TempoEstimator.swift — tempo and beat phase from the onset envelope (SPEC 4c).
//
//  Purpose : Estimates BPM, and where the most recent beat fell, from the last few
//            seconds of onset strength. One estimate is a snapshot; BeatTracker
//            turns a stream of snapshots into a steady clock.
//  Inputs  : a stream of onset-strength values, one per analysis window.
//  Outputs : a `TempoEstimate` (BPM + confidence), and `secondsSinceBeat(...)`.
//  Connects: AudioAnalyzer supplies `onsetStrength`; BeatTracker calls this.
//  Extend  : the method is the textbook one — autocorrelation of a detrended onset
//            envelope, scored through a comb of harmonics and a tempo prior (Ellis
//            2007; Davies & Plumbley 2007; Stark 2011). It is written from the
//            papers, not ported: the well-known implementations (BTrack, aubio) are
//            GPL, which this app cannot link.
//
//  ── WHAT WAS WRONG WITH THE FIRST VERSION ───────────────────────────────────────
//
//  It picked the single highest autocorrelation lag. At 1024-sample windows and
//  48 kHz the envelope runs at ~47 Hz, so at 120 BPM a beat is 23.4 windows long and
//  the only answers available were 23 (122.3 BPM) or 24 (117.2 BPM). Real music sat
//  between the two and the readout flipped five BPM back and forth. Here the period
//  is measured off the 2nd–4th multiples of the beat as well (each one quadruples the
//  precision of the last) and every peak is interpolated, so the resolution is a
//  small fraction of a BPM.
//
//  It also had no preference between a tempo and its double or half, so a busy hi-hat
//  could win over the kick. The comb and the prior settle that the way a listener
//  would: the pulse that explains the most of the envelope, near a comfortable tempo.
//

import Foundation

/// A tempo estimate.
public struct TempoEstimate: Equatable, Sendable {
    public let beatsPerMinute: Double
    /// 0...1. How strongly the envelope repeats at this period, relative to how it
    /// correlates with itself on average. Low confidence means the audio has no
    /// clear pulse — silence, speech, drone, a rubato intro.
    public let confidence: Double

    public init(beatsPerMinute: Double, confidence: Double) {
        self.beatsPerMinute = beatsPerMinute
        self.confidence = confidence
    }
}

/// Estimates tempo from onset strength over a sliding window.
public final class TempoEstimator {

    /// Tempo range considered. Outside this, a "tempo" is almost certainly a
    /// harmonic of the real one or noise.
    public static let minimumBPM = 60.0
    public static let maximumBPM = 200.0

    /// Where the tempo prior peaks, and how wide it is in octaves. 120 BPM is the
    /// centre of the literature's prior (Ellis 2007, Klapuri 2006); a one-octave
    /// spread leaves 90 and 160 almost unpenalised and only leans on the choice when
    /// the envelope itself cannot decide between a tempo and its double.
    public static let preferredBPM = 120.0
    private static let priorOctaves = 1.0

    /// Multiples of the beat period the comb looks at. Four: the envelope has to
    /// hold four beats even at the slowest tempo, which sets the history length.
    private static let harmonics = 4

    /// How much history to correlate over. Eight seconds holds four beats at 60 BPM
    /// with room to spare, and sixteen at 120.
    public static let historySeconds = 8.0

    /// Envelope samples per second.
    public let windowsPerSecond: Double
    private var onsetStrength: [Double] = []
    private let capacity: Int

    /// - Parameters:
    ///   - sampleRate: the audio sample rate.
    ///   - windowSize: the analyser's hop, which sets the envelope's rate.
    public init(sampleRate: Double = 48_000, windowSize: Int = AudioAnalyzer.windowSize) {
        self.windowsPerSecond = sampleRate / Double(windowSize)
        self.capacity = Int(Self.historySeconds * windowsPerSecond)
        onsetStrength.reserveCapacity(capacity + 1)
    }

    /// Adds one analysis window's onset strength.
    public func add(flux: Double) {
        onsetStrength.append(flux.isFinite ? flux : 0)
        if onsetStrength.count > capacity { onsetStrength.removeFirst() }
    }

    /// Clears the history.
    public func reset() {
        onsetStrength.removeAll(keepingCapacity: true)
    }

    /// Beat period in envelope samples for a tempo.
    private func lag(forBPM beatsPerMinute: Double) -> Double {
        60.0 / beatsPerMinute * windowsPerSecond
    }

    /// Longest lag the comb reads, in samples.
    private var maximumLag: Int {
        Int((lag(forBPM: Self.minimumBPM) * Double(Self.harmonics)).rounded(.up)) + 2
    }

    /// How many samples are needed before an estimate means anything: the comb's
    /// longest lag plus a second of overlap to correlate.
    public var minimumHistory: Int { min(maximumLag + Int(windowsPerSecond), capacity) }

    /// The envelope with its slow trend removed, then half-wave rectified.
    ///
    /// The trend (a local average over about a third of a second) is the loudness of
    /// the passage, not its rhythm; left in, it correlates with itself at every lag
    /// and flattens the peaks. Rectifying afterwards keeps only the moments that rose
    /// above their surroundings, which is what an onset is.
    private func detrended() -> [Double] {
        let count = onsetStrength.count
        let radius = max(Int(windowsPerSecond * 0.16), 1)
        // Running sum, so the local mean costs O(n) rather than O(n·radius).
        var prefix = [Double](repeating: 0, count: count + 1)
        for index in 0..<count { prefix[index + 1] = prefix[index] + onsetStrength[index] }
        var result = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let low = max(index - radius, 0)
            let high = min(index + radius + 1, count)
            let localMean = (prefix[high] - prefix[low]) / Double(high - low)
            result[index] = max(onsetStrength[index] - localMean, 0)
        }
        return result
    }

    /// Normalised autocorrelation of `signal` for lags 0...maximumLag. Entry 0 is 1.
    private func autocorrelation(_ signal: [Double], maximumLag: Int) -> [Double]? {
        let count = signal.count
        var zeroLag = 0.0
        for value in signal { zeroLag += value * value }
        // A flat envelope has no pulse to find.
        guard zeroLag > 1e-12, maximumLag < count else { return nil }
        let zeroLagMean = zeroLag / Double(count)

        var result = [Double](repeating: 0, count: maximumLag + 1)
        result[0] = 1
        signal.withUnsafeBufferPointer { pointer in
            for lag in 1...maximumLag {
                var sum = 0.0
                for index in 0..<(count - lag) { sum += pointer[index] * pointer[index + lag] }
                // Normalise by overlap, so long lags are not penalised merely for
                // having fewer terms, then by the zero lag so 1 means "identical".
                result[lag] = sum / Double(count - lag) / zeroLagMean
            }
        }
        return result
    }

    /// Autocorrelation at a fractional lag, by linear interpolation.
    private func value(_ correlation: [Double], at lag: Double) -> Double {
        let low = Int(lag)
        guard low >= 0, low + 1 < correlation.count else { return 0 }
        let fraction = lag - Double(low)
        return correlation[low] * (1 - fraction) + correlation[low + 1] * fraction
    }

    /// The tempo prior: a log-Gaussian around `preferredBPM`.
    private func prior(_ beatsPerMinute: Double) -> Double {
        let octaves = log2(beatsPerMinute / Self.preferredBPM) / Self.priorOctaves
        return exp(-0.5 * octaves * octaves)
    }

    /// How well the envelope repeats at a candidate period, over the comb.
    private func combScore(_ correlation: [Double], period: Double) -> Double {
        var score = 0.0
        for multiple in 1...Self.harmonics {
            score += value(correlation, at: period * Double(multiple))
        }
        return score / Double(Self.harmonics)
    }

    /// Where the true peak near a lag sits, by fitting a parabola through the local
    /// maximum and its neighbours. Nil when the neighbourhood holds no peak.
    private func refinedPeak(_ correlation: [Double], near lag: Double) -> Double? {
        var best = Int(lag.rounded())
        guard best > 1, best < correlation.count - 2 else { return nil }
        // The peak may be a sample either side of where the coarse period predicts.
        for candidate in (best - 1)...(best + 1) where correlation[candidate] > correlation[best] {
            best = candidate
        }
        let left = correlation[best - 1], centre = correlation[best], right = correlation[best + 1]
        guard centre >= left, centre >= right else { return nil }
        let curvature = left - 2 * centre + right
        guard curvature < 0 else { return Double(best) }
        let offset = 0.5 * (left - right) / curvature
        return Double(best) + max(min(offset, 0.5), -0.5)
    }

    /// The current best tempo estimate, or nil when there is not enough history or
    /// the envelope has no pulse.
    ///
    /// - Parameters:
    ///   - current: the tempo already being followed, if any.
    ///   - stickiness: 0...1. When `current` scores at least this fraction of the
    ///     best candidate, `current` is returned (refined) instead of the best.
    ///
    /// Why stickiness exists: real music supports several related tempos at once —
    /// a drum & bass record scores well at 185, 92.5, 123 (two-thirds) and 148
    /// (four-fifths), and which of them edges ahead changes from bar to bar with the
    /// drum pattern. Without a preference for staying put, the clock jumps between
    /// them. This is the same idea as the tempo transition model in Davies &
    /// Plumbley's and Stark's trackers, in its simplest form.
    public func estimate(current: Double? = nil, stickiness: Double = 0) -> TempoEstimate? {
        guard onsetStrength.count >= minimumHistory else { return nil }
        let signal = detrended()
        guard let correlation = autocorrelation(signal, maximumLag: maximumLag) else { return nil }

        // Coarse search on a 0.5 BPM grid, comb × prior.
        var bestTempo = 0.0
        var bestScore = -Double.infinity
        var currentTempo = 0.0
        var currentScore = -Double.infinity
        var scores: [Double] = []
        var tempo = Self.minimumBPM
        while tempo <= Self.maximumBPM {
            let comb = combScore(correlation, period: lag(forBPM: tempo))
            scores.append(comb)
            let weighted = comb * prior(tempo)
            if weighted > bestScore {
                bestScore = weighted
                bestTempo = tempo
            }
            // The best candidate within 3% of the tempo being followed.
            if let current, abs(tempo - current) / current <= 0.03, weighted > currentScore {
                currentScore = weighted
                currentTempo = tempo
            }
            tempo += 0.5
        }
        guard bestScore > 0 else { return nil }
        if current != nil, currentScore > 0, currentScore >= bestScore * stickiness {
            bestTempo = currentTempo
        }

        // Refine the period off each multiple's interpolated peak. The kth peak sits
        // at k·period, so it measures the period k times more finely than the first;
        // weighting by k lets the long lags carry the answer.
        let coarsePeriod = lag(forBPM: bestTempo)
        var weightedPeriods = 0.0
        var totalWeight = 0.0
        for multiple in 1...Self.harmonics {
            guard let peak = refinedPeak(correlation, near: coarsePeriod * Double(multiple)) else {
                continue
            }
            // Ignore a "peak" that has wandered off to a neighbouring bump.
            let period = peak / Double(multiple)
            guard abs(period - coarsePeriod) / coarsePeriod < 0.03 else { continue }
            weightedPeriods += period * Double(multiple)
            totalWeight += Double(multiple)
        }
        let period = totalWeight > 0 ? weightedPeriods / totalWeight : coarsePeriod
        let beatsPerMinute = min(
            max(60.0 * windowsPerSecond / period, Self.minimumBPM), Self.maximumBPM)

        // Confidence: how far the winning comb stands above the typical comb, as a
        // fraction of the headroom above typical. A click track reads near 1, a
        // drum loop well above half, a pad or a voice near 0.
        let sorted = scores.sorted()
        let median = sorted[sorted.count / 2]
        let winning = combScore(correlation, period: period)
        let headroom = max(1.0 - median, 1e-6)
        let confidence = min(max((winning - median) / headroom, 0), 1)

        return TempoEstimate(beatsPerMinute: beatsPerMinute, confidence: confidence)
    }

    /// How long ago the most recent beat fell, in seconds before the newest sample,
    /// for a given tempo. Nil without enough history.
    ///
    /// Folds the envelope at the beat period and finds the offset where the onsets
    /// pile up. Recent beats count more than old ones, so a drifting clock follows
    /// the music rather than an average of where it used to be.
    public func secondsSinceBeat(atBPM beatsPerMinute: Double) -> Double? {
        guard beatsPerMinute > 0, onsetStrength.count >= minimumHistory else { return nil }
        let signal = detrended()
        let period = lag(forBPM: beatsPerMinute)
        guard period >= 2 else { return nil }
        let newest = Double(signal.count - 1)
        let beatsToFold = Int(Double(signal.count) / period) - 1
        guard beatsToFold >= 2 else { return nil }

        // Quarter-sample steps across one period: about 5 ms at 48 kHz, several
        // times finer than a video frame.
        var bestOffset = 0.0
        var bestScore = -Double.infinity
        var offset = 0.0
        while offset < period {
            var score = 0.0
            var weight = 1.0
            for beat in 0..<beatsToFold {
                let position = newest - offset - Double(beat) * period
                guard position >= 0 else { break }
                let low = Int(position)
                let fraction = position - Double(low)
                let high = min(low + 1, signal.count - 1)
                score += weight * (signal[low] * (1 - fraction) + signal[high] * fraction)
                weight *= 0.85
            }
            if score > bestScore {
                bestScore = score
                bestOffset = offset
            }
            offset += 0.25
        }
        guard bestScore > 0 else { return nil }
        return bestOffset / windowsPerSecond
    }
}

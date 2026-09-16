//
//  TempoEstimator.swift — tempo from the onset envelope (SPEC 4c).
//
//  Purpose : Estimates BPM by autocorrelating the onset strength over the last few
//            seconds. SPEC 4c says energy-based onset plus autocorrelation is enough,
//            and it is: this is for locking the visual clock to music, not for
//            transcribing it.
//  Inputs  : a stream of onset-strength values, one per analysis window.
//  Outputs : a BPM estimate with a confidence.
//  Connects: AudioAnalyzer supplies the flux; Transport consumes the BPM.
//  Extend  : phase alignment (where the downbeat is) is not attempted here — the
//            transport's own tap/nudge handles that, and guessing it badly is worse
//            than not guessing.
//

import Foundation

/// A tempo estimate.
public struct TempoEstimate: Equatable, Sendable {
    public let beatsPerMinute: Double
    /// 0...1. How strongly the autocorrelation peaked relative to its surroundings.
    /// Low confidence means the audio has no clear pulse — silence, speech, drone.
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

    /// How much history to correlate over. Four seconds holds several beats at any
    /// tempo in range, which is the minimum for a stable estimate.
    private let historySeconds = 4.0

    private let windowsPerSecond: Double
    private var onsetStrength: [Double] = []
    private let capacity: Int

    /// - Parameters:
    ///   - sampleRate: the audio sample rate.
    ///   - windowSize: the analyser's window size, which sets the envelope's rate.
    public init(sampleRate: Double = 48_000, windowSize: Int = AudioAnalyzer.windowSize) {
        self.windowsPerSecond = sampleRate / Double(windowSize)
        self.capacity = Int(historySeconds * windowsPerSecond)
    }

    /// Adds one analysis window's onset strength.
    public func add(flux: Double) {
        onsetStrength.append(flux)
        if onsetStrength.count > capacity { onsetStrength.removeFirst() }
    }

    /// Clears the history.
    public func reset() {
        onsetStrength.removeAll()
    }

    /// The current best tempo estimate, or nil when there is not enough history.
    public func estimate() -> TempoEstimate? {
        // Need at least half the window before an estimate means anything.
        guard onsetStrength.count >= capacity / 2 else { return nil }

        // Work on the envelope with its mean removed, or the autocorrelation is
        // dominated by the DC component and peaks at lag zero for everything.
        let mean = onsetStrength.reduce(0, +) / Double(onsetStrength.count)
        let centred = onsetStrength.map { $0 - mean }

        // A flat envelope has no pulse to find.
        let energy = centred.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-12 else { return nil }

        // Lags corresponding to the tempo range.
        let minimumLag = Int((60.0 / Self.maximumBPM) * windowsPerSecond)
        let maximumLag = Int((60.0 / Self.minimumBPM) * windowsPerSecond)
        guard minimumLag >= 1, maximumLag < centred.count else { return nil }

        var correlations: [(lag: Int, value: Double)] = []
        for lag in minimumLag...maximumLag {
            var sum = 0.0
            for index in 0..<(centred.count - lag) {
                sum += centred[index] * centred[index + lag]
            }
            // Normalise by overlap so short lags are not favoured purely for having
            // more terms to sum.
            correlations.append((lag, sum / Double(centred.count - lag)))
        }

        guard let best = correlations.max(by: { $0.value < $1.value }), best.value > 0 else {
            return nil
        }

        // Confidence: how far the peak stands above the average correlation.
        let averageCorrelation = correlations.reduce(0) { $0 + $1.value } / Double(correlations.count)
        let spread = correlations
            .map { abs($0.value - averageCorrelation) }
            .reduce(0, +) / Double(correlations.count)
        let confidence = spread > 0 ? min((best.value - averageCorrelation) / (spread * 4.0), 1.0) : 0

        let secondsPerBeat = Double(best.lag) / windowsPerSecond
        guard secondsPerBeat > 0 else { return nil }
        return TempoEstimate(beatsPerMinute: 60.0 / secondsPerBeat, confidence: max(confidence, 0))
    }
}

//
//  AudioAnalyzer.swift — RMS, frequency bands and onset detection (SPEC 4c).
//
//  Purpose : Turns a buffer of audio samples into the handful of numbers that can
//            usefully drive video: how loud it is, how the energy is spread across
//            frequency, and whether something just started.
//  Inputs  : mono float samples, -1...1.
//  Outputs : an `AudioFrame` of measurements.
//  Connects: the App's AVAudioEngine tap supplies the samples; AudioReactivityBus
//            distributes the results; TempoEstimator consumes the onset envelope.
//  Extend  : add a measurement to `AudioFrame` and compute it in `analyze`. Keep
//            this type free of any audio-session or device concept — it takes
//            numbers and returns numbers, which is what makes it testable with
//            synthetic signals and no hardware.
//
//  The FFT is Accelerate's. It is a system framework, so this adds no dependency.
//

import Foundation
import Accelerate

/// One analysis window's worth of measurements.
public struct AudioFrame: Equatable, Sendable {
    /// Root-mean-square level, 0...1.
    public let rms: Double
    /// Peak absolute sample in the window, 0...1.
    public let peak: Double
    /// Energy in each frequency band, 0...1. See `AudioAnalyzer.bandEdges`.
    public let bands: [Double]
    /// Spectral flux: how much the spectrum grew since the previous window. This is
    /// the raw onset signal, before thresholding.
    public let flux: Double
    /// True when this window looks like the start of a new sound.
    public let onset: Bool

    public init(rms: Double, peak: Double, bands: [Double], flux: Double, onset: Bool) {
        self.rms = rms
        self.peak = peak
        self.bands = bands
        self.flux = flux
        self.onset = onset
    }

    /// A window of silence.
    public static func silent(bandCount: Int = AudioAnalyzer.bandEdges.count - 1) -> AudioFrame {
        AudioFrame(rms: 0, peak: 0, bands: Array(repeating: 0, count: bandCount), flux: 0, onset: false)
    }
}

/// Analyses audio windows.
public final class AudioAnalyzer {

    /// Band boundaries in Hz. Roughly octave-spaced across the musically useful
    /// range: sub, bass, low-mid, mid, high-mid, presence, air.
    public static let bandEdges: [Double] = [20, 60, 150, 400, 1000, 2500, 6000, 16000]

    /// Number of bands the analyser reports.
    public static var bandCount: Int { bandEdges.count - 1 }

    /// Window size in samples. A power of two, as the FFT requires. 1024 at 48 kHz is
    /// about 21 ms — short enough to place an onset tightly, long enough to resolve
    /// bass.
    public static let windowSize = 1024

    private let sampleRate: Double
    private let fftSetup: FFTSetup?
    private let log2Size: vDSP_Length

    /// Magnitude spectrum of the previous window, for spectral flux.
    private var previousMagnitudes: [Float]
    /// Recent flux values, for the adaptive onset threshold.
    private var fluxHistory: [Double] = []
    /// How many windows of flux history the threshold adapts over. About a second.
    private let fluxHistoryLength = 43

    /// Windows since the last onset, so one sound is not reported as several.
    private var windowsSinceOnset = 0
    /// Minimum gap between onsets, in windows. About 100 ms at 48 kHz — faster than
    /// this and a single drum hit reports as a flam.
    private let minimumOnsetGap = 5

    public init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        self.log2Size = vDSP_Length(log2(Double(AudioAnalyzer.windowSize)))
        self.fftSetup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))
        self.previousMagnitudes = Array(repeating: 0, count: AudioAnalyzer.windowSize / 2)
        if fftSetup == nil {
            Log.error(.clock, "could not create an FFT setup; audio bands will read zero")
        }
    }

    deinit {
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// Analyses one window of samples.
    ///
    /// - Parameter samples: mono, -1...1. Shorter buffers are zero-padded; longer
    ///   ones are truncated, because the FFT size is fixed.
    public func analyze(samples: [Float]) -> AudioFrame {
        let size = AudioAnalyzer.windowSize
        var window = [Float](repeating: 0, count: size)
        for index in 0..<min(samples.count, size) { window[index] = samples[index] }

        // Level measurements are on the raw samples, before any windowing.
        var meanSquare: Float = 0
        vDSP_measqv(window, 1, &meanSquare, vDSP_Length(size))
        let rms = Double(sqrt(meanSquare))

        var peak: Float = 0
        vDSP_maxmgv(window, 1, &peak, vDSP_Length(size))

        guard let fftSetup else {
            return AudioFrame(
                rms: min(rms, 1), peak: min(Double(peak), 1),
                bands: Array(repeating: 0, count: AudioAnalyzer.bandCount),
                flux: 0, onset: false
            )
        }

        // A Hann window before the FFT, or every window boundary looks like an edge
        // and smears energy across the whole spectrum.
        var hann = [Float](repeating: 0, count: size)
        vDSP_hann_window(&hann, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        vDSP_vmul(window, 1, hann, 1, &window, 1, vDSP_Length(size))

        let halfSize = size / 2
        var real = [Float](repeating: 0, count: halfSize)
        var imaginary = [Float](repeating: 0, count: halfSize)
        var magnitudes = [Float](repeating: 0, count: halfSize)

        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                window.withUnsafeBufferPointer { samplePointer in
                    samplePointer.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: halfSize
                    ) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))
            }
        }

        // Scale so the magnitudes are independent of the window size.
        var scale = Float(1.0 / Double(size))
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(halfSize))

        // Spectral flux: the sum of positive changes since the last window. Only
        // increases count — a sound ending is not an onset.
        var flux = 0.0
        for index in 0..<halfSize {
            let difference = Double(magnitudes[index] - previousMagnitudes[index])
            if difference > 0 { flux += difference }
        }
        previousMagnitudes = magnitudes

        let bands = bandEnergies(magnitudes: magnitudes, halfSize: halfSize)
        let onset = detectOnset(flux: flux)

        return AudioFrame(
            rms: min(rms, 1),
            peak: min(Double(peak), 1),
            bands: bands,
            flux: flux,
            onset: onset
        )
    }

    /// Sums magnitudes into the configured bands.
    private func bandEnergies(magnitudes: [Float], halfSize: Int) -> [Double] {
        let binWidth = sampleRate / Double(AudioAnalyzer.windowSize)
        var bands: [Double] = []
        bands.reserveCapacity(AudioAnalyzer.bandCount)

        for bandIndex in 0..<AudioAnalyzer.bandCount {
            let low = AudioAnalyzer.bandEdges[bandIndex]
            let high = AudioAnalyzer.bandEdges[bandIndex + 1]
            let firstBin = max(Int(low / binWidth), 1)
            let lastBin = min(Int(high / binWidth), halfSize - 1)
            guard firstBin <= lastBin else {
                bands.append(0)
                continue
            }
            var sum = 0.0
            for bin in firstBin...lastBin { sum += Double(magnitudes[bin]) }
            // Mean rather than total, so a wide band is not automatically louder
            // than a narrow one purely for being wide.
            bands.append(min(sum / Double(lastBin - firstBin + 1) * 4.0, 1.0))
        }
        return bands
    }

    /// Decides whether this window's flux counts as an onset.
    ///
    /// The threshold adapts to recent flux rather than being a fixed number: what
    /// counts as a sudden increase depends entirely on how busy the music is, and a
    /// fixed threshold would either miss everything quiet or fire constantly on
    /// anything loud.
    private func detectOnset(flux: Double) -> Bool {
        fluxHistory.append(flux)
        if fluxHistory.count > fluxHistoryLength { fluxHistory.removeFirst() }
        windowsSinceOnset += 1

        // Not enough history to judge against yet.
        guard fluxHistory.count >= 8 else { return false }

        let mean = fluxHistory.reduce(0, +) / Double(fluxHistory.count)
        let variance = fluxHistory
            .map { ($0 - mean) * ($0 - mean) }
            .reduce(0, +) / Double(fluxHistory.count)
        let standardDeviation = sqrt(variance)

        // 1.5 sigma above the running mean, with a floor so near-silence cannot
        // produce onsets out of numerical noise.
        let threshold = max(mean + 1.5 * standardDeviation, 1e-4)

        guard flux > threshold, windowsSinceOnset >= minimumOnsetGap else { return false }
        windowsSinceOnset = 0
        return true
    }

    /// Clears the analyser's history. Used when the input changes.
    public func reset() {
        previousMagnitudes = Array(repeating: 0, count: AudioAnalyzer.windowSize / 2)
        fluxHistory.removeAll()
        windowsSinceOnset = 0
    }
}

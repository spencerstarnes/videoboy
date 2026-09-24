//
//  AudioAnalyzer.swift — RMS, frequency bands and onset detection (SPEC 4c).
//
//  Purpose : Turns a buffer of audio samples into the handful of numbers that can
//            usefully drive video: how loud it is, how the energy is spread across
//            frequency, and whether something just started.
//  Inputs  : mono float samples, -1...1.
//  Outputs : an `AudioFrame` of measurements.
//  Connects: the App's AVAudioEngine tap supplies the samples; AudioReactivityBus
//            distributes the results; BeatTracker consumes `onsetStrength`.
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
    /// Log-compressed, log-frequency spectral flux — the signal the beat tracker
    /// listens to. Two changes from `flux`, both standard (Böck & Widmer's
    /// SuperFlux, Klapuri's band-wise flux):
    ///  - measured over log-spaced bands, so every octave has an equal say. Summed
    ///    over raw FFT bins, the treble owns most of the bins and a hi-hat outvotes
    ///    the kick drum, which is how a tracker ends up locked to the hats.
    ///  - log(1 + C·level) rather than level, so a quiet snare still counts next to
    ///    a loud sustained bass line.
    public let onsetStrength: Double
    /// The window's samples, -1…1, before windowing — what an ISF `audio` input shows.
    public var waveform: [Float] = []
    /// The window's spectrum, one value per FFT bin up to Nyquist, 0…1 on a 60 dB
    /// scale — what an ISF `audioFFT` input shows.
    public var spectrum: [Float] = []

    public init(
        rms: Double, peak: Double, bands: [Double], flux: Double, onset: Bool,
        onsetStrength: Double = 0
    ) {
        self.rms = rms
        self.peak = peak
        self.bands = bands
        self.flux = flux
        self.onset = onset
        self.onsetStrength = onsetStrength
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
    /// Log-compressed band levels of the previous window, for `onsetStrength`.
    private var previousCompressed: [Float]
    /// FFT bin ranges of the log-spaced bands `onsetStrength` is measured over.
    private let onsetBands: [ClosedRange<Int>]
    /// The Hann window, computed once. It depends only on the window size.
    private let hann: [Float]
    /// Compression constant for `onsetStrength`: log(1 + C·level). Magnitudes here
    /// are scaled by 1/windowSize, so a full-scale tone peaks around 0.25; C = 1000
    /// puts the knee of the curve around -50 dBFS, below anything musical.
    private let compression: Float = 1000
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
        self.onsetBands = AudioAnalyzer.logBands(sampleRate: sampleRate)
        self.previousCompressed = Array(repeating: 0, count: onsetBands.count)
        var hann = [Float](repeating: 0, count: AudioAnalyzer.windowSize)
        vDSP_hann_window(&hann, vDSP_Length(AudioAnalyzer.windowSize), Int32(vDSP_HANN_NORM))
        self.hann = hann
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

        let rawWindow = window

        // A Hann window before the FFT, or every window boundary looks like an edge
        // and smears energy across the whole spectrum.
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

        // The same, over log-spaced bands and log-compressed, for the beat tracker.
        var compressed = [Float](repeating: 0, count: onsetBands.count)
        for (bandIndex, bins) in onsetBands.enumerated() {
            var sum: Float = 0
            for bin in bins { sum += magnitudes[bin] }
            compressed[bandIndex] = log(1 + compression * sum / Float(bins.count))
        }
        var onsetStrength = 0.0
        for index in 0..<compressed.count {
            let difference = Double(compressed[index] - previousCompressed[index])
            if difference > 0 { onsetStrength += difference }
        }
        previousCompressed = compressed

        let bands = bandEnergies(magnitudes: magnitudes, halfSize: halfSize)
        let onset = detectOnset(flux: flux)

        var frame = AudioFrame(
            rms: min(rms, 1),
            peak: min(Double(peak), 1),
            bands: bands,
            flux: flux,
            onset: onset,
            onsetStrength: onsetStrength
        )
        frame.waveform = rawWindow
        frame.spectrum = AudioAnalyzer.displaySpectrum(magnitudes)
        return frame
    }

    /// Magnitudes as 0…1 on a 60 dB scale: a full-scale sine near 1, -60 dB and
    /// below at 0. Loudness is heard logarithmically, so a linear scale would leave
    /// everything but the loudest bins at the floor of an FFT visualiser.
    static func displaySpectrum(_ magnitudes: [Float]) -> [Float] {
        // A full-scale Hann-windowed sine peaks near 0.25 after the 1/size scaling.
        let reference: Float = 0.25
        return magnitudes.map { magnitude in
            let decibels = 20 * log10(max(magnitude / reference, 1e-6))
            return min(max((decibels + 60) / 60, 0), 1)
        }
    }

    /// Log-spaced bands from 40 Hz to 16 kHz, about a third of an octave each, as
    /// FFT bin ranges. At the bottom a third of an octave is narrower than one bin,
    /// so those bands collapse to a bin apiece and duplicates are dropped.
    static func logBands(sampleRate: Double) -> [ClosedRange<Int>] {
        let binWidth = sampleRate / Double(windowSize)
        let lastBin = windowSize / 2 - 1
        let low = 40.0, high = min(16_000.0, sampleRate / 2 - binWidth)
        let bandCount = 26
        var bands: [ClosedRange<Int>] = []
        var previousTop = 0
        for index in 0..<bandCount {
            let bottomHz = low * pow(high / low, Double(index) / Double(bandCount))
            let topHz = low * pow(high / low, Double(index + 1) / Double(bandCount))
            let bottom = max(Int((bottomHz / binWidth).rounded()), previousTop + 1)
            let top = min(max(Int((topHz / binWidth).rounded()), bottom), lastBin)
            guard bottom <= top else { continue }
            bands.append(bottom...top)
            previousTop = top
        }
        return bands
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
        previousCompressed = Array(repeating: 0, count: onsetBands.count)
        fluxHistory.removeAll()
        windowsSinceOnset = 0
    }
}

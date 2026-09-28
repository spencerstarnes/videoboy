//
//  BeatNetFeatures.swift — BeatNet's input features, one frame at a time.
//
//  Purpose : Turns 22,050 Hz mono audio into the 272 numbers per 20 ms frame that
//            BeatNet's network was trained on: a log-magnitude spectrogram on 136
//            log-spaced bands (24 per octave, 30 Hz up), followed by its positive
//            first difference. This is madmom's pipeline as BeatNet configures it
//            (LOG_SPECT in BeatNet/log_spect.py), rebuilt to run as a stream.
//  Inputs  : samples at `sampleRate`, any buffer size, via `add(_:)`.
//  Outputs : feature frames, in order, returned from `add(_:)`.
//  Connects: BeatNetTracker feeds it (after resampling); BeatNetModel consumes it.
//  Extend  : do not "improve" any step here. The network only knows these exact
//            numbers; BeatNetTests checks them against madmom to 1e-3.
//
//  ── THE STEPS, AND WHERE EACH MATCHES MADMOM ────────────────────────────────────
//
//  1. Frame i is 1,411 samples CENTRED on sample i·441, zero before the start —
//     madmom's FramedSignal with origin 0. So frame i needs audio 32 ms past its
//     own time before it can be computed; that is the feature's fixed latency.
//  2. Hann window (numpy's `hanning`, symmetric), then a 1,411-point DFT, keeping
//     bins 0…704 (madmom drops the Nyquist bin). 1,411 is not a size any FFT
//     library takes, so this is a direct DFT done as one matrix–vector product —
//     about 2 M multiply-adds per frame, a fraction of a millisecond on the AMX.
//  3. Magnitude times madmom's normalised log filterbank (shipped in the weights
//     file, not recomputed), then log10(1 + x).
//  4. Difference with the previous frame, negative values clipped to 0. madmom's
//     diff_ratio 0.5 works out to exactly one frame for this window and hop.
//     Frame 0 has no previous frame and madmom gives it a difference of zero —
//     not "everything rose from silence".
//

import Accelerate
import Foundation

/// Streams BeatNet's features out of audio.
public final class BeatNetFeatures {

    /// The rate the network was trained at.
    public static let sampleRate = 22_050.0
    /// Samples between frames: 20 ms, 50 frames per second.
    public static let hopSize = 441
    /// Samples per frame: 64 ms.
    public static let frameSize = 1_411
    /// DFT bins kept.
    public static let fftBins = 705
    /// Log-frequency bands.
    public static let bands = 136
    /// Numbers per feature frame: the bands, then their difference.
    public static let featureSize = 272
    /// Frames per second.
    public static let framesPerSecond = sampleRate / Double(hopSize)

    /// Samples before a frame's centre.
    private static let halfFrame = frameSize / 2

    /// cos and −sin of the DFT, bins × samples, with the Hann window folded in.
    /// Shared: it is 8 MB and identical for every instance.
    private static let dftTables: (real: [Float], imaginary: [Float]) = {
        let size = frameSize
        var real = [Float](repeating: 0, count: fftBins * size)
        var imaginary = [Float](repeating: 0, count: fftBins * size)
        for sample in 0..<size {
            // numpy.hanning(M): 0.5 − 0.5·cos(2πn/(M−1)).
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(sample) / Double(size - 1))
            for bin in 0..<fftBins {
                // k·n mod N keeps the angle exact however large k·n gets.
                let turn = Double((bin * sample) % size) / Double(size)
                real[bin * size + sample] = Float(window * cos(2 * Double.pi * turn))
                imaginary[bin * size + sample] = Float(-window * sin(2 * Double.pi * turn))
            }
        }
        return (real, imaginary)
    }()

    private let filterbank: [Float]

    /// Audio not yet consumed. `buffer[0]` is absolute sample `bufferStart`.
    private var buffer: [Float]
    private var bufferStart: Int
    /// Index of the next frame to compute.
    private(set) public var nextFrame = 0
    private var previousBands = [Float](repeating: 0, count: bands)

    // Scratch, reused every frame.
    private var real = [Float](repeating: 0, count: fftBins)
    private var imaginary = [Float](repeating: 0, count: fftBins)
    private var magnitude = [Float](repeating: 0, count: fftBins)
    private var filtered = [Float](repeating: 0, count: bands)

    public init(weights: BeatNetWeights) {
        filterbank = weights.filterbank.values
        _ = Self.dftTables
        buffer = [Float](repeating: 0, count: Self.halfFrame)
        bufferStart = -Self.halfFrame
        buffer.reserveCapacity(Self.frameSize * 4)
    }

    /// Forgets all audio; the next frame is frame 0 again.
    public func reset() {
        buffer = [Float](repeating: 0, count: Self.halfFrame)
        bufferStart = -Self.halfFrame
        nextFrame = 0
        previousBands = [Float](repeating: 0, count: Self.bands)
    }

    /// Adds audio and returns every frame it completed, oldest first.
    public func add(_ samples: [Float]) -> [[Float]] {
        buffer.append(contentsOf: samples)
        var frames: [[Float]] = []
        while true {
            let frameStart = nextFrame * Self.hopSize - Self.halfFrame
            let offset = frameStart - bufferStart
            guard offset >= 0, offset + Self.frameSize <= buffer.count else { break }
            frames.append(computeFrame(at: offset))
            nextFrame += 1
            // Drop what no later frame will read.
            let keepFrom = nextFrame * Self.hopSize - Self.halfFrame - bufferStart
            if keepFrom > 0 {
                buffer.removeFirst(keepFrom)
                bufferStart += keepFrom
            }
        }
        return frames
    }

    /// One feature frame from `buffer[offset ..< offset + frameSize]`.
    private func computeFrame(at offset: Int) -> [Float] {
        let size = Self.frameSize
        let tables = Self.dftTables
        buffer.withUnsafeBufferPointer { samples in
            let frame = samples.baseAddress! + offset
            // bins × samples times samples × 1.
            vDSP_mmul(tables.real, 1, frame, 1, &real, 1,
                      vDSP_Length(Self.fftBins), 1, vDSP_Length(size))
            vDSP_mmul(tables.imaginary, 1, frame, 1, &imaginary, 1,
                      vDSP_Length(Self.fftBins), 1, vDSP_Length(size))
        }
        for bin in 0..<Self.fftBins {
            magnitude[bin] = (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot()
        }
        // 1 × bins times bins × bands.
        vDSP_mmul(magnitude, 1, filterbank, 1, &filtered, 1,
                  1, vDSP_Length(Self.bands), vDSP_Length(Self.fftBins))

        var features = [Float](repeating: 0, count: Self.featureSize)
        for band in 0..<Self.bands {
            let level = log10(filtered[band] + 1)
            features[band] = level
            features[Self.bands + band] = nextFrame == 0 ? 0 : max(level - previousBands[band], 0)
            previousBands[band] = level
        }
        return features
    }
}

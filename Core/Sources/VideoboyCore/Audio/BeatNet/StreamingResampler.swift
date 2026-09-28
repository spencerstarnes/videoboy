//
//  StreamingResampler.swift — any sample rate to BeatNet's 22,050 Hz, as a stream.
//
//  Purpose : BeatNet was trained on 22,050 Hz audio; the Mac delivers 44.1 or
//            48 kHz. This converts a live stream with a windowed-sinc filter.
//  Inputs  : mono samples at `inputRate`, any buffer size.
//  Outputs : mono samples at `outputRate`.
//  Connects: BeatNetTracker, in front of BeatNetFeatures.
//  Extend  : quality is set by `zeroCrossings`; timing must stay exact (below).
//
//  ── TIMING ───────────────────────────────────────────────────────────────────────
//
//  Output sample n is the band-limited signal at time n / outputRate exactly — the
//  filter is centred on that instant, and the output simply waits until the input
//  has run far enough past it. So the resampler adds latency but no timing offset,
//  and a beat found at output time t happened at input time t. The beat clock's
//  phase depends on that.
//

import Foundation

/// A streaming windowed-sinc sample-rate converter.
public final class StreamingResampler {

    public let inputRate: Double
    public let outputRate: Double

    /// Kernel half-width, in zero crossings of the (lower) cutoff.
    private static let zeroCrossings = 16
    /// Table entries per zero crossing.
    private static let tableResolution = 256

    /// Input samples per output sample.
    private let step: Double
    /// Cutoff as a fraction of the input Nyquist: below both Nyquists, with a margin.
    private let cutoff: Double
    /// Kernel half-width in input samples.
    private let halfWidth: Double
    /// Windowed sinc sampled every 1/tableResolution of a zero crossing, from 0 out.
    private let table: [Double]

    /// Unconsumed input. `input[0]` is absolute input sample `inputStart`.
    private var input: [Float] = []
    private var inputStart = 0
    /// Next output sample to produce.
    private var nextOutput = 0

    public init(inputRate: Double, outputRate: Double) {
        self.inputRate = inputRate
        self.outputRate = outputRate
        step = inputRate / outputRate
        cutoff = min(1, outputRate / inputRate) * 0.95
        halfWidth = Double(Self.zeroCrossings) / cutoff
        let count = Self.zeroCrossings * Self.tableResolution + 2
        table = (0..<count).map { index in
            let x = Double(index) / Double(Self.tableResolution)      // in zero crossings
            let sinc = x == 0 ? 1 : sin(Double.pi * x) / (Double.pi * x)
            // Blackman window over ±zeroCrossings.
            let phase = Double.pi * (x / Double(Self.zeroCrossings) + 1)
            let window = x >= Double(Self.zeroCrossings)
                ? 0 : 0.42 - 0.5 * cos(phase) + 0.08 * cos(2 * phase)
            return sinc * window
        }
        // Samples before the stream starts are silence.
        let lead = Int(halfWidth.rounded(.up)) + 1
        input = [Float](repeating: 0, count: lead)
        inputStart = -lead
    }

    /// Whether this resampler is a no-op.
    public var isPassthrough: Bool { inputRate == outputRate }

    /// Kernel value at `distance` input samples from the centre.
    private func kernel(_ distance: Double) -> Double {
        let position = abs(distance) * cutoff * Double(Self.tableResolution)
        let index = Int(position)
        guard index + 1 < table.count else { return 0 }
        let fraction = position - Double(index)
        return table[index] * (1 - fraction) + table[index + 1] * fraction
    }

    /// Adds input and returns every output sample it completed.
    public func process(_ samples: [Float]) -> [Float] {
        if isPassthrough { return samples }
        input.append(contentsOf: samples)
        let inputEnd = inputStart + input.count          // one past the last sample
        var output: [Float] = []
        output.reserveCapacity(Int(Double(samples.count) / step) + 2)
        while true {
            let centre = Double(nextOutput) * step
            let last = Int((centre + halfWidth).rounded(.down))
            guard last < inputEnd else { break }
            let first = Int((centre - halfWidth).rounded(.up))
            var sum = 0.0
            for index in first...last {
                sum += Double(input[index - inputStart]) * kernel(Double(index) - centre)
            }
            output.append(Float(sum * cutoff))
            nextOutput += 1
        }
        // Drop input no later output will read.
        let keepFrom = Int((Double(nextOutput) * step - halfWidth).rounded(.up)) - 1
        let drop = min(keepFrom - inputStart, input.count)
        if drop > 0 {
            input.removeFirst(drop)
            inputStart += drop
        }
        return output
    }
}

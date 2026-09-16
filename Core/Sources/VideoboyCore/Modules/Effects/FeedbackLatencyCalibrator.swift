//
//  FeedbackLatencyCalibrator.swift — measures the round trip of a physical loop.
//
//  Purpose : SPEC 10 is explicit that physical feedback through display adapters and
//            a capture device has real round-trip latency — capture buffer, display
//            present, and the converter in between — and that beat-driven effects in
//            that loop go out of time unless it is measured. This measures it: flash
//            a frame, watch for it to come back, count the frames in between.
//  Inputs  : a `flash` closure that puts a marker frame on the output, and a
//            `sample` closure that returns the most recently captured frame.
//  Outputs : a measured round-trip in frames, and in seconds.
//  Connects: the feedback bus (which offsets its scheduling by the result), and the
//            self-QA loopback check.
//  Extend  : the detection is deliberately simple — mean luma crossing a threshold.
//            A marker with a spatial signature would survive a noisier loop.
//

import Foundation

/// The outcome of a calibration run.
public struct FeedbackLatency: Equatable {
    /// Round trip measured in captured frames, counted from one.
    ///
    /// A marker that comes back on the very next captured frame is **one** frame of
    /// latency, not zero: it still took a frame to get there. Counting from zero here
    /// would under-report every measurement by a frame and quietly bias the
    /// scheduling compensation that depends on it.
    public let frames: Int
    /// The same, in seconds.
    public let seconds: Double
    /// How confident the measurement is: how far the detected frame stood out from
    /// the baseline, relative to the threshold used. Above 1 means a clear detection.
    public let confidence: Double

    public init(frames: Int, seconds: Double, confidence: Double) {
        self.frames = frames
        self.seconds = seconds
        self.confidence = confidence
    }
}

/// Why a calibration could not produce a number.
public enum CalibrationFailure: Error, CustomStringConvertible {
    case noSignal
    case markerNeverReturned(searchedFrames: Int)

    public var description: String {
        switch self {
        case .noSignal:
            "the capture side produced no frames, so there is nothing to measure"
        case .markerNeverReturned(let searched):
            "the marker frame never came back within \(searched) frames — check that the loop is physically connected"
        }
    }
}

/// Measures how long a frame takes to go out and come back.
public enum FeedbackLatencyCalibrator {

    /// Runs a calibration.
    ///
    /// The method: sample the loop for a moment to learn what "nothing happening"
    /// looks like, flash a bright frame, then keep sampling until a frame stands out
    /// from that baseline. The number of frames in between is the round trip.
    ///
    /// - Parameters:
    ///   - frameRate: project frame rate, used to convert frames to seconds.
    ///   - maximumFrames: give up after this many frames.
    ///   - baselineFrames: how many frames to average for the "quiet" reference.
    ///   - flash: called once to put the marker on the output.
    ///   - sample: returns the most recently captured frame, or nil if none is ready.
    public static func measure(
        frameRate: Double = StandardDefinition.frameRate,
        maximumFrames: Int = 60,
        baselineFrames: Int = 8,
        flash: () -> Void,
        sample: () -> ImageBuffer?
    ) throws -> FeedbackLatency {

        /// Mean luma of a frame — the quantity a flash moves most.
        func brightness(_ image: ImageBuffer) -> Double {
            let mean = FrameAssertions.meanColor(image)
            return 0.299 * mean.r + 0.587 * mean.g + 0.114 * mean.b
        }

        // Learn the quiet baseline first, so the detector is measuring a change
        // rather than an absolute level it has no reason to know.
        var baselineSamples: [Double] = []
        for _ in 0..<baselineFrames {
            guard let frame = sample() else { continue }
            baselineSamples.append(brightness(frame))
        }
        guard !baselineSamples.isEmpty else { throw CalibrationFailure.noSignal }

        let baseline = baselineSamples.reduce(0, +) / Double(baselineSamples.count)
        // Spread of the quiet signal, so the threshold adapts to a noisy loop rather
        // than being a number picked in advance.
        let spread = baselineSamples
            .map { abs($0 - baseline) }
            .reduce(0, +) / Double(baselineSamples.count)
        // Well clear of the noise floor, with a minimum so a perfectly still image
        // does not give a threshold of zero.
        let threshold = max(spread * 6.0, 12.0)

        Log.info(.render, "feedback calibration: baseline luma \(String(format: "%.1f", baseline)), threshold \(String(format: "%.1f", threshold))")

        flash()

        for frameIndex in 0..<maximumFrames {
            guard let frame = sample() else { continue }
            let deviation = brightness(frame) - baseline
            if deviation > threshold {
                // See `frames`: the first frame after the flash counts as one.
                let roundTripFrames = frameIndex + 1
                let seconds = frameRate > 0 ? Double(roundTripFrames) / frameRate : 0
                Log.info(.render, "feedback round trip measured at \(roundTripFrames) frames (\(String(format: "%.1f", seconds * 1000)) ms)")
                return FeedbackLatency(
                    frames: roundTripFrames,
                    seconds: seconds,
                    confidence: deviation / threshold
                )
            }
        }
        throw CalibrationFailure.markerNeverReturned(searchedFrames: maximumFrames)
    }
}

//
//  CaptureSource.swift — the loopback capture seam and its metrics.
//
//  Purpose : Lets the harness read back the real analog-facing signal (app -> HDMI
//            card -> HDMI-to-RCA -> DVC100 -> USB) without Core depending on
//            AVFoundation, a camera permission, or the hardware being plugged in.
//  Inputs  : a `CaptureRequest` (which device, how many frames, expected format).
//  Outputs : `CapturedSequence` — sample frames plus a `CaptureMetrics` summary
//            that serialises to the metrics.json named in docs/SELF-QA-HARNESS.md.
//  Connects: implemented for real by AVFoundationCaptureSource in the App target
//            (which owns NSCameraUsageDescription); implemented by MockCaptureSource
//            here so Core builds and tests with nothing attached.
//  Extend  : add another conformer for a different grabber. Do not add device names
//            to this file — identity comes from config/devices.json (DeviceConfig).
//

import Foundation

/// What to capture.
public struct CaptureRequest {
    /// Substring matched against enumerated device names, from config/devices.json.
    public let deviceNameContains: String
    /// How many frames to grab before summarising.
    public let frameCount: Int
    /// The rate the app believes it is emitting, for comparison against measurement.
    public let expectedFrameRate: Double
    /// The mode string the app logged when it negotiated its output (SPEC 3), carried
    /// into metrics.json so the captured signal can be compared with what was claimed.
    public let loggedOutputMode: String

    public init(
        deviceNameContains: String,
        frameCount: Int = 120,
        expectedFrameRate: Double = StandardDefinition.frameRate,
        loggedOutputMode: String = "unknown"
    ) {
        self.deviceNameContains = deviceNameContains
        self.frameCount = frameCount
        self.expectedFrameRate = expectedFrameRate
        self.loggedOutputMode = loggedOutputMode
    }
}

/// One captured frame and the host time it arrived.
public struct CapturedFrame {
    public let image: ImageBuffer
    /// Presentation time in seconds on the host clock.
    public let timestamp: Double

    public init(image: ImageBuffer, timestamp: Double) {
        self.image = image
        self.timestamp = timestamp
    }
}

/// The numeric summary written to metrics.json. Field names match
/// docs/SELF-QA-HARNESS.md exactly so the doc stays the contract.
public struct CaptureMetrics: Codable {
    public var capturedWidth: Int
    public var capturedHeight: Int
    public var effectiveFps: Double
    public var droppedFrames: Int
    public var duplicateFrames: Int
    public var combingScore: Double
    public var signalPresent: Bool
    public var loggedOutputMode: String
    public var frameCount: Int
    public var deviceName: String

    public init(
        capturedWidth: Int, capturedHeight: Int, effectiveFps: Double,
        droppedFrames: Int, duplicateFrames: Int, combingScore: Double,
        signalPresent: Bool, loggedOutputMode: String, frameCount: Int, deviceName: String
    ) {
        self.capturedWidth = capturedWidth
        self.capturedHeight = capturedHeight
        self.effectiveFps = effectiveFps
        self.droppedFrames = droppedFrames
        self.duplicateFrames = duplicateFrames
        self.combingScore = combingScore
        self.signalPresent = signalPresent
        self.loggedOutputMode = loggedOutputMode
        self.frameCount = frameCount
        self.deviceName = deviceName
    }

    /// Writes metrics.json next to the sample PNGs.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
        Log.info(.selfqa, "wrote metrics -> \(url.path)")
    }
}

/// Frames plus their summary.
public struct CapturedSequence {
    public let frames: [CapturedFrame]
    public let metrics: CaptureMetrics

    public init(frames: [CapturedFrame], metrics: CaptureMetrics) {
        self.frames = frames
        self.metrics = metrics
    }
}

/// Why a capture could not run. `deviceNotFound` and `permissionDenied` are reported
/// as `blocked`, never `fail` — absent hardware is not a defect in the app.
public enum CaptureError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case permissionDenied
    case noFramesArrived(String)
    case configurationFailed(String)

    public var description: String {
        switch self {
        case .deviceNotFound(let name): "no capture device matching '\(name)' is attached"
        case .permissionDenied: "camera permission was not granted to this app"
        case .noFramesArrived(let detail): "capture produced no frames: \(detail)"
        case .configurationFailed(let detail): "capture session configuration failed: \(detail)"
        }
    }

    /// True when the cause is missing hardware or permission rather than a bug.
    /// The harness maps these to `blocked` in result.txt.
    public var isEnvironmental: Bool {
        switch self {
        case .deviceNotFound, .permissionDenied: true
        case .noFramesArrived, .configurationFailed: false
        }
    }
}

/// The seam. One method: hand it a request, get frames and metrics or an error.
public protocol CaptureSource {
    /// Names of capture devices currently visible, for logging and for filling in
    /// config/devices.json.
    func enumerateDeviceNames() -> [String]

    /// Captures `request.frameCount` frames, blocking until done or failed.
    func capture(_ request: CaptureRequest) throws -> CapturedSequence
}

/// A `CaptureSource` that fabricates a plausible sequence. Used so Core's tests run
/// with no DVC100 attached.
///
/// It is honest about being a mock: `deviceName` in the metrics is prefixed `mock:`,
/// so no artifact produced by this type can be mistaken for hardware evidence.
public struct MockCaptureSource: CaptureSource {
    /// The picture every mock frame carries.
    public let pattern: ImageBuffer
    /// The rate the mock pretends to run at.
    public let frameRate: Double
    /// Device names the mock claims to see.
    public let deviceNames: [String]

    public init(
        pattern: ImageBuffer = TestPattern.colorBars(),
        frameRate: Double = StandardDefinition.frameRate,
        deviceNames: [String] = ["mock: DVC100"]
    ) {
        self.pattern = pattern
        self.frameRate = frameRate
        self.deviceNames = deviceNames
    }

    public func enumerateDeviceNames() -> [String] { deviceNames }

    public func capture(_ request: CaptureRequest) throws -> CapturedSequence {
        let interval = 1.0 / frameRate
        var frames: [CapturedFrame] = []
        frames.reserveCapacity(request.frameCount)
        for index in 0..<request.frameCount {
            frames.append(CapturedFrame(image: pattern, timestamp: Double(index) * interval))
        }
        let metrics = CaptureMetricsBuilder.summarise(
            frames: frames,
            expectedFrameRate: request.expectedFrameRate,
            loggedOutputMode: request.loggedOutputMode,
            deviceName: "mock: \(request.deviceNameContains)"
        )
        Log.info(.selfqa, "MockCaptureSource produced \(frames.count) frames (not hardware evidence)")
        return CapturedSequence(frames: frames, metrics: metrics)
    }
}

/// Turns raw captured frames into the metrics summary. Shared by every
/// `CaptureSource` so mock and real capture are measured identically.
public enum CaptureMetricsBuilder {

    /// Measures rate, drops, duplicates, combing and signal presence over a sequence.
    ///
    /// - Parameters:
    ///   - frames: captured frames in arrival order. At least one is required.
    ///   - expectedFrameRate: the rate the app claims to emit, used to judge drops.
    ///   - loggedOutputMode: the app's own negotiated-mode string, copied through.
    ///   - deviceName: the device the frames came from, recorded for provenance.
    public static func summarise(
        frames: [CapturedFrame],
        expectedFrameRate: Double,
        loggedOutputMode: String,
        deviceName: String
    ) -> CaptureMetrics {
        guard let first = frames.first else {
            return CaptureMetrics(
                capturedWidth: 0, capturedHeight: 0, effectiveFps: 0,
                droppedFrames: 0, duplicateFrames: 0, combingScore: 0,
                signalPresent: false, loggedOutputMode: loggedOutputMode,
                frameCount: 0, deviceName: deviceName
            )
        }

        // Effective rate from the span between the first and last timestamps.
        let elapsed = (frames.last?.timestamp ?? first.timestamp) - first.timestamp
        let effectiveFps = (elapsed > 0 && frames.count > 1)
            ? Double(frames.count - 1) / elapsed
            : 0

        // A gap longer than 1.5 nominal intervals means at least one frame never
        // arrived. 1.5 leaves room for ordinary jitter without counting it as a drop.
        let nominalInterval = expectedFrameRate > 0 ? 1.0 / expectedFrameRate : 0
        var droppedFrames = 0
        if nominalInterval > 0 {
            for index in 1..<max(frames.count, 1) {
                let gap = frames[index].timestamp - frames[index - 1].timestamp
                if gap > nominalInterval * 1.5 {
                    droppedFrames += Int((gap / nominalInterval).rounded()) - 1
                }
            }
        }

        // Consecutive frames whose pictures are effectively identical. On a live
        // signal a few are normal; a runaway count means the source has stalled.
        var duplicateFrames = 0
        for index in 1..<max(frames.count, 1) {
            let changed = FrameAssertions.differingPixelFraction(
                frames[index - 1].image, frames[index].image
            )
            if changed < 0.001 { duplicateFrames += 1 }
        }

        // Combing and signal presence are sampled over a handful of frames rather
        // than all of them: both are properties of the signal, not of one frame,
        // and full-sequence analysis is needlessly slow.
        let sampleStride = max(frames.count / 8, 1)
        let sampled = stride(from: 0, to: frames.count, by: sampleStride).map { frames[$0].image }
        let combingScore = sampled.map(FrameAssertions.combingScore).reduce(0, +) / Double(sampled.count)
        let signalPresent = sampled.contains { FrameAssertions.signalPresent($0) }

        return CaptureMetrics(
            capturedWidth: first.image.width,
            capturedHeight: first.image.height,
            effectiveFps: effectiveFps,
            droppedFrames: droppedFrames,
            duplicateFrames: duplicateFrames,
            combingScore: combingScore,
            signalPresent: signalPresent,
            loggedOutputMode: loggedOutputMode,
            frameCount: frames.count,
            deviceName: deviceName
        )
    }
}

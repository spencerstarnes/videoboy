//
//  CaptureSourceNode.swift — a capture device as a normal graph source (SPEC 10).
//
//  Purpose : Makes live capture — the DVC100, or any UVC dongle — assignable to A/B/C/D
//            like any other source, so it can be mixed, recorded and fed back.
//  Inputs  : frames pushed in from a capture session on its own thread.
//  Outputs : one texture.
//  Connects: Core's `CaptureSource` protocol for the frames; the App supplies a real
//            implementation (AVFoundation, or the out-of-process DVC100 tool).
//  Extend  : this node does not know or care which grabber is behind it. Keep it that
//            way: device specifics belong in the `CaptureSource` conformer.
//
//  Threading: `submit(frame:)` is called from a capture thread and only touches
//  `pendingImage` under the lock. The GPU upload happens in `render`, on the render
//  thread, because Metal resources must not be created from the capture callback.
//

import Foundation
import Metal

/// Presents live capture as a source node.
public final class CaptureSourceNode: Node {

    public let identifier: String
    public let kind: NodeKind = .source

    /// A capture device buffers at least a frame before it hands anything over, and
    /// the loop that feeds it has its own delay. Declaring it lets the scheduler
    /// compensate; `measuredLatencyFrames` replaces it once calibration has run.
    public var latencyInFrames: Int { measuredLatencyFrames ?? 2 }

    /// Round-trip latency measured by `FeedbackLatencyCalibrator`, when it has run.
    /// Until then the declared default stands in.
    public var measuredLatencyFrames: Int?

    public var parameters: [Parameter] {
        [
            Parameter(code: .opacity, range: 0...1, defaultValue: 1),
            Parameter(code: .contrast, range: 0...2, defaultValue: 1),
            Parameter(code: .saturation, range: 0...2, defaultValue: 1)
        ]
    }

    /// Name of the device this node is showing, for the panel subtitle.
    public private(set) var deviceName: String?

    private let context: MetalContext?
    private let lock = NSLock()
    private var pendingImage: ImageBuffer?
    private var texture: MTLTexture?
    /// Frames handed over since this node started, for the debug overlay.
    private(set) public var receivedFrameCount = 0

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
    }

    /// Hands a newly captured frame to the node. Safe to call from a capture thread.
    ///
    /// Only the most recent frame is kept: if the render loop is behind, showing the
    /// newest frame is right and queueing stale ones would only add latency.
    public func submit(frame: ImageBuffer, deviceName: String? = nil) {
        lock.lock()
        pendingImage = frame
        receivedFrameCount += 1
        if let deviceName { self.deviceName = deviceName }
        lock.unlock()
    }

    /// The most recent captured frame, for the latency calibrator to sample.
    public func latestImage() -> ImageBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return pendingImage
    }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context else { return texture }

        lock.lock()
        let image = pendingImage
        pendingImage = nil
        lock.unlock()

        // Nothing new this frame: keep showing the last one rather than flashing black.
        guard let image else { return texture }

        texture = metal.makeTexture(from: image, label: "\(identifier)-capture")
        return texture
    }
}

//
//  FeedbackNode.swift — internal and external feedback (SPEC 10).
//
//  Purpose : Routes an output back into itself with a frame delay and a geometric
//            transform — the classic infinite tunnel. Internally this is a texture
//            loop; externally the same node takes a captured frame as its history,
//            so a physical loop out through a display and back through a grabber
//            behaves identically.
//  Inputs  : slot 0 the live picture; slot 1, optionally, an externally captured
//            frame to use as the loop's history instead of the internal one.
//  Outputs : one texture.
//  Connects: MetalContext.feedbackPipeline, FeedbackLatencyCalibrator.
//
//  Parameters: 43C gain, 44C delay frames, 45C zoom, 46C rotate, 47C threshold.
//

import Foundation
import Metal

/// The parameter block handed to the shader. Must match `FeedbackParams` in Metal.
private struct FeedbackParams {
    var gain: Float
    var zoom: Float
    var rotate: Float
    var threshold: Float
}

/// Mixes a delayed, transformed copy of its own output back in.
public final class FeedbackNode: Node {

    public let identifier: String
    public let kind: NodeKind = .effect

    /// The loop's own delay is its latency: an event that must land on a beat *after*
    /// going round the loop has to be scheduled this many frames early.
    public var latencyInFrames: Int { delayFrames }

    public var parameters: [Parameter] {
        [
            Parameter(code: .wetDry, range: 0...1, defaultValue: 1),
            Parameter(code: .feedbackGain, range: 0...1, defaultValue: 0.5),
            Parameter(
                code: .feedbackDelayFrames,
                range: 0...Double(FeedbackNode.maximumDelayFrames),
                defaultValue: 1
            ),
            Parameter(code: .feedbackZoom, range: 0.5...1.5, defaultValue: 1.02),
            Parameter(code: .feedbackRotate, range: -0.25...0.25, defaultValue: 0.0),
            Parameter(code: .feedbackThreshold, range: 0...1, defaultValue: 0.05)
        ]
    }

    /// Longest delay the ring buffer holds. Two seconds at SD rates is far more than
    /// the effect is musically useful over, and bounds the memory it costs.
    public static let maximumDelayFrames = 60

    public var gain = 0.5
    /// Zoom applied each time round the loop. Just above 1 pushes the image inward.
    public var zoom = 1.02
    /// Rotation per trip, in turns.
    public var rotate = 0.0
    /// Luma key on what re-enters the loop.
    public var threshold = 0.05
    /// How many frames back the loop reads from.
    public var delayFrames = 1 {
        didSet { delayFrames = min(max(delayFrames, 0), FeedbackNode.maximumDelayFrames) }
    }

    /// 0 bypasses the effect entirely, 1 is fully applied. This is what the Wet/Dry
    /// slider and the enable switch in the FX panel both drive.
    public var wetDry = 1.0

    /// Target for the wet/dry blend, allocated alongside the effect's own buffers.
    private var blendTarget: MTLTexture?

    private let context: MetalContext?
    /// Ring of past outputs, so a delay of N frames reads the frame from N ago.
    private var ring: [MTLTexture?] = []
    private var ringPosition = 0
    private var ringSize = 0

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
    }

    /// Empties the loop.
    public func reset() {
        ring = []
        ringSize = 0
        ringPosition = 0
    }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context, let input = inputs.first else { return inputs.first }
        // Fully dry bypasses the effect, and — importantly — leaves its history
        // alone, so switching it back on resumes rather than restarting.
        guard wetDry > 0.001 else { return input }

        let width = input.width
        let height = input.height
        // The ring must be one longer than the delay so the oldest entry is still
        // intact when it is read, rather than being the one about to be overwritten.
        let requiredSize = delayFrames + 2

        if ringSize != requiredSize || ring.first??.width != width || ring.first??.height != height {
            ring = (0..<requiredSize).map {
                metal.makeRenderTarget(width: width, height: height, label: "\(identifier)-ring\($0)")
            }
            ringSize = requiredSize
            ringPosition = 0
        }
        guard ringSize > 0, let target = ring[ringPosition] else { return input }

        // Read `delayFrames` back around the ring. An external frame, when supplied,
        // replaces the internal history — that is the physical-loop case.
        let readPosition = ((ringPosition - delayFrames) % ringSize + ringSize) % ringSize
        let history = inputs.count > 1 ? inputs[1] : ring[readPosition]

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            Log.error(.render, "\(identifier) could not encode its feedback pass")
            return input
        }

        var params = FeedbackParams(
            gain: Float(min(max(gain, 0), 1)),
            zoom: Float(zoom),
            rotate: Float(rotate),
            threshold: Float(threshold)
        )
        encoder.label = identifier
        encoder.setRenderPipelineState(metal.feedbackPipeline)
        encoder.setFragmentTexture(input, index: 0)
        // With no history yet, the input stands in: the first frame simply has no
        // loop behind it, which is correct rather than black.
        encoder.setFragmentTexture(history ?? input, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<FeedbackParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            Log.error(.render, "\(identifier) feedback pass failed: \(error)")
            return input
        }

        ringPosition = (ringPosition + 1) % ringSize
        guard wetDry < 0.999 else { return target }
        return blendWetDry(dry: input, wet: target, metal: metal)
    }

    /// Mixes the processed result back over the original by `wetDry`.
    private func blendWetDry(dry: MTLTexture, wet: MTLTexture, metal: MetalContext) -> MTLTexture? {
        if blendTarget == nil || blendTarget?.width != dry.width || blendTarget?.height != dry.height {
            blendTarget = metal.makeRenderTarget(
                width: dry.width, height: dry.height, label: "\(identifier)-wetdry")
        }
        guard let blendTarget else { return wet }
        guard metal.blend(dry: dry, wet: wet, amount: wetDry, into: blendTarget, label: identifier) else {
            return wet
        }
        return blendTarget
    }

    /// Pulls settings from the registry.
    public func applyParameters(from registry: ParamRegistry) {
        if let value = registry.value(slot: identifier, code: .wetDry) { wetDry = value }
        if let value = registry.value(slot: identifier, code: .feedbackGain) { gain = value }
        if let value = registry.value(slot: identifier, code: .feedbackZoom) { zoom = value }
        if let value = registry.value(slot: identifier, code: .feedbackRotate) { rotate = value }
        if let value = registry.value(slot: identifier, code: .feedbackThreshold) { threshold = value }
        if let value = registry.value(slot: identifier, code: .feedbackDelayFrames) {
            delayFrames = Int(value.rounded())
        }
    }
}

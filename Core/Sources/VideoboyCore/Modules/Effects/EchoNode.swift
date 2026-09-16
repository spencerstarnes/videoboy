//
//  EchoNode.swift — echo / tone trails (SPEC 9).
//
//  Purpose : VDMX-style feedback echo. Each frame is accumulated into a history
//            buffer that decays, so bright things leave tails behind them.
//  Inputs  : one texture.
//  Outputs : one texture — the live picture with its trail behind it.
//  Connects: MetalContext.echoPipeline; clock-syncable through the scheduler.
//
//  BEHAVIOURAL EMULATION, stated plainly per SPEC 9: this is a frame-history mix,
//  not a phosphor model. Real phosphor decays non-linearly and at different rates
//  per emitter, and this does not claim to.
//
//  Parameters: 21A decay, 22A trail length, 23A threshold, 02A wet/dry.
//

import Foundation
import Metal

/// The parameter block handed to the shader. Must match `EchoParams` in Metal.
private struct EchoParams {
    var decay: Float
    var threshold: Float
    var gain: Float
}

/// Accumulates a decaying history of its input.
public final class EchoNode: Node {

    public let identifier: String
    public let kind: NodeKind = .effect
    /// The trail is produced from history already in hand, within the frame.
    public let latencyInFrames = 0

    public var parameters: [Parameter] {
        [
            Parameter(code: .wetDry, range: 0...1, defaultValue: 1),
            Parameter(code: .echoDecay, range: 0...1, defaultValue: 0.8),
            Parameter(code: .trailLength, range: 0...1, defaultValue: 0.6),
            Parameter(code: .echoThreshold, range: 0...1, defaultValue: 0.15)
        ]
    }

    /// How much of the history survives each frame. Near 1 is a very long tail.
    public var decay = 0.8
    /// How strongly the trail shows behind the picture.
    public var gain = 0.6
    /// Luma below this leaves no trail.
    public var threshold = 0.15

    /// 0 bypasses the effect entirely, 1 is fully applied. This is what the Wet/Dry
    /// slider and the enable switch in the FX panel both drive.
    public var wetDry = 1.0

    /// Target for the wet/dry blend, allocated alongside the effect's own buffers.
    private var blendTarget: MTLTexture?

    private let context: MetalContext?
    /// Two buffers, swapped each frame: one is read as history while the other is
    /// written. Reading and writing one texture in a single pass is undefined.
    private var history: [MTLTexture?] = [nil, nil]
    private var writeIndex = 0

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
    }

    /// Clears the trail. Used on a cut, and when the node is first connected.
    public func reset() {
        history = [nil, nil]
    }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context, let input = inputs.first else { return inputs.first }
        // Fully dry bypasses the effect, and — importantly — leaves its history
        // alone, so switching it back on resumes rather than restarting.
        guard wetDry > 0.001 else { return input }

        let width = input.width
        let height = input.height
        for slot in 0..<2 where history[slot] == nil
            || history[slot]?.width != width || history[slot]?.height != height {
            history[slot] = metal.makeRenderTarget(
                width: width, height: height, label: "\(identifier)-history\(slot)")
        }
        guard let readBuffer = history[1 - writeIndex], let writeBuffer = history[writeIndex] else {
            return input
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = writeBuffer
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            Log.error(.render, "\(identifier) could not encode its echo pass")
            return input
        }

        var params = EchoParams(
            decay: Float(min(max(decay, 0), 0.999)),
            threshold: Float(threshold),
            gain: Float(gain)
        )
        encoder.label = identifier
        encoder.setRenderPipelineState(metal.echoPipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentTexture(readBuffer, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<EchoParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            Log.error(.render, "\(identifier) echo pass failed: \(error)")
            return input
        }

        // Swap so next frame reads what was just written.
        writeIndex = 1 - writeIndex
        guard wetDry < 0.999 else { return writeBuffer }
        return blendWetDry(dry: input, wet: writeBuffer, metal: metal)
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
        if let value = registry.value(slot: identifier, code: .echoDecay) { decay = value }
        if let value = registry.value(slot: identifier, code: .trailLength) { gain = value }
        if let value = registry.value(slot: identifier, code: .echoThreshold) { threshold = value }
    }
}

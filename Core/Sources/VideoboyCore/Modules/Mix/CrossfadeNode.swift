//
//  CrossfadeNode.swift — the two-input layer compositor used for every bus (SPEC 12).
//
//  Purpose : ONE is A over B, TWO is C over D, PRIMARY is ONE over TWO. All three
//            are this same node, which is why the routing can be fixed and the
//            behaviour identical everywhere.
//  Inputs  : two textures (slot 0 is the left/"A" side, slot 1 the right/"B" side).
//  Outputs : the mixed texture.
//  Connects: MetalContext's crossfade pipeline — the same one the self-QA harness
//            uses, so an offscreen check and the live output cannot diverge.
//  Extend  : a new blend mode is a case in `BlendMode` plus a branch in the shader;
//            the node does not change.
//
//  Parameters (SPEC 13): one of 61A / 62A / 63A depending on which bus this is,
//  plus 65A blend mode and 66A layer opacity.
//

import Foundation
import Metal

/// The parameter block handed to the blend shader. Layout must match `BlendParams`
/// in the Metal source exactly.
private struct BlendParams {
    var mixAmount: Float
    var opacity: Float
    var mode: Int32
}

/// Mixes two inputs by a single position parameter.
public final class CrossfadeNode: Node {

    public let identifier: String
    public let kind: NodeKind = .mix
    /// A GPU blend of two ready textures completes within the frame it starts.
    public let latencyInFrames = 0

    /// Which crossfade parameter this instance owns.
    public let positionCode: ParamCode

    public var parameters: [Parameter] {
        [
            Parameter(code: positionCode, range: 0...1, defaultValue: 0.5),
            Parameter(code: .opacity, range: 0...1, defaultValue: 1),
            Parameter(code: .blendMode, range: 0...1, defaultValue: 0),
            Parameter(code: .layerOpacity, range: 0...1, defaultValue: 1)
        ]
    }

    /// 0 is entirely input 0, 1 is entirely input 1.
    public var position: Double = 0.5

    /// How the upper layer combines with the lower one.
    public var blendMode: BlendMode = .normal

    /// Per-layer opacity of the upper layer.
    public var layerOpacity: Double = 1.0

    private let context: MetalContext?
    private var target: MTLTexture?

    public init(identifier: String, positionCode: ParamCode, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.positionCode = positionCode
        self.context = context
    }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context else { return nil }

        // With only one input connected there is nothing to mix; pass it through.
        // This is what makes a half-built graph still show a picture.
        guard inputs.count >= 2 else { return inputs.first }
        let sourceA = inputs[0]
        let sourceB = inputs[1]

        // Reuse the render target across frames: SPEC 1 forbids per-frame allocation
        // in the render loop.
        if target == nil || target?.width != renderContext.width || target?.height != renderContext.height {
            target = metal.makeRenderTarget(
                width: renderContext.width, height: renderContext.height, label: identifier)
        }
        guard let target else { return nil }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            Log.error(.render, "\(identifier) could not encode its crossfade")
            return target
        }
        encoder.label = identifier
        encoder.setRenderPipelineState(metal.blendPipeline)
        encoder.setFragmentTexture(sourceA, index: 0)
        encoder.setFragmentTexture(sourceB, index: 1)
        var params = BlendParams(
            mixAmount: Float(min(max(position, 0), 1)),
            opacity: Float(min(max(layerOpacity, 0), 1)),
            mode: Int32(blendMode.rawValue)
        )
        encoder.setFragmentBytes(&params, length: MemoryLayout<BlendParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()

        return target
    }

    /// Pulls this node's settings from the registry.
    public func applyParameters(from registry: ParamRegistry) {
        if let value = registry.value(slot: identifier, code: positionCode) {
            position = value
        }
        if let value = registry.value(slot: identifier, code: .blendMode) {
            blendMode = BlendMode.from(normalised: value)
        }
        if let value = registry.value(slot: identifier, code: .layerOpacity) {
            layerOpacity = value
        }
    }
}

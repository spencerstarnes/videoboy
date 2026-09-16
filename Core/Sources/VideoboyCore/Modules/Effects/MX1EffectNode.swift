//
//  MX1EffectNode.swift — the MX-1 effect set (SPEC 9).
//
//  Purpose : Freeze, negative, black and white, mosaic, posterize/paint, flip and
//            mirror. SPEC 9 says plainly that these are trivial and are *not* where
//            the analog character comes from — that is the composite path. They are
//            here because a video mixer is expected to have them.
//  Inputs  : one texture.
//  Outputs : one texture.
//  Connects: MetalContext.mx1Pipeline. Freeze is handled here rather than in the
//            shader, because holding a frame is a question of which texture to
//            return, not of how to shade one.
//
//  Parameters: 02A wet/dry, 31A-ish mode selection via `effect`, plus `amount`.
//

import Foundation
import Metal

/// The parameter block handed to the shader. Must match `MX1Params` in Metal.
private struct MX1Params {
    var mode: Int32
    var amount: Float
    var width: Float
    var height: Float
}

/// One of the MX-1 effects.
public enum MX1Effect: Int, CaseIterable, Codable, Sendable {
    case negative = 0
    case blackAndWhite = 1
    case mosaic = 2
    case posterize = 3
    case mirror = 4
    case flip = 5
    case rotate180 = 6
    /// Holds the last frame. Handled in Swift, not in the shader.
    case freeze = 7

    public var displayName: String {
        switch self {
        case .negative: "Negative"
        case .blackAndWhite: "Black & White"
        case .mosaic: "Mosaic"
        case .posterize: "Posterize"
        case .mirror: "Mirror"
        case .flip: "Flip"
        case .rotate180: "Rotate 180"
        case .freeze: "Freeze"
        }
    }

    /// Selects from a 0...1 parameter.
    public static func from(normalised value: Double) -> MX1Effect {
        let all = allCases
        let index = Int((min(max(value, 0), 1) * Double(all.count - 1)).rounded())
        return all[min(index, all.count - 1)]
    }
}

/// Applies one MX-1 effect.
public final class MX1EffectNode: Node {

    public let identifier: String
    public let kind: NodeKind = .effect
    public let latencyInFrames = 0

    public var parameters: [Parameter] {
        [
            Parameter(code: .wetDry, range: 0...1, defaultValue: 1),
            Parameter(code: .contrast, range: 0...1, defaultValue: 0.5)
        ]
    }

    /// Which effect is applied.
    public var effect: MX1Effect = .negative
    /// Strength, where the meaning depends on the effect.
    public var amount = 0.5
    /// 0 bypasses entirely.
    public var wetDry = 1.0

    private let context: MetalContext?
    private var target: MTLTexture?
    private var blendTarget: MTLTexture?
    /// The held frame, for `freeze`.
    private var frozen: MTLTexture?

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
    }

    /// Drops a held frame, so freeze grabs a new one next time it is switched on.
    public func releaseFreeze() {
        frozen = nil
    }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context, let input = inputs.first else { return inputs.first }
        guard wetDry > 0.001 else {
            // Bypassed: also let go of any held frame, so re-enabling freeze grabs
            // what is on screen then rather than something from minutes ago.
            frozen = nil
            return input
        }

        // Freeze is not a shading operation — it is a choice of which texture to
        // hand on, so it is handled before the pass rather than inside it.
        if effect == .freeze {
            if frozen == nil { frozen = input }
            return frozen ?? input
        }
        frozen = nil

        let width = input.width
        let height = input.height
        if target == nil || target?.width != width || target?.height != height {
            target = metal.makeRenderTarget(width: width, height: height, label: identifier)
        }
        guard let target else { return input }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            Log.error(.render, "\(identifier) could not encode its MX-1 pass")
            return input
        }

        var params = MX1Params(
            mode: Int32(effect.rawValue),
            amount: Float(min(max(amount, 0), 1)),
            width: Float(width),
            height: Float(height)
        )
        encoder.label = identifier
        encoder.setRenderPipelineState(metal.mx1Pipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<MX1Params>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            Log.error(.render, "\(identifier) MX-1 pass failed: \(error)")
            return input
        }

        guard wetDry < 0.999 else { return target }
        if blendTarget == nil || blendTarget?.width != width || blendTarget?.height != height {
            blendTarget = metal.makeRenderTarget(width: width, height: height, label: "\(identifier)-wetdry")
        }
        guard let blendTarget,
              metal.blend(dry: input, wet: target, amount: wetDry, into: blendTarget, label: identifier) else {
            return target
        }
        return blendTarget
    }

    /// Pulls settings from the registry.
    public func applyParameters(from registry: ParamRegistry) {
        if let value = registry.value(slot: identifier, code: .wetDry) { wetDry = value }
        if let value = registry.value(slot: identifier, code: .contrast) { amount = value }
    }
}

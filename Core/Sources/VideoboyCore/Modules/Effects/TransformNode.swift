//
//  TransformNode.swift — scale, rotate, flip.
//
//  Purpose : The geometry stage. Resize a source to fit, spin it, or mirror it —
//            the operations you reach for when two cameras disagree about which way
//            up the world is, or when a clip needs to sit inside the frame rather
//            than filling it.
//  Inputs  : one texture.
//  Outputs : one texture, transformed. Anything outside the source frame is black.
//  Connects: MetalContext.transformPipeline (where the INVERSE-sampling trick is
//            explained), the Transform card in the FX chains.
//  Extend  : a new geometry control is a field here and a field on the shader's
//            TransformParams in the same position. The struct layout is a contract.
//
//  Reuses the existing geometry param codes — `scale`, `rotation` — rather than
//  minting new ones, because they mean exactly the same thing here that they mean
//  everywhere else. Only the two flips are new.
//

import Foundation
import Metal

/// Everything the transform can be told to do. All defaults are neutral.
public struct TransformSettings: Equatable, Codable, Sendable {
    /// 0.1...4, about the centre. 1 is unchanged.
    public var scale: Double
    /// Turns, 0...1. A full turn is 1.
    public var rotation: Double
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    /// Where the picture sits, -1...1 of the frame. 0 is centred.
    ///
    /// A share of the frame rather than pixels, so the same value means the same thing
    /// whatever the project geometry is — and so a mapped knob or an LFO travelling
    /// 0...1 covers the whole useful range rather than a few pixels of a 720-wide frame.
    public var offsetX: Double
    public var offsetY: Double

    public init(
        scale: Double = 1, rotation: Double = 0,
        flipHorizontal: Bool = false, flipVertical: Bool = false,
        offsetX: Double = 0, offsetY: Double = 0
    ) {
        self.scale = scale
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    public static let neutral = TransformSettings()

    /// Whether these settings would leave the picture untouched, so the pass can be
    /// skipped entirely rather than reproducing its input.
    public var isNeutral: Bool { self == .neutral }

    public mutating func clampToValidRanges() {
        scale = min(max(scale, 0.1), 4)
        // Wrapped rather than clamped: a rotation control that stops at one full turn
        // would jam at the top of its travel instead of coming round again.
        rotation = rotation.truncatingRemainder(dividingBy: 1)
        if rotation < 0 { rotation += 1 }
        // Clamped, not wrapped. Rotation coming round again is a continuous gesture;
        // a picture leaping from one edge to the other is not.
        offsetX = min(max(offsetX, -1), 1)
        offsetY = min(max(offsetY, -1), 1)
    }
}

/// Layout handed to the shader. Must match `TransformParams` in the Metal source.
private struct TransformParams {
    var scale: Float
    var rotation: Float
    var flipH: Float
    var flipV: Float
    var offsetX: Float
    var offsetY: Float
}

/// Scales, rotates and mirrors its input.
public final class TransformNode: Node {

    public let identifier: String
    public let kind: NodeKind = .effect
    public var latencyInFrames: Int { 0 }

    public var settings = TransformSettings.neutral
    public var wetDry: Double = 1.0

    private let context: MetalContext?
    private var target: MTLTexture?
    private var blendTarget: MTLTexture?

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
    }

    public var parameters: [Parameter] {
        [
            Parameter(code: .wetDry, range: 0...1, defaultValue: 1),
            Parameter(code: .scale, range: 0.1...4, defaultValue: 1),
            Parameter(code: .rotation, range: 0...1, defaultValue: 0),
            Parameter(code: .flipHorizontal, range: 0...1, defaultValue: 0),
            Parameter(code: .flipVertical, range: 0...1, defaultValue: 0),
            // Centred is the middle of the fader, so the control reads as an
            // adjustment either way rather than something that only pushes one
            // direction from nothing.
            Parameter(code: .positionX, range: -1...1, defaultValue: 0),
            Parameter(code: .positionY, range: -1...1, defaultValue: 0)
        ]
    }

    public func applyParameters(from registry: ParamRegistry) {
        if let v = registry.value(slot: identifier, code: .wetDry) { wetDry = v }
        if let v = registry.value(slot: identifier, code: .scale) { settings.scale = v }
        if let v = registry.value(slot: identifier, code: .rotation) { settings.rotation = v }
        if let v = registry.value(slot: identifier, code: .flipHorizontal) {
            settings.flipHorizontal = v > 0.5
        }
        if let v = registry.value(slot: identifier, code: .flipVertical) {
            settings.flipVertical = v > 0.5
        }
        if let v = registry.value(slot: identifier, code: .positionX) { settings.offsetX = v }
        if let v = registry.value(slot: identifier, code: .positionY) { settings.offsetY = v }
        settings.clampToValidRanges()
    }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context, let input = inputs.first else { return inputs.first }
        guard wetDry > 0.001, !settings.isNeutral else { return input }

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
            Log.error(.render, "\(identifier) could not encode its transform pass")
            return input
        }

        var params = TransformParams(
            scale: Float(settings.scale),
            rotation: Float(settings.rotation),
            flipH: settings.flipHorizontal ? 1 : 0,
            flipV: settings.flipVertical ? 1 : 0,
            offsetX: Float(settings.offsetX),
            offsetY: Float(settings.offsetY)
        )
        encoder.label = identifier
        encoder.setRenderPipelineState(metal.transformPipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<TransformParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            Log.error(.render, "\(identifier) transform pass failed: \(error)")
            return input
        }

        guard wetDry < 0.999 else { return target }
        if blendTarget == nil || blendTarget?.width != width || blendTarget?.height != height {
            blendTarget = metal.makeRenderTarget(
                width: width, height: height, label: "\(identifier)-wetdry")
        }
        guard let blendTarget,
              metal.blend(dry: input, wet: target, amount: wetDry, into: blendTarget, label: identifier)
        else { return target }
        return blendTarget
    }
}

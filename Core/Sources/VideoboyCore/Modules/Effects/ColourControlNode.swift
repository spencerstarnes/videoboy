//
//  ColourControlNode.swift — the ordinary grade stage.
//
//  Purpose : Brightness, contrast, saturation, shadows, highlights, black and white
//            points, and gamma. Nothing clever and nothing stylised — the controls a
//            mixer is expected to have, so material from four different sources can
//            be matched before it goes anywhere near the wedge or the composite path.
//  Inputs  : one texture.
//  Outputs : one texture, graded.
//  Connects: MetalContext.colourPipeline (the arithmetic, and the ORDER of it, is
//            documented beside the shader), the FX chain card that drives it.
//  Extend  : a new control is a field on `ColourSettings`, a field on the shader's
//            ColourParams in the same position, and a row in `parameters`. The
//            struct layout is a contract with the shader — keep them in step.
//
//  Defaults are all no-ops. An effect that changes the picture the moment it is added
//  makes the operator undo something before they can start, and a grade stage that
//  is not doing anything should be indistinguishable from one that is not there.
//

import Foundation
import Metal

/// Everything the grade can be told to do. All defaults are neutral.
public struct ColourSettings: Equatable, Codable, Sendable {
    /// −1...1, added to every channel. 0 is unchanged.
    public var brightness: Double
    /// 0...2 about mid grey. 1 is unchanged.
    public var contrast: Double
    /// 0...2 about luma. 1 is unchanged, 0 is monochrome.
    public var saturation: Double
    /// −1...1. Lifts or crushes the dark end only.
    public var shadow: Double
    /// −1...1. Lifts or rolls off the bright end only.
    public var highlight: Double
    /// 0...1. The input level remapped to black. Raising it crushes.
    public var blackLevel: Double
    /// 0...1. The input level remapped to white. Lowering it clips.
    public var whiteLevel: Double
    /// 0.1...4. Midtone curve; below 1 brightens the middle.
    public var gamma: Double

    public init(
        brightness: Double = 0,
        contrast: Double = 1,
        saturation: Double = 1,
        shadow: Double = 0,
        highlight: Double = 0,
        blackLevel: Double = 0,
        whiteLevel: Double = 1,
        gamma: Double = 1
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.shadow = shadow
        self.highlight = highlight
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
        self.gamma = gamma
    }

    /// Changes nothing.
    public static let neutral = ColourSettings()

    /// Whether these settings would leave the picture untouched.
    ///
    /// Used to skip the pass entirely. A grade stage sitting at its defaults should
    /// cost nothing, not a full-frame render that returns what it was given.
    public var isNeutral: Bool { self == .neutral }

    /// Pulls everything into the range the shader expects. The shader floors the
    /// white/black span itself, but a caller should not be able to store nonsense.
    public mutating func clampToValidRanges() {
        brightness = min(max(brightness, -1), 1)
        contrast = min(max(contrast, 0), 2)
        saturation = min(max(saturation, 0), 2)
        shadow = min(max(shadow, -1), 1)
        highlight = min(max(highlight, -1), 1)
        blackLevel = min(max(blackLevel, 0), 1)
        whiteLevel = min(max(whiteLevel, 0), 1)
        gamma = min(max(gamma, 0.1), 4)
    }
}

/// The layout handed to the shader. Must match `ColourParams` in the Metal source
/// field for field, in order.
private struct ColourParams {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var shadow: Float
    var highlight: Float
    var blackLevel: Float
    var whiteLevel: Float
    var gamma: Float
}

/// Grades its input.
public final class ColourControlNode: Node {

    public let identifier: String
    public let kind: NodeKind = .effect
    public var latencyInFrames: Int { 0 }

    /// What the grade is currently set to.
    public var settings = ColourSettings.neutral

    /// Wet/dry, so the whole grade can be faded in against the original.
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
            Parameter(code: .brightness, range: -1...1, defaultValue: 0),
            Parameter(code: .contrast, range: 0...2, defaultValue: 1),
            Parameter(code: .saturation, range: 0...2, defaultValue: 1),
            Parameter(code: .shadow, range: -1...1, defaultValue: 0),
            Parameter(code: .highlight, range: -1...1, defaultValue: 0),
            Parameter(code: .blackLevel, range: 0...1, defaultValue: 0),
            Parameter(code: .whiteLevel, range: 0...1, defaultValue: 1),
            Parameter(code: .gamma, range: 0.1...4, defaultValue: 1)
        ]
    }

    public func applyParameters(from registry: ParamRegistry) {
        if let v = registry.value(slot: identifier, code: .wetDry) { wetDry = v }
        if let v = registry.value(slot: identifier, code: .brightness) { settings.brightness = v }
        if let v = registry.value(slot: identifier, code: .contrast) { settings.contrast = v }
        if let v = registry.value(slot: identifier, code: .saturation) { settings.saturation = v }
        if let v = registry.value(slot: identifier, code: .shadow) { settings.shadow = v }
        if let v = registry.value(slot: identifier, code: .highlight) { settings.highlight = v }
        if let v = registry.value(slot: identifier, code: .blackLevel) { settings.blackLevel = v }
        if let v = registry.value(slot: identifier, code: .whiteLevel) { settings.whiteLevel = v }
        if let v = registry.value(slot: identifier, code: .gamma) { settings.gamma = v }
        settings.clampToValidRanges()
    }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context, let input = inputs.first else { return inputs.first }
        // Bypassed, or set to do nothing at all: hand the picture straight back
        // rather than spend a full-frame pass reproducing it.
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
            Log.error(.render, "\(identifier) could not encode its colour pass")
            return input
        }

        var params = ColourParams(
            brightness: Float(settings.brightness),
            contrast: Float(settings.contrast),
            saturation: Float(settings.saturation),
            shadow: Float(settings.shadow),
            highlight: Float(settings.highlight),
            blackLevel: Float(settings.blackLevel),
            whiteLevel: Float(settings.whiteLevel),
            gamma: Float(settings.gamma)
        )
        encoder.label = identifier
        encoder.setRenderPipelineState(metal.colourPipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<ColourParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        metal.submit(commandBuffer, label: identifier)

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

//
//  GeneratorSourceNode.swift — synthetic sources (SPEC 6A).
//
//  Purpose : No-input producers that emit a texture on the clock. Assignable to any
//            channel, routable through the composite path and the effect chains, and
//            sharing the same parameter surface as everything else.
//  Inputs  : its own parameters; no texture input.
//  Outputs : one texture.
//  Connects: MetalContext.generatorPipeline, the Asset Browser's Generators tab,
//            and the LFO bank — every parameter here is worth oscillating.
//
//  Parameters: 11A scale, 12A phase, 51A amount, plus the two colours.
//
//  SPEC 6A says not to exceed the base set without reason. The list below IS the
//  base set; adding to it should need an argument.
//

import Foundation
import Metal

/// The parameter block handed to the shader. Must match `GeneratorParams` in Metal.
private struct GeneratorParams {
    var mode: Int32
    var scale: Float
    var phase: Float
    var amount: Float
    var colorA: SIMD4<Float>
    var colorB: SIMD4<Float>
    var width: Float
    var height: Float
}

/// A colour, as the generator takes them.
public struct GeneratorColor: Equatable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = GeneratorColor(red: 0, green: 0, blue: 0)
    public static let white = GeneratorColor(red: 1, green: 1, blue: 1)

    /// NTSC-legal white. Full-scale white is illegal in a broadcast signal and
    /// blooms badly on a CRT, so this is the one to reach for by default (SPEC 6A).
    public static let legalWhite = GeneratorColor(red: 235.0 / 255, green: 235.0 / 255, blue: 235.0 / 255)

    /// True when any channel is outside the NTSC-legal 16...235 range.
    public var isOutOfGamut: Bool {
        let low = 16.0 / 255.0
        let high = 235.0 / 255.0
        for channel in [red, green, blue] where channel < low - 1e-6 || channel > high + 1e-6 {
            return true
        }
        return false
    }

    var simd: SIMD4<Float> {
        SIMD4<Float>(Float(red), Float(green), Float(blue), 1)
    }
}

/// Which pattern a generator produces. Raw values are the shader contract.
public enum GeneratorKind: Int, CaseIterable, Codable, Sendable {
    case solid = 0
    case linearGradient = 1
    case radialGradient = 2
    case checkerboard = 3
    case stripes = 4
    case grid = 5
    case rings = 6
    case whiteNoise = 7
    case noiseField = 8
    case plasma = 9
    case halftone = 10
    case scanlines = 11

    public var displayName: String {
        switch self {
        case .solid: "Solid Colour"
        case .linearGradient: "Linear Gradient"
        case .radialGradient: "Radial Gradient"
        case .checkerboard: "Checkerboard"
        case .stripes: "Stripes"
        case .grid: "Grid / Crosshatch"
        case .rings: "Rings / Target"
        case .whiteNoise: "White Noise"
        case .noiseField: "Noise Field"
        case .plasma: "Difference Clouds"
        case .halftone: "Halftone Dots"
        case .scanlines: "Scanlines"
        }
    }

    /// Selects from a 0...1 parameter.
    public static func from(normalised value: Double) -> GeneratorKind {
        let all = allCases
        return all[NormalisedSweep.index(value, count: all.count)]
    }
}

/// Produces a synthetic picture.
public final class GeneratorSourceNode: Node {

    public let identifier: String
    public let kind: NodeKind = .source
    /// Generated on the GPU within the frame.
    public let latencyInFrames = 0

    public var parameters: [Parameter] {
        [
            Parameter(code: .opacity, range: 0...1, defaultValue: 1),
            Parameter(code: .scale, range: 0...1, defaultValue: 0.5),
            // Phase is what an LFO drives to animate the pattern — a checkerboard
            // flipping on the beat is this parameter on a square wave.
            Parameter(code: .positionX, range: 0...1, defaultValue: 0),
            Parameter(code: .contrast, range: 0...1, defaultValue: 0.5)
        ]
    }

    /// Which pattern.
    public var generator: GeneratorKind = .plasma
    /// Feature size, 0...1.
    public var scale = 0.5
    /// Animation position, 0...1. Usually driven by an LFO.
    public var phase = 0.0
    /// Mode-specific strength: octaves for plasma, line weight for the grid, and so on.
    public var amount = 0.5
    public var colorA = GeneratorColor.black
    public var colorB = GeneratorColor.legalWhite

    private let context: MetalContext?
    private var target: MTLTexture?

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
    }

    /// True when either colour is outside the NTSC-legal range (SPEC 6A's warning).
    public var hasOutOfGamutColor: Bool {
        colorA.isOutOfGamut || colorB.isOutOfGamut
    }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context else { return nil }

        let width = renderContext.width
        let height = renderContext.height
        if target == nil || target?.width != width || target?.height != height {
            target = metal.makeRenderTarget(width: width, height: height, label: identifier)
        }
        guard let target else { return nil }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            Log.error(.render, "\(identifier) could not encode its generator pass")
            return target
        }

        var params = GeneratorParams(
            mode: Int32(generator.rawValue),
            scale: Float(min(max(scale, 0), 1)),
            phase: Float(phase),
            amount: Float(min(max(amount, 0), 1)),
            colorA: colorA.simd,
            colorB: colorB.simd,
            width: Float(width),
            height: Float(height)
        )
        encoder.label = identifier
        encoder.setRenderPipelineState(metal.generatorPipeline)
        encoder.setFragmentBytes(&params, length: MemoryLayout<GeneratorParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        metal.submit(commandBuffer, label: identifier)
        return target
    }

    /// Pulls settings from the registry.
    public func applyParameters(from registry: ParamRegistry) {
        if let value = registry.value(slot: identifier, code: .scale) { scale = value }
        if let value = registry.value(slot: identifier, code: .positionX) { phase = value }
        if let value = registry.value(slot: identifier, code: .contrast) { amount = value }
    }
}

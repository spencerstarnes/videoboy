//
//  CompositeCodecNode.swift — NTSC composite encode/decode (SPEC 9).
//
//  Purpose : The analog character the app exists for does not come from named
//            effects; it comes from the composite signal path. This node runs the
//            picture through an NTSC encode/decode round trip so dot crawl,
//            rainbowing, chroma bleed and ringing arise from the process rather than
//            being drawn on top of it.
//  Inputs  : one texture.
//  Outputs : one texture, the same size.
//  Connects: MetalContext.compositePipeline (the signal model itself), the FX chain.
//
//  WHAT IS A REAL MODEL AND WHAT IS NOT — SPEC 9 asks for this to be stated plainly:
//    * REAL SIGNAL MODEL: the encode to a composite waveform and the decode back,
//      including subcarrier modulation, the filtering the decoder must do, and the
//      cross-luma / cross-chroma artefacts that follow from sharing one wire.
//      Dot crawl and rainbowing are emergent here, not painted on.
//    * BEHAVIOURAL EMULATION: the TBC wobble and the head-switching band. Those are
//      shaped to look like what a tape transport does, not derived from a model of
//      a servo or a helical scan.
//    * Generation loss is real in the sense that it is genuinely the codec run N
//      times — each pass degrades the output of the last, as a dub does.
//

import Foundation
import Metal

/// How luma and chroma travel.
public enum CompositePath: String, CaseIterable, Codable, Sendable {
    /// One wire. Luma and chroma interfere: dot crawl, rainbowing, cross-colour.
    case composite
    /// Separate Y and C. No cross artefacts — the cleaner MX-1 Y/C look.
    case sVideo

    /// Selects a path from a 0...1 parameter (code `74A`).
    public static func from(normalised value: Double) -> CompositePath {
        value < 0.5 ? .composite : .sVideo
    }
}

/// Chroma subsampling before encoding. DV is 4:1:1 on NTSC.
public enum ChromaSubsampling: String, CaseIterable, Codable, Sendable {
    case full444
    case half422
    case quarter411

    /// Horizontal chroma decimation factor, as the shader wants it.
    public var factor: Float {
        switch self {
        case .full444: 1
        case .half422: 2
        case .quarter411: 4
        }
    }

    /// Selects from a 0...1 parameter (code `77A`).
    public static func from(normalised value: Double) -> ChromaSubsampling {
        let all = allCases
        return all[NormalisedSweep.index(value, count: all.count)]
    }
}

/// Everything the composite codec can be told to do.
public struct CompositeSettings: Equatable, Codable, Sendable {
    public var path: CompositePath
    public var subsampling: ChromaSubsampling
    /// 0...1. How much luma detail survives; lower is softer, with more ringing.
    public var lumaBandwidth: Double
    /// 0...1. How far colour smears along the line.
    public var chromaBleed: Double
    /// 0...1. Strength of the crawling dot pattern (composite path only).
    public var crawl: Double
    /// 0...1. Time-base wobble. 0 is "TBC locked".
    public var wobble: Double
    /// 0...1. Head-switching tear at the bottom of the frame.
    public var headSwitching: Double
    /// How many times to run the codec — Nth-generation dubbing.
    public var generation: Int

    public init(
        path: CompositePath = .composite,
        subsampling: ChromaSubsampling = .quarter411,
        lumaBandwidth: Double = 0.7,
        chromaBleed: Double = 0.5,
        crawl: Double = 0.6,
        wobble: Double = 0.2,
        headSwitching: Double = 0.3,
        generation: Int = 1
    ) {
        self.path = path
        self.subsampling = subsampling
        self.lumaBandwidth = lumaBandwidth
        self.chromaBleed = chromaBleed
        self.crawl = crawl
        self.wobble = wobble
        self.headSwitching = headSwitching
        self.generation = generation
    }

    /// A clean pass: S-Video, full chroma, no wobble. Useful as a reference.
    public static let clean = CompositeSettings(
        path: .sVideo, subsampling: .full444, lumaBandwidth: 1.0,
        chromaBleed: 0.0, crawl: 0.0, wobble: 0.0, headSwitching: 0.0, generation: 1
    )

    /// The default VHS-ish look.
    public static let vhs = CompositeSettings()

    /// Largest number of passes allowed. Each one costs a full-frame render, and
    /// beyond a handful the picture is mud anyway.
    public static let maximumGeneration = 6
}

/// The parameter block handed to the shader. Layout must match `CompositeParams`
/// in the Metal source exactly.
private struct CompositeParams {
    var phasePerPixel: Float
    var phasePerLine: Float
    var phasePerFrame: Float
    var frameIndex: Float
    var lumaBandwidth: Float
    var chromaBleed: Float
    var crawl: Float
    var wobble: Float
    var headSwitching: Float
    var chromaSubsample: Float
    var sVideo: Float
    var width: Float
    var height: Float
}

/// Runs the NTSC codec over its input.
public final class CompositeCodecNode: Node {

    public let identifier: String
    public let kind: NodeKind = .effect
    /// Each generation is one full-frame pass, all completed within the frame.
    public var latencyInFrames: Int { 0 }

    public var parameters: [Parameter] {
        [
            Parameter(code: .wetDry, range: 0...1, defaultValue: 1),
            Parameter(code: .compositePath, range: 0...1, defaultValue: 0),
            Parameter(code: .chromaSubsampling, range: 0...1, defaultValue: 1),
            Parameter(code: .lumaBandwidth, range: 0...1, defaultValue: 0.7),
            Parameter(code: .chromaBleed, range: 0...1, defaultValue: 0.5),
            Parameter(code: .compositeCrawl, range: 0...1, defaultValue: 0.6),
            Parameter(code: .tbcWobble, range: 0...1, defaultValue: 0.2),
            Parameter(code: .headSwitchingNoise, range: 0...1, defaultValue: 0.3),
            Parameter(
                code: .compositeGeneration,
                range: 1...Double(CompositeSettings.maximumGeneration),
                defaultValue: 1
            )
        ]
    }

    /// Current settings. Driven by the UI, mappings and templates.
    public var settings = CompositeSettings.vhs

    // MARK: - NTSC subcarrier constants
    //
    // Derived once here rather than written as bare numbers in the shader, so the
    // arithmetic is auditable.

    /// Colour subcarrier frequency, Hz. 315/88 MHz, exactly, by definition.
    public static let subcarrierHertz = 315.0e6 / 88.0

    /// Active line duration, seconds. 52.6 µs of the 63.5 µs NTSC line.
    public static let activeLineSeconds = 52.6e-6

    /// Subcarrier radians per pixel, for a line sampled at `width` pixels.
    ///
    /// Over one active line the subcarrier completes
    /// `subcarrierHertz * activeLineSeconds` cycles — about 188 for NTSC. Spread
    /// across 720 samples that is roughly 3.8 samples per cycle.
    public static func phasePerPixel(width: Int) -> Double {
        let cyclesPerLine = subcarrierHertz * activeLineSeconds
        return 2.0 * Double.pi * cyclesPerLine / Double(width)
    }

    /// NTSC inverts subcarrier phase from one line to the next.
    public static let phasePerLine = Double.pi

    /// ...and steps it again each frame, which is what makes dot crawl crawl rather
    /// than sit still.
    public static let phasePerFrame = Double.pi / 2.0

    /// 0 bypasses the effect entirely, 1 is fully applied. This is what the Wet/Dry
    /// slider and the enable switch in the FX panel both drive.
    public var wetDry = 1.0

    /// Target for the wet/dry blend, allocated alongside the effect's own buffers.
    private var blendTarget: MTLTexture?

    private let context: MetalContext?
    /// Two targets, used alternately so multi-generation passes can ping-pong.
    private var targets: [MTLTexture?] = [nil, nil]

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
    }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let metal = context, let input = inputs.first else { return inputs.first }
        // Fully dry costs nothing: skip the passes entirely rather than running the
        // codec and then blending none of it in.
        guard wetDry > 0.001 else { return input }

        guard let processed = run(on: input, frameIndex: renderContext.frameIndex, metal: metal) else {
            return input
        }
        guard wetDry < 0.999 else { return processed }
        return blendWetDry(dry: input, wet: processed, metal: metal)
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

    /// Runs `generation` passes, each over the output of the last.
    private func run(on input: MTLTexture, frameIndex: Int, metal: MetalContext) -> MTLTexture? {
        let width = input.width
        let height = input.height

        for slot in 0..<2 where targets[slot] == nil
            || targets[slot]?.width != width || targets[slot]?.height != height {
            targets[slot] = metal.makeRenderTarget(
                width: width, height: height, label: "\(identifier)-pass\(slot)")
        }
        guard let first = targets[0], let second = targets[1] else { return input }

        let passes = min(max(settings.generation, 1), CompositeSettings.maximumGeneration)
        var source = input
        var produced: MTLTexture?

        for pass in 0..<passes {
            let target = (pass % 2 == 0) ? first : second
            // Each generation advances the frame index so successive dubs do not
            // land their subcarrier phase in exactly the same place — that is what
            // stops repeated passes looking like one strong pass.
            guard encode(from: source, to: target, frameIndex: frameIndex + pass, metal: metal) else {
                return produced ?? input
            }
            produced = target
            source = target
        }
        return produced ?? input
    }

    /// Encodes one pass into `target`.
    private func encode(
        from source: MTLTexture, to target: MTLTexture, frameIndex: Int, metal: MetalContext
    ) -> Bool {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            Log.error(.render, "\(identifier) could not encode a composite pass")
            return false
        }

        var params = CompositeParams(
            phasePerPixel: Float(Self.phasePerPixel(width: source.width)),
            phasePerLine: Float(Self.phasePerLine),
            phasePerFrame: Float(Self.phasePerFrame),
            frameIndex: Float(frameIndex),
            lumaBandwidth: Float(settings.lumaBandwidth),
            chromaBleed: Float(settings.chromaBleed),
            crawl: Float(settings.crawl),
            wobble: Float(settings.wobble),
            headSwitching: Float(settings.headSwitching),
            chromaSubsample: settings.subsampling.factor,
            sVideo: settings.path == .sVideo ? 1 : 0,
            width: Float(source.width),
            height: Float(source.height)
        )

        encoder.label = identifier
        encoder.setRenderPipelineState(metal.compositePipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<CompositeParams>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            Log.error(.render, "\(identifier) composite pass failed: \(error)")
            return false
        }
        return true
    }

    /// Pulls settings from the registry.
    public func applyParameters(from registry: ParamRegistry) {
        if let value = registry.value(slot: identifier, code: .wetDry) { wetDry = value }
        if let value = registry.value(slot: identifier, code: .compositePath) {
            settings.path = CompositePath.from(normalised: value)
        }
        if let value = registry.value(slot: identifier, code: .chromaSubsampling) {
            settings.subsampling = ChromaSubsampling.from(normalised: value)
        }
        if let value = registry.value(slot: identifier, code: .lumaBandwidth) {
            settings.lumaBandwidth = value
        }
        if let value = registry.value(slot: identifier, code: .chromaBleed) {
            settings.chromaBleed = value
        }
        if let value = registry.value(slot: identifier, code: .compositeCrawl) {
            settings.crawl = value
        }
        if let value = registry.value(slot: identifier, code: .tbcWobble) {
            settings.wobble = value
        }
        if let value = registry.value(slot: identifier, code: .headSwitchingNoise) {
            settings.headSwitching = value
        }
        if let value = registry.value(slot: identifier, code: .compositeGeneration) {
            settings.generation = Int(value.rounded())
        }
    }
}

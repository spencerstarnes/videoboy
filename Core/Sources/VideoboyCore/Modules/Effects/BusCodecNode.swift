//
//  BusCodecNode.swift — data effects on a mixed bus, via a re-encode.
//
//  Purpose : A source carries a bitstream and can be corrupted before decode. A BUS
//            does not — it is a texture, the result of compositing several sources.
//            To apply data effects to a *mix*, the mix has to be given a bitstream
//            first. This node encodes the bus to an interchange codec, damages those
//            bytes, and decodes them back.
//  Inputs  : one texture (the mixed bus).
//  Outputs : one texture, the round trip's result.
//  Connects: DVEncoder, DIFCorruptor, DVDecoder; the bus interchange popup.
//
//  MEASURED COST: the DV round trip runs at about 6.9 ms per 720x480 frame on an
//  M1 Max, against a 33.4 ms budget at 29.97 fps — roughly a fifth of the frame, and
//  there is a test that fails if it ever exceeds a third. That is what makes this
//  viable at all, and it is why DV is the interchange format: DV is intra-frame, so
//  one frame in gives one frame out. An MPEG round trip would need several frames in
//  hand before it could emit one, which a live mixer cannot give it.
//
//  Parameters: the same 31B/32B/33B/34B the source corruptor uses, so a mapping or an
//  LFO written for one works on the other.
//

import Foundation
import Metal

/// What a bus is re-encoded to before its data effects are applied.
public enum InterchangeCodec: String, CaseIterable, Codable, Sendable {
    /// No re-encode. The bus stays a texture and offers no data effects.
    case none
    /// DV. Intra-frame, so no added latency.
    case dv

    public var displayName: String {
        switch self {
        case .none: "None"
        case .dv: "DV (NTSC)"
        }
    }

    /// The data-effect family this interchange makes available.
    public var family: DataEffectFamily {
        switch self {
        case .none: .none
        case .dv: .dv
        }
    }
}

/// Re-encodes a bus so its bitstream can be damaged.
public final class BusCodecNode: Node, DataEffectProvider {

    public let identifier: String
    public let kind: NodeKind = .effect

    /// DV is intra-frame, so the round trip completes within the frame.
    public let latencyInFrames = 0

    public var parameters: [Parameter] {
        [
            Parameter(code: .wetDry, range: 0...1, defaultValue: 1),
            Parameter(code: .corruptAmount, range: 0...1, defaultValue: 0),
            Parameter(code: .corruptMode, range: 0...1, defaultValue: 0),
            Parameter(code: .corruptRate, range: 0...1, defaultValue: 0.25),
            Parameter(code: .corruptSeed, range: 0...65535, defaultValue: 1),
            Parameter(code: .compositeGeneration, range: 0...4, defaultValue: 0)
        ]
    }

    /// Which codec the bus is re-encoded to. `.none` makes this node a pass-through
    /// at no cost at all — no readback, no encode, nothing.
    public var interchange: InterchangeCodec = .none {
        didSet {
            guard interchange != oldValue else { return }
            // Tear the codec down when switching away, so an unused interchange is
            // not holding an encoder and a scaler open.
            if interchange == .none {
                encoder = nil
                decoder = nil
            }
            Log.info(.bitstream, "\(identifier) interchange is now \(interchange.displayName)")
        }
    }

    /// What damage to apply to the re-encoded bitstream.
    public var corruption = CorruptionSettings.inert

    /// How many DV encode/decode passes the bus makes, for generation loss.
    ///
    /// Zero means no round trip at all, which is different from one: a single pass is
    /// already a real change to the picture — DV is 4:1:1 and 8-bit, so the colour
    /// gets coarser whether or not anything is damaged afterwards. That is the whole
    /// of what the output's DV emulation does, and it is why the round trip can no
    /// longer be skipped just because the damage is zero.
    public var generations = 0

    /// Whatever the interchange currently offers.
    public var dataEffectFamily: DataEffectFamily { interchange.family }

    private let context: MetalContext?
    private let standard: DVStandard
    private var encoder: DVEncoder?
    private var decoder: DVDecoder?
    /// The previous encoded frame, which `holdSequences` needs.
    private var previousEncodedFrame: [UInt8]?
    private var readbackRenderer: OffscreenRenderer?
    /// Reused, double-buffered upload target — no allocation per frame.
    private var uploader: TextureUploader?

    public init(
        identifier: String,
        standard: DVStandard = .ntsc,
        context: MetalContext? = MetalContext.shared
    ) {
        self.identifier = identifier
        self.standard = standard
        self.context = context
    }

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let input = inputs.first else { return nil }

        // No interchange, or no damage asked for: leave the texture alone. Running a
        // full round trip to produce an identical picture would be the most expensive
        // no-op in the graph.
        guard interchange != .none, corruption.amount > 0 || generations > 0 else { return input }
        guard let metal = context else { return input }

        if readbackRenderer == nil { readbackRenderer = OffscreenRenderer(context: metal) }
        guard let readbackRenderer else { return input }

        // The encoder only accepts the standard's exact geometry; a bus at another
        // size is passed through rather than silently rescaled.
        let (width, height) = standard.size
        guard input.width == width, input.height == height else {
            Log.warn(.bitstream, "\(identifier) needs \(width)x\(height) to re-encode, got \(input.width)x\(input.height); passing through")
            return input
        }

        do {
            if encoder == nil { encoder = try DVEncoder(standard: standard) }
            if decoder == nil { decoder = try DVDecoder() }
        } catch {
            Log.error(.bitstream, "\(identifier) could not set up its interchange codec: \(error)")
            interchange = .none
            return input
        }
        guard let encoder, let decoder else { return input }

        guard var image = readbackRenderer.readback(input) else { return input }

        // At least one pass, because getting here at all means something asked for a
        // round trip. Extra passes are dubbing: each one re-quantises what the last
        // one produced, which is exactly how generation loss accumulates on tape.
        let passes = max(generations, 1)
        for pass in 0..<passes {
            guard let encoded = encoder.encode(image: image) else { return input }

            // Damage lands on the LAST pass only. Damaging every generation would
            // multiply the amount by the generation count, so turning up one control
            // would silently move the other.
            let bytes: [UInt8]
            if pass == passes - 1 && corruption.amount > 0 {
                bytes = DIFCorruptor.corrupt(
                    frame: encoded,
                    settings: corruption,
                    standard: standard,
                    previousFrame: previousEncodedFrame
                )
                previousEncodedFrame = encoded
            } else {
                bytes = encoded
            }

            guard let decoded = decoder.decode(frameBytes: bytes) else { return input }
            image = decoded
        }

        if uploader == nil { uploader = TextureUploader(context: metal, label: "\(identifier)-interchange") }
        return uploader?.upload(image) ?? input
    }

    /// Re-rolls the corruption seed, so bus damage can change on the beat too.
    public func rerollCorruptionSeed(using source: UInt64) {
        corruption.seed = source
    }

    /// Pulls settings from the registry.
    public func applyParameters(from registry: ParamRegistry) {
        if let value = registry.value(slot: identifier, code: .compositeGeneration) {
            generations = Int(value.rounded())
        }
        if let value = registry.value(slot: identifier, code: .corruptAmount) {
            corruption.amount = value
        }
        if let value = registry.value(slot: identifier, code: .corruptMode) {
            corruption.mode = CorruptionMode.from(normalised: value)
            // Kept alongside, so a family with a different mode list reads the
            // fader rather than the DV enum it happens to have been quantised to.
            corruption.modePosition = value
        }
        if let value = registry.value(slot: identifier, code: .corruptSeed) {
            corruption.seed = UInt64(max(0, value))
        }
    }
}

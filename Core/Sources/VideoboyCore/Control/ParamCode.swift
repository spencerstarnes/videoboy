//
//  ParamCode.swift — the stable parameter address table (SPEC 13).
//
//  Purpose : Every adjustable parameter has a code that outlives the module instance
//            holding it. Mappings (MIDI, OSC, audio-reactivity, keyboard) and saved
//            templates target the code, never a pointer, so swapping the effect in a
//            slot keeps any mapping whose code still exists.
//  Inputs  : none; this is the table itself.
//  Outputs : `ParamCode` values used by the registry, the UI, and templates.
//  Connects: ParamRegistry (resolution), templates (serialisation), the FX panels
//            (which print the code next to each parameter).
//  Extend  : add a case with a NEW code. Never reuse or renumber an existing one —
//            an old template holding that code would silently bind to the wrong
//            parameter. Codes are permanent once shipped.
//
//  Numbering scheme, so new codes are allocated consistently:
//    0xA  — universal per-node parameters (opacity, enable, wet/dry)
//    1xA  — geometry (scale, x, y, rotate)
//    2xA  — time-domain effects (echo decay, trails)
//    3xB  — the bitstream wedge (corruptor amount, mode, rate, seed)
//    4xC  — feedback
//    5xA  — colour controls
//    6xA  — mixer and transport
//    7xA  — composite / NTSC emulation
//

import Foundation

/// A stable parameter address. The raw value is what appears in templates and in
/// the FX panel next to the parameter's name.
public enum ParamCode: String, CaseIterable, Codable, Sendable {

    // MARK: Universal (0xA)

    /// Layer opacity, 0...1. Present on every node that composites.
    case opacity = "01A"
    /// Effect wet/dry mix, 0...1.
    case wetDry = "02A"
    /// Node enable, 0 or 1.
    case enabled = "03A"

    // MARK: Geometry (1xA)

    case scale = "11A"
    case positionX = "12A"
    case positionY = "13A"
    case rotation = "14A"

    // MARK: Time-domain effects (2xA)

    case echoDecay = "21A"
    case trailLength = "22A"
    /// Luma threshold above which a pixel is echoed at all.
    case echoThreshold = "23A"

    // MARK: The bitstream wedge (3xB)
    //
    // These are the competitive core. They address the corruptor that runs on
    // compressed packets before decode (SPEC 5).

    /// How much corruption to apply, 0...1.
    case corruptAmount = "31B"
    /// Which corruption transform is selected, quantised from 0...1.
    case corruptMode = "32B"
    /// How often corruption is re-rolled, as a beat subdivision.
    case corruptRate = "33B"
    /// The corruptor's random seed, so a performance is repeatable.
    case corruptSeed = "34B"

    // MARK: Feedback (4xC)

    case feedbackGain = "43C"
    case feedbackDelayFrames = "44C"
    /// Zoom applied inside the feedback loop — the classic infinite tunnel.
    case feedbackZoom = "45C"
    /// Rotation applied inside the feedback loop, in turns.
    case feedbackRotate = "46C"
    /// Luma key threshold for what re-enters the loop.
    case feedbackThreshold = "47C"

    // MARK: Colour (5xA)

    case contrast = "51A"
    case saturation = "52A"
    case brightness = "53A"

    // MARK: Mixer and transport (6xA)

    /// The A/B crossfader position, 0...1.
    case crossfadeAB = "61A"
    /// The C/D crossfader position, 0...1.
    case crossfadeCD = "62A"
    /// The ONE/TWO crossfader position, 0...1.
    case crossfadeOneTwo = "63A"
    /// Playback speed of a source, where 1.0 is nominal.
    case playbackSpeed = "64A"
    /// Layer blend mode of a composite (SPEC 12).
    case blendMode = "65A"
    /// Per-layer opacity of the blend layer in a composite.
    case layerOpacity = "66A"
    /// Which MX-1 effect is applied, as a 0...1 sweep across the set.
    ///
    /// A sweep rather than a menu because that is what makes it playable: a fader or
    /// a knob can run through the whole set mid-phrase, which is the entire reason
    /// the MX-1 is worth emulating.
    case mx1Effect = "91A"
    /// Strength of the MX-1 effect, where the meaning depends on which one.
    case mx1Amount = "92A"

    /// Playhead position within a clip, 0...1 — what the shuttle scrubs.
    ///
    /// Separate from `playbackSpeed`: speed is how fast the clip runs, position is
    /// where it is. A jog wheel wants the second one.
    case scrubPosition = "67A"

    // MARK: Composite emulation (7xA)

    case compositeCrawl = "71A"
    case chromaBleed = "72A"
    case tbcWobble = "73A"
    /// Signal path: composite (cross-colour artefacts) vs S-Video (clean Y/C).
    case compositePath = "74A"
    /// How many times the codec runs — Nth-generation dubbing feel.
    case compositeGeneration = "75A"
    /// Luma bandwidth limit, which controls ringing and softness.
    case lumaBandwidth = "76A"
    /// Chroma subsampling: 4:4:4 / 4:2:2 / 4:1:1.
    case chromaSubsampling = "77A"
    /// Head-switching noise band at the bottom of the frame.
    case headSwitchingNoise = "78A"

    // MARK: CRT target (8xA)

    /// Safe-zone overlay on previews.
    case safeZone = "81A"
    /// Overscan amount applied to output.
    case overscan = "82A"
    /// Black-frame insertion, clock-timed.
    case blackFrameInsertion = "83A"
    /// Grid/crosshatch overlay, for seeding feedback.
    case gridOverlay = "84A"

    /// Human-readable name, used in the UI and in template comments.
    public var displayName: String {
        switch self {
        case .opacity: "opacity"
        case .wetDry: "wet/dry"
        case .enabled: "enabled"
        case .scale: "scale"
        case .positionX: "x"
        case .positionY: "y"
        case .rotation: "rotate"
        case .echoDecay: "echo decay"
        case .trailLength: "trail length"
        case .corruptAmount: "corrupt amount"
        case .corruptMode: "corrupt mode"
        case .corruptRate: "corrupt rate"
        case .corruptSeed: "corrupt seed"
        case .feedbackGain: "feedback gain"
        case .feedbackDelayFrames: "feedback delay"
        case .contrast: "contrast"
        case .saturation: "saturation"
        case .brightness: "brightness"
        case .crossfadeAB: "A/B crossfade"
        case .crossfadeCD: "C/D crossfade"
        case .crossfadeOneTwo: "ONE/TWO crossfade"
        case .playbackSpeed: "speed"
        case .scrubPosition: "position"
        case .mx1Effect: "MX-1 effect"
        case .mx1Amount: "MX-1 amount"
        case .blendMode: "blend mode"
        case .layerOpacity: "layer opacity"
        case .compositeCrawl: "dot crawl"
        case .chromaBleed: "chroma bleed"
        case .tbcWobble: "TBC wobble"
        case .compositePath: "signal path"
        case .compositeGeneration: "generation"
        case .lumaBandwidth: "luma bandwidth"
        case .chromaSubsampling: "chroma subsampling"
        case .headSwitchingNoise: "head switching"
        case .echoThreshold: "echo threshold"
        case .feedbackZoom: "feedback zoom"
        case .feedbackRotate: "feedback rotate"
        case .feedbackThreshold: "feedback threshold"
        case .safeZone: "safe zones"
        case .overscan: "overscan"
        case .blackFrameInsertion: "black frame insertion"
        case .gridOverlay: "grid overlay"
        }
    }
}

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
//    9xD  — character generator (SPEC 18.1)
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
    /// Mirror left-to-right, above the halfway point.
    case flipHorizontal = "15A"
    /// Mirror top-to-bottom, above the halfway point.
    case flipVertical = "16A"

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
    /// Lifts or crushes the dark end without moving the highlights.
    case shadow = "54A"
    /// Rolls off or lifts the bright end without moving the shadows.
    case highlight = "55A"
    /// Input black point: what level is remapped to 0. Raising it crushes.
    case blackLevel = "56A"
    /// Input white point: what level is remapped to full. Lowering it clips.
    case whiteLevel = "57A"
    /// Midtone gamma. 1.0 is unchanged; below 1 brightens the middle.
    case gamma = "58A"

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

    // MARK: Momentary actions
    //
    // These are not settings, they are BUTTONS — a controller sends a note, the value
    // goes to 1, the action fires and it falls back to 0. They live in the param table
    // anyway so that learning, storing and recalling them is the same machinery as
    // everything else rather than a second mapping system alongside it (SPEC 2's one
    // extension point applies to control as well as to nodes).

    /// Cut to the other source on this bus.
    case cutTrigger = "68A"
    /// Fade to the other source on this bus, at the set rate.
    case fadeTrigger = "69A"

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

    // MARK: Character generator (9xD, SPEC 18.1)
    //
    // Position, scale and overall opacity/bypass are NOT re-declared here — the CG
    // reuses .positionX, .positionY, .scale, .opacity and .wetDry exactly as every
    // other node does, because they mean the same thing here that they mean
    // everywhere else. Only what is genuinely new to a character generator gets a
    // new code.

    /// Point size of the type.
    case cgFontSize = "91D"
    /// Which weight bucket, swept 0...1 across regular/medium/semibold/bold/heavy —
    /// the same "sweep selects from a small set" pattern as `mx1Effect`.
    case cgFontWeight = "92D"
    /// Paragraph alignment, swept 0...1 across left/center/right/justified.
    case cgAlignment = "93D"
    /// Native font pair-kerning, on above the halfway point. A font either has this
    /// or it does not, so a continuous fader is still a threshold in practice — but
    /// it stays a fader rather than a switch so it can be detect-mapped and
    /// audio-reactive like everything else here.
    case cgKerningEnabled = "94D"
    /// Uniform letter-spacing added on top of the font's own metrics, in points.
    /// Negative tightens, positive opens up — separate from kerning, which only
    /// toggles the font's own built-in pair adjustments.
    case cgTracking = "95D"
    /// Extra space between lines, in points, added to the font's natural leading.
    case cgLeading = "96D"
    /// Stroke width around each glyph, in points. Zero is no outline.
    case cgOutlineWidth = "97D"
    /// Drop shadow horizontal offset, in points.
    case cgShadowOffsetX = "98D"
    /// Drop shadow vertical offset, in points.
    case cgShadowOffsetY = "99D"
    /// Drop shadow blur radius, in points.
    case cgShadowBlur = "9AD"
    /// Drop shadow opacity, 0...1, independent of the text's own opacity.
    case cgShadowOpacity = "9BD"
    /// Roll/crawl/reveal mode, swept 0...1 across off/roll/crawl/reveal.
    case cgRollMode = "9CD"
    /// How fast a roll or crawl moves, in screen-heights (or -widths, for crawl) per
    /// bar — clock-synced per SPEC 18.1, so this is a musical rate, not seconds.
    case cgRollRate = "9DD"
    /// The mid-90s budget-titler style preset, routed through the CompositeCodec.
    /// Off is the clean, native rendering the SPEC calls the "basic" mode.
    case cgPeriodPreset = "9ED"
    /// Constrains placement inside the title-safe rectangle rather than the full
    /// frame, so text cannot be positioned somewhere a CRT would cut off.
    case cgSafeZoneClamp = "9FD"

    // MARK: CRT target (8xA)

    /// Safe-zone overlay on previews.
    case safeZone = "81A"
    /// Overscan amount applied to output.
    case overscan = "82A"
    /// Black-frame insertion, clock-timed.
    case blackFrameInsertion = "83A"
    /// Grid/crosshatch overlay, for seeding feedback.
    case gridOverlay = "84A"

    // MARK: Emulated titler (Axx)
    //
    // STABLE CODES, because these are what a MIDI mapping and a saved template store.
    // Every one maps to a real function inside the emulated software — see
    // TitlerFunction, which is the list these mirror. A control that cannot name the
    // thing it reaches does not get a code.

    /// Which of the titler's transitions takes the page.
    case emuWipe = "A1A"
    /// The direction that transition travels.
    case emuWipeDirection = "A2A"
    /// How long it takes.
    case emuWipeSpeed = "A3A"
    /// How text arrives on a page already shown.
    case emuTextWipe = "A4A"
    /// The typeface.
    case emuFontFace = "A5A"
    /// Type size — the titler's only text scale.
    case emuFontSize = "A6A"
    /// Text colour, through the screen palette.
    case emuTextColour = "A7A"
    /// Background colour, likewise.
    case emuBackgroundColour = "A8A"
    /// How large a placed graphic is drawn.
    case emuBrushScale = "A9A"
    /// Where the text sits across the screen.
    case emuTextX = "AAA"
    /// And down it.
    case emuTextY = "ABA"
    /// Left, centre or right.
    case emuAlignment = "ACA"
    /// Colour cycling, on or off.
    case emuColourCycle = "ADA"
    /// How long a page holds.
    case emuHold = "AEA"
    /// Jump to a named page.
    case emuPage = "AFA"
    /// Text decoration: shadow, edge, bevel.
    case emuDecoration = "B1A"
    /// Italics, on or off.
    case emuItalic = "B2A"
    /// Which background picture is behind the text.
    case emuBackdrop = "B3A"
    /// A filled bar behind the text, for a lower third.
    case emuBox = "B4A"

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
        case .flipHorizontal: "flip H"
        case .flipVertical: "flip V"
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
        case .shadow: "shadow"
        case .highlight: "highlight"
        case .blackLevel: "black level"
        case .whiteLevel: "white level"
        case .gamma: "gamma"
        case .crossfadeAB: "A/B crossfade"
        case .crossfadeCD: "C/D crossfade"
        case .crossfadeOneTwo: "ONE/TWO crossfade"
        case .playbackSpeed: "speed"
        case .scrubPosition: "position"
        case .cutTrigger: "cut"
        case .fadeTrigger: "fade"
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
        case .emuWipe: "emu wipe"
        case .emuWipeDirection: "emu wipe direction"
        case .emuWipeSpeed: "emu wipe speed"
        case .emuTextWipe: "emu text wipe"
        case .emuFontFace: "emu font"
        case .emuFontSize: "emu type size"
        case .emuTextColour: "emu text colour"
        case .emuBackgroundColour: "emu background"
        case .emuBrushScale: "emu graphic scale"
        case .emuTextX: "emu text x"
        case .emuTextY: "emu text y"
        case .emuAlignment: "emu alignment"
        case .emuColourCycle: "emu colour cycle"
        case .emuHold: "emu hold"
        case .emuPage: "emu page"
        case .emuDecoration: "emu decoration"
        case .emuItalic: "emu italic"
        case .emuBackdrop: "emu backdrop"
        case .emuBox: "emu box"
        case .safeZone: "safe zones"
        case .overscan: "overscan"
        case .blackFrameInsertion: "black frame insertion"
        case .gridOverlay: "grid overlay"
        case .cgFontSize: "font size"
        case .cgFontWeight: "font weight"
        case .cgAlignment: "alignment"
        case .cgKerningEnabled: "kerning"
        case .cgTracking: "tracking"
        case .cgLeading: "leading"
        case .cgOutlineWidth: "outline width"
        case .cgShadowOffsetX: "shadow x"
        case .cgShadowOffsetY: "shadow y"
        case .cgShadowBlur: "shadow blur"
        case .cgShadowOpacity: "shadow opacity"
        case .cgRollMode: "roll mode"
        case .cgRollRate: "roll rate"
        case .cgPeriodPreset: "period preset"
        case .cgSafeZoneClamp: "safe-zone clamp"
        }
    }
}

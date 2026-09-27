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
//  Extend  : add a `static let` with a NEW code (and its display name and an
//            `allCases` entry). Never reuse or renumber an existing one — an old
//            template holding that code would silently bind to the wrong parameter.
//            Codes are permanent once shipped. Retired codes (91A/92A, MX-1) are
//            listed in the header below so they are never reissued.
//
//  OPEN, not closed (ISF-PLAN M2): a module loaded at runtime — an ISF file — has
//  inputs nobody listed here. An input that declares `VIDEOBOY_CODE` uses that code;
//  any other gets `x:<input name>` (`isolated(inputName:)`). This used to be an enum;
//  it is a struct with the same names, so `.wetDry` still reads the same everywhere.
//
//  Numbering scheme, so new codes are allocated consistently:
//    0xA  — universal per-node parameters (opacity, enable, wet/dry)
//    1xA  — geometry (scale, x, y, rotate)
//    2xA  — time-domain effects (echo decay, trails)
//    3xB  — the bitstream wedge (corruptor amount, mode, rate, seed; datamosh 35B–3FB)
//    4xC  — feedback
//    5xA  — colour controls
//    6xA  — mixer and transport
//    6xF  — crossfader transition pattern (wipes, slides, pushes, iris — same
//           mixer family, same reason as 6xE), then the AVE-5 wipe block's state
//    6xG  — AVE-5 wipe block key PRESSES (momentary, like 68A–6BA)
//    6xE  — genlock/chroma key (6xA's nine slots are already spoken for; this
//           extends the same mixer family rather than starting a new number range,
//           because a key is a property of a composite exactly like blend mode is)
//    7xA  — composite / NTSC emulation
//    9xD  — character generator (SPEC 18.1)
//

import Foundation

/// A stable parameter address. The raw value is what appears in templates and in
/// the FX panel next to the parameter's name.
public struct ParamCode: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {

    /// The code as written in templates and beside each fader: "53A", or "x:amount".
    public let rawValue: String

    /// A code from the fixed table, or a runtime code (`x:<name>`, see `isolated`).
    /// Anything else is refused, so a typo in a template cannot mint a parameter.
    public init?(rawValue: String) {
        let isKnown = ParamCode.table[rawValue] != nil
        let isRuntime = rawValue.hasPrefix(ParamCode.runtimePrefix)
            && rawValue.count > ParamCode.runtimePrefix.count
        guard isKnown || isRuntime else { return nil }
        self.rawValue = rawValue
    }

    /// Table entries only; the fixed codes below are the one place these are minted.
    private init(known rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }

    // MARK: Runtime codes (ISF inputs, SPEC 13 / ISF-PLAN 3.4)

    /// The prefix that marks a code minted at runtime rather than listed here.
    public static let runtimePrefix = "x:"

    /// The code for a module input that declares none: `x:<input name>`. Stable while
    /// the input keeps its name, and shared by every module with an input of that
    /// name — so swapping one ISF effect for another that also has `amount` keeps the
    /// mapping, which is SPEC 13's intent.
    public static func isolated(inputName: String) -> ParamCode {
        ParamCode(known: runtimePrefix + inputName)
    }

    /// Whether this code was minted at runtime (an ISF input) rather than listed here.
    public var isRuntime: Bool { rawValue.hasPrefix(ParamCode.runtimePrefix) }

    // MARK: Codable — a bare string, exactly as the enum was written

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let code = ParamCode(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown param code '\(raw)'")
        }
        self = code
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }


    // MARK: Universal (0xA)

    /// Layer opacity, 0...1. Present on every node that composites.
    public static let opacity = ParamCode(known: "01A")
    /// Effect wet/dry mix, 0...1.
    public static let wetDry = ParamCode(known: "02A")
    /// Node enable, 0 or 1.
    public static let enabled = ParamCode(known: "03A")

    // MARK: Geometry (1xA)

    public static let scale = ParamCode(known: "11A")
    public static let positionX = ParamCode(known: "12A")
    public static let positionY = ParamCode(known: "13A")
    public static let rotation = ParamCode(known: "14A")
    /// Mirror left-to-right, above the halfway point.
    public static let flipHorizontal = ParamCode(known: "15A")
    /// Mirror top-to-bottom, above the halfway point.
    public static let flipVertical = ParamCode(known: "16A")

    // MARK: Time-domain effects (2xA)

    public static let echoDecay = ParamCode(known: "21A")
    public static let trailLength = ParamCode(known: "22A")
    /// Luma threshold above which a pixel is echoed at all.
    public static let echoThreshold = ParamCode(known: "23A")
    /// Freeze: above 0.5 the picture is held (the Freeze card, kept from MX-1).
    public static let freezeHold = ParamCode(known: "24A")

    // MARK: The bitstream wedge (3xB)
    //
    // These are the competitive core. They address the corruptor that runs on
    // compressed packets before decode (SPEC 5).

    /// How much corruption to apply, 0...1.
    public static let corruptAmount = ParamCode(known: "31B")
    /// Which corruption transform is selected, quantised from 0...1.
    public static let corruptMode = ParamCode(known: "32B")
    /// How often corruption is re-rolled, as a beat subdivision.
    public static let corruptRate = ParamCode(known: "33B")
    /// The corruptor's random seed, so a performance is repeatable.
    public static let corruptSeed = ParamCode(known: "34B")
    /// Datamosh: 0 clean; above 0, keyframes and cut frames never reach the decoder,
    /// so new motion smears the old picture. Towards 1, smaller changes count as cuts.
    public static let moshAmount = ParamCode(known: "35B")
    /// Datamosh bloom: 0 off; above 0, that share of frames are replays of the loop
    /// (1 = every frame), so the stream slows as it comes down.
    public static let moshBloom = ParamCode(known: "36B")
    /// Datamosh heal: a press (crossing halfway) eases the clean picture back in over
    /// the heal time, then lets one clean keyframe through.
    public static let moshHeal = ParamCode(known: "37B")
    /// Datamosh blocks: the encoder's bitrate. Low is starved and blocky.
    public static let moshBlocks = ParamCode(known: "38B")
    /// Datamosh melt: ordinary P-frames dropped at random, so continuous footage melts.
    public static let moshMelt = ParamCode(known: "39B")
    /// Datamosh loop: how many P-frames bloom replays, 1 to 16.
    public static let moshLoop = ParamCode(known: "3AB")
    /// Datamosh heal on the beat: off, or every 1/16 note up to every 4 bars.
    public static let moshHealEvery = ParamCode(known: "3BB")
    /// Datamosh heal time: 0 instant, up to two seconds of easing back to clean.
    public static let moshHealTime = ParamCode(known: "3CB")
    /// Datamosh heal shape: fade, blocks, wipe, luma.
    public static let moshHealShape = ParamCode(known: "3DB")
    /// Datamosh blend: how the mosh combines with the clean picture under it.
    public static let moshBlend = ParamCode(known: "3EB")
    /// Datamosh MOSH key: a hold. While held the node moshes at full whatever the
    /// faders say (every frame a bloom replay, keyframes and cuts dropped); let go,
    /// it returns to the faders, easing back to clean if they are at zero.
    public static let moshHold = ParamCode(known: "3FB")

    // MARK: Feedback (4xC)

    public static let feedbackGain = ParamCode(known: "43C")
    public static let feedbackDelayFrames = ParamCode(known: "44C")
    /// Zoom applied inside the feedback loop — the classic infinite tunnel.
    public static let feedbackZoom = ParamCode(known: "45C")
    /// Rotation applied inside the feedback loop, in turns.
    public static let feedbackRotate = ParamCode(known: "46C")
    /// Luma key threshold for what re-enters the loop.
    public static let feedbackThreshold = ParamCode(known: "47C")

    // MARK: Colour (5xA)

    public static let contrast = ParamCode(known: "51A")
    public static let saturation = ParamCode(known: "52A")
    public static let brightness = ParamCode(known: "53A")
    /// Lifts or crushes the dark end without moving the highlights.
    public static let shadow = ParamCode(known: "54A")
    /// Rolls off or lifts the bright end without moving the shadows.
    public static let highlight = ParamCode(known: "55A")
    /// Input black point: what level is remapped to 0. Raising it crushes.
    public static let blackLevel = ParamCode(known: "56A")
    /// Input white point: what level is remapped to full. Lowering it clips.
    public static let whiteLevel = ParamCode(known: "57A")
    /// Midtone gamma. 1.0 is unchanged; below 1 brightens the middle.
    public static let gamma = ParamCode(known: "58A")

    // MARK: Mixer and transport (6xA)

    /// The A/B crossfader position, 0...1.
    public static let crossfadeAB = ParamCode(known: "61A")
    /// The C/D crossfader position, 0...1.
    public static let crossfadeCD = ParamCode(known: "62A")
    /// The ONE/TWO crossfader position, 0...1.
    public static let crossfadeOneTwo = ParamCode(known: "63A")
    /// Playback speed of a source, where 1.0 is nominal.
    public static let playbackSpeed = ParamCode(known: "64A")
    /// Layer blend mode of a composite (SPEC 12).
    public static let blendMode = ParamCode(known: "65A")
    /// Per-layer opacity of the blend layer in a composite.
    public static let layerOpacity = ParamCode(known: "66A")
    // 91A and 92A were the MX-1 effect and amount. MX-1 was removed (2026-09-23,
    // ISF-PLAN §4.1); the codes are RETIRED and must never be reissued — an old
    // template holding them would bind to whatever took their place. They load as
    // unknown codes: kept in the file, not applied.

    /// Playhead position within a clip, 0...1 — what the shuttle scrubs.
    ///
    /// Separate from `playbackSpeed`: speed is how fast the clip runs, position is
    /// where it is. A jog wheel wants the second one.
    public static let scrubPosition = ParamCode(known: "67A")

    // MARK: Momentary actions
    //
    // These are not settings, they are BUTTONS — a controller sends a note, the value
    // goes to 1, the action fires and it falls back to 0. They live in the param table
    // anyway so that learning, storing and recalling them is the same machinery as
    // everything else rather than a second mapping system alongside it (SPEC 2's one
    // extension point applies to control as well as to nodes).

    /// Cut to the other source on this bus.
    public static let cutTrigger = ParamCode(known: "68A")
    /// Fade to the other source on this bus, at the set rate.
    public static let fadeTrigger = ParamCode(known: "69A")
    /// Cut straight to this bus's LEFT source (e.g. A, C, or ONE) — what the left
    /// bus key does. Unlike `cutTrigger`, this names a direction rather than
    /// toggling to whichever end is not already up.
    public static let cutToLeftTrigger = ParamCode(known: "6AA")
    /// Cut straight to this bus's RIGHT source (e.g. B, D, or TWO) — what the
    /// right bus key does.
    public static let cutToRightTrigger = ParamCode(known: "6BA")
    /// Toggles A/B ROLL on this sub-mix: the incoming source rolls on take, the
    /// outgoing one pauses and re-cues (docs/specs/ab-roll-adv.md).
    public static let rollToggleTrigger = ParamCode(known: "6CA")
    /// Toggles ADV on this sub-mix: a source leaving air loads its next clip.
    public static let advanceToggleTrigger = ParamCode(known: "6DA")

    // MARK: Now Playing generator (7xH)

    /// Which look: 0 slab, 0.5 ticker, 1 card (`NowPlayingTemplate`).
    public static let nowPlayingTemplate = ParamCode(known: "71H")
    /// Above 0.5: show only around a track change (fade in, hold, fade out).
    public static let nowPlayingOnChange = ParamCode(known: "72H")
    /// Seconds held on screen after a track change, 1...30.
    public static let nowPlayingHold = ParamCode(known: "73H")
    /// Above 0.5: draw the progress bar.
    public static let nowPlayingProgress = ParamCode(known: "74H")

    // MARK: Genlock/chroma key (6xE)
    //
    // A composite's key is a property of THAT composite, the same way blend mode and
    // layer opacity are — so these live beside them rather than beside whatever
    // happens to be plugged into the composite's blend-layer input. That is a
    // deliberate choice: the emulated titler is the reason this exists (SPEC 18.2 —
    // "provide luma/chroma key on the emulator source so the background drops out"),
    // but the key itself knows nothing about the titler. Any two layers can use it.

    /// The colour keyed out, swept around the hue circle exactly like
    /// `emuTextColour`/`emuBackgroundColour` — except 0 is pinned to true black
    /// rather than red, because "key out black" is the overwhelmingly common case
    /// (colour 0 on an Amiga, and most genlock hardware) and a fader's rest
    /// position should not silently key on red instead. See `CrossfadeNode.keyRGB`.
    public static let keyColour = ParamCode(known: "61E")
    /// How close a pixel must be to the key colour, in RGB distance, to be treated
    /// as background at all. Too low and real content near the key colour survives
    /// as a hole; too high and it eats the title's own anti-aliased edges.
    public static let keyThreshold = ParamCode(known: "62E")
    /// Width of the soft transition band just past the threshold. Zero would key on
    /// a hard binary edge, which fringes visibly once the frame has been through
    /// `CompositeCodecNode` — dot crawl and chroma bleed smear a bitmap font's edges
    /// well past one pixel, so the key has to tolerate that instead of fighting it.
    public static let keyEdge = ParamCode(known: "63E")

    // MARK: Transition pattern (6xF)
    //
    // Like blend mode and the key, a transition is a property of ONE composite, so
    // it lives in the mixer family. It is a sweep rather than a menu-only setting so
    // a knob can run through the patterns mid-phrase.

    /// Which pattern the crossfader's move follows — dissolve, wipe, slide, push,
    /// iris, split, interlace — as a 0...1 sweep across `Transition.allCases`.
    public static let transition = ParamCode(known: "61F")

    // MARK: AVE-5 wipe block — state (62F–69F)
    //
    // The WJ-AVE5's WIPE MODE block (AVE5Wipe.swift), read when `transition` is AVE-5.
    // These are the block's STATE — what is lit — so a template saves them and a
    // knob can sweep them. Pressing a key from MIDI goes through the 6xG codes below
    // instead, because a press toggles or cycles and a note can only say 1 then 0.

    /// Which of the five pattern keys are lit, as a 0...1 sweep over the 32 combinations.
    public static let ave5Keys = ParamCode(known: "62F")
    /// MULTI: off, ×4, ×16.
    public static let ave5Multi = ParamCode(known: "63F")
    /// WIPE: normal, border, soft edge.
    public static let ave5Edge = ParamCode(known: "64F")
    /// ONE-WAY, above the halfway point.
    public static let ave5OneWay = ParamCode(known: "65F")
    /// REVERSE, above the halfway point.
    public static let ave5Reverse = ParamCode(known: "66F")
    /// BACK COLOUR, a sweep over the eight colours.
    public static let ave5BackColour = ParamCode(known: "67F")
    /// Joystick positioner, left to right. 0.5 is the centre. A keyboard's pitch
    /// bend lands here naturally.
    public static let ave5PositionX = ParamCode(known: "68F")
    /// Joystick positioner, top to bottom. 0.5 is the centre.
    public static let ave5PositionY = ParamCode(known: "69F")

    // MARK: AVE-5 wipe block — key presses (6xG)
    //
    // Momentary, like CUT and FADE: a learned MIDI key writes 1, ShellController
    // presses the key once and puts the value back to 0.

    public static let ave5PressFromRight = ParamCode(known: "61G")
    public static let ave5PressFromLeft = ParamCode(known: "62G")
    public static let ave5PressFromBottom = ParamCode(known: "63G")
    public static let ave5PressFromTop = ParamCode(known: "64G")
    public static let ave5PressCircle = ParamCode(known: "65G")
    public static let ave5PressMulti = ParamCode(known: "66G")
    public static let ave5PressWipe = ParamCode(known: "67G")
    public static let ave5PressOneWay = ParamCode(known: "68G")
    public static let ave5PressReverse = ParamCode(known: "69G")
    public static let ave5PressBackColour = ParamCode(known: "6AG")

    // MARK: Composite emulation (7xA)

    public static let compositeCrawl = ParamCode(known: "71A")
    public static let chromaBleed = ParamCode(known: "72A")
    public static let tbcWobble = ParamCode(known: "73A")
    /// Signal path: composite (cross-colour artefacts) vs S-Video (clean Y/C).
    public static let compositePath = ParamCode(known: "74A")
    /// How many times the codec runs — Nth-generation dubbing feel.
    public static let compositeGeneration = ParamCode(known: "75A")
    /// Luma bandwidth limit, which controls ringing and softness.
    public static let lumaBandwidth = ParamCode(known: "76A")
    /// Chroma subsampling: 4:4:4 / 4:2:2 / 4:1:1.
    public static let chromaSubsampling = ParamCode(known: "77A")
    /// Head-switching noise band at the bottom of the frame.
    public static let headSwitchingNoise = ParamCode(known: "78A")

    // MARK: Character generator (9xD, SPEC 18.1)
    //
    // Position, scale and overall opacity/bypass are NOT re-declared here — the CG
    // reuses .positionX, .positionY, .scale, .opacity and .wetDry exactly as every
    // other node does, because they mean the same thing here that they mean
    // everywhere else. Only what is genuinely new to a character generator gets a
    // new code.

    /// Point size of the type.
    public static let cgFontSize = ParamCode(known: "91D")
    /// Which weight bucket, swept 0...1 across regular/medium/semibold/bold/heavy —
    /// the same "sweep selects from a small set" pattern as `blendMode`.
    public static let cgFontWeight = ParamCode(known: "92D")
    /// Paragraph alignment, swept 0...1 across left/center/right/justified.
    public static let cgAlignment = ParamCode(known: "93D")
    /// Native font pair-kerning, on above the halfway point. A font either has this
    /// or it does not, so a continuous fader is still a threshold in practice — but
    /// it stays a fader rather than a switch so it can be detect-mapped and
    /// audio-reactive like everything else here.
    public static let cgKerningEnabled = ParamCode(known: "94D")
    /// Uniform letter-spacing added on top of the font's own metrics, in points.
    /// Negative tightens, positive opens up — separate from kerning, which only
    /// toggles the font's own built-in pair adjustments.
    public static let cgTracking = ParamCode(known: "95D")
    /// Extra space between lines, in points, added to the font's natural leading.
    public static let cgLeading = ParamCode(known: "96D")
    /// Stroke width around each glyph, in points. Zero is no outline.
    public static let cgOutlineWidth = ParamCode(known: "97D")
    /// Drop shadow horizontal offset, in points.
    public static let cgShadowOffsetX = ParamCode(known: "98D")
    /// Drop shadow vertical offset, in points.
    public static let cgShadowOffsetY = ParamCode(known: "99D")
    /// Drop shadow blur radius, in points.
    public static let cgShadowBlur = ParamCode(known: "9AD")
    /// Drop shadow opacity, 0...1, independent of the text's own opacity.
    public static let cgShadowOpacity = ParamCode(known: "9BD")
    /// Roll/crawl/reveal mode, swept 0...1 across off/roll/crawl/reveal.
    public static let cgRollMode = ParamCode(known: "9CD")
    /// How fast a roll or crawl moves, in screen-heights (or -widths, for crawl) per
    /// bar — clock-synced per SPEC 18.1, so this is a musical rate, not seconds.
    public static let cgRollRate = ParamCode(known: "9DD")
    /// The mid-90s budget-titler style preset, routed through the CompositeCodec.
    /// Off is the clean, native rendering the SPEC calls the "basic" mode.
    public static let cgPeriodPreset = ParamCode(known: "9ED")
    /// Constrains placement inside the title-safe rectangle rather than the full
    /// frame, so text cannot be positioned somewhere a CRT would cut off.
    public static let cgSafeZoneClamp = ParamCode(known: "9FD")

    // MARK: CRT target (8xA)

    /// Safe-zone overlay on previews.
    public static let safeZone = ParamCode(known: "81A")
    /// Overscan amount applied to output.
    public static let overscan = ParamCode(known: "82A")
    /// Black-frame insertion, clock-timed.
    public static let blackFrameInsertion = ParamCode(known: "83A")
    /// Grid/crosshatch overlay, for seeding feedback.
    public static let gridOverlay = ParamCode(known: "84A")

    // MARK: Emulated titler (Axx)
    //
    // STABLE CODES, because these are what a MIDI mapping and a saved template store.
    // Every one maps to a real function inside the emulated software — see
    // TitlerFunction, which is the list these mirror. A control that cannot name the
    // thing it reaches does not get a code.

    /// Which of the titler's transitions takes the page.
    public static let emuWipe = ParamCode(known: "A1A")
    /// The direction that transition travels.
    public static let emuWipeDirection = ParamCode(known: "A2A")
    /// How long it takes.
    public static let emuWipeSpeed = ParamCode(known: "A3A")
    /// How text arrives on a page already shown.
    public static let emuTextWipe = ParamCode(known: "A4A")
    /// The typeface.
    public static let emuFontFace = ParamCode(known: "A5A")
    /// Type size — the titler's only text scale.
    public static let emuFontSize = ParamCode(known: "A6A")
    /// Text colour, through the screen palette.
    public static let emuTextColour = ParamCode(known: "A7A")
    /// Background colour, likewise.
    public static let emuBackgroundColour = ParamCode(known: "A8A")
    /// How large a placed graphic is drawn.
    public static let emuBrushScale = ParamCode(known: "A9A")
    /// Where the text sits across the screen.
    public static let emuTextX = ParamCode(known: "AAA")
    /// And down it.
    public static let emuTextY = ParamCode(known: "ABA")
    /// Left, centre or right.
    public static let emuAlignment = ParamCode(known: "ACA")
    /// Colour cycling, on or off.
    public static let emuColourCycle = ParamCode(known: "ADA")
    /// How long a page holds.
    public static let emuHold = ParamCode(known: "AEA")
    /// Jump to a named page.
    public static let emuPage = ParamCode(known: "AFA")
    /// Text decoration: shadow, edge, bevel.
    public static let emuDecoration = ParamCode(known: "B1A")
    /// Italics, on or off.
    public static let emuItalic = ParamCode(known: "B2A")
    /// Which background picture is behind the text.
    public static let emuBackdrop = ParamCode(known: "B3A")
    /// A filled bar behind the text, for a lower third.
    public static let emuBox = ParamCode(known: "B4A")

    /// Human-readable name, used in the UI and in template comments. A runtime code
    /// reads as its input's name.
    public var displayName: String {
        if let name = ParamCode.displayNames[rawValue] { return name }
        return isRuntime ? String(rawValue.dropFirst(ParamCode.runtimePrefix.count)) : rawValue
    }

    private static let displayNames: [String: String] = [
        "01A": "opacity",
        "02A": "wet/dry",
        "03A": "enabled",
        "11A": "scale",
        "12A": "x",
        "13A": "y",
        "14A": "rotate",
        "15A": "flip H",
        "16A": "flip V",
        "21A": "echo decay",
        "22A": "trail length",
        "31B": "corrupt amount",
        "32B": "corrupt mode",
        "33B": "corrupt rate",
        "34B": "corrupt seed",
        "35B": "mosh",
        "36B": "bloom",
        "37B": "heal",
        "38B": "blocks",
        "39B": "melt",
        "3AB": "loop",
        "3BB": "heal every",
        "3CB": "heal time",
        "3DB": "heal shape",
        "3EB": "mosh blend",
        "3FB": "mosh hold",
        "43C": "feedback gain",
        "44C": "feedback delay",
        "51A": "contrast",
        "52A": "saturation",
        "53A": "brightness",
        "54A": "shadow",
        "55A": "highlight",
        "56A": "black level",
        "57A": "white level",
        "58A": "gamma",
        "61A": "A/B crossfade",
        "62A": "C/D crossfade",
        "63A": "ONE/TWO crossfade",
        "64A": "speed",
        "67A": "position",
        "68A": "cut",
        "69A": "fade",
        "6AA": "cut to left",
        "6BA": "cut to right",
        "6CA": "A/B roll",
        "6DA": "advance",
        "71H": "now playing look",
        "72H": "now playing on change only",
        "73H": "now playing hold",
        "74H": "now playing progress bar",
        "65A": "blend mode",
        "66A": "layer opacity",
        "61E": "key colour",
        "62E": "key threshold",
        "63E": "key edge",
        "61F": "transition",
        "62F": "AVE-5 pattern keys",
        "63F": "AVE-5 multi",
        "64F": "AVE-5 wipe edge",
        "65F": "AVE-5 one-way",
        "66F": "AVE-5 reverse",
        "67F": "AVE-5 back colour",
        "68F": "AVE-5 position X",
        "69F": "AVE-5 position Y",
        "61G": "AVE-5 A|B key",
        "62G": "AVE-5 B|A key",
        "63G": "AVE-5 A/B key",
        "64G": "AVE-5 B/A key",
        "65G": "AVE-5 circle key",
        "66G": "AVE-5 MULTI key",
        "67G": "AVE-5 WIPE key",
        "68G": "AVE-5 ONE-WAY key",
        "69G": "AVE-5 REVERSE key",
        "6AG": "AVE-5 BACK COLOUR key",
        "71A": "dot crawl",
        "72A": "chroma bleed",
        "73A": "TBC wobble",
        "74A": "signal path",
        "75A": "generation",
        "76A": "luma bandwidth",
        "77A": "chroma subsampling",
        "78A": "head switching",
        "23A": "echo threshold",
        "24A": "hold",
        "45C": "feedback zoom",
        "46C": "feedback rotate",
        "47C": "feedback threshold",
        "A1A": "emu wipe",
        "A2A": "emu wipe direction",
        "A3A": "emu wipe speed",
        "A4A": "emu text wipe",
        "A5A": "emu font",
        "A6A": "emu type size",
        "A7A": "emu text colour",
        "A8A": "emu background",
        "A9A": "emu graphic scale",
        "AAA": "emu text x",
        "ABA": "emu text y",
        "ACA": "emu alignment",
        "ADA": "emu colour cycle",
        "AEA": "emu hold",
        "AFA": "emu page",
        "B1A": "emu decoration",
        "B2A": "emu italic",
        "B3A": "emu backdrop",
        "B4A": "emu box",
        "81A": "safe zones",
        "82A": "overscan",
        "83A": "black frame insertion",
        "84A": "grid overlay",
        "91D": "font size",
        "92D": "font weight",
        "93D": "alignment",
        "94D": "kerning",
        "95D": "tracking",
        "96D": "leading",
        "97D": "outline width",
        "98D": "shadow x",
        "99D": "shadow y",
        "9AD": "shadow blur",
        "9BD": "shadow opacity",
        "9CD": "roll mode",
        "9DD": "roll rate",
        "9ED": "period preset",
        "9FD": "safe-zone clamp"
    ]

    /// Every code in the fixed table, in declaration order (what `CaseIterable` gave
    /// the enum). Runtime codes are not listed: they are only known once a module is
    /// loaded.
    public static let allCases: [ParamCode] = [
        .opacity,
        .wetDry,
        .enabled,
        .scale,
        .positionX,
        .positionY,
        .rotation,
        .flipHorizontal,
        .flipVertical,
        .echoDecay,
        .trailLength,
        .echoThreshold,
        .freezeHold,
        .corruptAmount,
        .corruptMode,
        .corruptRate,
        .corruptSeed,
        .moshAmount,
        .moshBloom,
        .moshHeal,
        .moshBlocks,
        .moshMelt,
        .moshLoop,
        .moshHealEvery,
        .moshHealTime,
        .moshHealShape,
        .moshBlend,
        .moshHold,
        .feedbackGain,
        .feedbackDelayFrames,
        .feedbackZoom,
        .feedbackRotate,
        .feedbackThreshold,
        .contrast,
        .saturation,
        .brightness,
        .shadow,
        .highlight,
        .blackLevel,
        .whiteLevel,
        .gamma,
        .crossfadeAB,
        .crossfadeCD,
        .crossfadeOneTwo,
        .playbackSpeed,
        .blendMode,
        .layerOpacity,
        .scrubPosition,
        .cutTrigger,
        .fadeTrigger,
        .cutToLeftTrigger,
        .cutToRightTrigger,
        .rollToggleTrigger,
        .advanceToggleTrigger,
        .nowPlayingTemplate,
        .nowPlayingOnChange,
        .nowPlayingHold,
        .nowPlayingProgress,
        .keyColour,
        .keyThreshold,
        .keyEdge,
        .transition,
        .ave5Keys,
        .ave5Multi,
        .ave5Edge,
        .ave5OneWay,
        .ave5Reverse,
        .ave5BackColour,
        .ave5PositionX,
        .ave5PositionY,
        .ave5PressFromRight,
        .ave5PressFromLeft,
        .ave5PressFromBottom,
        .ave5PressFromTop,
        .ave5PressCircle,
        .ave5PressMulti,
        .ave5PressWipe,
        .ave5PressOneWay,
        .ave5PressReverse,
        .ave5PressBackColour,
        .compositeCrawl,
        .chromaBleed,
        .tbcWobble,
        .compositePath,
        .compositeGeneration,
        .lumaBandwidth,
        .chromaSubsampling,
        .headSwitchingNoise,
        .cgFontSize,
        .cgFontWeight,
        .cgAlignment,
        .cgKerningEnabled,
        .cgTracking,
        .cgLeading,
        .cgOutlineWidth,
        .cgShadowOffsetX,
        .cgShadowOffsetY,
        .cgShadowBlur,
        .cgShadowOpacity,
        .cgRollMode,
        .cgRollRate,
        .cgPeriodPreset,
        .cgSafeZoneClamp,
        .safeZone,
        .overscan,
        .blackFrameInsertion,
        .gridOverlay,
        .emuWipe,
        .emuWipeDirection,
        .emuWipeSpeed,
        .emuTextWipe,
        .emuFontFace,
        .emuFontSize,
        .emuTextColour,
        .emuBackgroundColour,
        .emuBrushScale,
        .emuTextX,
        .emuTextY,
        .emuAlignment,
        .emuColourCycle,
        .emuHold,
        .emuPage,
        .emuDecoration,
        .emuItalic,
        .emuBackdrop,
        .emuBox
    ]

    /// The fixed table by raw value, for validation.
    private static let table: [String: ParamCode] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0.rawValue, $0) })
}

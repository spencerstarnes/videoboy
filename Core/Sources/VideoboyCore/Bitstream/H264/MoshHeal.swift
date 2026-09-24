//
//  MoshHeal.swift — how a datamosh lets go: gracefully, on the beat, in a shape.
//
//  Purpose : Healing a mosh is one keyframe. A keyframe is a hard cut back to the
//            clean picture, which is right for a stab and wrong for an ending. This
//            file holds the pieces that make the exit playable:
//
//              MoshHealEnvelope  eases the clean picture back in over a heal time,
//                                THEN lets the keyframe through. At the end of the
//                                fade the screen already shows the clean picture, so
//                                the keyframe resetting the decoder is invisible and
//                                the mosh starts again from clean. Letting go of the
//                                card (mosh and bloom back to 0) fades out the same
//                                way before the encoder is released.
//              MoshHealShape     how the clean picture comes back: a dissolve, codec
//                                macroblocks refreshing at random, a top-down refresh
//                                sweep, or brightest-first.
//              MoshHealEvery     heal on the beat: every 1/16 note up to every 4 bars.
//              MoshBeatTrigger   turns the transport's position into "a division
//                                boundary was crossed on this frame".
//
//  Inputs  : the heal fader / button edge, the transport position, the heal time.
//  Outputs : how much clean picture to show (0...1), and when to ask for a keyframe
//            or stop.
//  Connects: DatamoshNode (drives these once per rendered frame on the main thread),
//            the "mosh layer" shader in MetalContext (draws the shape).
//  Extend  : a new shape is a case here plus a branch in `mosh_layer_fragment`. A new
//            division is a case in `MoshHealEvery`. Never reorder either: saved
//            templates and MIDI mappings store positions on a 0...1 fader.
//
//  Pure logic, no Metal, no codecs: every rule is unit-tested.
//

import Foundation

/// How the clean picture comes back during a heal. Raw values are the shader's
/// shape numbers.
public enum MoshHealShape: Int, CaseIterable, Sendable {
    /// A plain dissolve.
    case fade = 0
    /// 16×16 macroblocks snap back to clean at random, like intra refresh.
    case blocks = 1
    /// Macroblock rows refresh from the top down, like a gradual decoder refresh.
    case wipe = 2
    /// The brightest parts of the clean picture come back first.
    case luma = 3

    public var displayName: String {
        switch self {
        case .fade: "fade"
        case .blocks: "blocks"
        case .wipe: "wipe"
        case .luma: "luma"
        }
    }

    /// Selects a shape from a 0...1 parameter (code `3DB`).
    public static func from(normalised value: Double) -> MoshHealShape {
        allCases[NormalisedSweep.index(value, count: allCases.count)]
    }

    /// Where this shape sits on its 0...1 fader.
    public var normalisedPosition: Double {
        NormalisedSweep.value(forIndex: rawValue, count: Self.allCases.count)
    }
}

/// How often the mosh heals itself on the beat.
public enum MoshHealEvery: Int, CaseIterable, Sendable {
    case off = 0
    case sixteenth
    case eighth
    case beat
    case twoBeats
    case bar
    case twoBars
    case fourBars

    public var displayName: String {
        switch self {
        case .off: "off"
        case .sixteenth: "1/16"
        case .eighth: "1/8"
        case .beat: "1 beat"
        case .twoBeats: "2 beats"
        case .bar: "1 bar"
        case .twoBars: "2 bars"
        case .fourBars: "4 bars"
        }
    }

    /// The card's readout: five characters at most, for a narrow column.
    public var shortName: String {
        switch self {
        case .off: "off"
        case .sixteenth: "1/16"
        case .eighth: "1/8"
        case .beat: "1bt"
        case .twoBeats: "2bt"
        case .bar: "1bar"
        case .twoBars: "2bar"
        case .fourBars: "4bar"
        }
    }

    /// Selects a division from a 0...1 parameter (code `3BB`).
    public static func from(normalised value: Double) -> MoshHealEvery {
        allCases[NormalisedSweep.index(value, count: allCases.count)]
    }

    /// Where this division sits on its 0...1 fader.
    public var normalisedPosition: Double {
        NormalisedSweep.value(forIndex: rawValue, count: Self.allCases.count)
    }
}

/// Fires when the transport crosses a `MoshHealEvery` boundary.
///
/// Bars are counted with the transport's own bar number, so they follow its time
/// signature; shorter divisions use the total beat count. Nothing fires with the
/// transport stopped, on the first frame after it starts, or on the frame the
/// division is changed — only on a boundary actually crossed while playing.
public struct MoshBeatTrigger: Sendable {
    private var lastIndex: Int?
    private var lastEvery: MoshHealEvery = .off

    public init() {}

    /// Call once per rendered frame. True when this frame crossed a boundary.
    public mutating func fires(every: MoshHealEvery, at position: MusicalPosition?) -> Bool {
        defer { lastEvery = every }
        guard every != .off, let position else {
            lastIndex = nil
            return false
        }
        let index: Int
        switch every {
        case .off: return false
        case .sixteenth: index = Int((position.totalBeats / 0.25).rounded(.down))
        case .eighth: index = Int((position.totalBeats / 0.5).rounded(.down))
        case .beat: index = Int(position.totalBeats.rounded(.down))
        case .twoBeats: index = Int((position.totalBeats / 2).rounded(.down))
        case .bar: index = position.bar
        case .twoBars: index = position.bar / 2
        case .fourBars: index = position.bar / 4
        }
        let previous = every == lastEvery ? lastIndex : nil
        lastIndex = index
        guard let previous else { return false }
        return index != previous
    }
}

/// The clean picture's way back in, one rendered frame at a time.
///
///     heal pressed ──► HEALING (clean rises over the heal time)
///                        └─► AWAITING KEYFRAME (clean held at 1; keyframe asked for)
///                              └─► keyframe on screen ──► IDLE (clean 0: the mosh
///                                  now starts from the clean picture, so no jump)
///     mosh and bloom at 0 ──► RELEASING (clean rises) ──► stop the encoder
///     pushed up again while releasing ──► RETURNING (clean falls back to 0)
///
/// A heal time of 0 is the old behaviour: the keyframe is asked for at once and
/// letting go stops at once.
public struct MoshHealEnvelope: Equatable, Sendable {

    public enum Phase: Equatable, Sendable {
        case idle
        case healing
        case awaitingKeyframe
        case releasing
        case returning
    }

    /// What the node should do this frame.
    public enum Action: Equatable, Sendable {
        case none
        /// Force a keyframe from the encoder and let it through the engine.
        case requestKeyframe
        /// Release the encoder; the picture is clean.
        case stop
    }

    /// The longest heal the time fader reaches, in frames (two seconds at 29.97).
    public static let maximumFrames = 60
    /// Frames to wait for a requested keyframe before asking again. A request can be
    /// lost when the encoder is backed up; the screen must not sit on clean forever.
    public static let keyframeTimeout = 15

    /// Fifteen steps of 1/15 add up to a hair under 1; the ends snap within this.
    private static let tolerance = 1e-9

    public private(set) var phase: Phase = .idle
    /// How much of the clean picture shows through the mosh, 0...1.
    public private(set) var clean = 0.0
    private var waited = 0

    public init() {}

    /// The heal time fader (0...1) in frames: 0 is instant, 1 is two seconds.
    public static func frames(fromNormalised value: Double) -> Int {
        Int((min(max(value, 0), 1) * Double(maximumFrames)).rounded())
    }

    /// A heal was asked for (the button, MIDI, or the beat).
    public mutating func trigger(frames: Int) -> Action {
        switch phase {
        case .idle, .returning:
            guard frames > 0 else { return .requestKeyframe }
            phase = .healing
            return .none
        case .healing, .awaitingKeyframe, .releasing:
            return .none
        }
    }

    /// Once per rendered frame. `neutral` is true when the card has been let go.
    public mutating func advance(frames: Int, neutral: Bool) -> Action {
        let step = frames > 0 ? 1.0 / Double(frames) : 1.0
        if neutral {
            phase = .releasing
            clean = min(1, clean + step)
            if clean >= 1 - Self.tolerance {
                reset()
                return .stop
            }
            return .none
        }
        switch phase {
        case .idle:
            clean = 0
            return .none
        case .releasing, .returning:
            phase = .returning
            clean = max(0, clean - step)
            if clean <= Self.tolerance {
                clean = 0
                phase = .idle
            }
            return .none
        case .healing:
            clean = min(1, clean + step)
            guard clean >= 1 - Self.tolerance else { return .none }
            clean = 1
            phase = .awaitingKeyframe
            waited = 0
            return .requestKeyframe
        case .awaitingKeyframe:
            waited += 1
            guard waited > Self.keyframeTimeout else { return .none }
            waited = 0
            return .requestKeyframe
        }
    }

    /// The healed keyframe has reached the screen: the mosh and the clean picture are
    /// the same picture, so the fade can drop away without a visible step.
    public mutating func keyframeShown() {
        guard phase == .awaitingKeyframe else { return }
        phase = .idle
        clean = 0
        waited = 0
    }

    public mutating func reset() {
        phase = .idle
        clean = 0
        waited = 0
    }
}

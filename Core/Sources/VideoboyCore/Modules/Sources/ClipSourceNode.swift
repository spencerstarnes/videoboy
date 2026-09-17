//
//  ClipSourceNode.swift — a playable clip on one channel (SPEC 6).
//
//  Purpose : One of A/B/C/D. Owns the playhead, the loop modes, the musical step
//            playback, the in/out points and the pre-decode damage — everything about
//            WHEN a frame is shown. What turns bytes into a picture is behind
//            `ClipDecoding`, so DV and ordinary video share all of this rather than
//            being two source modules with two sets of playback bugs.
//  Inputs  : a media file, a param registry, and the render context's musical clock.
//  Outputs : one `MTLTexture` per frame, plus the last decoded `ImageBuffer` for
//            headless checks.
//  Connects: ClipDecoding (DV or AVFoundation), DIFCorruptor via the DV decoder,
//            Scheduler (beat-synced reseeds), the source panels.
//  Extend  : a new container is a new `ClipDecoding`, not a new node. Playback rules
//            added here are then true of every format at once, which is the point.
//
//  It is still named for clips rather than for DV because it is no longer about DV:
//  the wedge lives in `DVClipDecoder`, where it can only be applied to bytes that can
//  carry it.
//
import Foundation
import Metal

/// How playback is timed.
///
/// Continuous is ordinary playback: frames advance with the render clock, retimed to
/// the project rate. Stepped advances a fixed number of frames on each musical
/// subdivision and holds in between, so a 30 fps clip becomes a slideshow locked to
/// the music — one frame per beat, or per half beat, or four frames per beat.
public enum PlaybackTiming: Equatable, Codable, Sendable {
    /// Normal playback, retimed to the project clock.
    case continuous
    /// Advance `frames` once every `every` × `subdivision`, and hold in between.
    ///
    /// `every` exists so the ladder can reach BELOW one bar per frame — 2/1, 4/1 and
    /// 8/1 on the shuttle mean one frame every two, four or eight bars. `Subdivision`
    /// stops at a whole note, and a hold that long is the slowest, most deliberate
    /// end of step playback rather than an edge case.
    case stepped(subdivision: Subdivision, frames: Int, every: Int)

    /// The common form: once per subdivision.
    ///
    /// A static function shadowing the case, so the many call sites that never wanted
    /// a multiple read exactly as they did before.
    public static func stepped(subdivision: Subdivision, frames: Int) -> PlaybackTiming {
        .stepped(subdivision: subdivision, frames: frames, every: 1)
    }

    /// Every rung of the shuttle's ladder, slowest first.
    ///
    /// Numark's rule: the button reads STEP when it is off, clicking walks toward
    /// faster, and control-clicking walks toward slower. One ladder, two directions,
    /// with "off" sitting between the two halves.
    public static let slowLadder: [PlaybackTiming] = [
        .stepped(subdivision: .whole, frames: 1, every: 2),  // 2/1 — a frame every two bars
        .stepped(subdivision: .whole, frames: 1, every: 4),  // 4/1
        .stepped(subdivision: .whole, frames: 1, every: 8)   // 8/1
    ]

    public static let fastLadder: [PlaybackTiming] = [
        .stepped(subdivision: .whole, frames: 1),      // 1/1 — a frame a bar
        .stepped(subdivision: .half, frames: 1),       // 1/2
        .stepped(subdivision: .quarter, frames: 1),    // 1/4
        .stepped(subdivision: .eighth, frames: 1),     // 1/8
        .stepped(subdivision: .sixteenth, frames: 1)   // 1/16
    ]

    /// Kept for anything that still wants a flat list of the stepped options.
    public static let presets: [PlaybackTiming] = slowLadder.reversed() + fastLadder

    /// Short label, as it reads on the shuttle button.
    public var displayName: String {
        switch self {
        case .continuous:
            return "STEP"
        case .stepped(let subdivision, let frames, let every):
            // A multiple reads as a ratio the other way round: 2/1 is two bars per
            // frame, which is how a DJ deck labels the slow end.
            let name = every > 1 ? "\(every)/1" : subdivision.rawValue
            return frames == 1 ? name : "\(name)×\(frames)"
        }
    }

    /// A sentence for the tooltip, because "1/8×4" needs explaining once.
    public var explanation: String {
        switch self {
        case .continuous:
            return "Normal playback, retimed to the project rate."
        case .stepped(let subdivision, let frames, let every):
            let plural = frames == 1 ? "frame" : "frames"
            let unit = every > 1
                ? "\(every) bars"
                : "\(subdivision.rawValue) note"
            return "Advance \(frames) \(plural) every \(unit), holding in between."
        }
    }

    /// Beats between steps, or nil when playback is continuous.
    public var beatsPerStep: Double? {
        switch self {
        case .continuous: nil
        case .stepped(let subdivision, _, let every): subdivision.beats * Double(max(every, 1))
        }
    }

    /// Frames advanced per step.
    public var framesPerStep: Int {
        switch self {
        case .continuous: 0
        case .stepped(_, let frames, _): frames
        }
    }
}

/// How a clip behaves when it reaches its end (SPEC 12).
public enum LoopMode: String, CaseIterable, Codable, Sendable {

    /// Wrap back to the start and keep going.
    case loop
    /// Reverse direction at each end.
    case pingPong
    /// Stop on the last frame.
    case oneShot

    /// One character for the shuttle key, which cycles through the three.
    public var shuttleGlyph: String {
        switch self {
        case .loop: "↻"
        case .pingPong: "⇄"
        case .oneShot: "1"
        }
    }

    public var displayName: String {
        switch self {
        case .loop: "Loop"
        case .pingPong: "Ping-Pong"
        case .oneShot: "One Shot"
        }
    }

    /// Selects from a 0...1 parameter, or from a segmented control's index.
    public static func from(index: Int) -> LoopMode {
        let all = allCases
        return all[min(max(index, 0), all.count - 1)]
    }
}

/// Plays a DV file into the render graph, corrupting it before decode.
public final class ClipSourceNode: Node, DataEffectProvider {

    public let identifier: String
    public let kind: NodeKind = .source

    /// Decoding a DV frame is not instantaneous, and the mixer must compensate for
    /// it when scheduling a cut so the result lands on the beat (SPEC 4b). One frame
    /// is measured-conservative: DV decode runs well under a frame period, but the
    /// upload and composite that follow it occupy the rest of the frame.
    public let latencyInFrames = 1

    public var parameters: [Parameter] {
        [
            Parameter(code: .corruptAmount, range: 0...1, defaultValue: 0),
            Parameter(code: .corruptMode, range: 0...1, defaultValue: 0),
            Parameter(code: .corruptRate, range: 0...1, defaultValue: 0.25),
            Parameter(code: .corruptSeed, range: 0...65535, defaultValue: 1),
            Parameter(code: .playbackSpeed, range: 0...2, defaultValue: 1),
            Parameter(code: .scrubPosition, range: 0...1, defaultValue: 0)
        ]
    }

    /// What is decoding the loaded clip, or nil when nothing is loaded.
    ///
    /// DV for the wedge, AVFoundation for everything else. Which one is in use is
    /// the only thing that differs between a .dv and a .mov here — the playhead, the
    /// loop modes, the musical stepping and the in/out points are the same code.
    public private(set) var clipDecoder: ClipDecoding?
    /// The file's own path, for templates and the panel title.
    public private(set) var mediaURL: URL?

    /// What damage to apply. Set by the UI, by mappings, and by the scheduler.
    public var corruption = CorruptionSettings.inert

    /// Whether playback advances.
    public var isPlaying = false

    /// Playback rate, 1.0 being nominal.
    public var playbackSpeed = 1.0

    /// What happens at the end of the clip.
    public var loopMode: LoopMode = .loop

    /// In and out points as 0...1 fractions, set from the library.
    ///
    /// Nil means the whole clip. Every end-of-clip rule works over this range rather
    /// than over the file, so a trimmed clip loops, ping-pongs and one-shots within
    /// its marks — which is the only reading of "in and out" that is worth having.
    /// Marks the library only DREW would be decoration.
    public var playbackRange: ClosedRange<Double>? {
        didSet {
            guard let range = playbackRange, frameCount > 0 else { return }
            // Pull the playhead inside the new range rather than leaving it stranded
            // outside, where playback would appear frozen until it wrapped.
            let first = Double(rangeFirstFrame(range))
            let last = Double(rangeLastFrame(range))
            playheadFrame = min(max(playheadFrame, first), last)
        }
    }

    /// First frame index of the active range.
    private func rangeFirstFrame(_ range: ClosedRange<Double>?) -> Int {
        guard let range, frameCount > 0 else { return 0 }
        return min(max(Int(range.lowerBound * Double(frameCount - 1)), 0), frameCount - 1)
    }

    /// Last frame index of the active range, inclusive.
    private func rangeLastFrame(_ range: ClosedRange<Double>?) -> Int {
        guard let range, frameCount > 0 else { return max(frameCount - 1, 0) }
        let index = Int((range.upperBound * Double(frameCount - 1)).rounded())
        return min(max(index, rangeFirstFrame(range)), frameCount - 1)
    }

    /// Whether playback runs with the render clock or steps on the musical one.
    public var timing: PlaybackTiming = .continuous {
        didSet { lastSteppedBoundary = nil }
    }

    /// The musical position of the last step taken, so each boundary steps once.
    private var lastSteppedBoundary: Double?

    /// Direction of travel. Only ping-pong ever makes this negative.
    private(set) public var isPlayingBackwards = false

    /// Current position, in source frames. Fractional so non-nominal speeds work.
    public private(set) var playheadFrame = 0.0

    /// The most recently decoded picture, kept so the preview has something to show
    /// while paused and so a failed decode does not blank the output.
    public private(set) var lastImage: ImageBuffer?

    private let context: MetalContext?
    private var texture: MTLTexture?
    /// Frame index the current texture was produced from; avoids redundant decodes.
    private var textureFrameIndex = -1
    /// The last corruption settings the texture was produced with, for the same reason.
    private var textureCorruption = CorruptionSettings.inert

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
    }

    /// Total frames in the loaded file, or 0.
    public var frameCount: Int { clipDecoder?.frameCount ?? 0 }

    /// Wraps a frame index into the loaded clip.
    private func wrappedIndex(_ index: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let remainder = index % frameCount
        return remainder < 0 ? remainder + frameCount : remainder
    }

    /// Which data effects the loaded clip supports, if any.
    ///
    /// This is what the source panel's data stack reads to decide whether to appear
    /// at all. It says `.none` for an empty channel AND for ordinary video, because
    /// neither can be damaged before decode — and offering the wedge on a .mov would
    /// be advertising something that cannot happen.
    public var dataEffectFamily: DataEffectFamily {
        clipDecoder?.dataEffectFamily ?? .none
    }

    /// Playback position as 0...1, for the shuttle's scrub track.
    public var normalisedPosition: Double {
        guard frameCount > 1 else { return 0 }
        return playheadFrame / Double(frameCount - 1)
    }

    /// Loads a DV file.
    ///
    /// A failure is logged and leaves the node empty rather than throwing into the
    /// render loop; the panel then shows its "no source" state (SPEC 1.5).
    @discardableResult
    public func load(url: URL) -> Bool {
        // The extension chooses the decoder. DV goes down the bitstream path because
        // that is the only path the wedge can work on; everything else goes through
        // AVFoundation. A .dv that will not open is NOT retried as ordinary video —
        // it would then play without the effects that are the reason to use DV.
        let decoder: ClipDecoding?
        switch url.pathExtension.lowercased() {
        case "dv":
            decoder = try? DVClipDecoder(url: url)
        case "m2v", "mpg", "mpeg", "ts", "m2t", "m2ts", "vob":
            // The MPEG families go through the bitstream decoder rather than
            // AVFoundation, which could also play them but hands back finished
            // pictures with no seam to damage. The wedge needs the packet.
            decoder = MPEGStreamDecoder(url: url) ?? AVFClipDecoder(url: url)
        default:
            decoder = AVFClipDecoder(url: url)
        }

        guard let decoder, decoder.frameCount > 0 else {
            Log.error(.dv, "\(identifier) could not load \(url.lastPathComponent)")
            self.clipDecoder = nil
            self.mediaURL = nil
            return false
        }

        self.clipDecoder = decoder
        self.mediaURL = url
        self.playheadFrame = 0
        self.isPlayingBackwards = false
        self.textureFrameIndex = -1
        self.playbackRange = nil
        Log.info(.dv, "\(identifier) loaded \(url.lastPathComponent) "
            + "(\(decoder.dataEffectFamily.displayName) data effects)")
        return true
    }

    /// Steps the playhead if a subdivision boundary has been crossed since the last one.
    ///
    /// Boundary-crossing rather than "is the phase near zero": at slow subdivisions a
    /// phase test would fire for several frames running, and at fast ones it could
    /// miss a boundary entirely between two render frames. Comparing which step
    /// interval we are in does neither.
    func advanceIfBoundaryCrossed(
        totalBeats: Double, beatsPerStep: Double, frames: Int, frameCount: Int
    ) {
        guard beatsPerStep > 0, frameCount > 0 else { return }

        let currentInterval = (totalBeats / beatsPerStep).rounded(.down)
        guard let previous = lastSteppedBoundary else {
            // First frame after arming: take the current position as the reference
            // rather than stepping immediately, so enabling it mid-bar does not jump.
            lastSteppedBoundary = currentInterval
            return
        }
        guard currentInterval != previous else { return }

        // Step once per boundary crossed, so a late frame catches up rather than
        // silently losing steps and drifting out of phase with the music.
        let crossings = Int(abs(currentInterval - previous))
        for _ in 0..<max(crossings, 1) {
            advancePlayhead(by: Double(frames), frameCount: frameCount)
        }
        lastSteppedBoundary = currentInterval
    }

    /// Advances the playhead and applies the loop mode at the ends.
    ///
    /// Split out from `render` because the end-of-clip rules are the whole of what
    /// the loop buttons do, and they are worth being able to read and test on their
    /// own rather than buried in a render path.
    func advancePlayhead(by frames: Double, frameCount: Int) {
        guard frameCount > 0 else { return }

        // The ends are the in and out points when there are any, and the ends of the
        // file when there are not. Everything below is written against these two
        // numbers so there is one set of rules rather than a trimmed variant of each.
        let first = Double(rangeFirstFrame(playbackRange))
        let lastFrame = Double(rangeLastFrame(playbackRange))
        let span = lastFrame - first + 1

        playheadFrame += isPlayingBackwards ? -frames : frames

        switch loopMode {
        case .loop:
            // Wrap at both ends: playing backwards past the in point comes round to
            // the out point.
            if playheadFrame >= first + span {
                playheadFrame -= span
            } else if playheadFrame < first {
                playheadFrame += span
            }

        case .pingPong:
            // Turn around rather than wrap. The overshoot is reflected back so the
            // motion stays smooth at the turn instead of pausing on the end frame.
            if playheadFrame >= lastFrame {
                playheadFrame = max(lastFrame - (playheadFrame - lastFrame), first)
                isPlayingBackwards = true
            } else if playheadFrame <= first {
                playheadFrame = first + (first - playheadFrame)
                isPlayingBackwards = false
            }

        case .oneShot:
            // Stop on the out point and stay there.
            if playheadFrame >= lastFrame {
                playheadFrame = lastFrame
                isPlaying = false
                Log.info(.dv, "\(identifier) reached the end of its clip (one shot)")
            } else if playheadFrame < first {
                playheadFrame = first
                isPlaying = false
            }
        }
    }

    /// Moves the playhead to a 0...1 position (the shuttle scrub).
    public func seek(toNormalised position: Double) {
        guard frameCount > 0 else { return }
        // Relative to the in/out range, so the shuttle spans the TRIMMED clip. A
        // scrub that could land outside the marks would make them advisory, and the
        // first thing anyone would do is scrub straight past them.
        let first = Double(rangeFirstFrame(playbackRange))
        let lastFrame = Double(rangeLastFrame(playbackRange))
        playheadFrame = first + min(max(position, 0), 1) * (lastFrame - first)
    }

    /// Steps the playhead by whole frames (the shuttle's step buttons).
    public func step(by frames: Int) {
        guard clipDecoder != nil else { return }
        playheadFrame = Double(wrappedIndex(Int(playheadFrame.rounded()) + frames))
    }

    /// Re-rolls the corruption seed. Called by the scheduler on a beat boundary, so
    /// the damage changes in time with the music rather than continuously.
    public func rerollCorruptionSeed(using source: UInt64) {
        corruption.seed = source
    }

    // MARK: - Node

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let clipDecoder, let metal = context else { return texture }

        if isPlaying {
            switch timing {
            case .continuous:
                // Advance at the source's own rate relative to the project rate, so a
                // file is retimed to the clock rather than ad-hoc frame-dropped (SPEC 3).
                let sourceFramesPerProjectFrame =
                    (clipDecoder.frameRate / StandardDefinition.frameRate) * playbackSpeed
                advancePlayhead(by: sourceFramesPerProjectFrame, frameCount: clipDecoder.frameCount)

            case .stepped(_, let frames, _):
                // Hold the frame, and jump only when a boundary is crossed. With the
                // transport stopped there are no boundaries, so a stepped clip simply
                // holds — which is right: its timing comes from the music, and there
                // is no music.
                //
                // The interval comes from `beatsPerStep`, which already folds the bar
                // multiple in, so 2/1 and 1/2 travel the same code path.
                if let position = renderContext.musicalPosition,
                   let beatsPerStep = timing.beatsPerStep {
                    advanceIfBoundaryCrossed(
                        totalBeats: position.totalBeats,
                        beatsPerStep: beatsPerStep,
                        frames: frames,
                        frameCount: clipDecoder.frameCount
                    )
                }
            }
        }

        let frameIndex = wrappedIndex(Int(playheadFrame))

        // Re-decode only when the frame or the damage has actually changed. With the
        // transport stopped and no corruption this makes the preview free.
        if frameIndex == textureFrameIndex && corruption == textureCorruption, texture != nil {
            return texture
        }

        guard let image = clipDecoder.image(at: frameIndex, corruption: corruption) else {
            // A frame that will not decode at all keeps the previous picture on
            // screen rather than flashing black.
            Log.warn(.dv, "\(identifier) frame \(frameIndex) produced no picture; holding the last one")
            return texture
        }

        lastImage = image
        texture = metal.makeTexture(from: image, label: "\(identifier)-frame-\(frameIndex)")
        textureFrameIndex = frameIndex
        textureCorruption = corruption
        return texture
    }

    /// Renders one frame without a Metal device, for headless self-QA.
    ///
    /// Same read/corrupt/decode path as `render`, stopping before the GPU upload, so
    /// a test can assert on pixels with no window server present.
    public func renderToImage(frameIndex requestedIndex: Int) -> ImageBuffer? {
        guard let clipDecoder else { return nil }
        return clipDecoder.image(at: wrappedIndex(requestedIndex), corruption: corruption)
    }

    /// Applies parameter values from the registry. Called once per frame by the app,
    /// so a MIDI move, a template load and a UI drag all arrive the same way.
    public func applyParameters(from registry: ParamRegistry) {
        if let amount = registry.value(slot: identifier, code: .corruptAmount) {
            corruption.amount = amount
        }
        if let mode = registry.value(slot: identifier, code: .corruptMode) {
            corruption.mode = CorruptionMode.from(normalised: mode)
            // Kept alongside, so a family with a different mode list reads the
            // fader rather than the DV enum it happens to have been quantised to.
            corruption.modePosition = mode
        }
        if let speed = registry.value(slot: identifier, code: .playbackSpeed) {
            playbackSpeed = speed
        }
        if let seed = registry.value(slot: identifier, code: .corruptSeed) {
            corruption.seed = UInt64(max(0, seed))
        }
        // Position only seeks when the parameter MOVES. Applying it every frame the
        // way the others are applied would pin the playhead to wherever the fader
        // was last left, and the clip would never advance — a jog wheel would work
        // and the play button would not. Only a deliberate change counts.
        if let position = registry.value(slot: identifier, code: .scrubPosition) {
            if let last = lastAppliedScrub, abs(last - position) < 1e-6 {
                // Unchanged: leave the playhead where playback has carried it.
            } else {
                seek(toNormalised: position)
            }
            lastAppliedScrub = position
        }
    }

    /// The last scrub value seen from the registry, to tell a move from a repeat.
    private var lastAppliedScrub: Double?
}

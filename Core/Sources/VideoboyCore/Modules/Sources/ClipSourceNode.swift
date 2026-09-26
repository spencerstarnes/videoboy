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
            // Bypass for the wedge, the same code every other effect uses for the
            // same purpose. Below 0 is dry (clean, whatever `amount` is dialed to)
            // and 1 is fully engaged — reusing `.wetDry` here is what lets the
            // corruptor's card carry a real ON/OFF switch and real MIDI/AUD/LFO
            // badges instead of controls that resolve to nothing.
            Parameter(code: .wetDry, range: 0...1, defaultValue: 1),
            Parameter(code: .corruptAmount, range: 0...1, defaultValue: 0),
            Parameter(code: .corruptMode, range: 0...1, defaultValue: 0),
            Parameter(code: .corruptRate, range: 0...1, defaultValue: 0.25),
            Parameter(code: .corruptSeed, range: 0...65535, defaultValue: 1),
            Parameter(code: .playbackSpeed, range: 0...2, defaultValue: 1),
            Parameter(code: .scrubPosition, range: 0...1, defaultValue: 0)
        ]
    }

    /// Whether the wedge is engaged at all. Below the enable switch's threshold, the
    /// dialed-in `corruption.amount` is preserved but not applied — flipping the
    /// switch back on returns to exactly the damage that was set before, the same
    /// promise wet/dry makes on every bus effect.
    public var wetDry: Double = 1.0

    /// What actually reaches the decoder: `corruption` when engaged, `.inert` when
    /// bypassed. One seam, used by both the live render path and the headless one,
    /// so they cannot silently disagree about what "bypassed" means.
    private var effectiveCorruption: CorruptionSettings {
        wetDry > 0.001 ? corruption : .inert
    }

    /// What is decoding the loaded clip, or nil when nothing is loaded.
    ///
    /// DV for the wedge, AVFoundation for everything else. Which one is in use is
    /// the only thing that differs between a .dv and a .mov here — the playhead, the
    /// loop modes, the musical stepping and the in/out points are the same code.
    public private(set) var clipDecoder: ClipDecoding?
    /// Decodes ahead of the playhead, off the main thread. Owns every DECODE of
    /// `clipDecoder`; the node reads only the decoder's fixed facts directly.
    public private(set) var prefetcher: ClipPrefetcher?

    /// Installs a freshly opened decoder and starts decoding its first frames at once,
    /// so the first render after a load usually finds frame 0 ready.
    private func install(_ decoder: ClipDecoding?) {
        clipDecoder = decoder
        prefetcher = decoder.map { ClipPrefetcher(decoder: $0, label: identifier) }
        prefetcher?.prefetch(Array(0..<min(4, decoder?.frameCount ?? 0)), damage: effectiveCorruption)
    }
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
    /// Reused, double-buffered upload target — no allocation per frame.
    private var uploader: TextureUploader?
    /// Places a picture that is not canvas-shaped into the canvas (reused target).
    private var fitter: CanvasFit?

    /// How long the LIVE tick may wait for a frame that was not decoded ahead. Nil
    /// waits as long as it takes, which offline renders and the self-QA need (every
    /// render shows exactly the frame asked for). The engine sets a few milliseconds
    /// while the display link runs: a slower decode — the first frame of a freshly
    /// opened HD file — holds the channel's previous picture for a tick instead of
    /// delaying the whole frame.
    public var missWaitLimit: TimeInterval?

    /// Where the clip's picture sits in the canvas (unit rectangle, origin top-left),
    /// or nil when it fills the canvas exactly. The previews use it to mark the bars
    /// as bars rather than as picture.
    public private(set) var picturePlacement: CGRect?

    /// The canvas decoders size their frames for. Set before `load`; the project
    /// canvas becomes a setting in 0.4.11, and this is where it will arrive.
    public var decodeCanvas = CanvasGeometry.standardDefinition

    /// How a picture that is not the canvas's shape is placed in it: the whole picture
    /// with black bars (`fit`, Resolve's default), cropped to fill, or stretched. The
    /// bars are part of the picture that goes to air, so they are black.
    public var framing: PreviewFill = .fit {
        didSet { if framing != oldValue { textureFrameIndex = -1 } }
    }
    /// Frame index the current texture was produced from; avoids redundant decodes.
    private var textureFrameIndex = -1
    /// The last corruption settings the texture was produced with, for the same reason.
    private var textureCorruption = CorruptionSettings.inert

    public init(identifier: String, context: MetalContext? = MetalContext.shared) {
        self.identifier = identifier
        self.context = context
    }

    // MARK: - Exchanging clips between channels

    /// Everything that makes a node "the clip it is currently playing".
    ///
    /// Deliberately NOT everything the node holds. Corruption amount, wet/dry and the
    /// other registry-driven values belong to the SLOT, not to the clip: they are
    /// re-applied from the registry every frame, so carrying them across would either
    /// be undone a frame later or drag a channel's whole sound over with its picture.
    /// What travels is the clip and where it had got to.
    public struct LoadedClip {
        var decoder: ClipDecoding?
        var prefetcher: ClipPrefetcher?
        var mediaURL: URL?
        var playheadFrame: Double
        var timing: PlaybackTiming
        var loopMode: LoopMode
        var playbackRange: ClosedRange<Double>?
        var isPlaying: Bool
        var isPlayingBackwards: Bool
        var playbackSpeed: Double
        var lastImage: ImageBuffer?
    }

    /// Lifts the loaded clip out of this node, leaving it empty.
    public func takeLoadedClip() -> LoadedClip {
        let clip = LoadedClip(
            decoder: clipDecoder,
            prefetcher: prefetcher,
            mediaURL: mediaURL,
            playheadFrame: playheadFrame,
            timing: timing,
            loopMode: loopMode,
            playbackRange: playbackRange,
            isPlaying: isPlaying,
            isPlayingBackwards: isPlayingBackwards,
            playbackSpeed: playbackSpeed,
            lastImage: lastImage
        )
        clipDecoder = nil
        prefetcher = nil
        mediaURL = nil
        isPlaying = false
        return clip
    }

    /// Puts a clip taken from another node into this one.
    ///
    /// The decoder moves as an OBJECT — nothing is re-opened, no file is read, no
    /// keyframe is sought. That is the whole point: a swap during a show has to be
    /// free, and reloading two clips mid-performance would cost two reader restarts on
    /// the frame path, which is exactly the thing audit C2 was about.
    public func adopt(_ clip: LoadedClip) {
        clipDecoder = clip.decoder
        prefetcher = clip.prefetcher
        mediaURL = clip.mediaURL
        playheadFrame = clip.playheadFrame
        timing = clip.timing
        loopMode = clip.loopMode
        playbackRange = clip.playbackRange
        isPlaying = clip.isPlaying
        isPlayingBackwards = clip.isPlayingBackwards
        playbackSpeed = clip.playbackSpeed
        lastImage = clip.lastImage

        // INVALIDATE THE UPLOADED TEXTURE. `render` returns the cached texture when the
        // frame index and the damage are unchanged, and after a swap both can match by
        // coincidence while the picture behind them belongs to the other channel — two
        // channels sitting on frame 0 is the ordinary case, not a corner one. Without
        // this the swap looks like it did nothing.
        texture = nil
        textureFrameIndex = -1
        textureCorruption = .inert
        lastSteppedBoundary = nil
        lastAppliedScrub = nil
        isHoldingLastPicture = false
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

        // A FOLDER is a sequence of photographs. It comes first because a directory has
        // no useful extension to switch on, and because everything downstream —
        // playback, looping, in and out points, stepping a frame on the beat — is the
        // same work whether the frames came from a file or from a stack of pictures.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            decoder = try? ImageSequenceDecoder(folder: url)
            guard let decoder, decoder.frameCount > 0 else {
                Log.error(.dv, "\(identifier) found no images in \(url.lastPathComponent)")
                install(nil)
                self.mediaURL = nil
                return false
            }
            install(decoder)
            self.mediaURL = url
            self.playheadFrame = 0

            // A STACK OF PHOTOGRAPHS ARRIVES BEAT-LOCKED, not running at frame rate.
            //
            // SPEC §153 is explicit that the point of importing a folder is that it
            // "behaves as a beat-locked clip" — deliberately NOT baked to a frame
            // sequence at project fps the way an NLE would. Loading one as `.continuous`
            // met the letter of that and missed all of it: 400 photographs at 29.97 fps
            // is thirteen seconds of flicker, and every single person who dropped a
            // folder in would have had to find the STEP button before the feature did
            // anything they wanted.
            //
            // One frame per quarter note is the honest default: it is the rung of the
            // ladder people mean by "a slideshow on the beat", and the STEP button walks
            // either way from it. A video file is untouched by this — it has its own
            // frame rate and `.continuous` is the right reading of one.
            self.timing = .stepped(subdivision: .quarter, frames: 1)

            Log.info(.dv, "\(identifier) loaded \(url.lastPathComponent): "
                + "\(decoder.frameCount) photographs, one per 1/4 note")
            return true
        }

        // DV to the DV decoder, the MPEG families to the bitstream decoder (the wedge
        // needs the packet), everything else to AVFoundation — see ClipDecoders.
        decoder = ClipDecoders.open(url, canvas: decodeCanvas)

        guard let decoder, decoder.frameCount > 0 else {
            Log.error(.dv, "\(identifier) could not load \(url.lastPathComponent)")
            install(nil)
            self.mediaURL = nil
            return false
        }

        install(decoder)
        self.mediaURL = url
        self.playheadFrame = 0
        self.isPlayingBackwards = false
        self.textureFrameIndex = -1
        self.playbackRange = nil
        Log.info(.dv, "\(identifier) loaded \(url.lastPathComponent) "
            + "(\(decoder.dataEffectFamily.displayName) data effects)")
        return true
    }

    /// Called when a ONE SHOT clip runs out, so something upstream can decide what
    /// happens next — in practice, pull the next item off this channel's playlist.
    ///
    /// The node deliberately does not own that decision. It has no idea what a
    /// playlist is, and giving it one would mean the graph reaching back out into
    /// the library to fetch files mid-render.
    ///
    /// Fired from the playback advance, so a handler that loads a file should get
    /// itself onto the main queue before touching any UI.
    public var onReachedEnd: (() -> Void)?

    /// Takes the media out of this source — the exact inverse of `load`.
    ///
    /// Every field `load` sets is put back, including the cached texture: without
    /// that last one the panel would keep showing the frame that was on screen when
    /// the clip was ejected, which looks like a source that is still loaded and
    /// merely paused. Ejecting has to LOOK like ejecting.
    ///
    /// Playback stops too. A source with nothing in it that still reports itself as
    /// playing would leave the transport lit for a deck holding no tape.
    public func unload() {
        install(nil)
        picturePlacement = nil
        mediaURL = nil
        playheadFrame = 0
        isPlaying = false
        isPlayingBackwards = false
        texture = nil
        textureFrameIndex = -1
        playbackRange = nil
        Log.info(.dv, "\(identifier) ejected")
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
        let step = Self.step(
            position: playheadFrame, backwards: isPlayingBackwards, by: frames,
            first: Double(rangeFirstFrame(playbackRange)),
            last: Double(rangeLastFrame(playbackRange)), mode: loopMode)
        playheadFrame = step.position
        isPlayingBackwards = step.backwards

        // ONE SHOT stops on its end and asks what next — unless something is
        // listening, in which case it may put the next clip in (see `onReachedEnd`).
        // Only ONE SHOT asks: loop and ping-pong already have an answer for what
        // happens at the end, and a playlist that overrode them would quietly take
        // the shuttle key's meaning away.
        switch step.ended {
        case .none:
            break
        case .atOut:
            isPlaying = false
            Log.info(.dv, "\(identifier) reached the end of its clip (one shot)")
            onReachedEnd?()
        case .atIn:
            // Running backwards into the in point is equally "finished".
            isPlaying = false
            onReachedEnd?()
        }
    }

    /// Where a one-shot playhead stopped, if it did.
    enum StepEnd { case none, atOut, atIn }

    /// One playhead step with the loop rules applied — and no side effects, so the
    /// live advance and the prefetcher's prediction of the next frames are the SAME
    /// arithmetic and cannot disagree about where a loop wraps or a ping-pong turns.
    static func step(
        position: Double, backwards: Bool, by frames: Double,
        first: Double, last: Double, mode: LoopMode
    ) -> (position: Double, backwards: Bool, ended: StepEnd) {
        let span = last - first + 1
        var position = position + (backwards ? -frames : frames)
        var backwards = backwards
        switch mode {
        case .loop:
            // Wrap at both ends: playing backwards past the in point comes round to
            // the out point.
            if position >= first + span {
                position -= span
            } else if position < first {
                position += span
            }
            return (position, backwards, .none)

        case .pingPong:
            // Turn around rather than wrap. The overshoot is reflected back so the
            // motion stays smooth at the turn instead of pausing on the end frame.
            if position >= last {
                position = max(last - (position - last), first)
                backwards = true
            } else if position <= first {
                position = first + (first - position)
                backwards = false
            }
            return (position, backwards, .none)

        case .oneShot:
            if position >= last { return (last, backwards, .atOut) }
            if position < first { return (first, backwards, .atIn) }
            return (position, backwards, .none)
        }
    }

    /// The frame indices playback will ask for next, in order — what the prefetcher
    /// decodes ahead. Empty while paused: a held frame needs nothing new.
    private func predictedIndices(after current: Int, decoder: ClipDecoding) -> [Int] {
        guard isPlaying, frameCount > 0 else { return [] }
        let frames: Double
        let count: Int
        switch timing {
        case .continuous:
            frames = (decoder.frameRate / StandardDefinition.frameRate) * playbackSpeed
            count = 5
        case .stepped(_, let stepFrames, _):
            frames = Double(stepFrames)
            count = 2
        }
        guard frames > 0 else { return [] }
        let first = Double(rangeFirstFrame(playbackRange))
        let last = Double(rangeLastFrame(playbackRange))
        var position = playheadFrame
        var backwards = isPlayingBackwards
        var indices: [Int] = []
        for _ in 0..<(count * 2) where indices.count < count {
            let next = Self.step(position: position, backwards: backwards, by: frames,
                                 first: first, last: last, mode: loopMode)
            position = next.position
            backwards = next.backwards
            let index = wrappedIndex(Int(position))
            if index != current, indices.last != index { indices.append(index) }
            if next.ended != .none { break }
        }
        return indices
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

        // Re-decode only when the frame or the EFFECTIVE damage has actually
        // changed — not the dialed-in `corruption`, which can sit unchanged while the
        // enable switch flips it in and out. Caching on the wrong one would mean the
        // bypass switch changed nothing on screen until the next frame boundary the
        // cache happened to miss anyway.
        let damage = effectiveCorruption
        if frameIndex == textureFrameIndex && damage == textureCorruption, texture != nil {
            prefetcher?.prefetch(predictedIndices(after: frameIndex, decoder: clipDecoder), damage: damage)
            return texture
        }

        // Whatever happens below, keep the next frames decoding ahead of the playhead.
        defer {
            prefetcher?.prefetch(predictedIndices(after: frameIndex, decoder: clipDecoder), damage: damage)
        }
        let fetched: ImageBuffer?
        if let limit = missWaitLimit, let prefetcher {
            switch prefetcher.image(at: frameIndex, damage: damage, waitingAtMost: limit) {
            case .ready(let image): fetched = image
            // Not decoded yet: keep showing what is on screen; it lands next tick.
            case .pending: return texture
            case .failed: fetched = nil
            }
        } else {
            fetched = prefetcher?.image(at: frameIndex, damage: damage)
        }
        guard let image = fetched else {
            // A frame that will not decode at all keeps the previous picture on
            // screen rather than flashing black.
            //
            // LOGGED ON THE WAY IN, not every frame. A truncated or unsupported file
            // fails on every frame, and this line used to fire at the frame rate: ~30
            // lines a second, 432,000 lines over a four-hour show, each one a blocking
            // write from the render thread. The state is worth knowing about once; the
            // repetition told nobody anything and cost a syscall a frame.
            if !isHoldingLastPicture {
                isHoldingLastPicture = true
                Log.warn(.dv, "\(identifier) frame \(frameIndex) produced no picture; "
                    + "holding the last one (further frames will not be logged)")
            }
            return texture
        }
        if isHoldingLastPicture {
            isHoldingLastPicture = false
            Log.info(.dv, "\(identifier) is decoding again")
        }

        lastImage = image
        if uploader == nil { uploader = TextureUploader(context: metal, label: identifier) }
        if let uploaded = uploader?.upload(image) {
            texture = conformed(uploaded, decoder: clipDecoder, metal: metal, renderContext: renderContext)
        }
        textureFrameIndex = frameIndex
        textureCorruption = damage
        return texture
    }

    /// The uploaded picture as the canvas needs it: untouched when it already is the
    /// canvas's size and shape (DV on an SD canvas — the common case costs nothing),
    /// otherwise fitted, upright, by one GPU pass.
    private func conformed(
        _ uploaded: MTLTexture, decoder: ClipDecoding, metal: MetalContext, renderContext: RenderContext
    ) -> MTLTexture? {
        let canvas = CanvasGeometry(width: renderContext.width, height: renderContext.height)
        let aspect = decoder.displayAspectRatio
            ?? CanvasGeometry.displayAspect(width: uploaded.width, height: uploaded.height)
        if CanvasFit.isIdentity(texture: uploaded, sourceAspect: aspect,
                                quarterTurns: decoder.quarterTurns, canvas: canvas) {
            picturePlacement = nil
            return uploaded
        }
        let placed = canvas.placement(sourceAspect: aspect, framing: framing)
        let unit = CGRect(x: CGFloat(placed.origin.x), y: CGFloat(placed.origin.y),
                          width: CGFloat(placed.size.x), height: CGFloat(placed.size.y))
        // Nil when the picture covers the whole canvas (fill, stretch): no bars.
        picturePlacement = unit.contains(CGRect(x: 0, y: 0, width: 1, height: 1)) ? nil : unit
        if fitter == nil { fitter = CanvasFit(context: metal, label: identifier) }
        return fitter?.fit(uploaded, sourceAspect: aspect, quarterTurns: decoder.quarterTurns,
                           framing: framing, canvas: canvas) ?? uploaded
    }

    /// Renders one frame without a Metal device, for headless self-QA.
    ///
    /// Same read/corrupt/decode path as `render`, stopping before the GPU upload, so
    /// a test can assert on pixels with no window server present.
    public func renderToImage(frameIndex requestedIndex: Int) -> ImageBuffer? {
        guard let prefetcher else { return nil }
        return prefetcher.image(at: wrappedIndex(requestedIndex), damage: effectiveCorruption)
    }

    /// Applies parameter values from the registry. Called once per frame by the app,
    /// so a MIDI move, a template load and a UI drag all arrive the same way.
    public func applyParameters(from registry: ParamRegistry) {
        if let engaged = registry.value(slot: identifier, code: .wetDry) {
            wetDry = engaged
        }
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

    /// True while the clip is failing to decode and the previous picture is being held.
    /// Exists so the failure is logged as a transition rather than once per frame.
    private var isHoldingLastPicture = false
}

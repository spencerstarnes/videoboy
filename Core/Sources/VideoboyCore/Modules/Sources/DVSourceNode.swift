//
//  DVSourceNode.swift — a DV file as a playable graph source, corruptor inline.
//
//  Purpose : The wedge made playable. Reads a raw DV file, runs the Phase-1 DIF
//            corruptor over the compressed bytes, decodes the result, and hands the
//            graph a texture. The corruption happens between read and decode, which
//            is the entire point (SPEC 5).
//  Inputs  : a .dv file; parameters by param code; a RenderContext per frame.
//  Outputs : an `MTLTexture` at the project size.
//  Connects: DVReader, DIFCorruptor, DVDecoder, MetalContext; the Source A-D panels.
//  Extend  : an MPEG source is a sibling type with the same shape, not a mode here.
//
//  Parameters (SPEC 13):
//    31B corrupt amount   0...1
//    32B corrupt mode     0...1, quantised to a CorruptionMode
//    33B corrupt rate     0...1, quantised to a beat subdivision
//    34B corrupt seed     re-rolled by the scheduler on each subdivision boundary
//    64A playback speed   0...2, where 1.0 is nominal
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
    /// Advance `frames` every `subdivision`, and hold in between.
    case stepped(subdivision: Subdivision, frames: Int)

    /// The step presets offered in the shuttle, from slowest to fastest.
    ///
    /// Spread across subdivision AND step size on purpose: 1 frame per beat and 4
    /// frames per beat are musically different ideas, not the same idea twice.
    public static let presets: [PlaybackTiming] = [
        .stepped(subdivision: .whole, frames: 1),        // one frame per bar
        .stepped(subdivision: .half, frames: 1),         // one frame per two beats
        .stepped(subdivision: .quarter, frames: 1),      // one frame per beat
        .stepped(subdivision: .eighth, frames: 1),       // half time
        .stepped(subdivision: .sixteenth, frames: 1),    // quarter time
        .stepped(subdivision: .quarter, frames: 2),      // double
        .stepped(subdivision: .quarter, frames: 4)       // quad
    ]

    /// Short label for the shuttle's picker.
    public var displayName: String {
        switch self {
        case .continuous:
            return "Live"
        case .stepped(let subdivision, let frames):
            return frames == 1 ? subdivision.rawValue : "\(subdivision.rawValue)×\(frames)"
        }
    }

    /// A sentence for the tooltip, because "1/8×4" needs explaining once.
    public var explanation: String {
        switch self {
        case .continuous:
            return "Normal playback, retimed to the project rate."
        case .stepped(let subdivision, let frames):
            let plural = frames == 1 ? "frame" : "frames"
            return "Advance \(frames) \(plural) every \(subdivision.rawValue) note, holding in between."
        }
    }

    /// Beats between steps, or nil when playback is continuous.
    public var beatsPerStep: Double? {
        switch self {
        case .continuous: nil
        case .stepped(let subdivision, _): subdivision.beats
        }
    }

    /// Frames advanced per step.
    public var framesPerStep: Int {
        switch self {
        case .continuous: 0
        case .stepped(_, let frames): frames
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
public final class DVSourceNode: Node, DataEffectProvider {

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
            Parameter(code: .playbackSpeed, range: 0...2, defaultValue: 1)
        ]
    }

    /// The file being played, or nil when nothing is loaded.
    public private(set) var reader: DVReader?
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
    private var decoder: DVDecoder?
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
    public var frameCount: Int { reader?.frameCount ?? 0 }

    /// DV footage offers the DV data effects; an empty channel offers nothing.
    ///
    /// This is what the source panel's data stack reads to decide whether to appear
    /// at all — and it must say `.none` when nothing is loaded, or an empty channel
    /// would advertise effects it cannot apply.
    public var dataEffectFamily: DataEffectFamily {
        reader == nil ? .none : .dv
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
        do {
            let reader = try DVReader(url: url)
            if decoder == nil { decoder = try DVDecoder() }
            self.reader = reader
            self.mediaURL = url
            self.playheadFrame = 0
            self.isPlayingBackwards = false
            self.textureFrameIndex = -1
            Log.info(.dv, "\(identifier) loaded \(url.lastPathComponent)")
            return true
        } catch {
            Log.error(.dv, "\(identifier) could not load \(url.lastPathComponent): \(error)")
            self.reader = nil
            self.mediaURL = nil
            return false
        }
    }

    /// Steps the playhead if a subdivision boundary has been crossed since the last one.
    ///
    /// Boundary-crossing rather than "is the phase near zero": at slow subdivisions a
    /// phase test would fire for several frames running, and at fast ones it could
    /// miss a boundary entirely between two render frames. Comparing which step
    /// interval we are in does neither.
    func advanceIfBoundaryCrossed(
        totalBeats: Double, subdivision: Subdivision, frames: Int, frameCount: Int
    ) {
        let beatsPerStep = subdivision.beats
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
        let last = Double(frameCount)
        playheadFrame += isPlayingBackwards ? -frames : frames

        switch loopMode {
        case .loop:
            // Wrap at both ends: playing backwards past zero comes round to the end.
            if playheadFrame >= last {
                playheadFrame -= last
            } else if playheadFrame < 0 {
                playheadFrame += last
            }

        case .pingPong:
            // Turn around rather than wrap. The overshoot is reflected back so the
            // motion stays smooth at the turn instead of pausing on the end frame.
            if playheadFrame >= last - 1 {
                playheadFrame = max(last - 1 - (playheadFrame - (last - 1)), 0)
                isPlayingBackwards = true
            } else if playheadFrame <= 0 {
                playheadFrame = -playheadFrame
                isPlayingBackwards = false
            }

        case .oneShot:
            // Stop on the last frame and stay there.
            if playheadFrame >= last - 1 {
                playheadFrame = last - 1
                isPlaying = false
                Log.info(.dv, "\(identifier) reached the end of its clip (one shot)")
            } else if playheadFrame < 0 {
                playheadFrame = 0
                isPlaying = false
            }
        }
    }

    /// Moves the playhead to a 0...1 position (the shuttle scrub).
    public func seek(toNormalised position: Double) {
        guard frameCount > 0 else { return }
        playheadFrame = min(max(position, 0), 1) * Double(frameCount - 1)
    }

    /// Steps the playhead by whole frames (the shuttle's step buttons).
    public func step(by frames: Int) {
        guard let reader else { return }
        playheadFrame = Double(reader.wrappedIndex(Int(playheadFrame.rounded()) + frames))
    }

    /// Re-rolls the corruption seed. Called by the scheduler on a beat boundary, so
    /// the damage changes in time with the music rather than continuously.
    public func rerollCorruptionSeed(using source: UInt64) {
        corruption.seed = source
    }

    // MARK: - Node

    public func render(inputs: [MTLTexture], context renderContext: RenderContext) -> MTLTexture? {
        guard let reader, let decoder, let metal = context else { return texture }

        if isPlaying {
            switch timing {
            case .continuous:
                // Advance at the source's own rate relative to the project rate, so a
                // file is retimed to the clock rather than ad-hoc frame-dropped (SPEC 3).
                let sourceFramesPerProjectFrame =
                    (reader.standard.frameRate / StandardDefinition.frameRate) * playbackSpeed
                advancePlayhead(by: sourceFramesPerProjectFrame, frameCount: reader.frameCount)

            case .stepped(let subdivision, let frames):
                // Hold the frame, and jump only when a subdivision boundary is
                // crossed. With the transport stopped there are no boundaries, so a
                // stepped clip simply holds — which is right: its timing comes from
                // the music, and there is no music.
                if let position = renderContext.musicalPosition {
                    advanceIfBoundaryCrossed(
                        totalBeats: position.totalBeats,
                        subdivision: subdivision,
                        frames: frames,
                        frameCount: reader.frameCount
                    )
                }
            }
        }

        let frameIndex = reader.wrappedIndex(Int(playheadFrame))

        // Re-decode only when the frame or the damage has actually changed. With the
        // transport stopped and no corruption this makes the preview free.
        if frameIndex == textureFrameIndex && corruption == textureCorruption, texture != nil {
            return texture
        }

        guard let cleanBytes = reader.frame(at: frameIndex) else { return texture }
        let previousBytes = reader.frame(at: reader.wrappedIndex(frameIndex - 1))

        // THE WEDGE: damage the compressed bytes, then decode them. Never the other
        // way round — decoding first and damaging pixels would be an ordinary effect.
        let bytes = DIFCorruptor.corrupt(
            frame: cleanBytes,
            settings: corruption,
            standard: reader.standard,
            previousFrame: previousBytes
        )

        guard let image = decoder.decode(frameBytes: bytes) else {
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
        guard let reader, let decoder else { return nil }
        let frameIndex = reader.wrappedIndex(requestedIndex)
        guard let cleanBytes = reader.frame(at: frameIndex) else { return nil }
        let previousBytes = reader.frame(at: reader.wrappedIndex(frameIndex - 1))
        let bytes = DIFCorruptor.corrupt(
            frame: cleanBytes, settings: corruption,
            standard: reader.standard, previousFrame: previousBytes
        )
        return decoder.decode(frameBytes: bytes)
    }

    /// Applies parameter values from the registry. Called once per frame by the app,
    /// so a MIDI move, a template load and a UI drag all arrive the same way.
    public func applyParameters(from registry: ParamRegistry) {
        if let amount = registry.value(slot: identifier, code: .corruptAmount) {
            corruption.amount = amount
        }
        if let mode = registry.value(slot: identifier, code: .corruptMode) {
            corruption.mode = CorruptionMode.from(normalised: mode)
        }
        if let speed = registry.value(slot: identifier, code: .playbackSpeed) {
            playbackSpeed = speed
        }
        if let seed = registry.value(slot: identifier, code: .corruptSeed) {
            corruption.seed = UInt64(max(0, seed))
        }
    }
}

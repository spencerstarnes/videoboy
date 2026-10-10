//
//  RecordingClock.swift — where a recorded frame or audio sample goes on a take's timeline.
//
//  Purpose : A recording has two streams arriving on two clocks: pictures from the
//            render loop (29.97, one per content frame) and samples from whatever the
//            beat tracker is listening to (its own device clock, its own buffer
//            sizes, gaps when the source is switched). Played back, they have to
//            line up. These two rules decide where each piece is written so they do.
//  Inputs  : host times (seconds, CACurrentMediaTime's clock) — a frame's
//            presentation time, an audio buffer's first-sample time.
//  Outputs : a frame index, or how much of an audio buffer to keep and how much
//            silence to put before it.
//  Connects: RecordingSession and TakeAudio in the app, which own the writers.
//  Extend  : keep the rules here and the AVFoundation plumbing in the app. These are
//            the fragile bones of a recording: they are what goes silently wrong.
//
//  Why it matters: AVAssetWriter does NOT keep a gap in an audio track. Hand it
//  samples stamped 5 s and then 6 s with nothing between, and it butts them together
//  — everything after plays a second early, forever. Measured 2026-10-10 with LPCM
//  and AAC. So the audio is made continuous here, explicitly: silence where nothing
//  arrived, trimmed where two buffers overlap.
//

import Foundation

/// Puts recorded pictures on a steady frame grid without letting them drift from real time.
///
/// Counting frames alone drifts: a frame the writer was too busy to take, or a stall
/// the engine skipped past, shortens the picture and the sound slides out of sync.
/// Timing every frame from its presentation time alone stutters: the render loop
/// lands on display refreshes, so presentation times wobble by up to a refresh and
/// rounding them repeats one frame and skips the next. So: count, and only jump when
/// the count has fallen clearly behind the clock.
public struct RecordedFrameClock {

    /// Seconds per frame.
    public let frameDuration: Double
    /// How far the count may disagree with the clock, in frames, before it is
    /// corrected. Wider than a refresh's wobble (half a frame at 60 Hz), narrower
    /// than two frames, so a single lost frame is always noticed.
    public static let slackFrames = 1.5

    /// Presentation time of frame 0. Nil until the first frame.
    public private(set) var origin: Double?
    /// The index given to the last frame.
    public private(set) var lastIndex = -1

    public init(frameRate: Double = StandardDefinition.frameRate) {
        frameDuration = 1 / frameRate
    }

    /// The take's length in frames, counting any held across a gap.
    public var frameCount: Int { lastIndex + 1 }

    /// The index for a frame shown at `presentationTime`, or nil when it should not
    /// be written because the recording is already ahead of the clock.
    public mutating func index(forPresentationTime presentationTime: Double) -> Int? {
        guard let origin else {
            origin = presentationTime
            lastIndex = 0
            return 0
        }
        let next = lastIndex + 1
        let ideal = (presentationTime - origin) / frameDuration
        let index: Int
        if ideal - Double(next) > Self.slackFrames {
            // Frames were lost. Leave a gap — the player holds the previous picture
            // across it — so everything after still lines up with the sound.
            index = Int(ideal.rounded())
        } else if Double(next) - ideal > Self.slackFrames {
            // Ahead of the clock; writing this would put the picture early.
            return nil
        } else {
            index = next
        }
        lastIndex = index
        return index
    }
}

/// Keeps a recording's audio continuous and in step with its picture.
///
/// The track is one unbroken run of samples starting at the first one that arrived.
/// Each incoming buffer says when it was captured; this compares that with how much
/// has been written and decides what to do.
public struct RecordedAudioClock {

    /// What to do with one incoming buffer.
    public struct Placement: Equatable {
        /// Samples of silence to write before it, filling a gap.
        public var silenceBefore: Int
        /// Samples to drop from its start, because they overlap what is written.
        public var dropLeading: Int
        /// Where its first written sample lands, in samples from the take's start.
        public var startSample: Int64

        public init(silenceBefore: Int, dropLeading: Int, startSample: Int64) {
            self.silenceBefore = silenceBefore
            self.dropLeading = dropLeading
            self.startSample = startSample
        }
    }

    /// The track's rate. Everything is converted to it before it gets here.
    public let sampleRate: Double
    /// How far a buffer may disagree with the written position before it is moved.
    ///
    /// Small disagreements are timestamp noise and the slow drift between the audio
    /// device's clock and the host's; correcting each one would click constantly.
    /// 20 ms is under the ~45 ms where late sound starts to look wrong against
    /// picture, and at a typical 20 ppm drift it means a correction every ~15 min.
    public let toleranceSamples: Int
    /// How long nothing may arrive before silence is written to cover it. Longer than
    /// any audio buffer, so a slow source is not mistaken for a stopped one.
    public let stallSeconds: Double

    /// Samples written so far, including silence: the position the next one goes at.
    public private(set) var writtenSamples: Int64 = 0
    /// Whether any real audio has arrived. Before that nothing is written at all, so
    /// a take recorded with no audio source has no audio track rather than a silent one.
    public private(set) var hasStarted = false

    public init(sampleRate: Double, toleranceSeconds: Double = 0.020, stallSeconds: Double = 0.25) {
        self.sampleRate = sampleRate
        toleranceSamples = Int((toleranceSeconds * sampleRate).rounded())
        self.stallSeconds = stallSeconds
    }

    /// Where a buffer of `count` samples goes, given its first sample was captured
    /// `offset` seconds after the take's first frame. Nil when all of it is too early.
    public mutating func place(count: Int, atOffset offset: Double) -> Placement? {
        let target = Int64((offset * sampleRate).rounded())

        guard hasStarted else {
            // The first buffer goes exactly where it belongs. The writer keeps a
            // LEADING gap (it is only gaps in the middle it closes up), so no
            // silence is needed in front of it — which matters when the audio is
            // switched on twenty minutes into a take.
            let drop = target < 0 ? Int(min(-target, Int64(count))) : 0
            guard drop < count else { return nil }
            let start = max(target, 0)
            hasStarted = true
            writtenSamples = start + Int64(count - drop)
            return Placement(silenceBefore: 0, dropLeading: drop, startSample: start)
        }

        let drift = target - writtenSamples
        var placement = Placement(silenceBefore: 0, dropLeading: 0, startSample: writtenSamples)
        if drift > Int64(toleranceSamples) {
            placement.silenceBefore = Int(drift)
        } else if drift < -Int64(toleranceSamples) {
            placement.dropLeading = Int(min(-drift, Int64(count)))
            guard placement.dropLeading < count else { return nil }
        }
        writtenSamples += Int64(placement.silenceBefore + count - placement.dropLeading)
        return placement
    }

    /// Silence to write now so the track does not fall behind while nothing arrives,
    /// given the take is `offset` seconds old. Zero while audio is flowing.
    ///
    /// Without this, a source switched off mid-take and on again later would leave
    /// one huge gap to fill in a single burst. Filled as it happens, it is a quarter
    /// second at a time and the track stays in step.
    public mutating func silenceToCatchUp(atOffset offset: Double) -> Int {
        guard hasStarted else { return 0 }
        // Stay `stallSeconds` behind the clock, so audio that is merely late still
        // lands on samples nobody has written yet.
        let target = Int64(((offset - stallSeconds) * sampleRate).rounded())
        guard target > writtenSamples else { return 0 }
        let silence = Int(target - writtenSamples)
        writtenSamples = target
        return silence
    }
}

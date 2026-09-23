//
//  MoshEngine.swift — the datamosh itself: which coded frames reach the decoder.
//
//  Purpose : Datamoshing is a disagreement between an encoder and a decoder about
//            what the previous picture was. The encoder describes each new frame as
//            "the last one, with these blocks moved and these corrections". If the
//            decoder is holding a DIFFERENT last picture, it moves THAT picture's
//            blocks instead — the old image smeared along the new image's motion.
//            This engine creates the disagreement, by choosing which frames the
//            decoder gets:
//
//              MOSH   drops keyframes and the intra-heavy frames at a cut, so a new
//                     scene's motion is painted onto the old scene. Higher amounts
//                     also drop ordinary P-frames now and then, so the error builds
//                     and the picture melts even without a cut.
//              BLOOM  replays the last few P-frames in a loop, so the same motion is
//                     applied again and again and the picture streams outward.
//              HEAL   lets one clean keyframe through, resetting the picture.
//
//            These are the two classic moves (I-frame removal, P-frame duplication),
//            done live on real H.264 rather than simulated with optical flow.
//  Inputs  : access units from H264LiveEncoder, in encode order, and `MoshControls`.
//  Outputs : the access units to decode, renumbered so the decoder sees one unbroken
//            stream (H264Syntax).
//  Connects: DatamoshNode (drives it on its pipeline queue), H264MoshDecoder.
//  Extend  : a new move is a branch in `process` plus a field on `MoshControls`.
//
//  Pure logic, no codecs: every rule is unit-tested on hand-built streams.
//  Deterministic given a seed, like the DV corruptor, so a performance repeats.
//

import Foundation

/// What the performer is asking for, read once per frame.
public struct MoshControls: Equatable, Sendable {
    /// 0 is clean. Above 0, keyframes and cut frames are dropped; towards 1 the
    /// threshold for "a cut" falls and random P-frames are dropped as well.
    public var mosh: Double = 0
    /// 0 is off. Above 0, the last `bloomLength` P-frames are replayed in a loop.
    public var bloomLength: Int = 0
    /// Let the next keyframe through (the node asks the encoder for one).
    public var heal = false

    public init(mosh: Double = 0, bloomLength: Int = 0, heal: Bool = false) {
        self.mosh = mosh
        self.bloomLength = bloomLength
        self.heal = heal
    }

    /// Nothing is being done to the stream.
    public var isNeutral: Bool { mosh <= 0 && bloomLength <= 0 }

    /// Bloom's fader (0...1) as a loop length: off at 0, then 1...8 frames.
    public static func bloomLength(fromNormalised value: Double) -> Int {
        guard value > 0.001 else { return 0 }
        return 1 + Int((min(value, 1) * 7).rounded())
    }
}

/// Counters for the debug overlay and the self-QA evidence.
public struct MoshStatistics: Equatable, Sendable {
    public var received = 0
    public var emitted = 0
    public var droppedKeyframes = 0
    public var droppedCuts = 0
    public var droppedRandom = 0
    public var bloomed = 0
    public var passedUnchanged = 0

    public init() {}
}

/// Chooses and renumbers the frames a decoder sees.
public final class MoshEngine {

    public private(set) var statistics = MoshStatistics()

    private var sps: [UInt32: H264SPS] = [:]
    private var pps: [UInt32: H264PPS] = [:]
    /// The raw parameter-set NALs, re-sent ahead of the first picture and whenever
    /// the encoder changes them.
    private var parameterSetNALs: [UInt32: [UInt8]] = [:]
    private var ppsNALs: [UInt32: [UInt8]] = [:]
    private var parameterSetsDirty = true

    /// Whether the decoder has been given a keyframe to start from.
    public private(set) var started = false
    /// `frame_num` the next reference picture will carry.
    private var nextFrameNum: UInt32 = 0
    /// Pictures emitted since the last IDR, for the POC.
    private var picturesSinceIDR: UInt32 = 0

    /// Recent coded sizes of ordinary P-frames, for spotting a cut.
    private var recentSizes: [Int] = []
    private let sizeWindow = 30
    /// The last P-frames that were emitted, newest last, for bloom.
    private var recentPFrames: [H264AccessUnit] = []
    private let bloomCapacity = 8
    /// The loop bloom is playing, and where in it.
    private var bloomLoop: [H264AccessUnit] = []
    private var bloomIndex = 0

    private var random: SeededRandom

    public init(seed: UInt64 = 1) {
        random = SeededRandom(seed: seed)
    }

    /// Forgets everything, as if newly created. The next keyframe starts again.
    public func reset() {
        sps = [:]; pps = [:]; parameterSetNALs = [:]; ppsNALs = [:]
        parameterSetsDirty = true
        started = false
        nextFrameNum = 0
        picturesSinceIDR = 0
        recentSizes = []
        recentPFrames = []
        bloomLoop = []
        bloomIndex = 0
        statistics = MoshStatistics()
    }

    /// Takes one encoded picture and returns what the decoder should receive for it:
    /// usually one access unit, none when the frame is dropped, and always renumbered.
    public func process(_ unit: H264AccessUnit, controls: MoshControls) -> [H264AccessUnit] {
        statistics.received += 1
        let slices = absorbParameterSets(unit)
        guard !slices.nalUnits.isEmpty else { return [] }

        // The decoder cannot start from a P-frame: nothing to predict from.
        guard started else {
            guard slices.isKeyframe else { return [] }
            started = true
            return emit(slices)
        }

        // A requested heal: the keyframe is let through whatever else is asked.
        if slices.isKeyframe && controls.heal {
            bloomLoop = []
            return emit(slices)
        }

        let size = slices.sliceBytes
        let typical = medianSize()
        if !slices.isKeyframe { remember(size: size) }

        // BLOOM outranks MOSH: the live frame is discarded and the loop plays instead.
        if controls.bloomLength > 0, !recentPFrames.isEmpty {
            if bloomLoop.isEmpty || bloomLoop.count != min(controls.bloomLength, recentPFrames.count) {
                bloomLoop = Array(recentPFrames.suffix(controls.bloomLength))
                bloomIndex = 0
            }
            let replay = bloomLoop[bloomIndex % bloomLoop.count]
            bloomIndex += 1
            statistics.bloomed += 1
            return emit(replay, rememberAsP: false)
        }
        bloomLoop = []

        if controls.mosh > 0 {
            if slices.isKeyframe {
                statistics.droppedKeyframes += 1
                return []
            }
            // A frame several times the size of a typical one is mostly new picture:
            // a cut, or a big change. Dropping it is what makes the new scene's motion
            // land on the old scene. The multiple falls from 6x to 1.5x as mosh rises.
            let multiple = 6.0 - 4.5 * min(controls.mosh, 1)
            if let typical, Double(size) > Double(typical) * multiple {
                statistics.droppedCuts += 1
                return []
            }
            // Past halfway, ordinary P-frames are dropped too, so errors pile up even
            // on continuous footage. Squared, so the top of the fader is where it bites.
            let dropChance = max(0, controls.mosh - 0.5) * 2
            if random.nextUnitValue() < dropChance * dropChance * 0.35 {
                statistics.droppedRandom += 1
                return []
            }
        } else {
            statistics.passedUnchanged += 1
        }
        return emit(slices)
    }

    // MARK: - Internals

    /// Pulls SPS/PPS out of the unit into the engine's own store, returning the rest
    /// with SEI and delimiters removed (a recovery-point SEI in the wrong place would
    /// tell the decoder to wait for a picture it is never going to get).
    private func absorbParameterSets(_ unit: H264AccessUnit) -> H264AccessUnit {
        var kept: [[UInt8]] = []
        for nal in unit.nalUnits {
            guard let header = nal.first else { continue }
            switch H264NALType(header: header) {
            case .sps:
                do {
                    let parsed = try H264SPS.parse(nal)
                    if parameterSetNALs[parsed.id] != nal {
                        parameterSetNALs[parsed.id] = nal
                        sps[parsed.id] = parsed
                        parameterSetsDirty = true
                    }
                } catch {
                    Log.warn(.mosh, "unreadable SPS: \(error)")
                }
            case .pps:
                do {
                    let parsed = try H264PPS.parse(nal)
                    if ppsNALs[parsed.id] != nal {
                        ppsNALs[parsed.id] = nal
                        pps[parsed.id] = parsed
                        parameterSetsDirty = true
                    }
                } catch {
                    Log.warn(.mosh, "unreadable PPS: \(error)")
                }
            case .nonIDRSlice, .idrSlice:
                kept.append(nal)
            case .sei, .accessUnitDelimiter, .other:
                continue
            }
        }
        return H264AccessUnit(nalUnits: kept, isKeyframe: unit.isKeyframe)
    }

    /// Renumbers a picture to follow the last one emitted and hands it on.
    private func emit(_ unit: H264AccessUnit, rememberAsP: Bool = true) -> [H264AccessUnit] {
        var output: [[UInt8]] = []
        if parameterSetsDirty {
            output += parameterSetNALs.keys.sorted().compactMap { parameterSetNALs[$0] }
            output += ppsNALs.keys.sorted().compactMap { ppsNALs[$0] }
            parameterSetsDirty = false
        }

        let isIDR = unit.nalUnits.contains { H264NALType(header: $0.first ?? 0) == .idrSlice }
        if isIDR {
            nextFrameNum = 0
            picturesSinceIDR = 0
        }
        var isReference = false
        for nal in unit.nalUnits {
            do {
                let (header, rbsp) = try H264SliceHeader.parse(nal, sps: sps, pps: pps)
                isReference = isReference || header.referenceIDC > 0
                output.append(header.renumbered(
                    rbsp: rbsp, headerByte: nal[0],
                    frameNum: nextFrameNum, pocLSB: picturesSinceIDR * 2))
            } catch {
                // Unrenumberable: send it as it came. The decoder may complain, and
                // libav's concealment is what a mosh looks like anyway.
                Log.warn(.mosh, "slice passed through unrenumbered: \(error)")
                output.append(nal)
            }
        }
        if isReference { nextFrameNum &+= 1 }
        picturesSinceIDR &+= 1

        if rememberAsP && !isIDR {
            recentPFrames.append(unit)
            if recentPFrames.count > bloomCapacity { recentPFrames.removeFirst() }
        }
        statistics.emitted += 1
        return [H264AccessUnit(nalUnits: output, isKeyframe: isIDR)]
    }

    private func remember(size: Int) {
        recentSizes.append(size)
        if recentSizes.count > sizeWindow { recentSizes.removeFirst() }
    }

    /// Median coded size of recent P-frames, or nil until there are enough to judge.
    private func medianSize() -> Int? {
        guard recentSizes.count >= 5 else { return nil }
        let sorted = recentSizes.sorted()
        return sorted[sorted.count / 2]
    }
}

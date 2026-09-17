//
//  DIFCorruptor.swift — the wedge: musical damage to DV bytes before they decode.
//
//  Purpose : This is the competitive core of the app. Every transform here operates
//            on the *compressed* DV bitstream, before libav ever sees it, so the
//            decoder itself produces the artefacts. That is what makes the result
//            look like real tape damage rather than a shader imitating it.
//  Inputs  : one DV frame's bytes, a `CorruptionSettings`, and a seed.
//  Outputs : a new byte array of exactly the same length, still structurally a valid
//            DV frame, with picture data damaged.
//  Connects: DVSource (which applies it between demux and decode), the FX panel
//            (which exposes its parameters by param code), the scheduler (which
//            re-rolls the seed on a beat).
//  Extend  : add a case to `CorruptionMode` and a matching `private static func`.
//            Every transform must be pure, length-preserving, and deterministic.
//
//  Two invariants hold for every transform, and the tests enforce both:
//    1. Length is preserved. A DV frame is a fixed size; changing it would desync
//       every frame after it.
//    2. Only video DIF blocks are touched by default. Damaging header, subcode or
//       VAUX blocks makes decoders reject the frame outright, which produces a
//       dropout instead of an artefact.
//

import Foundation

/// Which damage to apply.
public enum CorruptionMode: String, CaseIterable, Codable, Sendable {
    /// Replace video blocks' payloads with those of other blocks in the same frame.
    /// Reads as blocks of picture landing in the wrong place.
    case shuffleBlocks
    /// Copy one video block's payload over its neighbours. Reads as smearing.
    case duplicateBlocks
    /// Zero a video block's DCT coefficients, leaving its header intact. The decoder
    /// renders flat blocks — classic DV dropout.
    case dropBlocks
    /// Flip individual bits inside DCT coefficient data. The decoder mis-reads
    /// coefficient runs and produces streaks and colour tearing.
    case flipCoefficients
    /// Replace a whole DIF sequence's video blocks with another sequence's, which
    /// displaces a horizontal band of the picture.
    case swapSequences
    /// Hold the previous frame's video blocks in place of this frame's. Reads as a
    /// stutter that still carries this frame's motion vectors.
    case holdSequences

    /// Position in the mode list, so a 0...1 parameter can select a mode.
    public var normalisedPosition: Double {
        let all = CorruptionMode.allCases
        guard let index = all.firstIndex(of: self), all.count > 1 else { return 0 }
        return Double(index) / Double(all.count - 1)
    }

    /// Selects a mode from a 0...1 parameter value (param code `32B`).
    public static func from(normalised value: Double) -> CorruptionMode {
        let all = allCases
        return all[NormalisedSweep.index(value, count: all.count)]
    }
}

/// How much damage, of which kind.
public struct CorruptionSettings: Equatable, Codable, Sendable {
    /// Which transform to apply.
    public var mode: CorruptionMode
    /// 0 is untouched, 1 is maximum damage. Maps to the fraction of eligible blocks
    /// affected (param code `31B`).
    public var amount: Double
    /// Reproducibility (param code `34B`). Re-rolled on a beat by the scheduler.
    public var seed: UInt64

    /// Where the mode fader sits, 0...1, independent of any one family's mode list.
    ///
    /// `mode` is the DV reading of this number. MPEG has three modes where DV has
    /// six, so a decoder for another family reads the POSITION and picks its own —
    /// which is why the position is carried rather than recomputed from the DV enum,
    /// where six-into-three would quantise twice and lose the ends.
    public var modePosition: Double

    public init(
        mode: CorruptionMode = .dropBlocks, amount: Double = 0, seed: UInt64 = 1,
        modePosition: Double? = nil
    ) {
        self.mode = mode
        self.amount = amount
        self.seed = seed
        self.modePosition = modePosition ?? mode.normalisedPosition
    }

    /// Settings that do nothing, used as the default and as the "dry" end of a mix.
    public static let inert = CorruptionSettings(mode: .dropBlocks, amount: 0, seed: 1)

    /// This damage as the MPEG family reads it.
    public var asMPEG: MPEGCorruptionSettings {
        MPEGCorruptionSettings(
            amount: amount,
            mode: MPEGCorruptionMode.from(normalised: modePosition),
            seed: seed
        )
    }
}

/// Applies bitstream damage to DV frames.
public enum DIFCorruptor {

    /// Corrupts one DV frame.
    ///
    /// - Parameters:
    ///   - frame: the raw DV frame. Must be exactly `standard.frameBytes` long.
    ///   - settings: what damage to do.
    ///   - standard: NTSC or PAL, which fixes the DIF layout.
    ///   - previousFrame: the frame before this one, needed only by `.holdSequences`.
    /// - Returns: a new frame of the same length. Returns the input unchanged when
    ///   `amount` is zero or the frame is the wrong size — a malformed frame is
    ///   logged and passed through rather than dropped, so playback never stops.
    public static func corrupt(
        frame: [UInt8],
        settings: CorruptionSettings,
        standard: DVStandard = .ntsc,
        previousFrame: [UInt8]? = nil
    ) -> [UInt8] {
        guard settings.amount > 0 else { return frame }
        guard frame.count == standard.frameBytes else {
            Log.warn(.bitstream, "frame is \(frame.count) bytes, expected \(standard.frameBytes) for \(standard.rawValue); passing through untouched")
            return frame
        }

        var random = SeededRandom(seed: settings.seed)
        let amount = min(max(settings.amount, 0), 1)

        switch settings.mode {
        case .shuffleBlocks:
            return shuffleBlocks(frame, amount: amount, standard: standard, random: &random)
        case .duplicateBlocks:
            return duplicateBlocks(frame, amount: amount, standard: standard, random: &random)
        case .dropBlocks:
            return dropBlocks(frame, amount: amount, standard: standard, random: &random)
        case .flipCoefficients:
            return flipCoefficients(frame, amount: amount, standard: standard, random: &random)
        case .swapSequences:
            return swapSequences(frame, amount: amount, standard: standard, random: &random)
        case .holdSequences:
            return holdSequences(frame, previousFrame: previousFrame, amount: amount,
                                 standard: standard, random: &random)
        }
    }

    // MARK: - Transforms
    //
    // Each takes the frame, returns a frame of identical length, and touches only
    // video DIF block payloads.

    /// Copies payloads between randomly chosen video blocks.
    private static func shuffleBlocks(
        _ frame: [UInt8], amount: Double, standard: DVStandard, random: inout SeededRandom
    ) -> [UInt8] {
        var output = frame
        let offsets = DVFormat.videoBlockOffsets(standard: standard)
        let count = affectedCount(of: offsets.count, amount: amount)
        for _ in 0..<count {
            let source = offsets[random.next(below: offsets.count)]
            let destination = offsets[random.next(below: offsets.count)]
            copyPayload(from: frame, at: source, to: &output, at: destination)
        }
        return output
    }

    /// Copies one block's payload over the blocks that follow it.
    private static func duplicateBlocks(
        _ frame: [UInt8], amount: Double, standard: DVStandard, random: inout SeededRandom
    ) -> [UInt8] {
        var output = frame
        let offsets = DVFormat.videoBlockOffsets(standard: standard)
        let count = affectedCount(of: offsets.count, amount: amount)
        // A run length of up to eight blocks reads as a visible smear without
        // wiping out the whole picture.
        let maximumRunLength = 8
        var index = 0
        while index < count {
            let start = random.next(below: offsets.count)
            let runLength = 1 + random.next(below: maximumRunLength)
            let sourceOffset = offsets[start]
            for step in 1..<runLength where start + step < offsets.count {
                copyPayload(from: frame, at: sourceOffset, to: &output, at: offsets[start + step])
            }
            index += runLength
        }
        return output
    }

    /// Zeroes DCT coefficient data, leaving each block's 3-byte header intact.
    private static func dropBlocks(
        _ frame: [UInt8], amount: Double, standard: DVStandard, random: inout SeededRandom
    ) -> [UInt8] {
        var output = frame
        let offsets = DVFormat.videoBlockOffsets(standard: standard)
        let count = affectedCount(of: offsets.count, amount: amount)
        for _ in 0..<count {
            let offset = offsets[random.next(below: offsets.count)]
            let payloadStart = offset + DVFormat.blockHeaderBytes
            let payloadEnd = offset + DVFormat.blockBytes
            for byte in payloadStart..<payloadEnd { output[byte] = 0 }
        }
        return output
    }

    /// Flips individual bits within coefficient data.
    private static func flipCoefficients(
        _ frame: [UInt8], amount: Double, standard: DVStandard, random: inout SeededRandom
    ) -> [UInt8] {
        var output = frame
        let offsets = DVFormat.videoBlockOffsets(standard: standard)
        let payloadBytes = DVFormat.blockBytes - DVFormat.blockHeaderBytes
        // Bit flips are far more disruptive per-byte than zeroing, because a flipped
        // bit desynchronises the variable-length coefficient decoder for the rest of
        // the block. Scaling down keeps the low end of the amount range usable.
        let flipsPerBlock = 4
        let count = affectedCount(of: offsets.count, amount: amount * 0.5)
        for _ in 0..<count {
            let offset = offsets[random.next(below: offsets.count)]
            for _ in 0..<flipsPerBlock {
                let byte = offset + DVFormat.blockHeaderBytes + random.next(below: payloadBytes)
                let bit = UInt8(1) << UInt8(random.next(below: 8))
                output[byte] ^= bit
            }
        }
        return output
    }

    /// Replaces one DIF sequence's video blocks with another's.
    private static func swapSequences(
        _ frame: [UInt8], amount: Double, standard: DVStandard, random: inout SeededRandom
    ) -> [UInt8] {
        var output = frame
        let sequenceCount = standard.sequencesPerFrame
        let swapCount = max(1, affectedCount(of: sequenceCount, amount: amount))
        let perSequence = DVFormat.videoBlocksPerSequence
        let allOffsets = DVFormat.videoBlockOffsets(standard: standard)

        for _ in 0..<swapCount {
            let source = random.next(below: sequenceCount)
            let destination = random.next(below: sequenceCount)
            guard source != destination else { continue }
            for block in 0..<perSequence {
                let sourceOffset = allOffsets[source * perSequence + block]
                let destinationOffset = allOffsets[destination * perSequence + block]
                copyPayload(from: frame, at: sourceOffset, to: &output, at: destinationOffset)
            }
        }
        return output
    }

    /// Substitutes the previous frame's video blocks for this frame's.
    ///
    /// With no previous frame there is nothing to hold, so the frame passes through —
    /// which is exactly right for the first frame of a clip.
    private static func holdSequences(
        _ frame: [UInt8], previousFrame: [UInt8]?, amount: Double,
        standard: DVStandard, random: inout SeededRandom
    ) -> [UInt8] {
        guard let previousFrame, previousFrame.count == frame.count else { return frame }
        var output = frame
        let sequenceCount = standard.sequencesPerFrame
        let perSequence = DVFormat.videoBlocksPerSequence
        let allOffsets = DVFormat.videoBlockOffsets(standard: standard)
        let heldCount = max(1, affectedCount(of: sequenceCount, amount: amount))

        for _ in 0..<heldCount {
            let sequence = random.next(below: sequenceCount)
            for block in 0..<perSequence {
                let offset = allOffsets[sequence * perSequence + block]
                copyPayload(from: previousFrame, at: offset, to: &output, at: offset)
            }
        }
        return output
    }

    // MARK: - Helpers

    /// How many items an `amount` of 0...1 affects, out of `total`.
    ///
    /// Deliberately not linear across the whole range: at amount 1.0 every eligible
    /// block is hit, which is total destruction, and a linear ramp would make the
    /// useful part of the range a sliver at the bottom. Squaring puts the musically
    /// interesting territory in the middle of the fader's travel.
    private static func affectedCount(of total: Int, amount: Double) -> Int {
        Int((Double(total) * amount * amount).rounded())
    }

    /// Copies one DIF block's payload, leaving the destination's 3-byte header alone.
    ///
    /// Keeping the destination header is what preserves frame structure: the header
    /// says which macroblock this data belongs to, so the decoder still knows where
    /// to put it — it just gets the wrong picture for that position.
    private static func copyPayload(
        from source: [UInt8], at sourceOffset: Int,
        to destination: inout [UInt8], at destinationOffset: Int
    ) {
        let payloadStart = DVFormat.blockHeaderBytes
        let payloadEnd = DVFormat.blockBytes
        for byte in payloadStart..<payloadEnd {
            destination[destinationOffset + byte] = source[sourceOffset + byte]
        }
    }
}

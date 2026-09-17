//
//  MPEGCorruptor.swift — the other half of the wedge (SPEC 5).
//
//  Purpose : DV damage is spatial — blocks land in the wrong place, coefficients
//            tear. MPEG damage is TEMPORAL, which is what makes it worth having as
//            well rather than instead: every DV frame is whole, so DV has no notion
//            of a picture that depends on another one, and these three effects all
//            live in that dependency. What each actually does is described on its own
//            case below, because they are genuinely different and lumping them
//            together as "datamoshing" would promise one look for all three.
//  Inputs  : MPEG-2 elementary-stream bytes, plus settings and a seed.
//  Outputs : the same bytes, damaged, still decodable.
//  Connects: MPEGFormat (which finds the boundaries), MPEGClipDecoder, the data
//            effect panels.
//  Extend  : a new mode is a case on `MPEGCorruptionMode` plus a branch here. Every
//            transform must leave the stream DECODABLE — the point is a picture that
//            is wrong, not an error.
//
//  Deterministic given a seed, exactly as the DV corruptor is, so the same beat
//  produces the same damage twice and a performance can be repeated.
//

import Foundation

/// What kind of temporal damage to apply.
public enum MPEGCorruptionMode: String, CaseIterable, Codable, Sendable {
    /// Remove predicted pictures, keeping the intra ones.
    ///
    /// The clip keeps its picture quality and loses its time: motion jumps forward in
    /// lumps, because the frames that carried the small movements are gone and only
    /// the whole pictures remain. A stutter that skips rather than repeats.
    case frameDrop
    /// Scramble bytes inside slice data.
    ///
    /// What the decoder makes of it is up to the decoder: libavcodec conceals errors
    /// aggressively, so in practice it resynchronises at the next slice and the GOP
    /// decodes to a valid picture that is not the right one. Measured at 0.56 of the
    /// frame changed on the test fixture. See the note at the foot of this file about
    /// the blockier look and what it would take.
    case motionVector
    /// Repeat the previous picture's bytes in place of this one, so the movements of
    /// an earlier moment are applied to whatever is on screen now.
    case referenceHold

    public var displayName: String {
        switch self {
        case .frameDrop: "Frame Drop"
        case .motionVector: "Motion Vector Corrupt"
        case .referenceHold: "Reference Hold"
        }
    }

    /// Position in the list, so a 0...1 parameter can select a mode.
    public var normalisedPosition: Double {
        let all = MPEGCorruptionMode.allCases
        guard let index = all.firstIndex(of: self), all.count > 1 else { return 0 }
        return Double(index) / Double(all.count - 1)
    }

    /// Which mode a 0...1 parameter selects.
    public static func from(normalised value: Double) -> MPEGCorruptionMode {
        let all = allCases
        return all[NormalisedSweep.index(value, count: all.count)]
    }
}

/// How much damage, of which kind, with which seed.
public struct MPEGCorruptionSettings: Equatable, Sendable {
    public var amount: Double
    public var mode: MPEGCorruptionMode
    public var seed: UInt64

    public init(amount: Double = 0, mode: MPEGCorruptionMode = .frameDrop, seed: UInt64 = 1) {
        self.amount = amount
        self.mode = mode
        self.seed = seed
    }

    /// Does nothing at all.
    public static let inert = MPEGCorruptionSettings(amount: 0)
}

/// Damages MPEG-2 bitstreams before they are decoded.
public enum MPEGCorruptor {

    /// Applies damage to one buffer of elementary stream.
    ///
    /// - Parameters:
    ///   - bytes: a decodable MPEG-2 elementary stream, usually one GOP.
    ///   - settings: what to do and how much of it.
    ///   - previousPicture: the bytes of the last picture, for `referenceHold`.
    /// - Returns: the damaged stream. Unlike the DV corruptor this is NOT
    ///   length-preserving — dropping a picture means removing its bytes, and an
    ///   MPEG stream is self-delimiting so its length is free to change. That is the
    ///   whole difference between the two families.
    public static func corrupt(
        stream bytes: [UInt8],
        settings: MPEGCorruptionSettings,
        previousPicture: [UInt8]? = nil
    ) -> [UInt8] {
        guard settings.amount > 0, !bytes.isEmpty else { return bytes }

        let pictures = MPEGFormat.pictures(in: bytes)
        guard !pictures.isEmpty else { return bytes }

        var random = SeededRandom(seed: settings.seed)

        switch settings.mode {
        case .frameDrop:
            return dropPictures(bytes, pictures: pictures,
                                amount: settings.amount, random: &random)
        case .motionVector:
            return scrambleSlices(bytes, pictures: pictures,
                                  amount: settings.amount, random: &random)
        case .referenceHold:
            return holdReference(bytes, pictures: pictures, previous: previousPicture,
                                 amount: settings.amount, random: &random)
        }
    }

    /// The last coded picture in a stream, kept to feed `referenceHold` next time.
    public static func lastPicture(in bytes: [UInt8]) -> [UInt8]? {
        guard let last = MPEGFormat.pictures(in: bytes).last else { return nil }
        return Array(bytes[last.start..<last.end])
    }

    // MARK: - Modes

    /// Removes predicted pictures, leaving intra pictures alone.
    ///
    /// Intra pictures are spared deliberately: they are what the decoder recovers on,
    /// and dropping them gives a stream that never resynchronises — a picture that
    /// stays broken rather than one that breaks and heals, which is not a performable
    /// effect but a fault.
    private static func dropPictures(
        _ bytes: [UInt8], pictures: [MPEGPicture],
        amount: Double, random: inout SeededRandom
    ) -> [UInt8] {
        let droppable = pictures.filter { $0.type == .predicted || $0.type == .bidirectional }
        guard !droppable.isEmpty else { return bytes }

        var dropped: Set<Int> = []
        for picture in droppable where random.nextUnitValue() < amount {
            dropped.insert(picture.start)
        }
        guard !dropped.isEmpty else { return bytes }

        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var cursor = 0
        for picture in pictures where dropped.contains(picture.start) {
            output.append(contentsOf: bytes[cursor..<picture.start])
            cursor = picture.end
        }
        output.append(contentsOf: bytes[cursor...])
        return output
    }

    /// Scrambles bytes inside slice payloads.
    ///
    /// Only inside a slice, and never over the four bytes of a start code: damaging
    /// those would lose the boundary itself and the decoder would skip the rest of
    /// the picture rather than mis-decode it. Mis-decoding is the point.
    private static func scrambleSlices(
        _ bytes: [UInt8], pictures: [MPEGPicture],
        amount: Double, random: inout SeededRandom
    ) -> [UInt8] {
        var output = bytes

        for picture in pictures {
            // Intra pictures carry no motion vectors, so scrambling them is just
            // block noise. The mode is about motion, so it works where motion is.
            guard picture.type != .intra else { continue }

            for (index, sliceOffset) in picture.sliceOffsets.enumerated() {
                guard random.nextUnitValue() < amount else { continue }

                let sliceEnd = index + 1 < picture.sliceOffsets.count
                    ? picture.sliceOffsets[index + 1]
                    : picture.end
                // Past the start code and the slice's own first byte.
                let from = sliceOffset + 5
                let to = sliceEnd - 4
                guard to > from else { continue }

                // Enough to displace blocks, not so much that the slice becomes
                // undecodable noise. Motion vectors are a few bits each, so this is
                // still a small fraction of the payload — scrambling wholesale gives
                // a grey mess rather than a picture sliding apart.
                let bytesToTouch = max(1, Int(Double(to - from) * 0.12 * amount))
                for _ in 0..<bytesToTouch {
                    let position = from + random.next(below: to - from)
                    output[position] = UInt8(truncatingIfNeeded: random.next(below: 256))
                }
            }
        }
        return output
    }

    /// Replaces pictures with the previous one's bytes.
    private static func holdReference(
        _ bytes: [UInt8], pictures: [MPEGPicture], previous: [UInt8]?,
        amount: Double, random: inout SeededRandom
    ) -> [UInt8] {
        guard let previous, !previous.isEmpty else {
            // Nothing held yet — the first frame has nothing to hold, so it passes
            // through rather than being dropped, which would be a different effect.
            return bytes
        }

        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var cursor = 0

        for picture in pictures {
            guard picture.type != .intra, random.nextUnitValue() < amount else { continue }
            output.append(contentsOf: bytes[cursor..<picture.start])
            output.append(contentsOf: previous)
            cursor = picture.end
        }
        output.append(contentsOf: bytes[cursor...])
        return output
    }
}

// MARK: - A known limit, stated
//
// These three do what they say: they edit the compressed bitstream before decode,
// deterministically, and leave it decodable. What they do NOT reliably produce is the
// blocky sliding look people mean by "datamoshing".
//
// The reason is that libavcodec conceals errors well. Damage at the byte level either
// lands somewhere the decoder resynchronises past, or breaks a slice badly enough
// that it is dropped and concealed. Either way the GOP decodes to a valid picture
// that is not the right one — measurably different, visibly clean.
//
// Getting blocks to move requires editing motion vectors AS VECTORS, which means
// parsing macroblocks: variable-length codes, a different layout per picture type,
// and re-encoding what you change. That is a decoder's worth of work, and this file
// says at the top that it will not do it. It is a real piece of work rather than a
// tweak, and it belongs behind its own decision.

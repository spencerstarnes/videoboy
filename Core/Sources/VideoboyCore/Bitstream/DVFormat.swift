//
//  DVFormat.swift — the DV bitstream layout, as constants and small accessors.
//
//  Purpose : The corruptor needs to know where DIF blocks are and what kind each one
//            is, so it can damage picture data without destroying the frame structure
//            the decoder relies on. Every magic number in the DV format lives here,
//            named, with its source stated.
//  Inputs  : raw DV frame bytes.
//  Outputs : block offsets, sequence/section identification.
//  Connects: DIFCorruptor (which uses these to pick targets), DVDemuxer (framing).
//  Extend  : PAL support means changing `sequencesPerFrame` and `frameBytes`; both
//            already exist as `DVStandard` cases.
//
//  Format summary (IEC 61834 / SMPTE 314M), enough to work from:
//    A DV frame is a whole number of 80-byte DIF blocks.
//    Blocks are grouped into DIF sequences of 150 blocks each.
//    NTSC has 10 sequences per frame, PAL has 12.
//    Within each sequence the 150 blocks run in a fixed order:
//      1 header, 2 subcode, 3 VAUX, then 135 audio+video in a repeating pattern of
//      1 audio block followed by 15 video blocks, nine times.
//    Each block's first byte carries its section type in the top three bits.
//

import Foundation

/// Which DV variant a stream is.
public enum DVStandard: String, Codable, Sendable {
    case ntsc
    case pal

    /// DIF sequences in one frame.
    public var sequencesPerFrame: Int {
        switch self {
        case .ntsc: 10
        case .pal: 12
        }
    }

    /// Total bytes in one frame.
    public var frameBytes: Int {
        sequencesPerFrame * DVFormat.blocksPerSequence * DVFormat.blockBytes
    }

    /// Picture geometry.
    public var size: (width: Int, height: Int) {
        switch self {
        case .ntsc: (720, 480)
        case .pal: (720, 576)
        }
    }

    /// Nominal frame rate.
    public var frameRate: Double {
        switch self {
        case .ntsc: 30000.0 / 1001.0
        case .pal: 25.0
        }
    }

    /// Identifies the standard from a file size, when the file is a whole number of
    /// frames of exactly one of them. Returns nil when the size fits neither.
    public static func inferred(fromByteCount byteCount: Int) -> DVStandard? {
        for standard in [DVStandard.ntsc, .pal] where byteCount > 0 && byteCount % standard.frameBytes == 0 {
            return standard
        }
        return nil
    }
}

/// What a DIF block carries. The value is the 3-bit section type from the block's
/// first byte.
public enum DIFSectionType: UInt8, Sendable {
    case header = 0
    case subcode = 1
    case vaux = 2
    case audio = 3
    case video = 4

    /// True for the two section types that carry compressed picture data.
    ///
    /// These are the only blocks the corruptor should touch by default: damaging a
    /// header or subcode block tends to make the decoder reject the whole frame,
    /// which produces a dropout rather than the artefact we want.
    public var carriesPicture: Bool { self == .video }
}

/// Constants and offsets for the DV DIF layout.
public enum DVFormat {

    /// Every DIF block is exactly 80 bytes.
    public static let blockBytes = 80

    /// Blocks in one DIF sequence.
    public static let blocksPerSequence = 150

    /// Bytes of block header before the payload. The remaining 77 bytes of a video
    /// block are DCT-coefficient data.
    public static let blockHeaderBytes = 3

    /// Video blocks in one DIF sequence: nine groups of fifteen.
    public static let videoBlocksPerSequence = 135

    /// Byte offset of a block within a frame.
    public static func blockOffset(sequence: Int, block: Int) -> Int {
        (sequence * blocksPerSequence + block) * blockBytes
    }

    /// The section type of the block starting at `offset`.
    ///
    /// The section type is the top three bits of the block's first byte.
    public static func sectionType(of frame: [UInt8], atOffset offset: Int) -> DIFSectionType? {
        guard offset >= 0, offset < frame.count else { return nil }
        return DIFSectionType(rawValue: frame[offset] >> 5)
    }

    /// Offsets of every video DIF block in a frame.
    ///
    /// These are the corruptor's targets. Built by walking the fixed block order
    /// rather than by scanning section types, so a frame whose headers have already
    /// been damaged still yields the right targets.
    public static func videoBlockOffsets(standard: DVStandard) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(standard.sequencesPerFrame * videoBlocksPerSequence)
        for sequence in 0..<standard.sequencesPerFrame {
            // Blocks 0..5 are header, subcode x2, VAUX x3. From block 6 the pattern
            // is one audio block then fifteen video blocks, repeated nine times.
            var block = 6
            for _ in 0..<9 {
                block += 1  // the audio block that starts each group
                for _ in 0..<15 {
                    offsets.append(blockOffset(sequence: sequence, block: block))
                    block += 1
                }
            }
        }
        return offsets
    }
}

//
//  H264Syntax.swift — just enough H.264 syntax to move frames around (SPEC 5).
//
//  Purpose : A datamosh feeds a decoder frames it was never meant to see in that
//            order: P-frames with their I-frame removed, one P-frame five times over.
//            The decoder only goes along with it if the frames still LOOK like a
//            continuous stream, which in H.264 means each slice's `frame_num` and
//            picture-order count follow on from the last. This file finds the NAL
//            units, reads the parameter sets, and rewrites those two numbers.
//  Inputs  : NAL unit payloads (no start code), as VideoToolbox hands them out.
//  Outputs : parsed SPS / PPS / slice-header facts, and slices renumbered in place.
//  Connects: MoshEngine (the only user), H264LiveEncoder upstream,
//            H264MoshDecoder downstream.
//  Extend  : a new field is one more read in the matching `parse`. Only fields
//            BEFORE the ones we rewrite are ever needed — the rewrite is a same-width
//            overwrite, so nothing after it has to be understood.
//
//  What is deliberately NOT here: macroblock parsing, CABAC, motion-vector editing.
//  The mosh is done at the level of whole frames, which is where the classic look
//  comes from (I-frame removal, P-frame repetition). Editing vectors as vectors is a
//  decoder's worth of work and a separate decision (see MPEGCorruptor's footnote).
//
//  Reference: ITU-T H.264 (08/2021) §7.3.1 (NAL unit), §7.3.2.1.1 (SPS), §7.3.2.2
//  (PPS), §7.3.3 (slice header), §7.4.1 (emulation prevention).
//

import Foundation

/// NAL unit types this code cares about (H.264 Table 7-1).
public enum H264NALType: UInt8, Sendable {
    case nonIDRSlice = 1
    case idrSlice = 5
    case sei = 6
    case sps = 7
    case pps = 8
    case accessUnitDelimiter = 9
    case other = 0

    public init(header: UInt8) {
        self = H264NALType(rawValue: header & 0x1F) ?? .other
    }

    public var isSlice: Bool { self == .nonIDRSlice || self == .idrSlice }
}

/// Why a piece of syntax could not be read. Always recoverable: the caller passes
/// the frame through unchanged rather than losing it.
public enum H264SyntaxError: Error, Equatable, CustomStringConvertible {
    case truncated
    case unsupported(String)

    public var description: String {
        switch self {
        case .truncated: "ran off the end of the NAL unit"
        case .unsupported(let what): "unsupported stream: \(what)"
        }
    }
}

// MARK: - Emulation prevention

/// Converts between a NAL payload (as stored) and its RBSP (the bits the syntax
/// describes). The encoder inserts a 0x03 after any two zero bytes that would
/// otherwise be followed by 0x00–0x03, so a start code can never appear by accident.
public enum H264EmulationPrevention {

    /// Removes emulation-prevention bytes.
    public static func unescape(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte == 0x03 {
                zeros = 0
                continue
            }
            output.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return output
    }

    /// Inserts emulation-prevention bytes where the RBSP needs them.
    public static func escape(_ rbsp: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(rbsp.count + rbsp.count / 64 + 4)
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2 && byte <= 0x03 {
                output.append(0x03)
                zeros = 0
            }
            output.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return output
    }
}

// MARK: - Bits

/// Reads bits MSB-first, with the Exp-Golomb codes H.264 headers are made of.
public struct H264BitReader {
    public let bytes: [UInt8]
    /// Position in bits from the start of `bytes`.
    public private(set) var position = 0

    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public mutating func bit() throws -> UInt32 {
        guard position < bytes.count * 8 else { throw H264SyntaxError.truncated }
        let value = (bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
        position += 1
        return UInt32(value)
    }

    public mutating func bits(_ count: Int) throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<count { value = (value << 1) | (try bit()) }
        return value
    }

    /// ue(v): unsigned Exp-Golomb.
    public mutating func ue() throws -> UInt32 {
        var leadingZeros = 0
        while try bit() == 0 {
            leadingZeros += 1
            guard leadingZeros < 32 else { throw H264SyntaxError.truncated }
        }
        guard leadingZeros > 0 else { return 0 }
        return (UInt32(1) << UInt32(leadingZeros)) - 1 + (try bits(leadingZeros))
    }

    /// se(v): signed Exp-Golomb.
    public mutating func se() throws -> Int32 {
        let code = try ue()
        return code & 1 == 1 ? Int32((code + 1) / 2) : -Int32(code / 2)
    }
}

/// Overwrites `count` bits at `position` (MSB-first) with `value`.
func writeBits(_ value: UInt32, count: Int, at position: Int, in bytes: inout [UInt8]) {
    for index in 0..<count {
        let bit = (value >> UInt32(count - 1 - index)) & 1
        let bitPosition = position + index
        let byteIndex = bitPosition >> 3
        let mask = UInt8(0x80) >> UInt8(bitPosition & 7)
        if bit == 1 { bytes[byteIndex] |= mask } else { bytes[byteIndex] &= ~mask }
    }
}

// MARK: - Parameter sets

/// The sequence parameter set fields a renumbering needs.
public struct H264SPS: Equatable, Sendable {
    public let id: UInt32
    public let separateColourPlane: Bool
    /// `frame_num` is this many bits wide.
    public let log2MaxFrameNum: Int
    public let pictureOrderCountType: UInt32
    /// `pic_order_cnt_lsb` is this many bits wide (type 0 only).
    public let log2MaxPictureOrderCountLSB: Int
    public let frameMBsOnly: Bool

    /// Parses an SPS NAL unit (header byte included).
    public static func parse(_ nal: [UInt8]) throws -> H264SPS {
        guard nal.count > 4 else { throw H264SyntaxError.truncated }
        var reader = H264BitReader(H264EmulationPrevention.unescape(nal[1...]))
        let profile = try reader.bits(8)
        _ = try reader.bits(8)   // constraint flags + reserved
        _ = try reader.bits(8)   // level
        let id = try reader.ue()

        var separateColourPlane = false
        // The High-family profiles carry chroma format and scaling lists here.
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            let chromaFormat = try reader.ue()
            if chromaFormat == 3 { separateColourPlane = try reader.bit() == 1 }
            _ = try reader.ue()   // bit_depth_luma_minus8
            _ = try reader.ue()   // bit_depth_chroma_minus8
            _ = try reader.bit()  // qpprime_y_zero_transform_bypass_flag
            if try reader.bit() == 1 {   // seq_scaling_matrix_present_flag
                let lists = chromaFormat == 3 ? 12 : 8
                for index in 0..<lists where try reader.bit() == 1 {
                    try skipScalingList(&reader, size: index < 6 ? 16 : 64)
                }
            }
        }

        let log2MaxFrameNum = Int(try reader.ue()) + 4
        let pocType = try reader.ue()
        var log2MaxPocLSB = 0
        if pocType == 0 {
            log2MaxPocLSB = Int(try reader.ue()) + 4
        } else if pocType == 1 {
            _ = try reader.bit()   // delta_pic_order_always_zero_flag
            _ = try reader.se()    // offset_for_non_ref_pic
            _ = try reader.se()    // offset_for_top_to_bottom_field
            let cycle = try reader.ue()
            for _ in 0..<cycle { _ = try reader.se() }
        }
        _ = try reader.ue()   // max_num_ref_frames
        _ = try reader.bit()  // gaps_in_frame_num_value_allowed_flag
        _ = try reader.ue()   // pic_width_in_mbs_minus1
        _ = try reader.ue()   // pic_height_in_map_units_minus1
        let frameMBsOnly = try reader.bit() == 1

        return H264SPS(
            id: id, separateColourPlane: separateColourPlane,
            log2MaxFrameNum: log2MaxFrameNum, pictureOrderCountType: pocType,
            log2MaxPictureOrderCountLSB: log2MaxPocLSB, frameMBsOnly: frameMBsOnly)
    }

    private static func skipScalingList(_ reader: inout H264BitReader, size: Int) throws {
        var last: Int32 = 8
        var next: Int32 = 8
        for _ in 0..<size where next != 0 {
            let delta = try reader.se()
            next = (last + delta + 256) % 256
            last = next == 0 ? last : next
        }
    }
}

/// The picture parameter set fields a renumbering needs: which SPS it points at.
public struct H264PPS: Equatable, Sendable {
    public let id: UInt32
    public let spsID: UInt32

    public static func parse(_ nal: [UInt8]) throws -> H264PPS {
        guard nal.count > 1 else { throw H264SyntaxError.truncated }
        var reader = H264BitReader(H264EmulationPrevention.unescape(nal[1...]))
        let id = try reader.ue()
        let spsID = try reader.ue()
        return H264PPS(id: id, spsID: spsID)
    }
}

// MARK: - Slice headers

/// Where the renumberable fields sit in one slice's RBSP.
public struct H264SliceHeader: Equatable, Sendable {
    public let type: H264NALType
    /// nal_ref_idc: zero for a picture nothing else will predict from.
    public let referenceIDC: UInt8
    public let ppsID: UInt32
    public let frameNum: UInt32
    /// Bit offset of `frame_num` in the RBSP (payload after the header byte).
    public let frameNumBitOffset: Int
    public let frameNumBits: Int
    /// Bit offset and width of `pic_order_cnt_lsb`, when the stream carries one.
    public let pocLSBBitOffset: Int?
    public let pocLSBBits: Int

    /// Reads a slice header up to `pic_order_cnt_lsb`.
    public static func parse(
        _ nal: [UInt8], sps: [UInt32: H264SPS], pps: [UInt32: H264PPS]
    ) throws -> (header: H264SliceHeader, rbsp: [UInt8]) {
        guard let first = nal.first else { throw H264SyntaxError.truncated }
        let type = H264NALType(header: first)
        guard type.isSlice else { throw H264SyntaxError.unsupported("not a slice") }
        let rbsp = H264EmulationPrevention.unescape(nal[1...])
        var reader = H264BitReader(rbsp)

        _ = try reader.ue()   // first_mb_in_slice
        _ = try reader.ue()   // slice_type
        let ppsID = try reader.ue()
        guard let pictureSet = pps[ppsID] else { throw H264SyntaxError.unsupported("unknown PPS \(ppsID)") }
        guard let sequenceSet = sps[pictureSet.spsID] else {
            throw H264SyntaxError.unsupported("unknown SPS \(pictureSet.spsID)")
        }
        if sequenceSet.separateColourPlane { _ = try reader.bits(2) }

        let frameNumOffset = reader.position
        let frameNum = try reader.bits(sequenceSet.log2MaxFrameNum)
        if !sequenceSet.frameMBsOnly {
            // Interlaced coding changes what a "frame" is; the encoder here never
            // produces it, and guessing would corrupt rather than renumber.
            throw H264SyntaxError.unsupported("field-coded pictures")
        }
        if type == .idrSlice { _ = try reader.ue() }   // idr_pic_id

        var pocOffset: Int?
        if sequenceSet.pictureOrderCountType == 0 {
            pocOffset = reader.position
            _ = try reader.bits(sequenceSet.log2MaxPictureOrderCountLSB)
        } else if sequenceSet.pictureOrderCountType == 1 {
            throw H264SyntaxError.unsupported("picture order count type 1")
        }

        let header = H264SliceHeader(
            type: type, referenceIDC: (first >> 5) & 0x03, ppsID: ppsID,
            frameNum: frameNum, frameNumBitOffset: frameNumOffset,
            frameNumBits: sequenceSet.log2MaxFrameNum,
            pocLSBBitOffset: pocOffset, pocLSBBits: sequenceSet.log2MaxPictureOrderCountLSB)
        return (header, rbsp)
    }

    /// The same slice with `frame_num` (and, where present, the POC LSB) replaced.
    ///
    /// Both are fixed-width fields, so the overwrite leaves every later bit where it
    /// was — the slice data after the header is untouched. The payload is re-escaped
    /// afterwards because a changed bit can create or remove a 00 00 0x pattern.
    public func renumbered(rbsp: [UInt8], headerByte: UInt8, frameNum: UInt32, pocLSB: UInt32) -> [UInt8] {
        var edited = rbsp
        let frameMask = frameNumBits >= 32 ? UInt32.max : (UInt32(1) << UInt32(frameNumBits)) - 1
        writeBits(frameNum & frameMask, count: frameNumBits, at: frameNumBitOffset, in: &edited)
        if let pocLSBBitOffset {
            let pocMask = pocLSBBits >= 32 ? UInt32.max : (UInt32(1) << UInt32(pocLSBBits)) - 1
            writeBits(pocLSB & pocMask, count: pocLSBBits, at: pocLSBBitOffset, in: &edited)
        }
        return [headerByte] + H264EmulationPrevention.escape(edited)
    }
}

// MARK: - Access units

/// One coded picture: its NAL units in decode order, without start codes.
public struct H264AccessUnit: Sendable {
    public var nalUnits: [[UInt8]]
    /// The encoder marked this a sync sample (an IDR picture).
    public var isKeyframe: Bool

    public init(nalUnits: [[UInt8]], isKeyframe: Bool) {
        self.nalUnits = nalUnits
        self.isKeyframe = isKeyframe
    }

    /// Coded size of the picture's slices, the proxy used for "how much of this frame
    /// is new picture rather than motion". An intra-heavy frame is several times the
    /// size of a typical P-frame.
    public var sliceBytes: Int {
        nalUnits.reduce(0) { $0 + (H264NALType(header: $1.first ?? 0).isSlice ? $1.count : 0) }
    }

    /// Annex B bytes (4-byte start codes), what libavcodec's H.264 parser expects.
    public var annexB: [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(nalUnits.reduce(0) { $0 + $1.count + 4 })
        for nal in nalUnits {
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(contentsOf: nal)
        }
        return output
    }

    /// Splits AVCC data (big-endian length-prefixed NAL units, as VideoToolbox emits
    /// them) into NAL units.
    public static func nalUnits(fromAVCC data: [UInt8], lengthSize: Int = 4) -> [[UInt8]] {
        var units: [[UInt8]] = []
        var cursor = 0
        while cursor + lengthSize <= data.count {
            var length = 0
            for index in 0..<lengthSize { length = (length << 8) | Int(data[cursor + index]) }
            cursor += lengthSize
            guard length > 0, cursor + length <= data.count else { break }
            units.append(Array(data[cursor..<(cursor + length)]))
            cursor += length
        }
        return units
    }
}

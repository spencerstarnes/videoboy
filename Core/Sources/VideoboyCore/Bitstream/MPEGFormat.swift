//
//  MPEGFormat.swift — just enough MPEG-2 structure to damage it on purpose.
//
//  Purpose : The wedge is bitstream manipulation of the MPEG family (CLAUDE.md,
//            SPEC 5); this is the structure its corruptor needs. It is deliberately not a decoder — it
//            finds the boundaries that matter and nothing else, because everything
//            past those boundaries is libavcodec's job.
//  Inputs  : MPEG-2 elementary-stream bytes.
//  Outputs : the positions and kinds of start codes, and of coded pictures.
//  Connects: MPEGCorruptor (which damages what this finds).
//  Extend  : a new start code is a case here. Do NOT start parsing macroblocks —
//            if a transform needs that, it belongs in a filter after decode, not in
//            a bitstream editor.
//
//  Why start codes are enough: MPEG-2 is self-delimiting at this level. Every
//  picture, slice and header begins with 00 00 01 followed by one identifying byte,
//  and those bytes cannot occur inside coded data (the encoder is required to prevent
//  it). So the boundaries are findable exactly, without decoding anything.
//

import Foundation

/// What an MPEG-2 start code introduces.
public enum MPEGStartCode: Equatable, Sendable {
    /// 0x00 — a coded picture.
    case picture
    /// 0x01...0xAF — a slice, one horizontal strip of macroblocks.
    case slice(row: UInt8)
    /// 0xB3 — the sequence header.
    case sequenceHeader
    /// 0xB8 — a group of pictures.
    case groupOfPictures
    /// 0xB5 — an extension.
    case extensionCode
    /// Anything else.
    case other(UInt8)

    init(identifier: UInt8) {
        switch identifier {
        case 0x00: self = .picture
        case 0x01...0xAF: self = .slice(row: identifier)
        case 0xB3: self = .sequenceHeader
        case 0xB5: self = .extensionCode
        case 0xB8: self = .groupOfPictures
        default: self = .other(identifier)
        }
    }

    public var isSlice: Bool {
        if case .slice = self { return true }
        return false
    }
}

/// How a picture was coded, which decides what damaging it looks like.
public enum MPEGPictureType: Int, Equatable, Sendable {
    /// Intra — a complete picture, standing alone.
    case intra = 1
    /// Predicted from the picture before it.
    case predicted = 2
    /// Predicted from both directions.
    case bidirectional = 3
    case unknown = 0

    public var displayName: String {
        switch self {
        case .intra: "I"
        case .predicted: "P"
        case .bidirectional: "B"
        case .unknown: "?"
        }
    }
}

/// One start code found in a stream.
public struct MPEGMarker: Equatable, Sendable {
    /// Offset of the first byte of the 00 00 01 prefix.
    public let offset: Int
    public let code: MPEGStartCode
    /// For a picture, how it was coded.
    public let pictureType: MPEGPictureType

    public init(offset: Int, code: MPEGStartCode, pictureType: MPEGPictureType = .unknown) {
        self.offset = offset
        self.code = code
        self.pictureType = pictureType
    }
}

/// One coded picture: where it starts, where it ends, and how it was coded.
public struct MPEGPicture: Equatable, Sendable {
    /// Offset of the picture start code.
    public let start: Int
    /// One past the last byte belonging to this picture.
    public let end: Int
    public let type: MPEGPictureType
    /// The slices inside it, by offset.
    public let sliceOffsets: [Int]

    public var byteCount: Int { end - start }
}

/// Finds the structure the corruptor needs.
public enum MPEGFormat {

    /// Every start code in a stream, in order.
    ///
    /// A plain scan rather than anything clever: these buffers are one GOP at a time
    /// and the cost is a byte comparison, which is nothing beside decoding them.
    public static func markers(in bytes: [UInt8]) -> [MPEGMarker] {
        var found: [MPEGMarker] = []
        guard bytes.count >= 4 else { return found }

        var index = 0
        while index <= bytes.count - 4 {
            guard bytes[index] == 0x00, bytes[index + 1] == 0x00, bytes[index + 2] == 0x01 else {
                index += 1
                continue
            }
            let identifier = bytes[index + 3]
            let code = MPEGStartCode(identifier: identifier)

            var pictureType = MPEGPictureType.unknown
            if code == .picture, index + 5 < bytes.count {
                // picture_coding_type is bits 3-5 of the second byte after the start
                // code, following the 10-bit temporal reference.
                pictureType = MPEGPictureType(
                    rawValue: Int((bytes[index + 5] >> 3) & 0x07)) ?? .unknown
            }
            found.append(MPEGMarker(offset: index, code: code, pictureType: pictureType))
            index += 4
        }
        return found
    }

    /// The coded pictures in a stream.
    ///
    /// A picture runs from its start code to the next picture, sequence header or
    /// GOP header — whichever comes first, because all three end it.
    public static func pictures(in bytes: [UInt8]) -> [MPEGPicture] {
        let all = markers(in: bytes)
        let pictureIndices = all.indices.filter { all[$0].code == .picture }

        return pictureIndices.map { index in
            let marker = all[index]
            // Where this picture ends: the next thing that can only begin a new one.
            let endMarker = all[(index + 1)...].first {
                $0.code == .picture || $0.code == .sequenceHeader || $0.code == .groupOfPictures
            }
            let end = endMarker?.offset ?? bytes.count

            let slices = all[(index + 1)...]
                .prefix { $0.offset < end }
                .filter(\.code.isSlice)
                .map(\.offset)

            return MPEGPicture(
                start: marker.offset, end: end,
                type: marker.pictureType, sliceOffsets: Array(slices))
        }
    }
}

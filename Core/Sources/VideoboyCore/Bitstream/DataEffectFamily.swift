//
//  DataEffectFamily.swift — which bitstream effects a piece of media can offer.
//
//  Purpose : Data effects are not general effects. They rewrite a *compressed
//            bitstream* before it is decoded, so what is available depends entirely
//            on what codec is carrying the picture. DV has DIF blocks; MPEG has
//            GOPs and motion vectors; a PNG or a generator has no bitstream at all
//            and can offer nothing.
//  Inputs  : a media file, or a bus's interchange setting.
//  Outputs : a family, and the effects that family provides.
//  Connects: DVSourceNode and BusCodecNode declare their family; the UI shows the
//            matching stack, or hides it entirely when there is none.
//  Extend  : adding MPEG means adding its transforms and flipping `isImplemented`.
//            Do not add a family that has no bitstream — that is what `.none` is for.
//

import Foundation

/// The kind of compressed bitstream something carries.
public enum DataEffectFamily: String, CaseIterable, Codable, Sendable {
    /// No compressed bitstream: stills, generators, raw or already-decoded video.
    /// There is nothing to corrupt, and the UI hides the data stack entirely.
    case none
    /// DV — fixed-size DIF blocks, intra-frame.
    case dv
    /// MPEG family — GOPs, motion vectors, reference frames.
    case mpeg

    public var displayName: String {
        switch self {
        case .none: "None"
        case .dv: "DV"
        case .mpeg: "MPEG"
        }
    }

    /// Whether this family's effects are actually built.
    ///
    /// MPEG is declared so the interface can say "this footage has data effects, but
    /// they are not written yet" rather than silently offering nothing — which would
    /// be indistinguishable from the footage having no bitstream at all.
    public var isImplemented: Bool {
        switch self {
        case .none: true
        case .dv: true
        case .mpeg: false
        }
    }

    /// The effects this family offers, in the order they should be shown.
    public var effects: [DataEffectDescriptor] {
        switch self {
        case .none:
            return []
        case .dv:
            return CorruptionMode.allCases.map { mode in
                DataEffectDescriptor(
                    identifier: mode.rawValue,
                    displayName: DataEffectFamily.dvDisplayName(for: mode),
                    family: .dv,
                    isImplemented: true
                )
            }
        case .mpeg:
            // SPEC 5's MPEG list. Declared, not built.
            return [
                DataEffectDescriptor(identifier: "frameDrop", displayName: "Frame Drop",
                                     family: .mpeg, isImplemented: false),
                DataEffectDescriptor(identifier: "motionVector", displayName: "Motion Vector Corrupt",
                                     family: .mpeg, isImplemented: false),
                DataEffectDescriptor(identifier: "referenceHold", displayName: "Reference Hold",
                                     family: .mpeg, isImplemented: false)
            ]
        }
    }

    /// Readable names for the DV corruption modes.
    private static func dvDisplayName(for mode: CorruptionMode) -> String {
        switch mode {
        case .shuffleBlocks: "Block Shuffle"
        case .duplicateBlocks: "Block Smear"
        case .dropBlocks: "Block Dropout"
        case .flipCoefficients: "Coefficient Flip"
        case .swapSequences: "Sequence Swap"
        case .holdSequences: "Sequence Hold"
        }
    }

    /// Identifies a family from a file's extension.
    ///
    /// Extension rather than content sniffing, deliberately: this decides what the
    /// interface offers, and being wrong in the safe direction (offering nothing)
    /// is better than promising DV effects for a file that turns out not to be DV.
    /// The source node confirms the real answer when it actually opens the file.
    public static func forMediaFile(at url: URL) -> DataEffectFamily {
        switch url.pathExtension.lowercased() {
        case "dv":
            return .dv
        case "m2v", "mpg", "mpeg", "ts", "m4v":
            return .mpeg
        case "mov", "mp4":
            // A QuickTime or MP4 container usually holds an MPEG-family stream, but
            // it can hold anything — ProRes, DV, raw. Until the demuxer reports what
            // is really inside, promising MPEG effects would be a guess.
            return .none
        default:
            return .none
        }
    }
}

/// One data effect a family offers.
public struct DataEffectDescriptor: Equatable, Sendable {
    /// Stable identifier, used as the UI's key and in templates.
    public let identifier: String
    public let displayName: String
    public let family: DataEffectFamily
    /// False for effects that are declared but not written.
    public let isImplemented: Bool

    public init(identifier: String, displayName: String, family: DataEffectFamily, isImplemented: Bool) {
        self.identifier = identifier
        self.displayName = displayName
        self.family = family
        self.isImplemented = isImplemented
    }
}

/// Anything that can offer data effects declares this.
public protocol DataEffectProvider {
    /// The family currently available, which may be `.none`.
    var dataEffectFamily: DataEffectFamily { get }
}

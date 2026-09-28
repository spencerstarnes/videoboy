//
//  ClipDecoding.swift — what a source node needs from a codec, and nothing more.
//
//  Purpose : The seam between a source node and a codec. Everything about WHEN a frame is shown stays in the node,
//            because it is identical whatever the codec; everything about HOW the
//            bytes become a picture lives behind here.
//  Inputs  : a frame index, and the corruption settings for codecs that can be
//            damaged before decode.
//  Outputs : a decoded `ImageBuffer`.
//  Connects: ClipSourceNode (the only caller), MPEGStreamDecoder, AVFClipDecoder,
//            ImageSequenceDecoder, HEV1Reader.
//  Extend  : a new container is a new conformer. It reports its own frame count and
//            rate, and says which data-effect family it belongs to — which is how the
//            UI knows whether to offer the bitstream effects at all.
//
//  Why corruption is a parameter here rather than applied afterwards: the wedge only
//  works BEFORE decode. Handing the settings to the decoder is what keeps that true —
//  a decoder that cannot be damaged says so by reporting `.none`, and the interface
//  then does not offer damage it cannot do.
//

import Foundation

/// A source of decoded frames for `ClipSourceNode`.
public protocol ClipDecoding: AnyObject {

    /// Total frames in the clip.
    var frameCount: Int { get }

    /// The clip's own frame rate, used to retime it against the project rate.
    var frameRate: Double { get }

    /// Which family of pre-decode data effects this codec supports, if any.
    var dataEffectFamily: DataEffectFamily { get }

    /// The picture at a frame index.
    ///
    /// - Parameter corruption: applied to the compressed bytes before decoding, for
    ///   codecs whose family is not `.none`. Ignored by the others, which is why they
    ///   report `.none` — so nothing offers the control in the first place.
    func image(at index: Int, corruption: CorruptionSettings) -> ImageBuffer?

    /// The picture's display shape (width over height, upright), when the file says
    /// something the decoded pixel count does not — a pixel aspect ratio, or a
    /// rotation. Nil means "read it off the decoded raster" (`CanvasGeometry`).
    var displayAspectRatio: Double? { get }

    /// Clockwise quarter turns needed to show the decoded raster upright. A phone's
    /// portrait clip is stored landscape with a rotation flag.
    var quarterTurns: Int { get }

    var nativeHeight: Int? { get }
}

public extension ClipDecoding {
    /// The picture's own height in pixels, upright — what Centre framing shows at 1:1.
    /// Nil when unknown (Centre then fits).
    var nativeHeight: Int? { nil }
    var displayAspectRatio: Double? { nil }
    var quarterTurns: Int { 0 }
}

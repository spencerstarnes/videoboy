//
//  ClipDecoding.swift — what a source node needs from a codec, and nothing more.
//
//  Purpose : Until now a source WAS a DV reader: the playhead, the loop modes, the
//            musical stepping and the DIF corruptor all lived in one type, so "play a
//            .mov" had no answer that was not a second, parallel source module. This
//            is the seam. Everything about WHEN a frame is shown stays in the node,
//            because it is identical whatever the codec; everything about HOW the
//            bytes become a picture lives behind here.
//  Inputs  : a frame index, and the corruption settings for codecs that can be
//            damaged before decode.
//  Outputs : a decoded `ImageBuffer`.
//  Connects: ClipSourceNode (the only caller), DVClipDecoder, AVFClipDecoder.
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
}

/// DV: the wedge's home. Damages DIF blocks before handing them to the decoder.
public final class DVClipDecoder: ClipDecoding {

    private let reader: DVReader
    private let decoder: DVDecoder

    public init(url: URL) throws {
        self.reader = try DVReader(url: url)
        self.decoder = try DVDecoder()
    }

    public var frameCount: Int { reader.frameCount }
    public var frameRate: Double { reader.standard.frameRate }
    public var dataEffectFamily: DataEffectFamily { .dv }

    /// The DV standard of the loaded file, which the node needs for retiming.
    public var standard: DVStandard { reader.standard }

    /// Wraps an index into the file, so callers need not.
    public func wrappedIndex(_ index: Int) -> Int { reader.wrappedIndex(index) }

    public func image(at index: Int, corruption: CorruptionSettings) -> ImageBuffer? {
        let frameIndex = reader.wrappedIndex(index)
        guard let clean = reader.frame(at: frameIndex) else { return nil }
        let previous = reader.frame(at: reader.wrappedIndex(frameIndex - 1))

        // THE WEDGE: damage the compressed bytes, then decode them. Never the other
        // way round — decoding first and damaging pixels would be an ordinary effect.
        let bytes = DIFCorruptor.corrupt(
            frame: clean, settings: corruption,
            standard: reader.standard, previousFrame: previous
        )
        return decoder.decode(frameBytes: bytes)
    }
}

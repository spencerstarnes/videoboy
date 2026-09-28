//
//  ClipDecoders.swift — which decoder a file gets, and how long it is.
//
//  Purpose : One answer to "what opens this file", shared by playback and by
//            anything that needs to know about a clip without playing it. The
//            library's Duration column read "—" for every imported clip because
//            nothing ever asked; asking through a second, different choice of
//            decoder would let the list and the player disagree about a file.
//  Inputs  : a file URL.
//  Outputs : a `ClipDecoding`, or a length in seconds.
//  Connects: ClipSourceNode (opens clips for playback), the App's LibraryModel
//            (fills in durations).
//  Extend  : a new container is a new case in `open`. `duration(of:)` follows.
//

import CFFmpeg
import Foundation

/// Chooses a decoder by container, and measures clips.
public enum ClipDecoders {

    /// The extensions that go through the MPEG bitstream decoder rather than
    /// AVFoundation. AVFoundation could play them, but hands back finished pictures
    /// with no seam to damage; the wedge needs the packet.
    public static let mpegExtensions: Set<String> = ["m2v", "mpg", "mpeg", "ts", "m2t", "m2ts", "vob"]

    /// Whether the vendored LGPL libav can decode MPEG-2, the wedge's own format.
    /// Checked at launch so a missing codec shows on the launch screen rather than
    /// when the first MPEG file fails to open.
    public static var bitstreamCodecAvailable: Bool {
        avcodec_find_decoder(AV_CODEC_ID_MPEG2VIDEO) != nil
    }

    /// Opens a video file with the decoder playback uses for it, or nil.
    ///
    /// - Parameter canvas: decode no larger than this canvas needs; nil for full size.
    /// - Parameter knownFrameCount: from the catalog; saves an MPEG stream a full scan.
    public static func open(_ url: URL, canvas: CanvasGeometry? = nil, knownFrameCount: Int? = nil) -> ClipDecoding? {
        let ext = url.pathExtension.lowercased()
        if mpegExtensions.contains(ext) {
            return MPEGStreamDecoder(url: url, canvas: canvas, knownFrameCount: knownFrameCount)
                ?? AVFClipDecoder(url: url, canvas: canvas)
        }
        return AVFClipDecoder(url: url, canvas: canvas)
    }

    /// A clip's length in seconds, or nil when it cannot be read.
    ///
    /// Opens the file, so call it off the main thread.
    public static func duration(of url: URL) -> Double? {
        guard let decoder = open(url), decoder.frameCount > 0, decoder.frameRate > 0 else { return nil }
        return Double(decoder.frameCount) / decoder.frameRate
    }
}

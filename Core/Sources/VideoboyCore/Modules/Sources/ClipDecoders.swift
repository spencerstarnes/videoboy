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

import Foundation

/// Chooses a decoder by container, and measures clips.
public enum ClipDecoders {

    /// The extensions that go through the MPEG bitstream decoder rather than
    /// AVFoundation. AVFoundation could play them, but hands back finished pictures
    /// with no seam to damage; the wedge needs the packet.
    public static let mpegExtensions: Set<String> = ["m2v", "mpg", "mpeg", "ts", "m2t", "m2ts", "vob"]

    /// Opens a video file with the decoder playback uses for it, or nil.
    public static func open(_ url: URL) -> ClipDecoding? {
        let ext = url.pathExtension.lowercased()
        if ext == "dv" { return try? DVClipDecoder(url: url) }
        if mpegExtensions.contains(ext) { return MPEGStreamDecoder(url: url) ?? AVFClipDecoder(url: url) }
        return AVFClipDecoder(url: url)
    }

    /// A clip's length in seconds, or nil when it cannot be read.
    ///
    /// Opens the file, so call it off the main thread. DV is measured from its size
    /// alone — frames are a fixed number of bytes — rather than by opening a reader,
    /// which loads the whole file into memory.
    public static func duration(of url: URL) -> Double? {
        if url.pathExtension.lowercased() == "dv" {
            // The file's size, not a symlink's: samples/ and many media folders link.
            let path = url.resolvingSymlinksInPath().path
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
                  let standard = DVStandard.inferred(fromByteCount: size) else { return nil }
            return Double(size / standard.frameBytes) / standard.frameRate
        }
        guard let decoder = open(url), decoder.frameCount > 0, decoder.frameRate > 0 else { return nil }
        return Double(decoder.frameCount) / decoder.frameRate
    }
}

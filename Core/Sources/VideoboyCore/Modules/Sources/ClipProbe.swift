//
//  ClipProbe.swift — what a clip IS, measured once, off the main thread.
//
//  Purpose : Length, frame count and rate, read when a clip is imported and stored in
//            the catalog. Opening a long MPEG elementary stream used to count every
//            picture in the file on the main thread (130 ms a minute of footage, audit
//            09-26); with the count stored, `ClipDecoders.open` skips it.
//  Inputs  : a file or image-sequence folder URL.
//  Outputs : `ClipFacts`, or nil when the file cannot be read.
//  Connects: the import job (App), Catalog, ClipDecoders (`knownFrameCount`).
//  Extend  : a new format answers here with the SAME frame count its decoder would
//            report — the playhead's wrap depends on the two agreeing.
//

import AVFoundation
import Foundation

/// A clip's measured facts.
public struct ClipFacts: Equatable, Sendable {
    public let duration: Double
    public let frameCount: Int
    public let frameRate: Double

    public init(duration: Double, frameCount: Int, frameRate: Double) {
        self.duration = duration
        self.frameCount = frameCount
        self.frameRate = frameRate
    }
}

public enum ClipProbe {

    /// Measures a clip. Slow for long MPEG files (it counts their pictures), so call
    /// it off the main thread — which is the point of measuring it once.
    public static func facts(of url: URL) -> ClipFacts? {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            guard ImageSequenceDecoder.isSequence(url) else { return nil }
            let count = ImageSequenceDecoder.frames(in: url).count
            guard count > 0 else { return nil }
            // A stack of pictures plays at 30 (ImageSequenceDecoder's rate).
            return ClipFacts(duration: Double(count) / 30.0, frameCount: count, frameRate: 30)
        }
        let ext = url.pathExtension.lowercased()
        if ClipDecoders.mpegExtensions.contains(ext), let decoder = MPEGStreamDecoder(url: url),
           decoder.frameCount > 0 {
            return ClipFacts(duration: Double(decoder.frameCount) / decoder.frameRate,
                             frameCount: decoder.frameCount, frameRate: decoder.frameRate)
        }
        // AVFoundation: the same arithmetic AVFClipDecoder uses, without starting a reader.
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let nominal = Double(track.nominalFrameRate)
        let rate = nominal > 0 ? nominal : StandardDefinition.frameRate
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else { return nil }
        let count = max(Int((duration * rate).rounded()), 1)
        return ClipFacts(duration: duration, frameCount: count, frameRate: rate)
    }
}

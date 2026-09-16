//
//  DVReader.swift — reads raw DV files as a sequence of fixed-size frames.
//
//  Purpose : Raw DV needs no real demuxer: frames are a fixed byte count and follow
//            one another with nothing in between. Reading them directly, rather than
//            through libav, means the corruptor gets untouched bytes and the whole
//            path is testable without the decoder.
//  Inputs  : a .dv file path.
//  Outputs : frame byte arrays, and the stream's standard and frame count.
//  Connects: DIFCorruptor (which damages what this yields), DVDecoder (which decodes
//            the result), DVSource (which drives playback).
//  Extend  : DV inside a QuickTime container needs a real demuxer; that is a libav
//            job and belongs in DVDecoder, not here.
//

import Foundation

/// Reads frames from a raw DV file.
public final class DVReader {

    /// Where the file is.
    public let url: URL
    /// NTSC or PAL, inferred from the file size.
    public let standard: DVStandard
    /// Total frames in the file.
    public let frameCount: Int

    private let data: Data

    /// Errors opening a DV file.
    public enum ReaderError: Error, CustomStringConvertible {
        case unreadable(URL, Error)
        case notWholeFrames(URL, Int)
        case empty(URL)

        public var description: String {
            switch self {
            case .unreadable(let url, let error): "cannot read \(url.lastPathComponent): \(error)"
            case .notWholeFrames(let url, let bytes):
                "\(url.lastPathComponent) is \(bytes) bytes, which is not a whole number of NTSC (\(DVStandard.ntsc.frameBytes)) or PAL (\(DVStandard.pal.frameBytes)) DV frames"
            case .empty(let url): "\(url.lastPathComponent) is empty"
            }
        }
    }

    /// Opens a raw DV file and works out its standard from the size.
    ///
    /// The whole file is read into memory. A DV file is about 3.5 MB per second, so a
    /// few minutes fits comfortably, and having the bytes resident is what lets the
    /// corruptor and the scrubber jump around without I/O in the render path.
    public init(url: URL) throws {
        self.url = url
        do {
            self.data = try Data(contentsOf: url)
        } catch {
            throw ReaderError.unreadable(url, error)
        }
        guard !data.isEmpty else { throw ReaderError.empty(url) }
        guard let standard = DVStandard.inferred(fromByteCount: data.count) else {
            throw ReaderError.notWholeFrames(url, data.count)
        }
        self.standard = standard
        self.frameCount = data.count / standard.frameBytes
        Log.info(.dv, "opened \(url.lastPathComponent): \(frameCount) \(standard.rawValue.uppercased()) frames, \(standard.size.width)x\(standard.size.height)")
    }

    /// The bytes of one frame, or nil when the index is out of range.
    public func frame(at index: Int) -> [UInt8]? {
        guard index >= 0, index < frameCount else { return nil }
        let start = index * standard.frameBytes
        let end = start + standard.frameBytes
        return [UInt8](data[start..<end])
    }

    /// Wraps an index into the file's range, for looping playback.
    public func wrappedIndex(_ index: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let remainder = index % frameCount
        return remainder < 0 ? remainder + frameCount : remainder
    }
}

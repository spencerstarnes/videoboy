//
//  ClipThumbnails.swift — filmstrip frames for library thumbnails.
//
//  Purpose : FCP's library lets you run the pointer across a thumbnail and see the
//            clip move under it, which tells you what a file IS far faster than its
//            name does. That needs frames decoded at arbitrary positions, cheaply
//            enough to follow a pointer.
//  Inputs  : a media URL and a 0...1 position.
//  Outputs : a decoded `ImageBuffer`, scaled down to thumbnail size.
//  Connects: LibraryItemView (which hovers), DVReader and DVDecoder (which decode).
//  Extend  : when the AVFoundation source lands, add a branch here for formats DV
//            cannot read. The cache and the position maths stay the same.
//
//  On the cache: a fixed number of evenly spaced positions per clip rather than a
//  frame per pixel. A thumbnail is about 80 pixels wide and decoding 80 DV frames to
//  cross it would be both slow and pointless — the eye reads a filmstrip of a dozen
//  frames as motion perfectly well, and every position afterwards is free.
//

import Foundation

/// Decodes and caches a handful of frames per clip, for hover-scrubbing.
public final class ClipThumbnails {

    /// Shared cache. Thumbnails are the same wherever they are shown, and decoding
    /// them once per panel would mean three copies of every DV frame in the window.
    public static let shared = ClipThumbnails()

    /// How many positions are sampled across a clip.
    public static let steps = 12

    /// Thumbnail width; height follows the source's aspect.
    public static let width = 160

    private struct Key: Hashable {
        let path: String
        let step: Int
    }

    private var cache: [Key: ImageBuffer] = [:]
    /// Clips that could not be opened, so a broken file is not retried on every
    /// mouse move.
    private var failed: Set<String> = []
    private let lock = NSLock()

    public init() {}

    /// The frame nearest a 0...1 position, or nil when the clip cannot be read.
    ///
    /// Positions are quantised to `steps`, so dragging across a thumbnail asks for
    /// the same handful of frames over and over and only decodes each once.
    public func frame(for url: URL, at position: Double) -> ImageBuffer? {
        let clamped = min(max(position, 0), 1)
        let step = Int((clamped * Double(Self.steps - 1)).rounded())
        let key = Key(path: url.path, step: step)

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        if failed.contains(url.path) {
            lock.unlock()
            return nil
        }
        lock.unlock()

        guard let decoded = decode(url: url, step: step) else {
            lock.lock()
            failed.insert(url.path)
            lock.unlock()
            Log.warn(.dv, "no thumbnail for \(url.lastPathComponent)")
            return nil
        }

        lock.lock()
        cache[key] = decoded
        lock.unlock()
        return decoded
    }

    /// The first frame, which is what a thumbnail shows when nothing is hovering it.
    public func poster(for url: URL) -> ImageBuffer? {
        frame(for: url, at: 0)
    }

    private func decode(url: URL, step: Int) -> ImageBuffer? {
        // The same decoders the sources use, so a clip that thumbnails is a clip that
        // plays. A library that showed a picture for something the app then refused
        // to load would be the worst of both.
        let decoder: ClipDecoding?
        if url.pathExtension.lowercased() == "dv" {
            decoder = try? DVClipDecoder(url: url)
        } else {
            decoder = AVFClipDecoder(url: url)
        }
        guard let decoder, decoder.frameCount > 0 else { return nil }

        let fraction = Double(step) / Double(max(Self.steps - 1, 1))
        let index = Int(fraction * Double(decoder.frameCount - 1))
        guard let full = decoder.image(at: index, corruption: .inert) else { return nil }
        return full.scaled(toWidth: Self.width)
    }

    /// Forgets everything, so a changed file is re-read.
    public func invalidate() {
        lock.lock()
        cache.removeAll()
        failed.removeAll()
        lock.unlock()
    }
}

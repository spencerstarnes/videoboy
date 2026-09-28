//
//  ImageSequenceDecoder.swift — a folder of photographs, played as a clip.
//
//  Purpose : A folder of images becomes a source: frame 1 is the first picture, frame
//            2 the second, at 30fps. Drop a folder in and it behaves like footage.
//  Inputs  : a directory of image files.
//  Outputs : `ImageBuffer`s, through `ClipDecoding`.
//  Connects: ClipSourceNode (unchanged), the library's folder drop.
//  Extend  : another still format is a line in `imageExtensions`. Anything about
//            PLAYBACK — looping, in and out points, stepping on the beat — belongs in
//            ClipSourceNode, which already does all of it.
//
//  ── WHY THIS IS A DECODER AND NOT A NEW KIND OF SOURCE ──────────────────────────
//
//  Because everything that makes a clip a clip is already written. `ClipSourceNode`
//  owns playback, looping, in and out points, scrubbing, the shuttle, and stepping a
//  frame on the beat — and it asks its decoder exactly two questions: how many frames
//  are there, and what does frame N look like. A folder of photographs can answer both.
//
//  So "the step does the same thing it always does" is not a feature that had to be
//  built here. It is what happens automatically when a sequence enters through the same
//  door as a video file.
//
//  ── AND WHY IT CACHES THE WAY IT DOES ───────────────────────────────────────────
//
//  Decoding a JPEG is far more expensive than reading a video frame ahead, and at
//  30fps there is 33ms for everything. Decoding one per frame on the render path would
//  break the rule that outranks every feature in this app.
//
//  So: a bounded cache of decoded frames, and a PREFETCH that runs ahead on a utility
//  queue. The render path only ever reads the cache; if a frame is not there it returns
//  the last one it had rather than decoding synchronously. A repeated frame is a much
//  smaller problem than a dropped one.
//

import Foundation
import CoreGraphics
import ImageIO

/// A folder of images, played as frames.
public final class ImageSequenceDecoder: ClipDecoding {

    /// Extensions treated as frames.
    ///
    /// Deliberately the common ones only. A folder is recognised as a sequence by
    /// CONTAINING these, so a generous list would turn any folder with a stray icon in
    /// it into a one-frame movie.
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tif", "tiff", "heic", "bmp", "gif", "webp"
    ]

    /// The frames, in order.
    public let urls: [URL]

    /// Photographs have no frame rate of their own, so they are given one.
    ///
    /// 30 rather than the project's 29.97: a sequence is not telecined footage, it is a
    /// stack of pictures, and "one picture per frame at thirty a second" is what a
    /// person means. ClipSourceNode retimes it against the project rate exactly as it
    /// retimes a 25fps PAL clip.
    public let frameRate: Double

    /// Nothing to damage: these are decoded pictures, not a bitstream.
    public var dataEffectFamily: DataEffectFamily { .none }

    public var frameCount: Int { urls.count }

    /// How many decoded frames are held at once.
    ///
    /// Two seconds' worth. Enough that a prefetch running slightly behind still has
    /// somewhere to land, small enough that a thousand-image folder does not become a
    /// gigabyte of RGBA.
    private let cacheLimit = 64

    private let width: Int
    private let height: Int

    private let lock = NSLock()
    private var cache: [Int: ImageBuffer] = [:]
    /// Least-recently-used order, so the cache evicts the frame furthest behind.
    private var recentlyUsed: [Int] = []
    /// The last frame handed out, returned when the wanted one is not ready.
    private var lastDelivered: ImageBuffer?
    private var inFlight: Set<Int> = []

    private let prefetchQueue = DispatchQueue(
        label: "com.videoboy.image-sequence", qos: .utility, attributes: .concurrent)

    /// Opens a folder as a sequence.
    ///
    /// - Throws: when the folder holds no images, which is the one case where silence
    ///   would be indistinguishable from a broken decoder.
    public init(
        folder: URL,
        width: Int = StandardDefinition.width,
        height: Int = StandardDefinition.height,
        frameRate: Double = 30
    ) throws {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.urls = Self.frames(in: folder)

        guard !urls.isEmpty else {
            throw SequenceError.noImages(folder.lastPathComponent)
        }
        Log.info(.clip, "image sequence \(folder.lastPathComponent): "
            + "\(urls.count) frames at \(Int(frameRate))fps")

        // The first few, now, so the very first render has something. Synchronous on
        // purpose: this runs when a clip is LOADED, not while one is playing.
        for index in 0..<min(4, urls.count) {
            if let image = decode(index) { store(image, at: index) }
        }
    }

    /// Every image in a folder, in the order a person would expect.
    ///
    /// Sorted with `localizedStandardCompare`, which is the Finder's ordering: it puts
    /// `frame2` before `frame10`. A plain string sort puts `frame10` second and turns
    /// the sequence into nonsense, which is the classic way to get this wrong.
    public static func frames(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        return contents
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending }
    }

    /// Whether a folder looks like a sequence of photographs.
    ///
    /// Two or more images. One image is a still, not a sequence, and treating it as a
    /// one-frame clip would be a worse answer than leaving it alone.
    public static func isSequence(_ folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return frames(in: folder).count >= 2
    }

    // MARK: - Frames

    public func image(at index: Int, corruption: CorruptionSettings) -> ImageBuffer? {
        guard !urls.isEmpty else { return nil }
        let wanted = ((index % urls.count) + urls.count) % urls.count

        lock.lock()
        if let cached = cache[wanted] {
            touch(wanted)
            lastDelivered = cached
            lock.unlock()
            prefetch(from: wanted)
            return cached
        }
        // NOT READY. Hand back the last picture rather than decoding here — this is the
        // render path, and a JPEG decode on it is a dropped frame. A repeated frame is
        // a far smaller problem.
        let fallback = lastDelivered
        lock.unlock()

        prefetch(from: wanted)
        return fallback
    }

    /// Decodes ahead, off the render path.
    private func prefetch(from index: Int) {
        // Half the cache ahead. Enough to cover a stall, short enough that scrubbing
        // backwards does not spend its life decoding frames nobody asked for.
        let ahead = cacheLimit / 2
        for offset in 0..<ahead {
            let target = (index + offset) % urls.count

            lock.lock()
            let needed = cache[target] == nil && !inFlight.contains(target)
            if needed { inFlight.insert(target) }
            lock.unlock()
            guard needed else { continue }

            prefetchQueue.async { [weak self] in
                guard let self else { return }
                let image = self.decode(target)
                self.lock.lock()
                self.inFlight.remove(target)
                self.lock.unlock()
                if let image { self.store(image, at: target) }
            }
        }
    }

    private func store(_ image: ImageBuffer, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        cache[index] = image
        touch(index)
        while recentlyUsed.count > cacheLimit, let oldest = recentlyUsed.first {
            recentlyUsed.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    /// Marks a frame as just used. Caller holds the lock.
    private func touch(_ index: Int) {
        if let existing = recentlyUsed.firstIndex(of: index) {
            recentlyUsed.remove(at: existing)
        }
        recentlyUsed.append(index)
    }

    /// Reads one image and scales it into the project's geometry.
    private func decode(_ index: Int) -> ImageBuffer? {
        guard urls.indices.contains(index) else { return nil }
        let url = urls[index]

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            Log.warn(.clip, "could not read \(url.lastPathComponent)")
            return nil
        }
        // Thumbnail rather than full decode: these are photographs, often many
        // megapixels, and the graph is 720x480. Decoding a 48-megapixel frame to throw
        // 99% of it away is the difference between this playing and not.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary) else {
            Log.warn(.clip, "could not decode \(url.lastPathComponent)")
            return nil
        }
        return ImageBuffer(scaling: cgImage, toWidth: width, height: height)
    }

    public enum SequenceError: LocalizedError {
        case noImages(String)

        public var errorDescription: String? {
            switch self {
            case .noImages(let name):
                return "\(name) has no images in it. A photo folder needs at least two "
                    + "pictures to play as a sequence."
            }
        }
    }
}

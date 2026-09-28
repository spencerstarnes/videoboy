//
//  ClipThumbnails.swift — filmstrip frames for library thumbnails.
//
//  Purpose : FCP's library lets you run the pointer across a thumbnail and see the
//            clip move under it, which tells you what a file IS far faster than its
//            name does. That needs frames decoded at arbitrary positions, cheaply
//            enough to follow a pointer.
//  Inputs  : a media URL and a 0...1 position.
//  Outputs : a decoded `ImageBuffer`, scaled down to thumbnail size.
//  Connects: LibraryItemView (which hovers), ClipDecoders (the playback decoders).
//  Extend  : a new format needs nothing here — it arrives through ClipDecoders.
//
//  Decoding is OFF the main thread (`request`): posters decoded synchronously as tiles
//  appeared were what froze large imports (audit 09-26 R1). The cache is LRU-bounded.
//
//  On the cache: a fixed number of evenly spaced positions per clip rather than a
//  frame per pixel. A thumbnail is about 80 pixels wide and decoding 80 frames to
//  cross it would be both slow and pointless — the eye reads a filmstrip of a dozen
//  frames as motion perfectly well, and every position afterwards is free.
//

import Foundation

/// Decodes and caches a handful of frames per clip, for hover-scrubbing.
public final class ClipThumbnails {

    /// Shared cache. Thumbnails are the same wherever they are shown, and decoding
    /// them once per panel would mean three copies of every frame in the window.
    public static let shared = ClipThumbnails()

    /// How many positions are sampled across a clip.
    public static let steps = 12

    /// Thumbnail width; height follows the source's aspect.
    public static let width = 160

    private struct Key: Hashable {
        let path: String
        let step: Int
    }

    /// How much decoded thumbnail the cache may hold before the least recently used
    /// frames go. Unbounded, it grew with every clip ever hovered (audit 09-26 R2).
    public static let byteBudget = 64 * 1024 * 1024

    /// Frames are decoded at twice thumbnail size (the decoders scale in VideoToolbox
    /// or swscale, which is nearly free), then box-averaged down.
    private static let decodeCanvas = CanvasGeometry(width: width * 2, height: width * 3 / 2)

    // Guarded by `lock`.
    private var cache: [Key: ImageBuffer] = [:]
    private var recency: [Key] = []
    private var cachedBytes = 0
    /// Clips that could not be opened, so a broken file is not retried on every
    /// mouse move.
    private var failed: Set<String> = []
    private let lock = NSLock()

    /// Decoding happens here, never on the caller's thread. Decoders are touched
    /// only on this queue.
    private let queue = DispatchQueue(label: "videoboy.thumbnails", qos: .utility)
    /// The last few clips' decoders, so twelve hover steps open a file once, not
    /// twelve times. Touched only on `queue`.
    private var decoders: [(path: String, decoder: ClipDecoding)] = []
    private static let openDecoders = 3

    public init() {}

    private static func key(for url: URL, at position: Double) -> Key {
        let clamped = min(max(position, 0), 1)
        return Key(path: url.path, step: Int((clamped * Double(steps - 1)).rounded()))
    }

    /// The frame nearest a 0...1 position, or nil when the clip cannot be read.
    /// BLOCKS until it is decoded — for tests and self-QA. The interface uses
    /// `request`, which never makes the main thread wait.
    ///
    /// Positions are quantised to `steps`, so dragging across a thumbnail asks for
    /// the same handful of frames over and over and only decodes each once.
    public func frame(for url: URL, at position: Double) -> ImageBuffer? {
        let key = Self.key(for: url, at: position)
        if let cached = cachedFrame(key) { return cached }
        if isFailed(url) { return nil }
        return queue.sync { produce(url: url, key: key) }
    }

    /// The frame nearest a position, delivered on the main run loop — at once if it
    /// is cached, else once it has been decoded in the background. Nil when the clip
    /// cannot be read.
    public func request(for url: URL, at position: Double,
                        completion: @escaping (ImageBuffer?) -> Void) {
        let key = Self.key(for: url, at: position)
        if let cached = cachedFrame(key) { return completion(cached) }
        if isFailed(url) { return completion(nil) }
        queue.async { [weak self] in
            let image = self?.cachedFrame(key) ?? self?.produce(url: url, key: key)
            // Through the run loop rather than the main queue: the self-QA drives the
            // app from a nested `RunLoop.run`, which never drains a main-queue block.
            let main = CFRunLoopGetMain()
            CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
                autoreleasepool { completion(image) }
            }
            CFRunLoopWakeUp(main)
        }
    }

    /// The first frame, which is what a thumbnail shows when nothing is hovering it.
    public func poster(for url: URL) -> ImageBuffer? {
        frame(for: url, at: 0)
    }

    private func cachedFrame(_ key: Key) -> ImageBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let image = cache[key] else { return nil }
        if let position = recency.firstIndex(of: key) {
            recency.remove(at: position)
            recency.append(key)
        }
        return image
    }

    private func isFailed(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return failed.contains(url.path)
    }

    /// Decodes, caches and returns one thumbnail frame. Runs on `queue`.
    private func produce(url: URL, key: Key) -> ImageBuffer? {
        if let cached = cachedFrame(key) { return cached }
        guard let decoded = decode(url: url, step: key.step) else {
            lock.lock(); failed.insert(url.path); lock.unlock()
            Log.warn(.clip, "no thumbnail for \(url.lastPathComponent)")
            return nil
        }
        lock.lock()
        cache[key] = decoded
        recency.append(key)
        cachedBytes += decoded.pixels.count
        while cachedBytes > Self.byteBudget, !recency.isEmpty {
            let oldest = recency.removeFirst()
            cachedBytes -= cache.removeValue(forKey: oldest)?.pixels.count ?? 0
        }
        lock.unlock()
        return decoded
    }

    /// Runs on `queue`.
    private func decode(url: URL, step: Int) -> ImageBuffer? {
        // The same decoders the sources use, so a clip that thumbnails is a clip that
        // plays. A library that showed a picture for something the app then refused
        // to load would be the worst of both. (MPEG files through the MPEG decoder:
        // opening them in AVFoundation cost 90–140 ms a thumbnail.)
        let decoder: ClipDecoding
        if let open = decoders.first(where: { $0.path == url.path }) {
            decoder = open.decoder
        } else {
            guard let opened = ClipDecoders.open(url, canvas: Self.decodeCanvas) else { return nil }
            decoders.append((url.path, opened))
            if decoders.count > Self.openDecoders { decoders.removeFirst() }
            decoder = opened
        }
        guard decoder.frameCount > 0 else { return nil }

        let fraction = Double(step) / Double(max(Self.steps - 1, 1))
        let index = Int(fraction * Double(decoder.frameCount - 1))
        guard let full = decoder.image(at: index, corruption: .inert) else { return nil }
        return Self.upright(full, quarterTurns: decoder.quarterTurns).scaled(toWidth: Self.width)
    }

    /// A raster turned clockwise by quarter turns — a phone's portrait clip is stored
    /// landscape. Thumbnail-sized and off the main thread, so a plain loop is fine.
    private static func upright(_ image: ImageBuffer, quarterTurns: Int) -> ImageBuffer {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let (w, h) = (image.width, image.height)
        let outWidth = turns == 2 ? w : h
        let outHeight = turns == 2 ? h : w
        var out = [UInt8](repeating: 255, count: outWidth * outHeight * 4)
        image.pixels.withUnsafeBufferPointer { source in
            for y in 0..<outHeight {
                for x in 0..<outWidth {
                    // Display (x, y) samples the stored raster; see CanvasFit's shader.
                    let (sx, sy): (Int, Int)
                    switch turns {
                    case 1: (sx, sy) = (y, h - 1 - x)
                    case 2: (sx, sy) = (w - 1 - x, h - 1 - y)
                    default: (sx, sy) = (w - 1 - y, x)
                    }
                    let from = (sy * w + sx) * 4
                    let to = (y * outWidth + x) * 4
                    out[to] = source[from]; out[to + 1] = source[from + 1]
                    out[to + 2] = source[from + 2]; out[to + 3] = source[from + 3]
                }
            }
        }
        return ImageBuffer(width: outWidth, height: outHeight, pixels: out)
    }

    /// Forgets everything, so a changed file is re-read.
    public func invalidate() {
        queue.sync { decoders.removeAll() }
        lock.lock()
        cache.removeAll()
        recency.removeAll()
        cachedBytes = 0
        failed.removeAll()
        lock.unlock()
    }
}

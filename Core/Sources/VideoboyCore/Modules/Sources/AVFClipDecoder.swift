//
//  AVFClipDecoder.swift — ordinary video files, decoded to our own playhead.
//
//  Purpose : Everything AVFoundation can open — .mov, .mp4, ProRes, H.264, HEVC.
//            The MPEG wedge has its own decoder (MPEGStreamDecoder); this is for the
//            rest of the footage people actually have.
//  Inputs  : a media URL and a frame index.
//  Outputs : decoded RGBA frames.
//  Connects: ClipSourceNode, through `ClipDecoding`.
//  Extend  : nothing here knows about playback rules — loop modes, musical stepping
//            and in/out points all live in the node and work identically for every
//            decoder. Only decoding belongs here.
//
//  Why AVAssetReader and not AVPlayer: the app's playhead is authoritative. Frames
//  are shown because the render clock or the musical clock says so, and step playback
//  holds a frame for a whole beat. An AVPlayer runs on its own clock and would have
//  to be chased; a reader hands over frames when asked, which is the relationship we
//  want. The cost is that seeking backwards means restarting the reader, so recently
//  decoded frames are kept to make short steps and ping-pong turns free.
//

import Accelerate
import AVFoundation
import CoreVideo
import Foundation

/// Decodes an ordinary video file frame by frame.
public final class AVFClipDecoder: ClipDecoding {

    /// How many decoded frames are kept behind the playhead.
    ///
    /// Enough to cover a ping-pong turn and a handful of step-backs without a reader
    /// restart. Each is a full RGBA frame, so this is a real memory cost and not a
    /// number to raise casually — four channels of SD at 48 frames is about 66 MB.
    private static let cacheSize = 48

    /// How far ahead a requested frame can be before it is cheaper to restart the
    /// reader than to decode everything in between.
    private static let maximumForwardScan = 90

    /// How many frames a BACKWARD seek decodes in one go, so reverse playback pays for
    /// a reader restart once per block instead of once per frame.
    ///
    /// Comfortably under `cacheSize`, so a block cannot evict its own earlier frames
    /// before the playhead reaches them — that would put the restart-per-frame
    /// behaviour straight back. The rest of the cache stays available for the forward
    /// direction, which is what a ping-pong turn needs immediately afterwards.
    private static let backwardPrefetch = 24

    private let asset: AVAsset
    private let track: AVAssetTrack

    public let frameCount: Int
    public let frameRate: Double

    /// Ordinary video has no bitstream effects here. MPEG-family damage is a separate
    /// module (SPEC 5) and saying `.none` is what stops the interface offering
    /// controls that would do nothing.
    public var dataEffectFamily: DataEffectFamily { .none }

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// The frame index the reader will produce next.
    private var nextFrameIndex = 0

    private var cache: [Int: ImageBuffer] = [:]
    private var cacheOrder: [Int] = []

    /// Upright display shape, from the stored raster, its pixel aspect and rotation.
    public let displayAspectRatio: Double?
    /// Clockwise quarter turns from the stored raster to upright.
    public let quarterTurns: Int
    /// Upright pixel height of the file's own picture (Centre framing).
    public let nativeHeight: Int?
    /// The size frames are decoded at (stored orientation), or nil for the file's own.
    /// VideoToolbox scales during decode, which is nearly free; the alternative was
    /// copying 8 MB 1080p frames through the CPU and scaling them in the graph.
    private let decodeSize: (width: Int, height: Int)?
    /// Set for HEVC tagged `hev1`, which AVAssetReader will not decode (BUGHUNT S7):
    /// frames then come from VideoToolbox directly, through the same cache and seeks.
    private var hev1: HEV1Reader?

    /// Opens a clip, or fails if it has no readable video track.
    ///
    /// - Parameter canvas: when given, frames are decoded no larger than this canvas
    ///   needs (`CanvasGeometry.decodeSize`); nil decodes at the file's own size.
    public init?(url: URL, canvas: CanvasGeometry? = nil) {
        let asset = AVURLAsset(url: url)
        // Synchronous loading: this runs when a clip is loaded, not per frame, and
        // the source panel is waiting for a yes or no answer.
        guard let track = asset.tracks(withMediaType: .video).first else {
            Log.error(.clip, "\(url.lastPathComponent) has no video track")
            return nil
        }
        self.asset = asset
        self.track = track

        let rate = Double(track.nominalFrameRate)
        self.frameRate = rate > 0 ? rate : StandardDefinition.frameRate

        let duration = CMTimeGetSeconds(asset.duration)
        guard duration.isFinite, duration > 0 else {
            Log.error(.clip, "\(url.lastPathComponent) has no usable duration")
            return nil
        }
        self.frameCount = max(Int((duration * self.frameRate).rounded()), 1)

        // ORIENTATION AND SHAPE. The stored raster is what the reader hands back; the
        // track's transform says how to turn it upright, and its format description
        // may carry a pixel aspect ratio (anamorphic footage).
        let transform = track.preferredTransform
        let angle = atan2(Double(transform.b), Double(transform.a))
        let turns = ((Int((angle / (Double.pi / 2)).rounded()) % 4) + 4) % 4
        let stored = (width: Int(track.naturalSize.width), height: Int(track.naturalSize.height))
        var storedAspect = CanvasGeometry.displayAspect(width: stored.width, height: stored.height)
        if let description = track.formatDescriptions.first,
           let pixelAspect = CMFormatDescriptionGetExtension(
               description as! CMFormatDescription,
               extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Any],
           let horizontal = (pixelAspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? NSNumber)?.doubleValue,
           let vertical = (pixelAspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? NSNumber)?.doubleValue,
           horizontal > 0, vertical > 0, abs(horizontal - vertical) > 0.001, stored.height > 0 {
            storedAspect = Double(stored.width) * horizontal / (Double(stored.height) * vertical)
        }
        let uprightAspect = turns % 2 == 1 ? 1 / storedAspect : storedAspect
        self.quarterTurns = turns
        self.displayAspectRatio = uprightAspect
        self.nativeHeight = turns % 2 == 1 ? stored.width : stored.height

        if let canvas, stored.width > 0, stored.height > 0 {
            let uprightNative = turns % 2 == 1 ? (stored.height, stored.width) : (stored.width, stored.height)
            let upright = canvas.decodeSize(sourceAspect: uprightAspect, nativeSize: uprightNative)
            let size = turns % 2 == 1 ? (width: upright.height, height: upright.width) : (width: upright.width, height: upright.height)
            // Only ever smaller: decoding larger than the file adds nothing.
            self.decodeSize = (size.width < stored.width || size.height < stored.height) ? size : nil
        } else {
            self.decodeSize = nil
        }

        Log.info(.clip, "opened \(url.lastPathComponent): \(frameCount) frames at "
            + String(format: "%.2f", self.frameRate) + " fps, "
            + "\(Int(track.naturalSize.width))x\(Int(track.naturalSize.height))"
            + (decodeSize.map { ", decoded at \($0.width)x\($0.height)" } ?? "")
            + (quarterTurns != 0 ? ", turned \(quarterTurns * 90)°" : ""))

        if HEV1Reader.applies(to: track) {
            guard let direct = HEV1Reader(asset: asset, track: track, frameRate: frameRate,
                                          decodeSize: decodeSize) else {
                Log.error(.clip, "\(url.lastPathComponent) is HEVC tagged hev1 and could not be decoded")
                return nil
            }
            Log.info(.clip, "\(url.lastPathComponent) is HEVC tagged hev1: decoding through VideoToolbox directly")
            self.hev1 = direct
        }

        guard restartReader(atFrame: 0) else { return nil }
    }

    public func image(at index: Int, corruption: CorruptionSettings) -> ImageBuffer? {
        // Corruption is deliberately ignored: this family is `.none`, so nothing
        // should be asking. Silently ignoring it is right — the alternative is
        // failing a render because a control that is not offered was set anyway.
        let wrapped = wrappedIndex(index)

        if let cached = cache[wrapped] { return cached }

        // Backwards, or a long way forward: start again at the right place. Reading
        // a thousand frames to reach one is slower than a seek, and seeking to reach
        // the very next frame is slower than reading it.
        if wrapped < nextFrameIndex || wrapped > nextFrameIndex + Self.maximumForwardScan {
            // A BACKWARD SEEK STARTS A BLOCK EARLY, so one restart serves many frames.
            //
            // Restarting exactly at `wrapped` was pathological in reverse. The restart
            // sets `nextFrameIndex = wrapped`, one frame is decoded, and it becomes
            // `wrapped + 1` — so the NEXT frame backwards is again `< nextFrameIndex`
            // and restarts again. One whole `AVAssetReader` construction per displayed
            // frame, for the entire backward half of a ping-pong.
            //
            // And each restart is far worse than it looks: `timeRange` starts at an
            // arbitrary frame, not a keyframe, so the reader decodes from the preceding
            // keyframe to get there — on H.264 with a two-second GOP that is ~60
            // decodes to show one frame.
            //
            // Starting the block early means the walk below decodes forward THROUGH the
            // wanted frame and stores everything on the way, so the frames the playhead
            // is about to ask for are already cached. The keyframe seek dominates the
            // cost either way, so this is roughly the price of one restart in place of
            // `backwardPrefetch` of them.
            let isBackwardSeek = wrapped < nextFrameIndex
            let start = isBackwardSeek
                ? max(0, wrapped - Self.backwardPrefetch + 1)
                : wrapped
            guard restartReader(atFrame: start) else { return nil }
        }

        while nextFrameIndex <= wrapped {
            guard let frame = readNextFrame() else {
                // The reader ran dry before reaching the frame — a truncated file, or
                // a frame count that over-estimated. Restart from the wanted frame
                // once; if that fails too, give up rather than spin.
                guard restartReader(atFrame: wrapped), let frame = readNextFrame() else {
                    return cache[wrapped]
                }
                store(frame, at: wrapped)
                return frame
            }
            store(frame, at: nextFrameIndex - 1)
        }
        return cache[wrapped]
    }

    /// Wraps an index into the clip.
    public func wrappedIndex(_ index: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let remainder = index % frameCount
        return remainder < 0 ? remainder + frameCount : remainder
    }

    // MARK: - Reading

    /// How many times a reader has been rebuilt. Instrumentation: reverse playback used
    /// to do this once per displayed frame, and a count is the only way to show it does
    /// not any more — the symptom is a dropped frame, which a unit test cannot see.
    private(set) var readerRestarts = 0

    private func restartReader(atFrame index: Int) -> Bool {
        readerRestarts += 1
        if let hev1 {
            guard hev1.start(atSeconds: Double(index) / frameRate) else { return false }
            nextFrameIndex = index
            return true
        }
        reader?.cancelReading()

        guard let newReader = try? AVAssetReader(asset: asset) else {
            Log.error(.clip, "could not create a reader for \(asset)")
            return false
        }
        // BGRA because that is what Metal and ImageBuffer both want; letting
        // AVFoundation convert is faster and more correct than doing it here.
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        if let decodeSize {
            settings[kCVPixelBufferWidthKey as String] = decodeSize.width
            settings[kCVPixelBufferHeightKey as String] = decodeSize.height
        }
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        trackOutput.alwaysCopiesSampleData = false
        guard newReader.canAdd(trackOutput) else { return false }
        newReader.add(trackOutput)

        if index > 0 {
            let start = CMTime(seconds: Double(index) / frameRate, preferredTimescale: 600)
            newReader.timeRange = CMTimeRange(start: start, duration: .positiveInfinity)
        }
        guard newReader.startReading() else {
            Log.error(.clip, "reader refused to start: \(newReader.error?.localizedDescription ?? "unknown")")
            return false
        }

        reader = newReader
        output = trackOutput
        nextFrameIndex = index
        return true
    }

    private func readNextFrame() -> ImageBuffer? {
        if let hev1 {
            guard let frame = hev1.next() else { return nil }
            nextFrameIndex = frame.index + 1
            return Self.imageBuffer(from: frame.image)
        }
        guard let output, let sample = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        nextFrameIndex += 1
        return Self.imageBuffer(from: pixelBuffer)
    }

    /// Copies a BGRA pixel buffer into an RGBA `ImageBuffer`.
    ///
    /// One vImage permute (SIMD) rather than a per-pixel Swift loop: the loop cost
    /// ~5 ms on a 1080p frame, on the main thread, every frame (audit F3).
    private static func imageBuffer(from pixelBuffer: CVPixelBuffer) -> ImageBuffer? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer), width > 0, height > 0
        else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let result: vImage_Error = pixels.withUnsafeMutableBytes { destination in
            var source = vImage_Buffer(
                data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
            var target = vImage_Buffer(
                data: destination.baseAddress, height: vImagePixelCount(height),
                width: vImagePixelCount(width), rowBytes: width * 4)
            // BGRA → RGBA: output channel i takes input channel map[i].
            let map: [UInt8] = [2, 1, 0, 3]
            return vImagePermuteChannels_ARGB8888(&source, &target, map, vImage_Flags(kvImageNoFlags))
        }
        guard result == kvImageNoError else {
            Log.error(.clip, "vImage could not convert a decoded frame (\(result))")
            return nil
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }

    private func store(_ frame: ImageBuffer, at index: Int) {
        // ONE ENTRY PER INDEX. `cacheOrder` is the eviction queue and it only works if
        // it corresponds one-to-one with the keys in `cache`. Appending unconditionally
        // meant re-storing a frame — which ping-pong and stepped playback do constantly,
        // because they revisit the same indices — pushed a DUPLICATE. The queue then hit
        // its cap while holding far fewer than `cacheSize` distinct frames, and evicting
        // the first copy deleted a frame the second copy still claimed was cached.
        //
        // The effect was a cache that quietly shrank toward useless exactly when it was
        // needed most, and every miss it caused is a reader restart on the render thread.
        if cache[index] == nil {
            cacheOrder.append(index)
        }
        cache[index] = frame
        while cacheOrder.count > Self.cacheSize {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}

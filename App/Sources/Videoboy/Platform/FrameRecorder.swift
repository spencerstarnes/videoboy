//
//  FrameRecorder.swift — writes a feed to a ProRes file.
//
//  Purpose : The record button and the arming dots have worked since Phase 2 with
//            nothing behind them. This is the encoder: one recorder per armed feed,
//            so PROGRAM and the four sources can be captured discretely (SPEC 15) and
//            cut together afterwards rather than only as a finished mix.
//  Inputs  : `ImageBuffer` frames, pushed once per rendered frame.
//  Outputs : a .mov per feed, in the save location from preferences.
//  Connects: RecordingSession (which owns one of these per feed), ShellController.
//  Extend  : another codec is another `AVVideoCodecType` in `Codec`. Do NOT add a
//            second writer path — AVAssetWriter handles every codec macOS can encode,
//            and a parallel libav path would be two sets of timing bugs.
//
//  ProRes rather than H.264: this is a capture of a performance, meant to be edited.
//  Re-encoding the output of a chain built to preserve a specific texture through
//  a lossy codec would throw away the thing the app exists to produce.
//

import AVFoundation
import Foundation
import VideoboyCore

/// Writes frames from one feed to one file.
final class FrameRecorder {

    /// What to encode with. The names match the toolbar's popup.
    /// What a recording is written as.
    ///
    /// ── WHY BOTH KINDS ARE HERE ─────────────────────────────────────────────────
    ///
    /// ProRes is an INTERMEDIATE codec: every frame is whole, it survives being cut
    /// and re-graded, and it is what you want if the recording is going into an edit.
    /// It is also enormous — SD ProRes 422 runs around 40 Mbit/s, so an hour is about
    /// 18GB.
    ///
    /// H.264 and HEVC are DELIVERY codecs: an order of magnitude smaller, because they
    /// describe most frames as differences from their neighbours. That makes them the
    /// right answer for "record the set so I can watch it back" or "put this online",
    /// and the wrong answer for anything that will be cut up afterwards.
    ///
    /// Both belong here because this app is used for both, and picking for someone is
    /// how you end up with a 40GB file they wanted to text to a friend.
    enum Codec: String, CaseIterable {
        case proRes422 = "ProRes 422"
        case proRes422HQ = "ProRes HQ"
        case appleProRes4444 = "ProRes 4444"
        case h264 = "H.264"
        case hevc = "HEVC"

        var videoCodecType: AVVideoCodecType {
            switch self {
            case .proRes422: .proRes422
            case .proRes422HQ: .proRes422HQ
            case .appleProRes4444: .proRes4444
            case .h264: .h264
            case .hevc: .hevc
            }
        }

        /// Whether this one needs a bitrate. ProRes sets its own by quality tier.
        var isCompressed: Bool {
            self == .h264 || self == .hevc
        }

        /// Bits per second at standard definition.
        ///
        /// Generous for SD on purpose. The pictures this app makes are full of exactly
        /// what a delivery codec handles worst — noise, chroma bleed, whole-frame
        /// changes on the beat, and deliberate bitstream corruption — so a bitrate
        /// chosen for ordinary footage would smear the very thing being recorded.
        /// HEVC gets less for the same result because it is roughly that much better.
        var bitRate: Int {
            switch self {
            case .h264: 12_000_000
            case .hevc: 8_000_000
            default: 0
            }
        }

        /// One line for the tooltip, so the choice can be made without knowing codecs.
        var explanation: String {
            switch self {
            case .proRes422: "Edit-ready, large. About 18GB an hour."
            case .proRes422HQ: "Edit-ready, larger, more headroom for grading."
            case .appleProRes4444: "Edit-ready, largest, keeps everything."
            case .h264: "Compressed and small — for watching back and sharing. "
                + "About 5GB an hour. Plays anywhere."
            case .hevc: "Compressed and smaller still, same picture. "
                + "About 3.5GB an hour. Needs a recent machine to play."
            }
        }
    }

    /// Where this recording is being written.
    let url: URL
    /// Frames written so far, for the status readout.
    private(set) var frameCount: Int64 = 0

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frameDuration: CMTime
    private var hasStarted = false
    private var hasFailed = false

    /// The writer settings for a codec.
    ///
    /// Separate from `init` so it can be read and tested on its own — a wrong bitrate
    /// or a stray B-frame is invisible until someone plays a recording back, which is
    /// far too late to find out.
    static func settings(codec: Codec, width: Int, height: Int) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.videoCodecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        guard codec.isCompressed else { return settings }

        settings[AVVideoCompressionPropertiesKey] = [
            AVVideoAverageBitRateKey: codec.bitRate,
            // NO FRAME REORDERING. B-frames buy a little efficiency by describing a
            // frame from the one AFTER it, which means holding frames back before
            // writing them. For a live recording that costs latency and makes the file
            // awkward to scrub; for a performance nobody will thank you for the 8%.
            AVVideoAllowFrameReorderingKey: false,
            // A keyframe every second, so scrubbing lands somewhere sensible rather
            // than decoding half a minute to reach a point.
            AVVideoMaxKeyFrameIntervalKey: 30
        ] as [String: Any]
        return settings
    }

    /// Opens a file and gets the writer ready.
    ///
    /// - Throws: if the file cannot be created. A recording that cannot start must
    ///   say so at the moment record is pressed, not silently produce nothing.
    init(
        url: URL,
        codec: Codec,
        width: Int = StandardDefinition.width,
        height: Int = StandardDefinition.height,
        frameRate: Double = StandardDefinition.frameRate
    ) throws {
        self.url = url
        // A stale file at the same path would be appended to rather than replaced,
        // which is how a recording ends up containing a previous take.
        try? FileManager.default.removeItem(at: url)

        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: FrameRecorder.settings(
                codec: codec, width: width, height: height)
        )
        // Frames arrive from the render loop as it produces them, which is as close
        // to real time as this gets.
        input.expectsMediaDataInRealTime = true

        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        guard writer.canAdd(input) else {
            throw NSError(
                domain: "Videoboy", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "the writer would not accept a \(codec.rawValue) video input"])
        }
        writer.add(input)

        // 1001/30000 for 29.97, as a ratio rather than a decimal — NTSC's rate is a
        // ratio and rounding it is how a long recording drifts out of sync.
        frameDuration = CMTime(
            value: 1001, timescale: CMTimeScale((frameRate * 1001).rounded()))

        guard writer.startWriting() else {
            throw writer.error ?? NSError(
                domain: "Videoboy", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "the writer refused to start"])
        }
        writer.startSession(atSourceTime: .zero)
        hasStarted = true
        Log.info(.app, "recording to \(url.lastPathComponent) as \(codec.rawValue)")
    }

    /// Writes one frame.
    ///
    /// - Returns: false when the frame was dropped, either because the writer is not
    ///   ready or because it has failed. Dropping rather than blocking is deliberate:
    ///   the render loop must not stall waiting on a disk.
    @discardableResult
    func write(_ image: ImageBuffer) -> Bool {
        guard hasStarted, !hasFailed else { return false }
        guard writer.status == .writing else {
            if writer.status == .failed {
                hasFailed = true
                Log.error(.app, "recording to \(url.lastPathComponent) failed: "
                    + "\(writer.error?.localizedDescription ?? "unknown")")
            }
            return false
        }
        guard input.isReadyForMoreMediaData else { return false }
        guard let pool = adaptor.pixelBufferPool else { return false }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return false }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }

        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destination = base.assumingMemoryBound(to: UInt8.self)
        let width = min(image.width, CVPixelBufferGetWidth(pixelBuffer))
        let height = min(image.height, CVPixelBufferGetHeight(pixelBuffer))

        image.pixels.withUnsafeBufferPointer { source in
            for y in 0..<height {
                let sourceRow = y * image.bytesPerRow
                let destinationRow = y * stride
                for x in 0..<width {
                    let from = sourceRow + x * 4
                    let to = destinationRow + x * 4
                    // RGBA in, BGRA out.
                    destination[to] = source[from + 2]
                    destination[to + 1] = source[from + 1]
                    destination[to + 2] = source[from]
                    destination[to + 3] = source[from + 3]
                }
            }
        }

        let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameCount))
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            Log.warn(.app, "a frame was refused by \(url.lastPathComponent)")
            return false
        }
        frameCount += 1
        return true
    }

    /// Finishes the file and calls back when it is safe to open.
    ///
    /// Asynchronous because AVAssetWriter is: returning before the moov atom is
    /// written would hand back a file that cannot be opened.
    func finish(completion: @escaping (URL?) -> Void) {
        guard hasStarted, writer.status == .writing else {
            completion(nil)
            return
        }
        input.markAsFinished()
        let url = self.url
        let frames = frameCount
        writer.finishWriting {
            Log.info(.app, "wrote \(frames) frames to \(url.lastPathComponent)")
            completion(url)
        }
    }
}

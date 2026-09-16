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
    enum Codec: String, CaseIterable {
        case proRes422 = "ProRes 422"
        case proRes422HQ = "ProRes HQ"
        case appleProRes4444 = "ProRes 4444"

        var videoCodecType: AVVideoCodecType {
            switch self {
            case .proRes422: .proRes422
            case .proRes422HQ: .proRes422HQ
            case .appleProRes4444: .proRes4444
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
            outputSettings: [
                AVVideoCodecKey: codec.videoCodecType,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
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

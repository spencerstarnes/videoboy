//
//  HEV1Reader.swift — HEVC tagged `hev1`, decoded through VideoToolbox directly.
//
//  Purpose : AVAssetReader refuses to DECODE HEVC whose sample description is tagged
//            `hev1` ("Cannot Decode", -12906), while the identical stream tagged
//            `hvc1` plays (BUGHUNT S7). `hev1` is legal and common — ffmpeg's
//            hevc_videotoolbox writes it, and so do some cameras. The reader will
//            still DEMUX it (passthrough), and VideoToolbox decodes the samples once
//            their format description is re-made with the `hvc1` codec type and the
//            same extensions (the hvcC parameter sets). That is what this does.
//  Inputs  : an asset's video track, a start time, a decode size.
//  Outputs : BGRA pixel buffers in display order, each with its frame index.
//  Connects: AVFClipDecoder, which uses this in place of its decoding track output
//            when the track is `hev1`. Everything above (cache, seeks, loop) is shared.
//  Extend  : a stream whose parameter sets live only in-band (not in hvcC) will fail
//            the session create here and the clip is refused with a logged reason.
//
//  THREADING: used only from the owning decoder's queue, like the decoder itself.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Demuxes a `hev1` track and decodes it with a VideoToolbox session.
final class HEV1Reader {

    /// The four-character code this reader exists for.
    static let hev1: FourCharCode = 0x6865_7631 // 'hev1'

    /// Frames held back so B-frame reordering comes out in display order. Passthrough
    /// samples arrive in decode order; VideoToolbox without temporal processing hands
    /// them back in the same order, so the earliest of a few is always the next one.
    private static let reorderDepth = 4

    private let asset: AVAsset
    private let track: AVAssetTrack
    private let frameRate: Double
    private let retagged: CMVideoFormatDescription
    private let session: VTDecompressionSession
    private let trackStart: Double

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var pending: [(time: Double, image: CVPixelBuffer)] = []
    private var ended = false
    /// Frames earlier than this belong to the GOP lead-in before a seek; decoded for
    /// reference, never shown.
    private var startTime = 0.0

    /// True when `track` is HEVC tagged `hev1`.
    static func applies(to track: AVAssetTrack) -> Bool {
        guard let first = track.formatDescriptions.first else { return false }
        return CMFormatDescriptionGetMediaSubType(first as! CMFormatDescription) == hev1
    }

    /// Makes the retagged description and the session, or nil (logged) if VideoToolbox
    /// will not take them either.
    init?(asset: AVAsset, track: AVAssetTrack, frameRate: Double,
          decodeSize: (width: Int, height: Int)?) {
        guard let first = track.formatDescriptions.first else { return nil }
        let original = first as! CMFormatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(original)
        var description: CMVideoFormatDescription?
        let made = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_HEVC,
            width: dimensions.width, height: dimensions.height,
            extensions: CMFormatDescriptionGetExtensions(original),
            formatDescriptionOut: &description)
        guard made == noErr, let description else {
            Log.error(.dv, "hev1: could not re-make the format description (\(made))")
            return nil
        }

        var attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        if let decodeSize {
            attributes[kCVPixelBufferWidthKey as String] = decodeSize.width
            attributes[kCVPixelBufferHeightKey as String] = decodeSize.height
        }
        var session: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: description, decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &session)
        guard created == noErr, let session else {
            Log.error(.dv, "hev1: VideoToolbox refused the stream (\(created)); "
                + "its parameter sets may be in-band only")
            return nil
        }
        self.asset = asset
        self.track = track
        self.frameRate = frameRate
        self.retagged = description
        self.session = session
        self.trackStart = CMTimeGetSeconds(track.timeRange.start)
    }

    deinit {
        reader?.cancelReading()
        VTDecompressionSessionInvalidate(session)
    }

    /// Starts reading at `seconds` into the track. The reader begins at the keyframe
    /// before it; frames before `seconds` are decoded and dropped.
    func start(atSeconds seconds: Double) -> Bool {
        reader?.cancelReading()
        pending.removeAll()
        ended = false
        startTime = trackStart + seconds

        guard let newReader = try? AVAssetReader(asset: asset) else {
            Log.error(.dv, "hev1: could not create a reader")
            return false
        }
        let passthrough = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        passthrough.alwaysCopiesSampleData = false
        guard newReader.canAdd(passthrough) else { return false }
        newReader.add(passthrough)
        if seconds > 0 {
            newReader.timeRange = CMTimeRange(
                start: CMTime(seconds: startTime, preferredTimescale: 600), duration: .positiveInfinity)
        }
        guard newReader.startReading() else {
            Log.error(.dv, "hev1: reader refused to start: \(newReader.error?.localizedDescription ?? "unknown")")
            return false
        }
        reader = newReader
        output = passthrough
        return true
    }

    /// The next frame in display order and its index in the clip, or nil at the end.
    func next() -> (index: Int, image: CVPixelBuffer)? {
        let halfFrame = 0.5 / frameRate
        while true {
            while pending.count <= Self.reorderDepth, !ended {
                decodeNextSample()
            }
            guard let earliest = pending.indices.min(by: { pending[$0].time < pending[$1].time })
            else { return nil }
            let frame = pending.remove(at: earliest)
            if frame.time < startTime - halfFrame { continue }
            let index = Int(((frame.time - trackStart) * frameRate).rounded())
            return (index, frame.image)
        }
    }

    /// Reads one sample and decodes it (synchronously) into `pending`.
    private func decodeNextSample() {
        guard let output, let sample = output.copyNextSampleBuffer() else {
            ended = true
            return
        }
        let count = CMSampleBufferGetNumSamples(sample)
        guard count > 0, let data = CMSampleBufferGetDataBuffer(sample) else { return }

        // Same bytes and timing, re-described as `hvc1`.
        var timingCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil,
                                               entriesNeededOut: &timingCount)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: timingCount)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: timingCount,
                                               arrayToFill: &timing, entriesNeededOut: nil)
        var sizeCount = 0
        CMSampleBufferGetSampleSizeArray(sample, entryCount: 0, arrayToFill: nil,
                                         entriesNeededOut: &sizeCount)
        var sizes = [Int](repeating: 0, count: sizeCount)
        CMSampleBufferGetSampleSizeArray(sample, entryCount: sizeCount,
                                         arrayToFill: &sizes, entriesNeededOut: nil)
        var rewrapped: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: data, formatDescription: retagged,
            sampleCount: count, sampleTimingEntryCount: timingCount, sampleTimingArray: &timing,
            sampleSizeEntryCount: sizeCount, sampleSizeArray: &sizes, sampleBufferOut: &rewrapped)
        guard status == noErr, let rewrapped else {
            Log.error(.dv, "hev1: could not re-wrap a sample (\(status))")
            return
        }

        let decoded = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: rewrapped, flags: [], infoFlagsOut: nil
        ) { [weak self] result, _, image, time, _ in
            guard result == noErr, let image else { return }
            self?.pending.append((CMTimeGetSeconds(time), image))
        }
        // Belt and braces: without the asynchronous flag the handler has already run.
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if decoded != noErr {
            Log.error(.dv, "hev1: a frame did not decode (\(decoded))")
        }
    }
}

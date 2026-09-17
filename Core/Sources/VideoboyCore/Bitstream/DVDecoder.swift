//
//  DVDecoder.swift — decodes DV frames to RGBA using the vendored LGPL libav.
//
//  Purpose : AVFoundation dropped DV at macOS 10.15 (SPEC 5), so decoding goes
//            through libavcodec. This wraps the C API in something Swift can use
//            safely, and — importantly — decodes *whatever bytes it is handed*,
//            including deliberately corrupted ones.
//  Inputs  : DV frame bytes (usually straight from DIFCorruptor).
//  Outputs : an `ImageBuffer`, ready to upload to Metal or assert on.
//  Connects: CFFmpeg (the C shim), DVReader and DIFCorruptor upstream, the render
//            graph downstream.
//  Extend  : MPEG decoding follows the identical shape — a different codec ID and
//            a real parser. Keep it a separate type rather than adding a mode here.
//
//  Error handling note: libav reports a damaged frame by returning an error *and*
//  often still filling the picture. That is precisely the behaviour the wedge wants,
//  so a decode error is logged at info level and the picture is used anyway.
//

import Foundation
import CFFmpeg

/// Decodes DV frames with libavcodec.
public final class DVDecoder {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var scaler: UnsafeMutablePointer<SwsContext>?
    private var scalerWidth: Int32 = 0
    private var scalerHeight: Int32 = 0

    /// Frames decoded since this decoder was created, for the debug overlay.
    private(set) public var decodedFrameCount = 0
    /// Frames libav reported an error on. Expected to be non-zero once corruption is
    /// switched on; that is the point.
    private(set) public var damagedFrameCount = 0

    /// Why a decoder could not be created.
    public enum DecoderError: Error, CustomStringConvertible {
        case codecUnavailable
        case contextAllocationFailed
        case contextOpenFailed(Int32)
        case allocationFailed(String)

        public var description: String {
            switch self {
            case .codecUnavailable:
                "the DV decoder is missing from the vendored libavcodec — rebuild with scripts/build-ffmpeg.sh"
            case .contextAllocationFailed: "could not allocate an AVCodecContext"
            case .contextOpenFailed(let code): "avcodec_open2 failed with code \(code)"
            case .allocationFailed(let what): "could not allocate \(what)"
            }
        }
    }

    /// Creates a DV decoder.
    public init() throws {
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_DVVIDEO) else {
            throw DecoderError.codecUnavailable
        }
        guard let context = avcodec_alloc_context3(codec) else {
            throw DecoderError.contextAllocationFailed
        }
        self.codecContext = context

        // Ask libav to keep going through damaged data rather than bailing out.
        // Without these the corruptor's output would frequently decode to nothing.
        context.pointee.flags |= AV_CODEC_FLAG_OUTPUT_CORRUPT
        context.pointee.flags2 |= AV_CODEC_FLAG2_SHOW_ALL
        context.pointee.err_recognition = 0

        let openResult = avcodec_open2(context, codec, nil)
        guard openResult >= 0 else {
            throw DecoderError.contextOpenFailed(openResult)
        }

        guard let frame = av_frame_alloc() else { throw DecoderError.allocationFailed("AVFrame") }
        self.frame = frame
        guard let packet = av_packet_alloc() else { throw DecoderError.allocationFailed("AVPacket") }
        self.packet = packet

        Log.info(.dv, "DV decoder ready (libavcodec \(String(cString: av_version_info())))")
    }

    deinit {
        if let scaler { sws_freeContext(scaler) }
        if packet != nil { av_packet_free(&packet) }
        if frame != nil { av_frame_free(&frame) }
        if codecContext != nil { avcodec_free_context(&codecContext) }
    }

    /// Decodes one DV frame to RGBA.
    ///
    /// - Parameter bytes: a complete DV frame, possibly corrupted.
    /// - Returns: the decoded picture, or nil only when libav produced no picture at
    ///   all. A *damaged* picture is returned, not discarded.
    public func decode(frameBytes bytes: [UInt8]) -> ImageBuffer? {
        guard let codecContext, let frame, let packet else { return nil }

        // av_packet_from_data wants a buffer it can own; giving libav a pointer into
        // a Swift array would be a use-after-free the moment this function returns.
        // Copying into an av_malloc'd buffer with the required padding is the
        // supported way to do this.
        let paddedSize = bytes.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let buffer = av_malloc(paddedSize) else {
            Log.error(.dv, "could not allocate a \(paddedSize)-byte packet buffer")
            return nil
        }
        // Copied straight out of `bytes`. This used to copy the whole frame into a
        // `var mutableBytes` first and then copy THAT into the libav buffer — 120KB
        // of DV per frame, copied twice, for a local that was never mutated.
        bytes.withUnsafeBytes { raw in
            _ = memcpy(buffer, raw.baseAddress!, bytes.count)
        }
        // libav reads past the end of a packet when parsing; the padding must be zero.
        memset(buffer.advanced(by: bytes.count), 0, Int(AV_INPUT_BUFFER_PADDING_SIZE))

        av_packet_unref(packet)
        let attachResult = av_packet_from_data(
            packet, buffer.assumingMemoryBound(to: UInt8.self), Int32(bytes.count)
        )
        guard attachResult >= 0 else {
            av_free(buffer)
            Log.error(.dv, "av_packet_from_data failed with code \(attachResult)")
            return nil
        }

        let sendResult = avcodec_send_packet(codecContext, packet)
        if sendResult < 0 {
            // Expected once corruption is on; the decoder often still produces a
            // picture, so this is information, not an error.
            damagedFrameCount += 1
            Log.info(.dv, "decoder reported damage on send (code \(sendResult)); continuing")
        }

        let receiveResult = avcodec_receive_frame(codecContext, frame)
        guard receiveResult >= 0 else {
            av_packet_unref(packet)
            Log.warn(.dv, "no picture from this frame (code \(receiveResult))")
            return nil
        }

        decodedFrameCount += 1
        let image = convertToRGBA(frame)
        av_packet_unref(packet)
        return image
    }

    /// Converts libav's planar YUV output into packed RGBA via swscale.
    ///
    /// DV is yuv411p on NTSC, which nothing downstream wants to deal with, so the
    /// conversion happens once here at the boundary.
    private func convertToRGBA(_ frame: UnsafeMutablePointer<AVFrame>) -> ImageBuffer? {
        let width = frame.pointee.width
        let height = frame.pointee.height
        guard width > 0, height > 0 else {
            Log.error(.dv, "decoded frame has no dimensions")
            return nil
        }

        // Rebuild the scaler only when the geometry changes, not per frame.
        if scaler == nil || scalerWidth != width || scalerHeight != height {
            if let scaler { sws_freeContext(scaler) }
            scaler = sws_getContext(
                width, height, AVPixelFormat(rawValue: frame.pointee.format),
                width, height, AV_PIX_FMT_RGBA,
                Int32(SWS_BILINEAR.rawValue), nil, nil, nil
            )
            scalerWidth = width
            scalerHeight = height
            guard scaler != nil else {
                Log.error(.dv, "could not create a swscale context for \(width)x\(height)")
                return nil
            }
        }

        let bytesPerRow = Int(width) * ImageBuffer.bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * Int(height))

        pixels.withUnsafeMutableBytes { raw in
            var destinationData: [UnsafeMutablePointer<UInt8>?] = [
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self), nil, nil, nil
            ]
            var destinationStride: [Int32] = [Int32(bytesPerRow), 0, 0, 0]
            // libav's `data` is a tuple of mutable pointers but sws_scale takes
            // immutable ones, so the planes are rebound to a plain array first.
            var sourcePlanes: [UnsafePointer<UInt8>?] = [
                UnsafePointer(frame.pointee.data.0),
                UnsafePointer(frame.pointee.data.1),
                UnsafePointer(frame.pointee.data.2),
                UnsafePointer(frame.pointee.data.3)
            ]
            var sourceStride: [Int32] = [
                frame.pointee.linesize.0,
                frame.pointee.linesize.1,
                frame.pointee.linesize.2,
                frame.pointee.linesize.3
            ]
            _ = sws_scale(
                scaler,
                &sourcePlanes, &sourceStride,
                0, height,
                &destinationData, &destinationStride
            )
        }

        return ImageBuffer(width: Int(width), height: Int(height), pixels: pixels)
    }
}

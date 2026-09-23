//
//  H264MoshDecoder.swift — decodes a moshed H.264 stream with libavcodec.
//
//  Purpose : The look of a datamosh is the look of a TOLERANT decoder: one that,
//            handed a P-frame whose reference is the wrong picture, decodes it
//            anyway. libavcodec's H.264 decoder is that decoder — it is what VLC and
//            ffplay use, which is why moshed files are traditionally watched there
//            and not in QuickTime. Apple's hardware decoder is stricter and tends to
//            reject the stream instead, so it is not used here.
//  Inputs  : `H264AccessUnit`s from MoshEngine, in decode order.
//  Outputs : RGBA `ImageBuffer`s, one per picture.
//  Connects: CFFmpeg (the vendored LGPL libav; the native h264 decoder is LGPL,
//            only the x264 ENCODER is GPL and it is not built), DatamoshNode.
//  Extend  : a GPU colour conversion (upload Y/U/V planes, convert in a shader) is
//            the next step if the swscale pass ever shows up in a profile.
//

import Foundation
import CFFmpeg

/// libavcodec's H.264 decoder, configured to keep going through anything.
public final class H264MoshDecoder {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var scaler: UnsafeMutablePointer<SwsContext>?
    private var scalerWidth: Int32 = 0
    private var scalerHeight: Int32 = 0
    private var scalerFormat: Int32 = -1
    /// The colour matrix and range the scaler was set up for; a stream that changes
    /// either gets a new setup rather than quietly wrong colours.
    private var scalerColour: (space: UInt32, range: UInt32) = (UInt32.max, UInt32.max)

    public private(set) var decodedFrameCount = 0
    /// Pictures libav complained about. Expected, once moshing — that is the effect.
    public private(set) var damagedFrameCount = 0

    public enum DecoderError: Error, CustomStringConvertible {
        case codecUnavailable
        case setupFailed(String)

        public var description: String {
            switch self {
            case .codecUnavailable:
                "the H.264 decoder is missing from the vendored libavcodec — rebuild with scripts/build-ffmpeg.sh"
            case .setupFailed(let what): "could not set up the H.264 decoder: \(what)"
            }
        }
    }

    public init() throws {
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_H264) else { throw DecoderError.codecUnavailable }
        guard let context = avcodec_alloc_context3(codec) else { throw DecoderError.setupFailed("context") }
        codecContext = context

        // Output each picture as soon as it is decoded (no reorder buffer: the
        // stream has no B-frames), output pictures that are damaged or whose
        // references are missing, and never give up on an error.
        context.pointee.flags |= AV_CODEC_FLAG_LOW_DELAY
        context.pointee.flags |= AV_CODEC_FLAG_OUTPUT_CORRUPT
        context.pointee.flags2 |= AV_CODEC_FLAG2_SHOW_ALL
        context.pointee.err_recognition = 0
        // One thread: frame threading adds a frame of latency per thread, and an
        // SD picture decodes in a millisecond or two anyway.
        context.pointee.thread_count = 1

        let opened = avcodec_open2(context, codec, nil)
        guard opened >= 0 else { throw DecoderError.setupFailed("avcodec_open2 returned \(opened)") }
        guard let frame = av_frame_alloc() else { throw DecoderError.setupFailed("frame") }
        self.frame = frame
        guard let packet = av_packet_alloc() else { throw DecoderError.setupFailed("packet") }
        self.packet = packet
        Log.info(.mosh, "H.264 decoder ready (libavcodec \(String(cString: av_version_info())))")
    }

    deinit {
        if let scaler { sws_freeContext(scaler) }
        if packet != nil { av_packet_free(&packet) }
        if frame != nil { av_frame_free(&frame) }
        if codecContext != nil { avcodec_free_context(&codecContext) }
    }

    /// Decodes one access unit. Nil when libav produced no picture for it.
    public func decode(_ unit: H264AccessUnit) -> ImageBuffer? {
        guard let codecContext, let frame, let packet else { return nil }
        let bytes = unit.annexB
        guard !bytes.isEmpty else { return nil }

        let padded = bytes.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)
        guard let buffer = av_malloc(padded) else {
            Log.error(.mosh, "could not allocate a \(padded)-byte packet")
            return nil
        }
        bytes.withUnsafeBytes { raw in _ = memcpy(buffer, raw.baseAddress!, bytes.count) }
        memset(buffer.advanced(by: bytes.count), 0, Int(AV_INPUT_BUFFER_PADDING_SIZE))

        av_packet_unref(packet)
        guard av_packet_from_data(packet, buffer.assumingMemoryBound(to: UInt8.self), Int32(bytes.count)) >= 0 else {
            av_free(buffer)
            Log.error(.mosh, "av_packet_from_data failed")
            return nil
        }
        if unit.isKeyframe { packet.pointee.flags |= AV_PKT_FLAG_KEY }

        if avcodec_send_packet(codecContext, packet) < 0 { damagedFrameCount += 1 }
        av_packet_unref(packet)

        // Drain: with LOW_DELAY there is at most one picture per packet, but taking
        // everything available keeps the decoder from ever backing up.
        var latest: ImageBuffer?
        while avcodec_receive_frame(codecContext, frame) >= 0 {
            decodedFrameCount += 1
            if frame.pointee.decode_error_flags != 0 { damagedFrameCount += 1 }
            latest = convertToRGBA(frame) ?? latest
            av_frame_unref(frame)
        }
        return latest
    }

    /// Discards whatever pictures the decoder is holding (after a restart).
    public func flush() {
        guard let codecContext else { return }
        avcodec_flush_buffers(codecContext)
    }

    private func convertToRGBA(_ frame: UnsafeMutablePointer<AVFrame>) -> ImageBuffer? {
        let width = frame.pointee.width
        let height = frame.pointee.height
        guard width > 0, height > 0 else { return nil }

        if scaler == nil || scalerWidth != width || scalerHeight != height || scalerFormat != frame.pointee.format {
            if let scaler { sws_freeContext(scaler) }
            scaler = sws_getContext(
                width, height, AVPixelFormat(rawValue: frame.pointee.format),
                width, height, AV_PIX_FMT_RGBA,
                Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
            scalerWidth = width
            scalerHeight = height
            scalerFormat = frame.pointee.format
            guard scaler != nil else {
                Log.error(.mosh, "could not create a swscale context for \(width)x\(height)")
                return nil
            }
            scalerColour = (UInt32.max, UInt32.max)
        }

        // Convert with the matrix and range the STREAM declares. swscale otherwise
        // assumes BT.601 video range, and gets any other stream subtly wrong —
        // saturated reds came back as 235 instead of 255 before this.
        let space = frame.pointee.colorspace.rawValue
        let range = frame.pointee.color_range.rawValue
        if scalerColour.space != space || scalerColour.range != range {
            let matrix = frame.pointee.colorspace == AVCOL_SPC_BT709 ? SWS_CS_ITU709 : SWS_CS_ITU601
            let fullRange: Int32 = frame.pointee.color_range == AVCOL_RANGE_JPEG ? 1 : 0
            sws_setColorspaceDetails(
                scaler, sws_getCoefficients(matrix), fullRange,
                sws_getCoefficients(SWS_CS_ITU601), 1, 0, 1 << 16, 1 << 16)
            scalerColour = (space, range)
        }

        let bytesPerRow = Int(width) * ImageBuffer.bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * Int(height))
        pixels.withUnsafeMutableBytes { raw in
            var destination: [UnsafeMutablePointer<UInt8>?] = [
                raw.baseAddress!.assumingMemoryBound(to: UInt8.self), nil, nil, nil
            ]
            var destinationStride: [Int32] = [Int32(bytesPerRow), 0, 0, 0]
            var planes: [UnsafePointer<UInt8>?] = [
                UnsafePointer(frame.pointee.data.0), UnsafePointer(frame.pointee.data.1),
                UnsafePointer(frame.pointee.data.2), UnsafePointer(frame.pointee.data.3)
            ]
            var strides: [Int32] = [
                frame.pointee.linesize.0, frame.pointee.linesize.1,
                frame.pointee.linesize.2, frame.pointee.linesize.3
            ]
            _ = sws_scale(scaler, &planes, &strides, 0, height, &destination, &destinationStride)
        }
        return ImageBuffer(width: Int(width), height: Int(height), pixels: pixels)
    }
}

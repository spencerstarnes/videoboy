//
//  MPEG2Encoder.swift — RGBA frames to an MPEG-2 elementary stream (.m2v).
//
//  Purpose : The Compact optimize preset (proposal §7): MPEG-2, GOP 6, no B-frames —
//            the shape that keeps the MPEG wedge and nearly matches intra-only's
//            worst case at a third of the size. An elementary stream, not a container,
//            because the app's MPEG decoder and the corruptor work on the raw stream.
//  Inputs  : SD-sized RGBA `ImageBuffer`s, in order.
//  Outputs : encoded bytes, appended by the caller to a file.
//  Connects: ClipOptimizer. Same bundled LGPL libavcodec as MPEGTSStreamer.
//  Extend  : other canvases (0.4.11) pass their own width/height/bitrate.
//

import Foundation
import CFFmpeg

public final class MPEG2Encoder {

    public enum EncoderError: Error, CustomStringConvertible {
        case unavailable(String)
        public var description: String {
            switch self { case .unavailable(let what): "MPEG-2 encoder: \(what)" }
        }
    }

    private var context: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var scaler: UnsafeMutablePointer<SwsContext>?
    public let width: Int
    public let height: Int
    private var pts: Int64 = 0

    /// - Parameters:
    ///   - gop: frames between keyframes (6: loops, seeks and reverse stay cheap).
    ///   - bitrate: bits per second.
    public init(width: Int = StandardDefinition.width, height: Int = StandardDefinition.height,
                gop: Int = 6, bitrate: Int = 6_000_000) throws {
        self.width = width
        self.height = height
        guard let codec = avcodec_find_encoder(AV_CODEC_ID_MPEG2VIDEO) else {
            throw EncoderError.unavailable("no mpeg2video encoder in libavcodec")
        }
        guard let context = avcodec_alloc_context3(codec) else { throw EncoderError.unavailable("context") }
        self.context = context
        context.pointee.width = Int32(width)
        context.pointee.height = Int32(height)
        context.pointee.pix_fmt = AV_PIX_FMT_YUV420P
        context.pointee.bit_rate = Int64(bitrate)
        context.pointee.rc_max_rate = Int64(bitrate * 3 / 2)
        context.pointee.rc_buffer_size = Int32(bitrate)
        context.pointee.time_base = AVRational(num: 1001, den: 30000)
        context.pointee.framerate = AVRational(num: 30000, den: 1001)
        context.pointee.gop_size = Int32(gop)
        context.pointee.max_b_frames = 0
        // SD is 4:3 on non-square pixels: say so in the sequence header.
        context.pointee.sample_aspect_ratio = AVRational(num: 10, den: 11)
        guard avcodec_open2(context, codec, nil) >= 0 else { throw EncoderError.unavailable("open") }

        guard let frame = av_frame_alloc() else { throw EncoderError.unavailable("frame") }
        self.frame = frame
        frame.pointee.format = Int32(AV_PIX_FMT_YUV420P.rawValue)
        frame.pointee.width = Int32(width)
        frame.pointee.height = Int32(height)
        guard av_frame_get_buffer(frame, 0) >= 0 else { throw EncoderError.unavailable("frame buffer") }
        guard let packet = av_packet_alloc() else { throw EncoderError.unavailable("packet") }
        self.packet = packet
        scaler = sws_getContext(Int32(width), Int32(height), AV_PIX_FMT_RGBA,
                                Int32(width), Int32(height), AV_PIX_FMT_YUV420P,
                                Int32(SWS_BILINEAR.rawValue), nil, nil, nil)
        guard scaler != nil else { throw EncoderError.unavailable("swscale") }
    }

    deinit {
        if let scaler { sws_freeContext(scaler) }
        if packet != nil { av_packet_free(&packet) }
        if frame != nil { av_frame_free(&frame) }
        if context != nil { avcodec_free_context(&context) }
    }

    /// Encodes one frame; returns whatever bytes the encoder emitted (maybe none).
    public func encode(_ image: ImageBuffer) -> [UInt8] {
        guard let context, let frame, let scaler, image.width == width, image.height == height,
              av_frame_make_writable(frame) >= 0 else { return [] }
        var pixels = image.pixels
        _ = pixels.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            var source: [UnsafePointer<UInt8>?] = [UnsafePointer(base.assumingMemoryBound(to: UInt8.self)), nil, nil, nil]
            var sourceStride: [Int32] = [Int32(image.bytesPerRow), 0, 0, 0]
            var planes: [UnsafeMutablePointer<UInt8>?] = [frame.pointee.data.0, frame.pointee.data.1,
                                                          frame.pointee.data.2, frame.pointee.data.3]
            var strides: [Int32] = [frame.pointee.linesize.0, frame.pointee.linesize.1,
                                    frame.pointee.linesize.2, frame.pointee.linesize.3]
            return sws_scale(scaler, &source, &sourceStride, 0, Int32(height), &planes, &strides)
        }
        frame.pointee.pts = pts
        pts += 1
        guard avcodec_send_frame(context, frame) >= 0 else { return [] }
        return drain()
    }

    /// Flushes the encoder at the end of the clip.
    public func finish() -> [UInt8] {
        guard let context else { return [] }
        _ = avcodec_send_frame(context, nil)
        return drain()
    }

    private func drain() -> [UInt8] {
        guard let context, let packet else { return [] }
        var out: [UInt8] = []
        while avcodec_receive_packet(context, packet) >= 0 {
            if let data = packet.pointee.data, packet.pointee.size > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)))
            }
            av_packet_unref(packet)
        }
        return out
    }
}

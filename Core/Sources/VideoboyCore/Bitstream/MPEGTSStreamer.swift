//
//  MPEGTSStreamer.swift — sends the programme out as MPEG-TS over UDP, for OBS.
//
//  Purpose : Getting Videoboy into OBS. OBS reads an MPEG-TS stream with its own
//            Media Source and needs nothing installed on either side — no Syphon
//            plugin, no NDI runtime, no virtual-camera system extension (which would
//            need a signed installer this project deliberately does not have). The
//            dvc100 tool already publishes NUT over UDP for OBS, so this is the same
//            relationship, from the app itself.
//  Inputs  : `ImageBuffer` frames at the programme's size, and a host:port.
//  Outputs : UDP datagrams carrying MPEG-TS.
//  Connects: OutputRouter (which decides what is sent), the vendored LGPL FFmpeg.
//  Extend  : the bitrate and GOP are the two knobs worth exposing. Do NOT add a
//            second transport here — if another one is wanted it is another type,
//            because the muxing and the sending are different concerns and this file
//            is already doing both.
//
//  On the network rule: this is the only runtime network path in the app and it
//  defaults to 127.0.0.1. Sending video off the machine is a deliberate act that has
//  to be typed into the destination's target field, never a default.
//

import Foundation
import CFFmpeg

/// Muxes frames to MPEG-TS and sends them over UDP.
public final class MPEGTSStreamer {

    /// Why a stream could not be started.
    public enum StreamError: Error, CustomStringConvertible {
        case encoderUnavailable
        case muxerUnavailable
        case allocationFailed(String)
        case openFailed(String, Int32)

        public var description: String {
            switch self {
            case .encoderUnavailable:
                "the MPEG-2 video encoder is missing from the vendored libavcodec — "
                    + "rebuild with scripts/build-ffmpeg.sh"
            case .muxerUnavailable:
                "the MPEG-TS muxer or the UDP protocol is missing from the vendored "
                    + "libavformat — rebuild with scripts/build-ffmpeg.sh"
            case .allocationFailed(let what): "could not allocate \(what)"
            case .openFailed(let what, let code): "\(what) failed with code \(code)"
            }
        }
    }

    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var stream: UnsafeMutablePointer<AVStream>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var scaler: UnsafeMutablePointer<SwsContext>?

    private let width: Int
    private let height: Int
    private var sentFrameCount: Int64 = 0

    /// Where the stream is going, for the status bar.
    public let url: String

    /// Frames successfully muxed since the stream opened.
    public var framesSent: Int { Int(sentFrameCount) }

    /// Opens a stream to a UDP endpoint.
    ///
    /// - Parameters:
    ///   - target: "host:port". A bare port is taken as localhost.
    ///   - bitrate: bits per second. 6 Mb/s is generous for SD and keeps the
    ///     compression from being what anyone notices about the picture.
    public init(
        target: String,
        width: Int = StandardDefinition.width,
        height: Int = StandardDefinition.height,
        frameRate: Double = StandardDefinition.frameRate,
        bitrate: Int = 6_000_000
    ) throws {
        self.width = width
        self.height = height
        self.url = Self.normalise(target: target)

        guard let codec = avcodec_find_encoder(AV_CODEC_ID_MPEG2VIDEO) else {
            throw StreamError.encoderUnavailable
        }
        guard let codecContext = avcodec_alloc_context3(codec) else {
            throw StreamError.allocationFailed("AVCodecContext")
        }
        self.codecContext = codecContext

        codecContext.pointee.width = Int32(width)
        codecContext.pointee.height = Int32(height)
        codecContext.pointee.pix_fmt = AV_PIX_FMT_YUV420P
        codecContext.pointee.bit_rate = Int64(bitrate)
        // 30000/1001 for 29.97, expressed exactly rather than as a decimal, because
        // NTSC's rate is a ratio and rounding it is how drift gets in.
        codecContext.pointee.time_base = AVRational(num: 1001, den: 30000)
        codecContext.pointee.framerate = AVRational(num: 30000, den: 1001)
        // A keyframe twice a second. OBS joins a running stream, and a long GOP would
        // mean a black Media Source for as long as it takes the next one to arrive.
        codecContext.pointee.gop_size = Int32(max(frameRate / 2, 1))
        codecContext.pointee.max_b_frames = 0

        let openResult = avcodec_open2(codecContext, codec, nil)
        guard openResult >= 0 else { throw StreamError.openFailed("avcodec_open2", openResult) }

        var format: UnsafeMutablePointer<AVFormatContext>?
        let allocResult = avformat_alloc_output_context2(&format, nil, "mpegts", url)
        guard allocResult >= 0, let format else { throw StreamError.muxerUnavailable }
        self.formatContext = format

        guard let stream = avformat_new_stream(format, nil) else {
            throw StreamError.allocationFailed("AVStream")
        }
        self.stream = stream
        stream.pointee.time_base = codecContext.pointee.time_base
        guard avcodec_parameters_from_context(stream.pointee.codecpar, codecContext) >= 0 else {
            throw StreamError.allocationFailed("stream parameters")
        }

        // 1316 bytes: seven 188-byte transport packets, which is the conventional
        // MPEG-TS-over-UDP payload. libavformat's default is an MTU-sized 1472, which
        // is not a multiple of 188 and so splits TS packets across datagrams — lose
        // one and you corrupt two packets instead of one, and some receivers will not
        // take it at all.
        var options: OpaquePointer?
        defer { if options != nil { av_dict_free(&options) } }
        _ = av_dict_set(&options, "pkt_size", "1316", 0)

        let openIO = avio_open2(&format.pointee.pb, url, AVIO_FLAG_WRITE, nil, &options)
        guard openIO >= 0 else { throw StreamError.openFailed("avio_open2(\(url))", openIO) }

        let header = avformat_write_header(format, nil)
        guard header >= 0 else { throw StreamError.openFailed("avformat_write_header", header) }

        guard let frame = av_frame_alloc() else { throw StreamError.allocationFailed("AVFrame") }
        self.frame = frame
        frame.pointee.format = Int32(AV_PIX_FMT_YUV420P.rawValue)
        frame.pointee.width = Int32(width)
        frame.pointee.height = Int32(height)
        guard av_frame_get_buffer(frame, 0) >= 0 else {
            throw StreamError.allocationFailed("frame buffer")
        }

        guard let packet = av_packet_alloc() else { throw StreamError.allocationFailed("AVPacket") }
        self.packet = packet

        scaler = sws_getContext(
            Int32(width), Int32(height), AV_PIX_FMT_RGBA,
            Int32(width), Int32(height), AV_PIX_FMT_YUV420P,
            Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        )
        guard scaler != nil else { throw StreamError.allocationFailed("swscale context") }

        Log.info(.render, "streaming MPEG-TS to \(url) at \(width)x\(height), \(bitrate / 1000) kb/s")
    }

    deinit { close() }

    /// Sends one frame.
    ///
    /// - Returns: false if the frame could not be encoded or written. A caller that
    ///   sees this repeatedly should stop the stream rather than keep trying — a
    ///   receiver that has gone away does not come back on its own.
    @discardableResult
    public func send(image: ImageBuffer) -> Bool {
        guard let codecContext, let formatContext, let frame, let packet, let scaler,
              let stream else { return false }
        guard image.width == width, image.height == height else {
            Log.warn(.render, "stream got \(image.width)x\(image.height), needs \(width)x\(height)")
            return false
        }
        guard av_frame_make_writable(frame) >= 0 else { return false }

        var pixels = image.pixels
        let converted: Int32 = pixels.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            var sourcePlanes: [UnsafePointer<UInt8>?] = [
                UnsafePointer(base.assumingMemoryBound(to: UInt8.self)), nil, nil, nil
            ]
            var sourceStride: [Int32] = [Int32(image.bytesPerRow), 0, 0, 0]
            var destinationPlanes: [UnsafeMutablePointer<UInt8>?] = [
                frame.pointee.data.0, frame.pointee.data.1,
                frame.pointee.data.2, frame.pointee.data.3
            ]
            var destinationStride: [Int32] = [
                frame.pointee.linesize.0, frame.pointee.linesize.1,
                frame.pointee.linesize.2, frame.pointee.linesize.3
            ]
            return sws_scale(
                scaler, &sourcePlanes, &sourceStride, 0, Int32(height),
                &destinationPlanes, &destinationStride
            )
        }
        guard converted > 0 else { return false }

        frame.pointee.pts = sentFrameCount
        guard avcodec_send_frame(codecContext, frame) >= 0 else { return false }

        // Drain whatever the encoder is ready to hand over. A negative result means
        // "nothing yet" (it needs more frames) or a real error; either way there is
        // nothing more to write this time round, which is the same action.
        while avcodec_receive_packet(codecContext, packet) >= 0 {
            av_packet_rescale_ts(packet, codecContext.pointee.time_base, stream.pointee.time_base)
            packet.pointee.stream_index = stream.pointee.index
            // Interleaved, so the muxer owns the ordering rather than this file
            // assuming there will only ever be one stream in it.
            _ = av_interleaved_write_frame(formatContext, packet)
            av_packet_unref(packet)
        }

        sentFrameCount += 1
        return true
    }

    /// Flushes the encoder, writes the trailer and closes the socket.
    public func close() {
        if let codecContext, let formatContext, let packet, let stream {
            // Drain: frames still inside the encoder belong in the stream, and a
            // receiver left waiting for them is how a recording ends up short.
            _ = avcodec_send_frame(codecContext, nil)
            while avcodec_receive_packet(codecContext, packet) >= 0 {
                av_packet_rescale_ts(
                    packet, codecContext.pointee.time_base, stream.pointee.time_base)
                packet.pointee.stream_index = stream.pointee.index
                _ = av_interleaved_write_frame(formatContext, packet)
                av_packet_unref(packet)
            }
            _ = av_write_trailer(formatContext)
        }

        if let scaler { sws_freeContext(scaler) }
        scaler = nil
        if packet != nil { av_packet_free(&packet) }
        if frame != nil { av_frame_free(&frame) }
        if codecContext != nil { avcodec_free_context(&codecContext) }
        if let formatContext {
            if formatContext.pointee.pb != nil { avio_closep(&formatContext.pointee.pb) }
            avformat_free_context(formatContext)
        }
        formatContext = nil
        stream = nil
    }

    /// Turns what someone typed into a URL libavformat will accept.
    ///
    /// A bare port means localhost, because that is what someone typing "9000" into a
    /// box labelled OBS means — and defaulting the other way would put video on the
    /// network by accident.
    static func normalise(target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("udp://") { return trimmed }
        if trimmed.contains(":") { return "udp://\(trimmed)" }
        if trimmed.allSatisfy(\.isNumber), !trimmed.isEmpty { return "udp://127.0.0.1:\(trimmed)" }
        return "udp://\(trimmed)"
    }
}

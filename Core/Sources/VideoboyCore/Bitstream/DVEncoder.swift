//
//  DVEncoder.swift — encodes RGBA frames to a DV bitstream.
//
//  Purpose : Lets the wedge reach material that did not arrive as DV. A mixed bus is
//            a texture, not a bitstream, so there is nothing to corrupt — unless it
//            is re-encoded first. Encode to DV, damage the DIF blocks, decode back,
//            and a composited mix can be datamoshed the same way a DV file can.
//  Inputs  : an `ImageBuffer` at the DV standard's size.
//  Outputs : a complete DV frame's bytes, ready for `DIFCorruptor`.
//  Connects: DIFCorruptor and DVDecoder — together they form the round trip that
//            BusCodecNode runs.
//
//  DV is intra-frame, so one frame in gives one frame out with no GOP and no
//  latency. That is exactly why it is the right interchange format here: an MPEG
//  round trip would need several frames in hand before it could emit one, which a
//  live mixer cannot give it.
//

import Foundation
import CFFmpeg

/// Encodes frames into DV.
public final class DVEncoder {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var scaler: UnsafeMutablePointer<SwsContext>?

    /// The standard being encoded to, which fixes the frame size and rate.
    public let standard: DVStandard

    /// Frames encoded since this encoder was created.
    private(set) public var encodedFrameCount = 0

    /// Why an encoder could not be created.
    public enum EncoderError: Error, CustomStringConvertible {
        case codecUnavailable
        case contextAllocationFailed
        case contextOpenFailed(Int32)
        case allocationFailed(String)

        public var description: String {
            switch self {
            case .codecUnavailable:
                "the DV encoder is missing from the vendored libavcodec — rebuild with scripts/build-ffmpeg.sh"
            case .contextAllocationFailed: "could not allocate an AVCodecContext"
            case .contextOpenFailed(let code): "avcodec_open2 failed with code \(code)"
            case .allocationFailed(let what): "could not allocate \(what)"
            }
        }
    }

    public init(standard: DVStandard = .ntsc) throws {
        self.standard = standard

        guard let codec = avcodec_find_encoder(AV_CODEC_ID_DVVIDEO) else {
            throw EncoderError.codecUnavailable
        }
        guard let context = avcodec_alloc_context3(codec) else {
            throw EncoderError.contextAllocationFailed
        }
        self.codecContext = context

        let (width, height) = standard.size
        context.pointee.width = Int32(width)
        context.pointee.height = Int32(height)
        // NTSC DV is 4:1:1; PAL DV is 4:2:0. The encoder refuses anything else, and
        // leaning into that subsampling is part of the look anyway (SPEC 9).
        context.pointee.pix_fmt = standard == .ntsc ? AV_PIX_FMT_YUV411P : AV_PIX_FMT_YUV420P
        context.pointee.time_base = AVRational(
            num: standard == .ntsc ? 1001 : 1,
            den: standard == .ntsc ? 30000 : 25
        )

        let openResult = avcodec_open2(context, codec, nil)
        guard openResult >= 0 else { throw EncoderError.contextOpenFailed(openResult) }

        guard let frame = av_frame_alloc() else { throw EncoderError.allocationFailed("AVFrame") }
        self.frame = frame
        frame.pointee.format = Int32(context.pointee.pix_fmt.rawValue)
        frame.pointee.width = Int32(width)
        frame.pointee.height = Int32(height)
        guard av_frame_get_buffer(frame, 0) >= 0 else {
            throw EncoderError.allocationFailed("frame buffer")
        }

        guard let packet = av_packet_alloc() else { throw EncoderError.allocationFailed("AVPacket") }
        self.packet = packet

        // RGBA in, planar YUV out. Built once: the geometry never changes for a
        // given standard, and rebuilding it per frame would dominate the cost.
        scaler = sws_getContext(
            Int32(width), Int32(height), AV_PIX_FMT_RGBA,
            Int32(width), Int32(height), context.pointee.pix_fmt,
            Int32(SWS_BILINEAR.rawValue), nil, nil, nil
        )
        guard scaler != nil else { throw EncoderError.allocationFailed("swscale context") }

        Log.info(.dv, "DV encoder ready (\(standard.rawValue.uppercased()), \(width)x\(height))")
    }

    deinit {
        if let scaler { sws_freeContext(scaler) }
        if packet != nil { av_packet_free(&packet) }
        if frame != nil { av_frame_free(&frame) }
        if codecContext != nil { avcodec_free_context(&codecContext) }
    }

    /// Encodes one frame to a DV bitstream.
    ///
    /// - Parameter image: must match the standard's size; anything else is refused
    ///   rather than silently rescaled, because a rescale here would be an invisible
    ///   quality loss in the middle of a signal path built to avoid exactly that.
    /// - Returns: the DV frame's bytes, or nil if the encoder produced nothing.
    public func encode(image: ImageBuffer) -> [UInt8]? {
        guard let codecContext, let frame, let packet, let scaler else { return nil }

        let (width, height) = standard.size
        guard image.width == width, image.height == height else {
            Log.error(.dv, "DV encoder got \(image.width)x\(image.height), needs \(width)x\(height)")
            return nil
        }

        // The frame buffer may be shared with a previous encode; make it writable.
        guard av_frame_make_writable(frame) >= 0 else {
            Log.error(.dv, "could not make the encode frame writable")
            return nil
        }

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
        guard converted > 0 else {
            Log.error(.dv, "RGBA to YUV conversion produced no rows")
            return nil
        }

        frame.pointee.pts = Int64(encodedFrameCount)

        let sendResult = avcodec_send_frame(codecContext, frame)
        guard sendResult >= 0 else {
            Log.error(.dv, "avcodec_send_frame failed with code \(sendResult)")
            return nil
        }

        av_packet_unref(packet)
        let receiveResult = avcodec_receive_packet(codecContext, packet)
        guard receiveResult >= 0 else {
            Log.warn(.dv, "DV encoder produced no packet (code \(receiveResult))")
            return nil
        }

        let size = Int(packet.pointee.size)
        guard size > 0, let data = packet.pointee.data else {
            av_packet_unref(packet)
            return nil
        }
        let bytes = [UInt8](UnsafeBufferPointer(start: data, count: size))
        av_packet_unref(packet)
        encodedFrameCount += 1
        return bytes
    }
}

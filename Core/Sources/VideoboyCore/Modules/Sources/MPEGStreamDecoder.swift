//
//  MPEGStreamDecoder.swift — MPEG-2 playback with the damage applied before decode.
//
//  Purpose : The MPEG half of the wedge, playable. What makes this different from
//            `AVFClipDecoder` — which could also open an MPEG file — is that the
//            corruption happens to the COMPRESSED bytes on their way to the decoder.
//            AVFoundation hands back finished pictures and there is no seam to reach
//            into; libavcodec is fed packet by packet, and that packet is where the
//            wedge lives.
//  Inputs  : an MPEG-2 file, a frame index, and damage settings.
//  Outputs : a decoded `ImageBuffer`, usually a wrong one on purpose.
//  Connects: ClipSourceNode through `ClipDecoding`, MPEGCorruptor, MPEGFormat.
//  Extend  : another long-GOP family (MPEG-4, H.264) is another decoder here with its
//            own corruptor. The playback rules stay in the node, as they do for DV.
//
//  On decoding a damaged stream: libavcodec complains loudly and keeps going, which
//  is exactly what is wanted. Its log is silenced for this path — the errors are the
//  effect working, and a console full of them would bury real problems.
//

import Foundation
import CFFmpeg

/// Decodes MPEG-2, damaging the bitstream on the way in.
public final class MPEGStreamDecoder: ClipDecoding {

    /// How many pictures are decoded in one go.
    ///
    /// MPEG is long-GOP: a predicted picture means nothing without the ones it was
    /// predicted from, so frames are decoded in GOP-sized runs and kept. Asking for
    /// one frame in isolation is not a thing this format can do.
    private static let cacheSize = 32

    private let url: URL
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var packet: UnsafeMutablePointer<AVPacket>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var scaler: UnsafeMutablePointer<SwsContext>?
    private var streamIndex: Int32 = -1

    public private(set) var frameCount = 0
    public private(set) var frameRate = StandardDefinition.frameRate

    /// MPEG footage offers the MPEG data effects. This is what makes the source panel
    /// show the frame-drop and reference-hold controls rather than the DV ones.
    public var dataEffectFamily: DataEffectFamily { .mpeg }

    private var cache: [Int: ImageBuffer] = [:]
    private var cacheOrder: [Int] = []
    private var nextFrameIndex = 0
    /// The last coded picture seen, which `referenceHold` substitutes in.
    private var previousPicture: [UInt8]?
    /// The damage the current decode run is using.
    private var activeDamage = MPEGCorruptionSettings.inert

    /// The canvas frames are sized for, or nil to decode at the stream's own size.
    private let canvas: CanvasGeometry?
    /// The size swscale produces. Decided when the stream opens, from its parameters,
    /// so nothing about the clip changes once decoding moves off the main thread.
    private var outputSize: (width: Int, height: Int)?

    /// Upright display shape: the stream's sample aspect ratio, else the SD rule.
    /// Set once, at open.
    public private(set) var displayAspectRatio: Double?

    /// - Parameter canvas: when given, swscale scales each frame to what this canvas
    ///   needs (`CanvasGeometry.decodeSize`) in the same pass that converts it to RGBA —
    ///   free, where scaling afterwards meant carrying full HD through the graph.
    public init?(url: URL, canvas: CanvasGeometry? = nil) {
        self.url = url
        self.canvas = canvas

        var format: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&format, url.path, nil, nil) >= 0, let format else {
            Log.error(.bitstream, "could not open \(url.lastPathComponent) as MPEG")
            return nil
        }
        self.formatContext = format

        guard avformat_find_stream_info(format, nil) >= 0 else {
            Log.error(.bitstream, "no stream info in \(url.lastPathComponent)")
            return nil
        }

        // The first video stream. An elementary stream has exactly one.
        for index in 0..<Int(format.pointee.nb_streams) {
            guard let stream = format.pointee.streams[index] else { continue }
            if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
                streamIndex = Int32(index)
                break
            }
        }
        guard streamIndex >= 0, let stream = format.pointee.streams[Int(streamIndex)] else {
            Log.error(.bitstream, "\(url.lastPathComponent) has no video stream")
            return nil
        }

        guard let codec = avcodec_find_decoder(stream.pointee.codecpar.pointee.codec_id),
              let codecContext = avcodec_alloc_context3(codec) else {
            Log.error(.bitstream, "no decoder for \(url.lastPathComponent)")
            return nil
        }
        self.codecContext = codecContext
        guard avcodec_parameters_to_context(codecContext, stream.pointee.codecpar) >= 0,
              avcodec_open2(codecContext, codec, nil) >= 0 else {
            Log.error(.bitstream, "could not open the decoder for \(url.lastPathComponent)")
            return nil
        }
        // The errors are the effect working. A console full of them would bury real
        // problems, so this path is quiet on purpose.
        av_log_set_level(AV_LOG_QUIET)

        let rate = av_q2d(stream.pointee.avg_frame_rate)
        frameRate = rate > 0 ? rate : StandardDefinition.frameRate

        // SHAPE AND OUTPUT SIZE, from the stream's parameters.
        let codedWidth = Int(stream.pointee.codecpar.pointee.width)
        let codedHeight = Int(stream.pointee.codecpar.pointee.height)
        if codedWidth > 0, codedHeight > 0 {
            var aspect = CanvasGeometry.displayAspect(width: codedWidth, height: codedHeight)
            let sample = stream.pointee.codecpar.pointee.sample_aspect_ratio
            if sample.num > 0, sample.den > 0, sample.num != sample.den {
                aspect = Double(codedWidth) * Double(sample.num) / (Double(codedHeight) * Double(sample.den))
            }
            displayAspectRatio = aspect
            var size = (width: codedWidth, height: codedHeight)
            if let canvas {
                let wanted = canvas.decodeSize(sourceAspect: aspect, nativeSize: (codedWidth, codedHeight))
                if wanted.width < codedWidth || wanted.height < codedHeight { size = wanted }
            }
            outputSize = size
        }

        if stream.pointee.nb_frames > 0 {
            frameCount = Int(stream.pointee.nb_frames)
        } else {
            let duration = Double(format.pointee.duration) / Double(AV_TIME_BASE)
            frameCount = duration > 0 ? max(Int(duration * frameRate), 1) : 0
        }

        guard let packet = av_packet_alloc(), let frame = av_frame_alloc() else { return nil }
        self.packet = packet
        self.frame = frame

        // A raw elementary stream carries no timestamps and no frame count, so the
        // container can only say "unknown". Counting picture start codes is the only
        // way to know, and getting it wrong is not subtle: a count of 1 makes every
        // index wrap to frame 0, so the clip decodes perfectly and never appears to
        // move — which looks like the effects being broken rather than the length.
        if frameCount <= 1 {
            frameCount = max(countPictures(), 1)
        }

        Log.info(.bitstream, "opened \(url.lastPathComponent): \(frameCount) MPEG frames at "
            + String(format: "%.2f", frameRate) + " fps")
    }

    deinit {
        if let scaler { sws_freeContext(scaler) }
        if packet != nil { av_packet_free(&packet) }
        if frame != nil { av_frame_free(&frame) }
        if codecContext != nil { avcodec_free_context(&codecContext) }
        if formatContext != nil { avformat_close_input(&formatContext) }
    }

    public func image(at index: Int, corruption: CorruptionSettings) -> ImageBuffer? {
        let damage = corruption.asMPEG
        let wrapped = wrappedIndex(index)

        // Changing the damage invalidates everything: a long-GOP decode carries
        // errors forward by design, so a cached frame decoded under other settings is
        // not the frame those settings would have produced.
        if damage != activeDamage {
            activeDamage = damage
            cache.removeAll()
            cacheOrder.removeAll()
            previousPicture = nil
            restart(at: 0)
        }

        if let cached = cache[wrapped] { return cached }

        if wrapped < nextFrameIndex { restart(at: 0) }
        while nextFrameIndex <= wrapped {
            guard decodeNext() else {
                // The stream ran out before reaching the wanted index. Damage that
                // removes coded pictures makes the clip genuinely SHORTER than the
                // frame count taken from the clean file, so this is the normal case
                // for frame drop rather than an error.
                //
                // Returning nil here would leave the source holding its last good
                // texture, so the picture would appear frozen and the effect would
                // read as doing nothing at all. Wrapping into what the damaged stream
                // actually produced is what makes it read as the clip running short
                // and jumpy, which is what dropping frames does.
                let available = nextFrameIndex
                guard available > 0 else { return nil }
                let effective = wrapped % available
                if let cached = cache[effective] { return cached }
                restart(at: 0)
                while nextFrameIndex <= effective {
                    guard decodeNext() else { break }
                }
                return cache[effective]
            }
        }
        return cache[wrapped]
    }

    public func wrappedIndex(_ index: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let remainder = index % frameCount
        return remainder < 0 ? remainder + frameCount : remainder
    }

    /// Counts coded pictures by demuxing once, without decoding any of them.
    ///
    /// Cheap — it reads packets and scans for picture start codes, which is a byte
    /// comparison — and exact, which an estimate from bitrate would not be.
    private func countPictures() -> Int {
        guard let formatContext, let packet else { return 0 }
        var count = 0
        while av_read_frame(formatContext, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == streamIndex,
                  let data = packet.pointee.data, packet.pointee.size > 0 else { continue }
            let bytes = [UInt8](UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)))
            count += MPEGFormat.pictures(in: bytes).count
        }
        // Back to the beginning, since this consumed the whole stream.
        av_seek_frame(formatContext, streamIndex, 0, AVSEEK_FLAG_BACKWARD)
        if let codecContext { avcodec_flush_buffers(codecContext) }
        return count
    }

    // MARK: - Decoding

    private func restart(at index: Int) {
        guard let formatContext, let codecContext else { return }
        av_seek_frame(formatContext, streamIndex, 0, AVSEEK_FLAG_BACKWARD)
        avcodec_flush_buffers(codecContext)
        nextFrameIndex = index
        previousPicture = nil
    }

    /// Reads one packet, damages it, decodes it, and caches whatever comes out.
    private func decodeNext() -> Bool {
        guard let formatContext, let codecContext, let packet, let frame else { return false }

        while av_read_frame(formatContext, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == streamIndex else { continue }

            guard let data = packet.pointee.data, packet.pointee.size > 0 else { continue }
            var bytes = [UInt8](UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)))

            // THE WEDGE, for MPEG: damage the compressed bytes on the way to the
            // decoder. Never after — a damaged picture is the effect, a damaged
            // pixel buffer is an ordinary filter.
            if activeDamage.amount > 0 {
                let held = MPEGCorruptor.lastPicture(in: bytes)
                bytes = MPEGCorruptor.corrupt(
                    stream: bytes, settings: activeDamage, previousPicture: previousPicture)
                if let held { previousPicture = held }
            }

            let sent: Int32 = bytes.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                var temporary = AVPacket()
                temporary.data = base
                temporary.size = Int32(buffer.count)
                temporary.stream_index = streamIndex
                temporary.pts = packet.pointee.pts
                temporary.dts = packet.pointee.dts
                return avcodec_send_packet(codecContext, &temporary)
            }
            // A packet the decoder refuses is skipped rather than fatal: at high
            // damage some of them will be, and stopping there would end playback in
            // the middle of the effect.
            guard sent >= 0 else { continue }

            var produced = false
            while avcodec_receive_frame(codecContext, frame) >= 0 {
                if let image = convert(frame) {
                    store(image, at: nextFrameIndex)
                    nextFrameIndex += 1
                    produced = true
                }
            }
            if produced { return true }
        }
        return false
    }

    private func convert(_ frame: UnsafeMutablePointer<AVFrame>) -> ImageBuffer? {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return nil }

        // A stream whose parameters gave no size decodes at its own.
        if outputSize == nil { outputSize = (width, height) }
        if scaler == nil, let size = outputSize {
            scaler = sws_getContext(
                Int32(width), Int32(height), AVPixelFormat(rawValue: frame.pointee.format),
                Int32(size.width), Int32(size.height), AV_PIX_FMT_RGBA,
                Int32(SWS_BILINEAR.rawValue), nil, nil, nil
            )
        }
        guard let scaler, let outputSize else { return nil }
        let outputWidth = outputSize.width
        let outputHeight = outputSize.height

        var pixels = [UInt8](repeating: 255, count: outputWidth * outputHeight * 4)
        let converted: Int32 = pixels.withUnsafeMutableBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            var sourcePlanes: [UnsafePointer<UInt8>?] = [
                UnsafePointer(frame.pointee.data.0), UnsafePointer(frame.pointee.data.1),
                UnsafePointer(frame.pointee.data.2), UnsafePointer(frame.pointee.data.3)
            ]
            var sourceStride: [Int32] = [
                frame.pointee.linesize.0, frame.pointee.linesize.1,
                frame.pointee.linesize.2, frame.pointee.linesize.3
            ]
            var destinationPlanes: [UnsafeMutablePointer<UInt8>?] = [
                base.assumingMemoryBound(to: UInt8.self), nil, nil, nil
            ]
            var destinationStride: [Int32] = [Int32(outputWidth * 4), 0, 0, 0]
            return sws_scale(
                scaler, &sourcePlanes, &sourceStride, 0, Int32(height),
                &destinationPlanes, &destinationStride)
        }
        guard converted > 0 else { return nil }
        return ImageBuffer(width: outputWidth, height: outputHeight, pixels: pixels)
    }

    private func store(_ image: ImageBuffer, at index: Int) {
        cache[index] = image
        cacheOrder.append(index)
        while cacheOrder.count > Self.cacheSize {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}

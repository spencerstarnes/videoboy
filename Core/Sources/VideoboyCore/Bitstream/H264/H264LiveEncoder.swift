//
//  H264LiveEncoder.swift — a live picture into H.264, shaped for moshing.
//
//  Purpose : Every live datamosh tool normalises its input before it moshes:
//            FFglitch's live mode encodes the webcam to MPEG-4 with no B-frames and
//            an endless GOP; the WebCodecs tools re-encode both clips with identical
//            headers. Videoboy does the same, live, with the hardware H.264 encoder:
//            whatever reaches the node — a clip, a camera, a mix — becomes ONE
//            continuous stream with one set of parameters, so any frame can be spliced
//            after any other. That is what lets a cut between two sources mosh.
//  Inputs  : RGBA `ImageBuffer`s, one per content frame.
//  Outputs : `H264AccessUnit`s, on VideoToolbox's callback thread.
//  Connects: DatamoshNode (owner), MoshEngine (consumer).
//  Extend  : encoder settings live in `configure`. Keep B-frames off — a reordered
//            stream cannot be spliced frame by frame.
//
//  Settings, and why:
//    - no frame reordering (no B-frames): every frame depends only on earlier ones.
//    - keyframes effectively never, unless asked (heal): an I-frame is exactly what
//      a mosh removes, and the encoder should not be putting them back on its own.
//    - real-time mode: the encoder must keep up with 29.97 and never queue.
//    - bitrate is a performance control ("blocks"): starved, the encoder leans on
//      motion vectors and big blocks, which is what the smear is made of.
//

import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo
import Accelerate

/// Why the encoder could not start.
public enum H264EncoderError: Error, CustomStringConvertible {
    case sessionCreation(OSStatus)
    case poolCreation(OSStatus)

    public var description: String {
        switch self {
        case .sessionCreation(let status): "VideoToolbox would not create an H.264 encoder (\(status))"
        case .poolCreation(let status): "could not create a pixel buffer pool (\(status))"
        }
    }
}

/// Wraps a VTCompressionSession.
public final class H264LiveEncoder {

    public let width: Int
    public let height: Int
    /// Guarded by `lock`: encodes arrive on Metal's completion threads.
    private var session: VTCompressionSession?
    private var frameIndex: Int64 = 0
    private let output: (H264AccessUnit) -> Void

    /// Frames handed to VideoToolbox and not yet returned. The node skips encoding
    /// while this is high rather than letting a queue build behind the picture.
    public var framesInFlight: Int { lock.withLock { inFlight } }
    private var inFlight = 0
    private let lock = NSLock()

    /// Bits per second at "blocks" 0 and 1. SD at 29.97: 400 kb/s is visibly
    /// starved, 8 Mb/s is clean.
    public static let bitRateRange: ClosedRange<Double> = 400_000...8_000_000

    /// - Parameter output: called with each encoded picture, on VideoToolbox's thread.
    public init(width: Int, height: Int, output: @escaping (H264AccessUnit) -> Void) throws {
        self.width = width
        self.height = height
        self.output = output

        var created: VTCompressionSession?
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let created else { throw H264EncoderError.sessionCreation(status) }
        session = created
        configure(created)
        VTCompressionSessionPrepareToEncodeFrames(created)
        Log.info(.mosh, "H.264 encoder ready at \(width)x\(height)")
    }

    deinit { invalidate(completingPending: false) }

    /// Stops the encoder. Safe to call twice.
    ///
    /// - Parameter completingPending: wait for frames already submitted (tests want
    ///   every frame out). The live node passes false: stopping must never block the
    ///   render tick, and a frame in flight when the mosh is released is not wanted.
    public func invalidate(completingPending: Bool = true) {
        let taken: VTCompressionSession? = lock.withLock {
            defer { session = nil }
            return session
        }
        guard let taken else { return }
        if completingPending {
            VTCompressionSessionCompleteFrames(taken, untilPresentationTimeStamp: .invalid)
        }
        VTCompressionSessionInvalidate(taken)
    }

    private func configure(_ session: VTCompressionSession) {
        let settings: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Int32.max)),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1_000_000.0)),
            (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: 29.97)),
            (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: 2_000_000)),
            // SD colour (BT.601 / SMPTE-C), written into the stream so the decoder
            // converts back with the same matrix it went in with.
            (kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_601_4),
            (kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_SMPTE_C),
            (kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        ]
        for (key, value) in settings {
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status != noErr {
                Log.warn(.mosh, "encoder refused \(key) (\(status)); continuing without it")
            }
        }
    }

    /// Sets the bitrate from a 0...1 "blocks" control: 0 starved, 1 clean.
    public func setQuality(_ normalised: Double) {
        guard let session = lock.withLock({ self.session }) else { return }
        let clamped = min(max(normalised, 0), 1)
        let range = H264LiveEncoder.bitRateRange
        // Exponential, so the fader spends its travel where the look changes.
        let bitRate = range.lowerBound * pow(range.upperBound / range.lowerBound, clamped)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: Int(bitRate)))
    }

    /// Encodes one RGBA picture. Returns immediately; the result arrives on `output`.
    ///
    /// - Parameter forceKeyframe: ask for an IDR (the heal gesture).
    public func encode(_ image: ImageBuffer, forceKeyframe: Bool = false) {
        guard image.width == width, image.height == height else {
            Log.warn(.mosh, "encoder is \(width)x\(height), got \(image.width)x\(image.height); frame skipped")
            return
        }
        encode(forceKeyframe: forceKeyframe) { base, bytesPerRow in
            self.copy(image, into: base, bytesPerRow: bytesPerRow)
        }
    }

    /// Encodes one picture that `fill` writes straight into the encoder's own BGRA
    /// buffer (`width`x`height`, the given row stride). This is the live path: the
    /// node copies GPU bytes in with no intermediate image and no channel swizzle.
    /// Safe to call from any thread.
    public func encode(forceKeyframe: Bool = false, fill: (UnsafeMutableRawPointer, Int) -> Void) {
        // Taken under the lock: `invalidate` may run on another thread. A session
        // invalidated after this point just rejects the frame, which is logged.
        guard let session = lock.withLock({ self.session }),
              let pool = VTCompressionSessionGetPixelBufferPool(session) else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else {
            Log.warn(.mosh, "no pixel buffer free in the pool; frame skipped")
            return
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            fill(base, CVPixelBufferGetBytesPerRow(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        // The same tags on the picture, so VideoToolbox's RGB → YUV uses BT.601 too.
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)

        let index: Int64 = lock.withLock {
            inFlight += 1
            defer { frameIndex += 1 }
            return frameIndex
        }
        let time = CMTime(value: index * 1001, timescale: 30000)
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil

        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: time,
            duration: CMTime(value: 1001, timescale: 30000),
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            self.lock.withLock { self.inFlight -= 1 }
            guard status == noErr, let sampleBuffer else {
                if status != noErr { Log.warn(.mosh, "encode failed (\(status))") }
                return
            }
            if let unit = H264LiveEncoder.accessUnit(from: sampleBuffer) { self.output(unit) }
        }
        if status != noErr {
            lock.withLock { inFlight -= 1 }
            Log.warn(.mosh, "encoder rejected a frame (\(status))")
        }
    }

    /// RGBA → BGRA into the encoder's buffer, vectorised.
    private func copy(_ image: ImageBuffer, into base: UnsafeMutableRawPointer, bytesPerRow: Int) {
        var destination = vImage_Buffer(
            data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
            rowBytes: bytesPerRow)
        image.pixels.withUnsafeBytes { raw in
            var source = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: raw.baseAddress!),
                height: vImagePixelCount(height), width: vImagePixelCount(width),
                rowBytes: image.bytesPerRow)
            let map: [UInt8] = [2, 1, 0, 3]
            vImagePermuteChannels_ARGB8888(&source, &destination, map, vImage_Flags(kvImageNoFlags))
        }
    }

    /// The NAL units of one encoded sample, with SPS/PPS in front of keyframes.
    static func accessUnit(from sampleBuffer: CMSampleBuffer) -> H264AccessUnit? {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length,
                                         destination: &bytes) == noErr else { return nil }

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        var nalUnits: [[UInt8]] = []
        var lengthSize: Int32 = 4
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: &lengthSize)
            // Parameter sets go in front of EVERY picture; the engine keeps only
            // what changed, so this costs a comparison, and it means an encoder that
            // changes its SPS mid-stream is noticed at once.
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil) == noErr, let pointer {
                    nalUnits.append(Array(UnsafeBufferPointer(start: pointer, count: size)))
                }
            }
        }
        nalUnits += H264AccessUnit.nalUnits(fromAVCC: bytes, lengthSize: Int(lengthSize))
        return H264AccessUnit(nalUnits: nalUnits, isKeyframe: isKeyframe)
    }
}

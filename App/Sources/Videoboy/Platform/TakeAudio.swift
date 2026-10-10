//
//  TakeAudio.swift — the sound for a take: whatever the beat is coming from.
//
//  Purpose : A recording of a set without its music is half a recording. The beat
//            tracker is already listening to the music — the input, the whole Mac,
//            or one app — so this takes that same audio and writes it into every
//            file of the take, lined up with the picture.
//  Inputs  : interleaved stereo float buffers with the host time of their first
//            sample (from AudioRecordFeed, on a capture thread); the presentation
//            time of the take's first frame (from RecordingSession).
//  Outputs : 48 kHz stereo sample buffers, appended to each FrameRecorder's audio
//            track on this object's queue.
//  Connects: AudioInput / AudioRecordFeed (source), RecordingSession (owner),
//            FrameRecorder (sink), RecordedAudioClock in Core (where samples go).
//  Extend  : another audio source needs nothing here — anything that reaches the
//            feed is recorded. Placement rules belong in RecordedAudioClock, not here.
//
//  Everything after `receive` runs on one serial queue, which is never the render
//  loop or an audio device's IO thread: converting, placing and appending all
//  happen here, and the capture thread only hands its samples over.
//

import AVFoundation
import Foundation
import QuartzCore
import VideoboyCore

/// Writes the clock's audio into every file of one take.
final class TakeAudio {

    /// One buffer as it arrived, kept until the take's first frame says where zero is.
    private struct Arrival {
        let samples: [Float]
        let sampleRate: Double
        let hostTime: Double
    }

    private let queue = DispatchQueue(label: "videoboy.record.audio", qos: .userInitiated)
    private let recorders: [FrameRecorder]
    private let trackRate = FrameRecorder.audioSampleRate

    // Queue state.
    /// Host time of the take's first frame. Nil until it has been written.
    private var origin: Double?
    /// Audio that arrived before the first frame.
    private var waiting: [Arrival] = []
    private var clock = RecordedAudioClock(sampleRate: FrameRecorder.audioSampleRate)
    private var isFinished = false
    /// Converts a source that is not at the track's rate. Rebuilt when the rate
    /// changes, which happens when the clock source is switched mid-take.
    private var converter: AVAudioConverter?
    private var converterRate: Double = 0
    /// Fills silence while the source is quiet. See `RecordedAudioClock.silenceToCatchUp`.
    private var catchUpTimer: DispatchSourceTimer?

    /// How many arrivals to hold while waiting for the first frame — a few seconds,
    /// far more than the frame or two that wait ever lasts.
    private static let waitingLimit = 200
    /// Silence is written in pieces this long, so a long gap is not one huge buffer.
    private static let silenceChunkSamples = 24_000
    /// How often to check for a quiet source.
    private static let catchUpInterval = 0.25

    /// - Parameters:
    ///   - keepsUpWhileQuiet: fill silence in real time while no audio arrives. Off
    ///     only for the self-QA check, whose frames are not in real time.
    init(recorders: [FrameRecorder], keepsUpWhileQuiet: Bool = true) {
        self.recorders = recorders
        guard keepsUpWhileQuiet else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.catchUpInterval, repeating: Self.catchUpInterval)
        timer.setEventHandler { [weak self] in self?.catchUp() }
        timer.resume()
        catchUpTimer = timer
    }

    deinit { catchUpTimer?.cancel() }

    /// Takes one buffer of captured audio. Any thread; returns at once.
    func receive(_ interleavedStereo: [Float], sampleRate: Double, hostTime: Double) {
        queue.async { [self] in
            guard !isFinished else { return }
            let arrival = Arrival(samples: interleavedStereo, sampleRate: sampleRate, hostTime: hostTime)
            guard origin != nil else {
                waiting.append(arrival)
                if waiting.count > Self.waitingLimit { waiting.removeFirst() }
                return
            }
            place(arrival)
        }
    }

    /// Sets where the take starts: the presentation time of its first frame. Audio
    /// captured before it is trimmed.
    func start(at firstFramePresentationTime: Double) {
        queue.async { [self] in
            origin = firstFramePresentationTime
            let held = waiting
            waiting.removeAll()
            held.forEach(place)
        }
    }

    /// Stops taking audio, then runs `then` on this queue with whether any arrived.
    /// Anything already received is written first, so the files can be finished
    /// from `then` without racing an append.
    func finish(then: @escaping (_ hadAudio: Bool) -> Void) {
        queue.async { [self] in
            isFinished = true
            catchUpTimer?.cancel()
            catchUpTimer = nil
            then(clock.hasStarted)
        }
    }

    // MARK: - Queue work

    /// Converts, places and writes one buffer.
    private func place(_ arrival: Arrival) {
        guard let origin, !isFinished else { return }
        guard let samples = convertToTrackRate(arrival) else { return }
        let frameCount = samples.count / 2
        guard frameCount > 0,
              let placement = clock.place(count: frameCount, atOffset: arrival.hostTime - origin)
        else { return }

        if placement.silenceBefore > 0 {
            writeSilence(placement.silenceBefore, startingAt: placement.startSample)
        }
        let start = placement.startSample + Int64(placement.silenceBefore)
        let kept = Array(samples[(placement.dropLeading * 2)...])
        write(kept, at: start)
    }

    /// Writes silence up to just behind now, while nothing is arriving.
    private func catchUp() {
        guard let origin, !isFinished else { return }
        let before = clock.writtenSamples
        let silence = clock.silenceToCatchUp(atOffset: CACurrentMediaTime() - origin)
        if silence > 0 { writeSilence(silence, startingAt: before) }
    }

    private func writeSilence(_ count: Int, startingAt start: Int64) {
        var written = 0
        while written < count {
            let piece = min(Self.silenceChunkSamples, count - written)
            write([Float](repeating: 0, count: piece * 2), at: start + Int64(written))
            written += piece
        }
    }

    /// Appends interleaved stereo at the track's rate to every file, at `start`
    /// samples from the take's beginning.
    private func write(_ interleaved: [Float], at start: Int64) {
        guard let buffer = makeSampleBuffer(interleaved, at: start) else { return }
        for recorder in recorders { recorder.appendAudio(buffer) }
    }

    /// The buffer's samples at the track's rate, interleaved stereo.
    private func convertToTrackRate(_ arrival: Arrival) -> [Float]? {
        guard arrival.sampleRate != trackRate else { return arrival.samples }

        if converter == nil || converterRate != arrival.sampleRate {
            guard let from = Self.stereoFormat(arrival.sampleRate),
                  let to = Self.stereoFormat(trackRate),
                  let made = AVAudioConverter(from: from, to: to) else {
                Log.error(.app, "cannot convert \(Int(arrival.sampleRate)) Hz audio for recording")
                return nil
            }
            converter = made
            converterRate = arrival.sampleRate
            Log.info(.app, "recording audio converted from \(Int(arrival.sampleRate)) Hz")
        }
        guard let converter else { return nil }

        let inputFrames = arrival.samples.count / 2
        guard let input = AVAudioPCMBuffer(
                pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(inputFrames)),
              let output = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: AVAudioFrameCount(
                    (Double(inputFrames) * trackRate / arrival.sampleRate).rounded(.up) + 64))
        else { return nil }
        input.frameLength = AVAudioFrameCount(inputFrames)
        arrival.samples.withUnsafeBytes { source in
            guard let destination = input.mutableAudioBufferList.pointee.mBuffers.mData else { return }
            destination.copyMemory(from: source.baseAddress!, byteCount: source.count)
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let data = output.audioBufferList.pointee.mBuffers.mData else {
            Log.error(.app, "recording audio conversion failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        }
        let count = Int(output.frameLength) * 2
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
    }

    private static func stereoFormat(_ rate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true)
    }

    /// Wraps interleaved stereo float samples as a sample buffer stamped `start`
    /// samples into the take.
    private func makeSampleBuffer(_ interleaved: [Float], at start: Int64) -> CMSampleBuffer? {
        let frameCount = interleaved.count / 2
        guard frameCount > 0 else { return nil }
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size * 2)
        var description = AudioStreamBasicDescription(
            mSampleRate: trackRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &format) == noErr, let format else { return nil }

        let byteCount = interleaved.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0,
                blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = interleaved.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else { return nil }

        var buffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: frameCount,
            presentationTimeStamp: CMTime(value: start, timescale: CMTimeScale(trackRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer)
        guard status == noErr else {
            Log.error(.app, "could not wrap recording audio (\(status))")
            return nil
        }
        return buffer
    }
}

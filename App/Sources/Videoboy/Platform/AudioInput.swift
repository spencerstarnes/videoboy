//
//  AudioInput.swift — the live audio tap (SPEC 4c).
//
//  Purpose : Pulls samples off an input device with AVAudioEngine and feeds them to
//            the analyser. Everything that decides what the numbers *mean* lives in
//            Core; this file only gets the samples.
//  Inputs  : the default audio input device.
//  Outputs : `AudioFrame`s, delivered to a callback on the audio thread.
//  Connects: AudioAnalyzer and TempoEstimator (Core), the Engine (which routes the
//            results to the reactivity bus and, optionally, the transport).
//  Extend  : system-audio capture needs a loopback device such as BlackHole; it
//            appears as an ordinary input, so nothing here changes.
//
//  Permission: macOS gates audio input behind the microphone permission, and the
//  bundle carries NSMicrophoneUsageDescription for it. Denied permission degrades to
//  "audio clock unavailable", never a crash.
//

import AVFoundation
import Foundation
import VideoboyCore

/// Taps the default audio input and analyses it.
final class AudioInput {

    /// Called for each analysed window, on the audio thread. Keep it cheap.
    var onFrame: ((AudioFrame) -> Void)?
    /// Called when a new tempo estimate is available, on the audio thread.
    var onTempo: ((TempoEstimate) -> Void)?

    /// Whether the tap is running.
    private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private var analyzer: AudioAnalyzer?
    private var tempoEstimator: TempoEstimator?

    /// Samples not yet analysed. The tap hands over whatever buffer size it likes,
    /// which is rarely the analyser's window size, so they are accumulated here.
    private var pending: [Float] = []

    /// Requests microphone access, blocking until answered.
    private func ensureAuthorised() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            Log.info(.clock, "requesting microphone access for audio beat detection")
            let gate = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { allowed in
                granted = allowed
                gate.signal()
            }
            if gate.wait(timeout: .now() + 60) == .timedOut {
                Log.error(.clock, "microphone permission prompt was not answered")
                return false
            }
            return granted
        case .denied, .restricted:
            Log.warn(.clock, "microphone access denied; the audio clock and reactivity are unavailable")
            return false
        @unknown default:
            return false
        }
    }

    /// Starts tapping the default input.
    ///
    /// - Returns: false when audio is unavailable, which leaves the app running with
    ///   the audio clock source greyed out rather than failing to launch.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        guard ensureAuthorised() else { return false }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            Log.error(.clock, "the audio input reports no usable format; is a device connected?")
            return false
        }

        let analyzer = AudioAnalyzer(sampleRate: format.sampleRate)
        let estimator = TempoEstimator(sampleRate: format.sampleRate)
        self.analyzer = analyzer
        self.tempoEstimator = estimator
        pending.removeAll()

        // Tap size is a request, not a promise — CoreAudio delivers what it likes,
        // which is why the samples are accumulated rather than analysed per buffer.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer: buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            Log.error(.clock, "could not start the audio engine: \(error)")
            input.removeTap(onBus: 0)
            return false
        }

        isRunning = true
        Log.info(.clock, "audio input running at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
        return true
    }

    /// Stops tapping.
    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        analyzer?.reset()
        tempoEstimator?.reset()
        pending.removeAll()
        Log.info(.clock, "audio input stopped")
    }

    /// Accumulates a delivered buffer and analyses whole windows out of it.
    private func consume(buffer: AVAudioPCMBuffer) {
        guard let analyzer, let tempoEstimator,
              let channelData = buffer.floatChannelData else { return }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }

        // Mix to mono. A stereo mix where one channel is out of phase would partially
        // cancel, but for level and onset detection that is a fair trade against
        // analysing both channels.
        pending.reserveCapacity(pending.count + frameCount)
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channelData[channel][frame]
            }
            pending.append(sum / Float(channelCount))
        }

        let windowSize = AudioAnalyzer.windowSize
        while pending.count >= windowSize {
            let window = Array(pending[0..<windowSize])
            pending.removeFirst(windowSize)

            let frame = analyzer.analyze(samples: window)
            onFrame?(frame)

            tempoEstimator.add(flux: frame.flux)
            if let estimate = tempoEstimator.estimate() {
                onTempo?(estimate)
            }
        }

        // A runaway backlog means the analyser is not keeping up; drop the oldest
        // rather than growing without bound.
        if pending.count > windowSize * 8 {
            pending.removeFirst(pending.count - windowSize)
            Log.warn(.clock, "audio analysis fell behind; dropped a backlog of samples")
        }
    }
}

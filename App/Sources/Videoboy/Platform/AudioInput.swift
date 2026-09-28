//
//  AudioInput.swift — the live audio tap (SPEC 4c).
//
//  Purpose : Gets samples from wherever the music is — the input device, everything
//            the Mac is playing, or one app — and feeds them to the analyser and the
//            beat tracker. Everything that decides what the numbers *mean* lives in
//            Core; this file only gets the samples and keeps time on them.
//  Inputs  : an `AudioCaptureSource`.
//  Outputs : `AudioFrame`s and `BeatTrackerReport`s, delivered on the analysis queue.
//  Connects: AudioAnalyzer, and BeatNetTracker (Core) — or the older BeatTracker
//            when VIDEOBOY_LEGACY_BEAT=1 or the BeatNet weights are missing —
//            SystemAudioTap (for system and
//            app sources), and the Engine, which routes results to the reactivity
//            bus and the transport.
//  Extend  : a new kind of source is a new case in `AudioCaptureSource` and a branch
//            in `start()` that ends by calling `deliver(_:sampleRate:hostTime:)`.
//
//  Permission: the input device needs microphone permission (NSMicrophoneUsage-
//  Description); system and app sources need System Audio Recording permission
//  (NSAudioCaptureUsageDescription). Refused permission degrades to "unavailable" or
//  to a silent tap, never a crash.
//

import AVFoundation
import Foundation
import QuartzCore
import VideoboyCore

/// Where the beat tracker listens.
enum AudioCaptureSource: Equatable {
    /// The default input device: a microphone, or a line in from the mixer.
    case inputDevice
    /// Everything the Mac is playing.
    case systemAudio
    /// One app's audio — Music, Spotify, a browser.
    case application(bundleID: String, name: String)

    /// Short enough for the toolbar's CLOCK field.
    var shortName: String {
        switch self {
        case .inputDevice: "Input"
        case .systemAudio: "System"
        case .application(_, let name): name.count > 10 ? String(name.prefix(9)) + "…" : name
        }
    }

    /// For menus and notices.
    var longName: String {
        switch self {
        case .inputDevice: "Audio Input (microphone or line in)"
        case .systemAudio: "System Audio"
        case .application(_, let name): name
        }
    }

    /// Whether this macOS can capture it. Process taps arrived in 14.2.
    var isSupported: Bool {
        switch self {
        case .inputDevice: return true
        case .systemAudio, .application:
            if #available(macOS 14.2, *) { return true }
            return false
        }
    }
}

/// Captures audio from one source and analyses it.
final class AudioInput {

    /// Called for each analysed window, on the analysis queue. Keep it cheap.
    var onFrame: ((AudioFrame) -> Void)?
    /// Called a few times a second with the tracker's view, on the analysis queue.
    /// The second argument is the host time (CACurrentMediaTime's clock) of the end
    /// of the newest analysed window — what `secondsSinceBeat` is measured back from.
    var onBeatReport: ((BeatTrackerReport, Double) -> Void)?

    let source: AudioCaptureSource
    /// Whether capture is running.
    private(set) var isRunning = false
    /// Why the last `start()` failed, for the notice. Nil after a success.
    private(set) var failureReason: String?

    private let engine = AVAudioEngine()
    /// The SystemAudioTap, when the source is not the input device. Typed loosely
    /// because the class only exists on macOS 14.2 and later.
    private var tap: AnyObject?

    /// Analysis runs here, never on an audio device's IO thread: the tempo estimate
    /// is a few milliseconds of work four times a second, and an IO thread that
    /// stalls that long glitches.
    private let analysisQueue = DispatchQueue(label: "videoboy.audio.analysis", qos: .userInitiated)

    // Analysis-queue state.
    private var analyzer: AudioAnalyzer?
    private var tracker: BeatTracker?
    /// BeatNet, which does the tracking when it is available; `tracker` then only
    /// stands by. See BeatNetTracker and docs/BEATNET.md.
    private var beatNet: BeatNetTracker?
    /// Which tracker the last analysed audio went through: "BeatNet", "onset", or
    /// "none" before any audio. Written on the analysis queue; read it only once the
    /// input has stopped (self-QA does, to prove which path it measured).
    private(set) var trackerInUse = "none"
    private var sampleRate: Double = 0
    /// Samples not yet analysed. Sources deliver whatever buffer size they like,
    /// which is rarely the analyser's window size, so they are accumulated here.
    private var pending: [Float] = []
    /// Host time of `pending[0]`.
    private var pendingStartTime: Double = 0

    init(source: AudioCaptureSource) {
        self.source = source
    }

    // Only the capture is torn down here: `stop()` also queues work that captures
    // self, which must never happen from deinit. The Engine calls `stop()` itself.
    deinit { stopCapture() }

    /// Requests microphone access, blocking until answered.
    private func ensureMicrophoneAuthorised() -> Bool {
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

    /// Starts capturing.
    ///
    /// - Returns: false when the source is unavailable (see `failureReason`), which
    ///   leaves the app on the internal clock rather than failing.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        failureReason = nil
        switch source {
        case .inputDevice:
            isRunning = startInputDevice()
        case .systemAudio, .application:
            guard #available(macOS 14.2, *) else {
                failureReason = "Listening to system or app audio needs macOS 14.2 or later. Audio Input still works."
                return false
            }
            isRunning = startTap()
        }
        if isRunning { Log.info(.clock, "beat detection listening to \(source.longName)") }
        return isRunning
    }

    private func startInputDevice() -> Bool {
        guard ensureMicrophoneAuthorised() else {
            failureReason = "Microphone access is off. Allow Videoboy in System Settings ▸ Privacy & Security ▸ Microphone."
            return false
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            failureReason = "The audio input reports no usable format. Is an input device connected?"
            Log.error(.clock, "the audio input reports no usable format; is a device connected?")
            return false
        }

        // Tap size is a request, not a promise — CoreAudio delivers what it likes.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self, let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            let channelCount = Int(buffer.format.channelCount)
            guard frameCount > 0, channelCount > 0 else { return }
            // Mix to mono. An out-of-phase stereo pair would partly cancel, but for
            // level and onset detection that is a fair trade.
            var mono = [Float](repeating: 0, count: frameCount)
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for frame in 0..<frameCount { mono[frame] += samples[frame] }
            }
            if channelCount > 1 {
                let scale = 1 / Float(channelCount)
                for frame in 0..<frameCount { mono[frame] *= scale }
            }
            let hostTime = when.isHostTimeValid
                ? AVAudioTime.seconds(forHostTime: when.hostTime) : CACurrentMediaTime()
            self.deliver(mono, sampleRate: format.sampleRate, hostTime: hostTime)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            failureReason = "Could not start the audio input: \(error.localizedDescription)"
            Log.error(.clock, "could not start the audio engine: \(error)")
            return false
        }
        Log.info(.clock, "audio input running at \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
        return true
    }

    @available(macOS 14.2, *)
    private func startTap() -> Bool {
        let target: SystemAudioTap.Target
        switch source {
        case .application(let bundleID, let name):
            let objects = AudioAppCatalog.processObjects(forBundleID: bundleID)
            guard !objects.isEmpty else {
                failureReason = "\(name) is not running, or has not opened any audio yet. Start playback in it, or choose System Audio."
                Log.warn(.clock, "cannot tap \(name): no audio processes")
                return false
            }
            target = .processes(objects)
        default:
            target = .system
        }

        let systemTap = SystemAudioTap()
        do {
            try systemTap.start(target) { [weak self] samples, sampleRate, hostTime in
                self?.deliver(samples, sampleRate: sampleRate, hostTime: hostTime)
            }
        } catch {
            failureReason = "\(error)"
            Log.error(.clock, "system audio tap failed: \(error)")
            return false
        }
        tap = systemTap
        return true
    }

    /// Stops capturing and forgets the analysis state.
    func stop() {
        guard isRunning else { return }
        stopCapture()
        // Anything already queued still runs, against a tracker that is about to be
        // dropped; the Engine ignores reports from an input it no longer holds.
        analysisQueue.async { [self] in
            analyzer = nil
            tracker = nil
            beatNet = nil
            pending.removeAll()
        }
        Log.info(.clock, "audio input stopped (\(source.longName))")
    }

    /// Stops the device or tap. Safe to call when nothing is running.
    private func stopCapture() {
        guard isRunning else { return }
        switch source {
        case .inputDevice:
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        case .systemAudio, .application:
            if #available(macOS 14.2, *) { (tap as? SystemAudioTap)?.stop() }
            tap = nil
        }
        isRunning = false
    }

    /// BeatNet for this rate, or nil — with the reason logged — to use the older
    /// tracker. Analysis queue.
    private static func makeBeatNet(sampleRate: Double) -> BeatNetTracker? {
        if ProcessInfo.processInfo.environment["VIDEOBOY_LEGACY_BEAT"] == "1" {
            Log.info(.clock, "beat tracking: the older onset tracker (VIDEOBOY_LEGACY_BEAT=1)")
            return nil
        }
        switch BeatNetWeights.shared {
        case .success(let weights):
            Log.info(.clock, "beat tracking: BeatNet at \(Int(sampleRate)) Hz")
            return BeatNetTracker(weights: weights, inputRate: sampleRate)
        case .failure(let error):
            Log.warn(.clock, "beat tracking: BeatNet unavailable (\(error)); using the older onset tracker")
            return nil
        }
    }

    /// Hands samples to the analysis queue. Called from whichever thread the source
    /// delivers on.
    private func deliver(_ samples: [Float], sampleRate: Double, hostTime: Double) {
        analysisQueue.async { [weak self] in
            self?.analyse(samples, sampleRate: sampleRate, hostTime: hostTime)
        }
    }

    /// Accumulates samples and analyses whole windows out of them. Analysis queue.
    private func analyse(_ samples: [Float], sampleRate: Double, hostTime: Double) {
        guard isRunning else { return }
        // First buffer, or the device changed rate: start the analysis afresh.
        if analyzer == nil || sampleRate != self.sampleRate {
            self.sampleRate = sampleRate
            analyzer = AudioAnalyzer(sampleRate: sampleRate)
            tracker = BeatTracker(sampleRate: sampleRate)
            // An input nobody asks for beats from (ISF shaders' audio) skips BeatNet.
            beatNet = onBeatReport == nil ? nil : Self.makeBeatNet(sampleRate: sampleRate)
            trackerInUse = onBeatReport == nil ? "none" : (beatNet == nil ? "onset" : "BeatNet")
            pending.removeAll()
        }
        guard let analyzer, let tracker else { return }

        // Keep time on the samples: pending[0] is at pendingStartTime. Resync on a
        // gap or overlap bigger than a window, which is what a device hiccup looks like.
        let windowDuration = Double(AudioAnalyzer.windowSize) / sampleRate
        let pendingEndTime = pendingStartTime + Double(pending.count) / sampleRate
        if pending.isEmpty || abs(hostTime - pendingEndTime) > windowDuration {
            pendingStartTime = hostTime - Double(pending.count) / sampleRate
        }
        pending.append(contentsOf: samples)

        let windowSize = AudioAnalyzer.windowSize
        while pending.count >= windowSize {
            let window = Array(pending[0..<windowSize])
            let frame = analyzer.analyze(samples: window)
            pending.removeFirst(windowSize)
            pendingStartTime += windowDuration
            onFrame?(frame)
            if let beatNet {
                // Same window, same clock: each report is measured back from the end
                // of the window just fed, which pendingStartTime now is.
                for report in beatNet.add(window) { onBeatReport?(report, pendingStartTime) }
            } else if let report = tracker.add(frame) {
                // pendingStartTime is now the end of the window just analysed.
                onBeatReport?(report, pendingStartTime)
            }
        }

        // A runaway backlog means analysis is not keeping up; drop the oldest rather
        // than growing without bound.
        if pending.count > windowSize * 8 {
            let drop = pending.count - windowSize
            pending.removeFirst(drop)
            pendingStartTime += Double(drop) / sampleRate
            Log.warn(.clock, "audio analysis fell behind; dropped a backlog of samples")
        }
    }
}

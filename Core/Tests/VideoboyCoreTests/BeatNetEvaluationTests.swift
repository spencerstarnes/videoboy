//
//  BeatNetEvaluationTests.swift — both beat trackers over real music, for scoring.
//
//  Purpose : Synthetic drums are what let the old tracker look fine while failing on
//            records. This runs real music — the owner's own files, never committed —
//            through the old onset tracker and through BeatNet, exactly as the live
//            input would deliver it, and writes every report to a CSV for
//            scripts/beat-eval.py to score against reference beats.
//  Inputs  : VIDEOBOY_BEAT_EVAL_CLIPS — a colon-separated list of audio files (WAV,
//            AIFF, anything AVAudioFile reads). Skipped when unset.
//            VIDEOBOY_BEAT_EVAL_OUT — the output folder (default selfqa/out/beatnet).
//  Outputs : one `<clip name>.csv` per clip: tracker, time, state, bpm, confidence,
//            predicted beat time.
//  Connects: AudioAnalyzer + BeatTracker (old), BeatNetTracker (new).
//

import AVFoundation
import XCTest
@testable import VideoboyCore

final class BeatNetEvaluationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Log.echoesToStandardError = false
    }

    func testEvaluateClips() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let list = environment["VIDEOBOY_BEAT_EVAL_CLIPS"], !list.isEmpty else {
            throw XCTSkip("set VIDEOBOY_BEAT_EVAL_CLIPS to score the beat trackers on real music")
        }
        let outputFolder = URL(fileURLWithPath: environment["VIDEOBOY_BEAT_EVAL_OUT"] ?? "selfqa/out/beatnet")
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let weights = try BeatNetWeights(contentsOf: BeatNetTests.weightsURL)

        for path in list.split(separator: ":").map(String.init) {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let rate = file.processingFormat.sampleRate
            let frames = AVAudioFrameCount(file.length)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            try file.read(into: buffer)
            let channels = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: Int(buffer.frameLength))
            for channel in 0..<channels {
                let data = buffer.floatChannelData![channel]
                for index in mono.indices { mono[index] += data[index] / Float(channels) }
            }

            var lines = ["tracker,time,state,bpm,confidence,beat"]
            func record(_ tracker: String, _ time: Double, _ report: BeatTrackerReport) {
                let beat = report.secondsSinceBeat.map { String(format: "%.4f", time - $0) } ?? ""
                lines.append("\(tracker),\(String(format: "%.4f", time)),\(report.state.rawValue),"
                    + "\(report.beatsPerMinute.map { String(format: "%.3f", $0) } ?? ""),"
                    + "\(String(format: "%.3f", report.confidence)),\(beat)")
            }

            // Old: 1,024-sample windows through the analyser and tracker, as AudioInput does.
            let analyzer = AudioAnalyzer(sampleRate: rate)
            let old = BeatTracker(sampleRate: rate)
            let window = AudioAnalyzer.windowSize
            var index = 0
            while index + window <= mono.count {
                let frame = analyzer.analyze(samples: Array(mono[index..<(index + window)]))
                index += window
                if let report = old.add(frame) { record("old", Double(index) / rate, report) }
            }

            // BeatNet: the same buffers.
            let beatNet = BeatNetTracker(weights: weights, inputRate: rate, mode: .particleFilter)
            beatNet.keepsAllBeats = true
            let started = Date()
            index = 0
            while index < mono.count {
                let end = min(index + window, mono.count)
                for report in beatNet.add(Array(mono[index..<end])) {
                    record("beatnet", beatNet.streamTime, report)
                }
                index = end
            }
            let elapsed = Date().timeIntervalSince(started)

            // Hybrid (the default mode): the activations through the autocorrelation tracker.
            var tuning = BeatNetTracker.activationTempoTuning
            // Experiment knobs: VIDEOBOY_HYBRID_TUNING="lock=8,conf=0.25,stick=0.8,relock=8"
            // overrides BeatNetTracker.activationTempoTuning.
            for pair in (environment["VIDEOBOY_HYBRID_TUNING"] ?? "").split(separator: ",") {
                let parts = pair.split(separator: "=")
                guard parts.count == 2, let value = Double(parts[1]) else { continue }
                switch parts[0] {
                case "lock": tuning.estimatesToLock = Int(value)
                case "conf": tuning.minimumConfidence = value
                case "stick": tuning.stickiness = value
                case "relock": tuning.estimatesToRelock = Int(value)
                case "smooth": tuning.smoothing = value
                default: break
                }
            }
            let hybrid = BeatNetTracker(weights: weights, inputRate: rate, activationTempoTuning: tuning)
            index = 0
            while index < mono.count {
                let end = min(index + window, mono.count)
                for report in hybrid.add(Array(mono[index..<end])) { record("hybrid", hybrid.streamTime, report) }
                index = end
            }
            // The particle filter's raw beats, for comparing the port with the Python.
            for time in beatNet.allBeatTimes {
                lines.append("beatnet-beat,\(String(format: "%.4f", time)),,,,")
            }
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            try lines.joined(separator: "\n").write(
                to: outputFolder.appendingPathComponent("\(name).csv"), atomically: true, encoding: .utf8)
            print("[beat-eval] \(name): \(String(format: "%.1f", Double(mono.count) / rate)) s of audio, "
                + "BeatNet took \(String(format: "%.2f", elapsed)) s")
        }
    }
}

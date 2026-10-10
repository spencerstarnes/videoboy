//
//  RecordSelfQA.swift — that a take produces files you can actually open.
//
//  Purpose : Recording is the one feature where "it seemed to work" is discovered
//            hours later, with nothing to show for a set. So this records a real
//            graph to real files and then READS THEM BACK with AVFoundation — frame
//            count, duration, dimensions, and a decoded frame that is not black.
//            Anything less would pass on a file that cannot be opened. Then the
//            sound: audio pushed in at known times (at 44.1 kHz, a gap, then 48 kHz)
//            must come back out of every file at those times, and a take with no
//            audio must have no audio track.
//  Inputs  : none; it builds its own engine and writes to a temporary folder.
//  Outputs : selfqa/out/phase-4/record/ — a result and a frame read back OUT of the
//            recorded file, not the one that went in.
//  Connects: RecordingSession, FrameRecorder, TakeAudio, Engine.
//

import AVFoundation
import Foundation
import VideoboyCore

enum RecordSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "phase-4/record")

        guard let metal = MetalContext.shared else {
            check.record(AssertionResult(
                name: "Metal is available", passed: false, detail: "no device"))
            return check.finish()
        }

        let engine = Engine()
        let source = RepoPaths.samples.appendingPathComponent("motion.dv")
        guard FileManager.default.fileExists(atPath: source.path),
              engine.load(url: source, intoChannel: "A") else {
            check.record(AssertionResult(
                name: "a source loads", passed: false,
                detail: "samples/motion.dv is missing — run scripts/make-fixtures.sh"))
            return check.finish()
        }
        engine.registry.setValue(0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        engine.registry.setValue(0, slot: GraphTopology.primary, code: .crossfadeOneTwo)
        engine.setPlaying(true, channel: "A")

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoboy-record-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Two feeds, because discrete recording is the point (SPEC 15) and a single
        // file would not exercise the part that can go wrong.
        let session: RecordingSession
        do {
            session = try RecordingSession(
                feeds: ["P": Engine.outputSlot, "A": GraphTopology.sourceA],
                codec: .proRes422,
                directory: directory,
                metal: metal,
                framesAreRealTime: false
            )
        } catch {
            check.record(AssertionResult(
                name: "a take opens", passed: false, detail: "\(error)"))
            return check.finish()
        }

        // The audio, on the same clock as the frames (frame 0 is shown at time 0):
        // a 44.1 kHz tone from 0.3 s, nothing from 0.6 s, a 48 kHz tone from 0.7 s.
        // The writer would close that gap up if TakeAudio did not fill it, and the
        // 48 kHz tone would come back at 0.6 s.
        let audioSink = session.audioSink
        func pushTone(from start: Double, to end: Double, rate: Double) {
            let chunk = 512
            var position = Int((start * rate).rounded())
            while Double(position) / rate < end {
                var stereo = [Float](repeating: 0, count: chunk * 2)
                for frame in 0..<chunk {
                    let value = Float(0.3 * sin(2 * Double.pi * 440 * Double(position + frame) / rate))
                    stereo[frame * 2] = value
                    stereo[frame * 2 + 1] = value
                }
                audioSink(stereo, rate, Double(position) / rate)
                position += chunk
            }
        }

        let framesToRecord = 30
        // Three frames the engine never produced, as in a stall: the frames after
        // must still land at their own times, not three frames early.
        let lostFrames = 20..<23
        let started = Date()
        for index in 0..<framesToRecord where !lostFrames.contains(index) {
            let context = RenderContext(
                frameIndex: index,
                presentationTime: Double(index) / StandardDefinition.frameRate,
                musicalPosition: nil
            )
            let produced = engine.evaluateGraph(context: context)
            session.write(presentationTime: context.presentationTime) { feed in
                switch feed {
                case "P": return produced[Engine.outputSlot] ?? produced[GraphTopology.primary]
                default: return produced[GraphTopology.sourceA]
                }
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        pushTone(from: 0.3, to: 0.6, rate: 44_100)
        pushTone(from: 0.7, to: Double(framesToRecord) / StandardDefinition.frameRate, rate: 48_000)

        // Finishing is asynchronous; a file read before the moov atom is written is a
        // file that cannot be opened, which is exactly the bug worth catching.
        let finished = DispatchSemaphore(value: 0)
        var written: [URL] = []
        session.finish { urls in
            written = urls
            finished.signal()
        }
        // The writer calls back on the main queue, so this has to be pumped rather
        // than blocked on, or the check deadlocks against its own completion.
        while finished.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        check.record(AssertionResult(
            name: "the take knows it has sound",
            passed: session.hadAudio, detail: session.hadAudio ? "yes" : "no"))

        check.record(AssertionResult(
            name: "a take writes one file per armed feed",
            passed: written.count == 2,
            detail: "\(written.count) files: "
                + written.map(\.lastPathComponent).joined(separator: ", ")
        ))

        for url in written {
            let label = url.deletingPathExtension().lastPathComponent
            let asset = AVURLAsset(url: url)

            guard let track = asset.tracks(withMediaType: .video).first else {
                check.record(AssertionResult(
                    name: "\(label) has a video track", passed: false,
                    detail: "the file has no readable video"))
                continue
            }

            let duration = CMTimeGetSeconds(asset.duration)
            let expected = Double(framesToRecord) / StandardDefinition.frameRate
            check.record(AssertionResult(
                name: "\(label) is as long as the take",
                // Within a frame: the last frame's duration is a legitimate rounding
                // difference, anything more means frames were dropped.
                passed: abs(duration - expected) < (2.0 / StandardDefinition.frameRate),
                detail: String(format: "%.3f s recorded, %.3f s expected", duration, expected)
            ))

            check.record(AssertionResult(
                name: "\(label) is the canvas size (\(CanvasGeometry.project.width)x\(CanvasGeometry.project.height))",
                passed: Int(track.naturalSize.width) == CanvasGeometry.project.width
                    && Int(track.naturalSize.height) == CanvasGeometry.project.height,
                detail: "\(Int(track.naturalSize.width))x\(Int(track.naturalSize.height))"
            ))

            // Read a frame back OUT of the file. A writer that produced a valid but
            // empty file would pass everything above.
            guard let decoder = AVFClipDecoder(url: url),
                  let frame = decoder.image(at: framesToRecord / 2, corruption: .inert) else {
                check.record(AssertionResult(
                    name: "\(label) can be decoded again", passed: false,
                    detail: "the recorded file would not decode"))
                continue
            }
            _ = try? check.writeImage(frame, named: "\(label)-read-back.png")
            checkSound(in: asset, label: label, check: check)
            check.record(AssertionResult(
                name: "\(label) contains a picture, not black",
                passed: FrameAssertions.signalPresent(frame, varianceThreshold: 25.0),
                detail: "luminance variance "
                    + String(format: "%.1f", FrameAssertions.luminanceVariance(frame))
            ))
        }

        // Cost, stated. Two feeds means two readbacks and two ProRes encodes per
        // frame, which is the expensive part and worth knowing before a set.
        let perFrame = elapsed / Double(framesToRecord) * 1000
        let budget = 1000.0 / StandardDefinition.frameRate
        check.record(AssertionResult(
            name: "recording two feeds keeps inside the frame budget",
            passed: perFrame < budget,
            detail: String(format: "%.1f ms per frame against a %.1f ms budget", perFrame, budget)
        ))

        checkSilentTake(directory: directory, metal: metal, check: check)
        return check.finish()
    }

    /// Reads the sound back out of a recorded file and checks it is where it was put.
    private static func checkSound(in asset: AVURLAsset, label: String, check: SelfQACheck) {
        guard let track = asset.tracks(withMediaType: .audio).first else {
            check.record(AssertionResult(
                name: "\(label) has a sound track", passed: false, detail: "no audio track"))
            return
        }
        let rate = FrameRecorder.audioSampleRate
        guard let reader = try? AVAssetReader(asset: asset) else { return }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 2
        ])
        reader.add(output)
        reader.startReading()
        var left: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            _ = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            for index in stride(from: 0, to: samples.count, by: 2) { left.append(samples[index]) }
        }

        // Where the sound starts after a given time, in seconds.
        func onset(after time: Double) -> Double? {
            let from = Int(time * rate)
            guard from < left.count else { return nil }
            return (from..<left.count).first { abs(left[$0]) > 0.05 }.map { Double($0) / rate }
        }
        let tolerance = 0.010
        let first = onset(after: 0)
        let afterGap = onset(after: 0.65)
        let quietInGap = onset(after: 0.61).map { $0 >= 0.69 } ?? false
        check.record(AssertionResult(
            name: "\(label) sound starts where it was captured (44.1 kHz, converted)",
            passed: first.map { abs($0 - 0.3) < tolerance } ?? false,
            detail: first.map { String(format: "starts at %.4f s, expected 0.3000", $0) } ?? "silent"))
        check.record(AssertionResult(
            name: "\(label) keeps a gap in the sound instead of closing it up",
            passed: quietInGap && (afterGap.map { abs($0 - 0.7) < tolerance } ?? false),
            detail: afterGap.map { String(format: "resumes at %.4f s, expected 0.7000", $0) } ?? "never resumes"))
        let seconds = Double(left.count) / rate
        let expected = 30 / StandardDefinition.frameRate
        check.record(AssertionResult(
            name: "\(label) sound runs as long as the picture",
            passed: abs(seconds - expected) < 0.05,
            detail: String(format: "%.3f s of sound, %.3f s of picture", seconds, expected)))
    }

    /// A take with no audio source must have no sound track — not a silent one,
    /// which would look like the audio failed rather than was never there.
    private static func checkSilentTake(directory: URL, metal: MetalContext, check: SelfQACheck) {
        guard let session = try? RecordingSession(
            feeds: ["P": Engine.outputSlot], codec: .h264,
            directory: directory.appendingPathComponent("silent"),
            metal: metal, framesAreRealTime: false),
            let texture = metal.makeTexture(from: TestPattern.colorBars(), label: "record-silent") else {
            check.record(AssertionResult(
                name: "a take with no audio opens", passed: false, detail: "could not open"))
            return
        }
        for index in 0..<10 {
            session.write(presentationTime: Double(index) / StandardDefinition.frameRate) { _ in texture }
        }
        let finished = DispatchSemaphore(value: 0)
        var written: [URL] = []
        session.finish { urls in
            written = urls
            finished.signal()
        }
        while finished.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let audioTracks = written.first.map { AVURLAsset(url: $0).tracks(withMediaType: .audio).count } ?? -1
        check.record(AssertionResult(
            name: "a take with no audio source has no sound track",
            passed: audioTracks == 0 && !session.hadAudio,
            detail: "\(audioTracks) audio tracks, hadAudio \(session.hadAudio)"))
    }
}

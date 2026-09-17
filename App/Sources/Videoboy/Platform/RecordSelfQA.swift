//
//  RecordSelfQA.swift — that a take produces files you can actually open.
//
//  Purpose : Recording is the one feature where "it seemed to work" is discovered
//            hours later, with nothing to show for a set. So this records a real
//            graph to real files and then READS THEM BACK with AVFoundation — frame
//            count, duration, dimensions, and a decoded frame that is not black.
//            Anything less would pass on a file that cannot be opened.
//  Inputs  : none; it builds its own engine and writes to a temporary folder.
//  Outputs : selfqa/out/phase-4/record/ — a result and a frame read back OUT of the
//            recorded file, not the one that went in.
//  Connects: RecordingSession, FrameRecorder, Engine.
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
                metal: metal
            )
        } catch {
            check.record(AssertionResult(
                name: "a take opens", passed: false, detail: "\(error)"))
            return check.finish()
        }

        let framesToRecord = 30
        let started = Date()
        for index in 0..<framesToRecord {
            let context = RenderContext(
                frameIndex: index,
                presentationTime: Double(index) / StandardDefinition.frameRate,
                musicalPosition: nil
            )
            let produced = engine.evaluateGraph(context: context)
            session.write { feed in
                switch feed {
                case "P": return produced[Engine.outputSlot] ?? produced[GraphTopology.primary]
                default: return produced[GraphTopology.sourceA]
                }
            }
        }
        let elapsed = Date().timeIntervalSince(started)

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
                name: "\(label) is SD",
                passed: Int(track.naturalSize.width) == StandardDefinition.width
                    && Int(track.naturalSize.height) == StandardDefinition.height,
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

        return check.finish()
    }
}

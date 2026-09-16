//
//  CalibrationSelfQA.swift — measures the real feedback round trip (SPEC 10).
//
//  Purpose : Physical feedback through a display adapter, a converter and a grabber
//            has real latency, and beat-driven effects inside that loop play late
//            unless it is measured. This measures it on the actual rig: flash a frame
//            on the HDMI card, watch the DVC100 for it to come back, count the frames.
//  Inputs  : the output display and the DVC100, both from config/devices.json.
//  Outputs : selfqa/out/phase-3/feedback-latency/{*.png,metrics.json,result.txt}.
//  Connects: DVC100StreamCapture (live frames), FeedbackLatencyCalibrator (the
//            detection), OutputWindowController (the flash), Engine (which is told
//            the result so its scheduling compensates).
//
//  Why this needs the streaming capture rather than the recording one: measuring a
//  round trip needs one clock observing both ends. A batch recorder starts on its own
//  schedule, and the uncertainty in when it began would swamp the few-frame latency
//  being measured. Streaming lets this process see the flash go out and the frame
//  come back, so the number means something.
//

import AppKit
import Metal
import VideoboyCore

/// Measures the physical feedback round trip.
enum CalibrationSelfQA {

    /// The latency measurement, as written to metrics.json.
    private struct LatencyMetrics: Codable {
        var roundTripFrames: Int
        var roundTripMilliseconds: Double
        var confidence: Double
        var captureFrameRate: Double
        var outputDisplay: String
        var negotiatedOutputMode: String
        var connector: String
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "phase-3/feedback-latency")

        guard let metal = MetalContext.shared else {
            return check.finish(blockedReason: "no Metal device is available")
        }
        let config = DeviceConfig.load()
        guard let captureConfig = config.loopbackCapture else {
            return check.finish(blockedReason: "config/devices.json has no loopback_capture section")
        }
        guard let display = DisplayRouter.preferredOutputDisplay(config: config) else {
            return check.finish(blockedReason: "no output display could be resolved")
        }

        // The two patterns the measurement flips between. Black is the quiet
        // baseline; white is the marker that has to come back.
        let blackImage = TestPattern.solid(r: 0, g: 0, b: 0)
        let whiteImage = TestPattern.solid(r: 255, g: 255, b: 255)
        guard let blackTexture = metal.makeTexture(from: blackImage, label: "calibrate-black"),
              let whiteTexture = metal.makeTexture(from: whiteImage, label: "calibrate-white") else {
            return check.finish(blockedReason: "could not upload the calibration patterns")
        }

        let output = OutputWindowController(display: display, requestedMode: config.requestedMode)
        output.present()
        output.present(texture: blackTexture)
        check.note("output: '\(display.name)' at \(output.negotiatedMode)")
        defer { output.dismiss() }

        // Let the display settle on black before anything is measured.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        let stream = DVC100StreamCapture(connector: captureConfig.connector)
        do {
            try stream.start()
        } catch let error as CaptureError {
            return check.finish(blockedReason: error.description)
        } catch {
            return check.finish(blockedReason: "\(error)")
        }
        defer { stream.stop() }
        check.note("capturing live from the DVC100 '\(captureConfig.connector)' input")

        // Advance to a fresh frame each time the calibrator asks, so "one sample" is
        // "one captured frame" rather than "the same frame read repeatedly".
        var lastSeenIndex = stream.availableFrameCount() - 1
        var flashIndex: Int?

        func nextFrame() -> ImageBuffer? {
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline {
                let available = stream.availableFrameCount()
                if available > lastSeenIndex + 1 {
                    lastSeenIndex += 1
                    return stream.frame(at: lastSeenIndex)
                }
                // A short sleep: frames arrive every ~33 ms, so polling faster only
                // burns CPU without seeing anything new.
                Thread.sleep(forTimeInterval: 0.004)
            }
            return nil
        }

        let latency: FeedbackLatency
        do {
            latency = try FeedbackLatencyCalibrator.measure(
                frameRate: captureConfig.expectedFormat.fps,
                maximumFrames: 90,
                flash: {
                    // The instant the marker goes out. Everything after this frame
                    // index is a candidate for carrying it back.
                    flashIndex = lastSeenIndex
                    output.present(texture: whiteTexture)
                },
                sample: { nextFrame() }
            )
        } catch let error as CalibrationFailure {
            // An unconnected loop is an environment condition, not a defect.
            try? check.writeImage(stream.latestFrame() ?? blackImage, named: "what-the-grabber-saw.png")
            return check.finish(blockedReason: error.description)
        } catch {
            check.record(AssertionResult(name: "calibration", passed: false, detail: "\(error)"))
            return check.finish()
        }

        // Evidence: the frame before the flash and the one that carried it back.
        if let flashIndex {
            if let before = stream.frame(at: flashIndex) {
                try? check.writeImage(before, named: "01-before-flash.png")
            }
            if let after = stream.frame(at: flashIndex + latency.frames) {
                try? check.writeImage(after, named: "02-marker-returned.png")
            }
        }

        let metrics = LatencyMetrics(
            roundTripFrames: latency.frames,
            roundTripMilliseconds: latency.seconds * 1000,
            confidence: latency.confidence,
            captureFrameRate: captureConfig.expectedFormat.fps,
            outputDisplay: display.name,
            negotiatedOutputMode: output.negotiatedMode,
            connector: captureConfig.connector
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(metrics).write(to: check.artifactURL("metrics.json"))
        } catch {
            Log.error(.selfqa, "could not write latency metrics: \(error)")
        }

        check.note("round trip \(latency.frames) frames = \(String(format: "%.1f", latency.seconds * 1000)) ms")
        check.note("this is what beat-driven effects inside the physical loop must be scheduled early by")

        // The measurement has to be physically plausible. A loop through a display, a
        // converter and a USB grabber cannot be instantaneous, and anything beyond
        // about a second means the detector latched onto something else.
        check.record(AssertionResult(
            name: "round trip is physically plausible",
            passed: latency.frames >= 1 && latency.frames <= 45,
            detail: "\(latency.frames) frames (\(String(format: "%.1f", latency.seconds * 1000)) ms)"
        ))
        check.record(AssertionResult(
            name: "detection is confident",
            passed: latency.confidence > 1.0,
            detail: "marker exceeded the adaptive threshold by \(String(format: "%.1fx", latency.confidence))"
        ))

        return check.finish()
    }
}

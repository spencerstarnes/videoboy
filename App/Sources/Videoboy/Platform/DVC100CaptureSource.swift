//
//  DVC100CaptureSource.swift — loopback capture through the out-of-process dvc100 tool.
//
//  Purpose : The Pinnacle DVC100 presents a vendor-specific USB interface (class
//            0xff), not USB Video Class, so macOS binds no driver and AVFoundation
//            cannot see it at all. The separate `dvc100` command-line tool speaks to
//            its EM28xx bridge over libusb and can. This runs that tool and reads the
//            raw frames it writes, which closes the analog loop for the self-QA
//            harness.
//  Inputs  : a `CaptureRequest`; the `dvc100` binary.
//  Outputs : a `CapturedSequence` — frames plus metrics, exactly like the
//            AVFoundation source, so the harness cannot tell them apart.
//  Connects: conforms to Core's `CaptureSource`; used by the loopback check.
//
//  LICENSING — this is deliberate and must not be "tidied up" into a linked library.
//  The dvc100 tool is GPL v2. Videoboy is distributed, so linking it would impose the
//  GPL on the whole app. CLAUDE.md's rule for GPL components is to run them
//  out-of-process and never link them — the same treatment the libretro cores get in
//  a later phase. So this spawns a separate process and reads its output file. No
//  headers, no library, no linkage.
//

import Foundation
import VideoboyCore

/// Captures from the DVC100 by running the `dvc100` CLI as a separate process.
final class DVC100CaptureSource: CaptureSource {

    /// Which connector to read: "composite" or "svideo".
    ///
    /// This matters more than it sounds: reading the wrong connector returns a
    /// perfectly valid, perfectly black 720x480 picture, which looks exactly like a
    /// dead output stage. It comes from config/devices.json.
    let connector: String

    init(connector: String = "composite") {
        self.connector = connector
    }

    /// Where the tool might be. The first one that exists is used.
    ///
    /// Checked in order of specificity: an explicit override, then the usual install
    /// prefixes, then the source checkout it is normally built in.
    private static var candidatePaths: [String] {
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["VIDEOBOY_DVC100_TOOL"] {
            paths.append(override)
        }
        paths.append("/usr/local/bin/dvc100")
        paths.append("/opt/homebrew/bin/dvc100")
        paths.append(NSHomeDirectory() + "/dvc100/build/dvc100")
        return paths
    }

    /// The tool's path, or nil when it is not installed.
    static var toolPath: String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// One NTSC frame is 720x480 YUYV 4:2:2 — two bytes per pixel.
    private static let bytesPerPixel = 2

    func enumerateDeviceNames() -> [String] {
        guard let toolPath = Self.toolPath else { return [] }
        // `--probe` exits non-zero when no device is attached, which is the check.
        let result = Self.run(toolPath, arguments: ["--probe"], timeout: 10)
        guard result.exitCode == 0 else { return [] }
        return ["DVC100 (via dvc100 tool)"]
    }

    func capture(_ request: CaptureRequest) throws -> CapturedSequence {
        guard let toolPath = Self.toolPath else {
            throw CaptureError.deviceNotFound(
                "the dvc100 tool is not installed (looked in \(Self.candidatePaths.joined(separator: ", ")))")
        }

        let standard: DVStandard = request.expectedFrameRate < 27 ? .pal : .ntsc
        let (width, height) = standard.size
        let frameBytes = width * height * Self.bytesPerPixel

        // Record a whole number of seconds long enough to hold the requested frames.
        let seconds = max(2, Int((Double(request.frameCount) / max(request.expectedFrameRate, 1)).rounded(.up)))

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-dvc100-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let movie = workingDirectory.appendingPathComponent("loop.mov")
        // --raw-sidecar writes the untouched YUYV bytes beside the movie, which is
        // what this wants: no codec, no colour conversion, nothing interpreted.
        let sidecar = workingDirectory.appendingPathComponent("loop.yuv")

        let started = Date()
        let result = Self.run(toolPath, arguments: [
            "--record", String(seconds), movie.path,
            "--raw-sidecar",
            "--no-audio",
            "--codec", "raw",
            "--standard", standard.rawValue,
            "--input", connector
        ], timeout: Double(seconds) + 30)
        let elapsed = Date().timeIntervalSince(started)

        // The tool reports a busy device in its output; that is environmental.
        if result.output.localizedCaseInsensitiveContains("already in use") {
            throw CaptureError.deviceNotFound(
                "the DVC100 is held by another process — quit DVC100.app (or any other app using it) and retry")
        }
        guard result.exitCode == 0 else {
            throw CaptureError.configurationFailed(
                "dvc100 exited with code \(result.exitCode): \(result.output.suffix(300))")
        }

        guard let data = try? Data(contentsOf: sidecar), data.count >= frameBytes else {
            throw CaptureError.noFramesArrived(
                "dvc100 wrote \((try? Data(contentsOf: sidecar))?.count ?? 0) bytes, less than one \(width)x\(height) frame")
        }

        let frameCount = data.count / frameBytes
        Log.info(.selfqa, "dvc100 delivered \(frameCount) frames in \(String(format: "%.2f", elapsed))s")

        // Timestamps come from the real delivered rate: frames actually written over
        // the length of recording that was asked for. A grabber losing frames shows
        // up here as a lower effective rate, which is the point of measuring it.
        let effectiveInterval = Double(seconds) / Double(max(frameCount, 1))

        var frames: [CapturedFrame] = []
        frames.reserveCapacity(min(frameCount, request.frameCount))
        for index in 0..<min(frameCount, request.frameCount) {
            let start = index * frameBytes
            let bytes = [UInt8](data[start..<(start + frameBytes)])
            let image = Self.imageFromYUYV(bytes, width: width, height: height)
            frames.append(CapturedFrame(image: image, timestamp: Double(index) * effectiveInterval))
        }

        let metrics = CaptureMetricsBuilder.summarise(
            frames: frames,
            expectedFrameRate: request.expectedFrameRate,
            loggedOutputMode: request.loggedOutputMode,
            deviceName: "DVC100 (via dvc100 tool)"
        )
        return CapturedSequence(frames: frames, metrics: metrics)
    }

    // MARK: - Conversion

    /// Converts packed YUYV 4:2:2 into RGBA.
    ///
    /// YUYV stores two pixels in four bytes: Y0 U Y1 V, with the chroma pair shared.
    /// The conversion is BT.601 studio-swing, which is what the SAA7113 digitiser
    /// produces for composite NTSC.
    static func imageFromYUYV(_ bytes: [UInt8], width: Int, height: Int) -> ImageBuffer {
        var pixels = [UInt8](repeating: 255, count: width * height * ImageBuffer.bytesPerPixel)

        for y in 0..<height {
            let rowStart = y * width * 2
            var x = 0
            while x < width - 1 {
                let offset = rowStart + x * 2
                guard offset + 3 < bytes.count else { break }
                let y0 = Double(bytes[offset])
                let u = Double(bytes[offset + 1]) - 128.0
                let y1 = Double(bytes[offset + 2])
                let v = Double(bytes[offset + 3]) - 128.0

                writePixel(&pixels, width: width, x: x, y: y, luma: y0, u: u, v: v)
                writePixel(&pixels, width: width, x: x + 1, y: y, luma: y1, u: u, v: v)
                x += 2
            }
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }

    /// Writes one BT.601 studio-swing YUV sample as RGBA.
    private static func writePixel(
        _ pixels: inout [UInt8], width: Int, x: Int, y: Int, luma: Double, u: Double, v: Double
    ) {
        // Studio swing: luma runs 16...235, so it is offset and scaled to 0...255.
        let scaledLuma = 1.164 * (luma - 16.0)
        let red = scaledLuma + 1.596 * v
        let green = scaledLuma - 0.813 * v - 0.391 * u
        let blue = scaledLuma + 2.018 * u

        let offset = (y * width + x) * ImageBuffer.bytesPerPixel
        pixels[offset] = clampToByte(red)
        pixels[offset + 1] = clampToByte(green)
        pixels[offset + 2] = clampToByte(blue)
        pixels[offset + 3] = 255
    }

    private static func clampToByte(_ value: Double) -> UInt8 {
        UInt8(min(max(value, 0), 255))
    }

    // MARK: - Process

    /// Runs a command and returns its exit code and combined output.
    private static func run(
        _ launchPath: String, arguments: [String], timeout: TimeInterval
    ) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "could not launch \(launchPath): \(error)")
        }

        // Read while it runs: a full pipe buffer would otherwise deadlock the child.
        let handle = pipe.fileHandleForReading
        var collected = Data()
        let queue = DispatchQueue(label: "videoboy.dvc100.reader")
        let finished = DispatchSemaphore(value: 0)
        queue.async {
            while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
                collected.append(chunk)
            }
            finished.signal()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            Log.error(.selfqa, "dvc100 exceeded \(Int(timeout))s; terminating it")
            process.terminate()
        }
        process.waitUntilExit()
        _ = finished.wait(timeout: .now() + 5)

        return (process.terminationStatus, String(data: collected, encoding: .utf8) ?? "")
    }
}

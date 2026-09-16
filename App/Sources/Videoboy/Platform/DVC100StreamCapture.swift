//
//  DVC100StreamCapture.swift — live frames from the DVC100, for latency calibration.
//
//  Purpose : `DVC100CaptureSource` records a fixed number of seconds and hands the
//            frames over afterwards, which is fine for measuring a signal but cannot
//            measure a *round trip*: there is no shared clock between when the flash
//            went out and when the recording began. This streams instead, so the
//            same process observes both the flash and the frame that carries it back.
//  Inputs  : the `dvc100` tool's `--stream ... --backup` mode, which appends raw
//            YUYV frames to a file as they arrive.
//  Outputs : frames on demand, by index, as they land.
//  Connects: FeedbackLatencyCalibrator (which flashes and samples through this), the
//            capture source node.
//
//  LICENSING: as with `DVC100CaptureSource`, the GPL `dvc100` tool runs as a separate
//  process and is never linked. See docs/BLOCKED.md.
//
//  Why a file rather than the UDP stream: the tool publishes NUT over UDP for OBS,
//  and `--backup` writes the untouched frames alongside it. Reading fixed-size raw
//  frames out of a growing file needs no container parsing and cannot misinterpret
//  what it is given — the frame boundary is arithmetic.
//

import Foundation
import VideoboyCore

/// Streams live frames from the DVC100 by tailing the tool's raw backup file.
final class DVC100StreamCapture {

    /// Which connector to read.
    let connector: String
    /// Video standard, which fixes the frame size.
    let standard: DVStandard

    private var process: Process?
    private let backupURL: URL
    private let workingDirectory: URL
    private var handle: FileHandle?

    /// Bytes in one frame — YUYV 4:2:2 is two bytes per pixel.
    private let frameBytes: Int
    private let width: Int
    private let height: Int

    init(connector: String = "composite", standard: DVStandard = .ntsc) {
        self.connector = connector
        self.standard = standard
        (self.width, self.height) = standard.size
        self.frameBytes = width * height * 2
        self.workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-dvc100-stream-\(UUID().uuidString)", isDirectory: true)
        self.backupURL = workingDirectory.appendingPathComponent("live.yuv")
    }

    deinit { stop() }

    /// Starts the tool streaming. Returns false if it cannot be started.
    func start() throws {
        guard let toolPath = DVC100CaptureSource.toolPath else {
            throw CaptureError.deviceNotFound("the dvc100 tool is not installed")
        }
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        // Deliberately NOT pre-created: the tool refuses to overwrite an existing
        // backup path, so the file has to be its to make.

        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        // The UDP sink has no listener here and does not need one — it is fire and
        // forget. The backup file is what this class actually reads.
        process.arguments = [
            "--stream", "udp://127.0.0.1:5004",
            "--backup", backupURL.path,
            "--no-audio",
            "--standard", standard.rawValue,
            "--input", connector
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw CaptureError.configurationFailed("could not launch dvc100: \(error)")
        }
        self.process = process

        // Wait for frames to actually start arriving before claiming to be running.
        let deadline = Date().addingTimeInterval(10)
        while availableFrameCount() < 2 && Date() < deadline {
            if !process.isRunning {
                let output = String(data: pipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
                if output.localizedCaseInsensitiveContains("already in use") {
                    throw CaptureError.deviceNotFound(
                        "the DVC100 is held by another process — quit DVC100.app and retry")
                }
                throw CaptureError.noFramesArrived("dvc100 exited: \(output.suffix(200))")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard availableFrameCount() >= 2 else {
            throw CaptureError.noFramesArrived("no frames appeared within 10 seconds")
        }
        // Open the reader only once the tool has created the file.
        self.handle = try? FileHandle(forReadingFrom: backupURL)
        guard handle != nil else {
            throw CaptureError.noFramesArrived("the backup file could not be opened for reading")
        }
        Log.info(.selfqa, "dvc100 streaming live from '\(connector)'")
    }

    /// Stops the tool and cleans up.
    func stop() {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    /// How many complete frames have arrived so far.
    ///
    /// Only whole frames count: a partially written one is not yet readable, and
    /// treating it as readable would hand back a torn picture.
    func availableFrameCount() -> Int {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: backupURL.path)[.size] as? Int else { return 0 }
        return size / frameBytes
    }

    /// Reads one frame by index, or nil if it has not arrived yet.
    func frame(at index: Int) -> ImageBuffer? {
        guard index >= 0, index < availableFrameCount(), let handle else { return nil }
        do {
            try handle.seek(toOffset: UInt64(index * frameBytes))
            guard let data = try handle.read(upToCount: frameBytes), data.count == frameBytes else {
                return nil
            }
            return DVC100CaptureSource.imageFromYUYV([UInt8](data), width: width, height: height)
        } catch {
            Log.warn(.selfqa, "could not read frame \(index): \(error)")
            return nil
        }
    }

    /// The most recently completed frame.
    func latestFrame() -> ImageBuffer? {
        let count = availableFrameCount()
        guard count > 0 else { return nil }
        return frame(at: count - 1)
    }
}

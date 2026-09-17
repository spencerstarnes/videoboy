//
//  FSUAEHost.swift — a real Amiga, as a source.
//
//  Purpose : Runs FS-UAE as a separate program, captures its window, and hands the
//            frames to the graph. This is what makes "the Amiga" an input the mixer
//            can cut to like any other.
//  Inputs  : a TitlerProgram, and whatever the machine draws.
//  Outputs : ImageBuffers, through `EmulatorHost`.
//  Connects: EmulatedTitlerNode (which turns them into textures), EmulatorController,
//            FSUAEConfiguration, AmigaCommandBridge.
//  Extend  : another emulator is another `EmulatorHost`. Nothing above this knows
//            which one is running.
//
//  ── WHY A SEPARATE PROCESS AND A SCREEN CAPTURE ─────────────────────────────────
//
//  FS-UAE is GPL. This app is distributed, so linking it would relicense the whole
//  app — which makes "launch it and never link it" not a workaround but the correct
//  and simplest compliance.
//
//  The consequence is that there is no API to ask it for a frame. There are three ways
//  round that: patch the emulator (which is the linking problem again), have it write
//  frames to a file (slow, and it has no such mode), or capture its window. macOS has
//  a first-class API for the third — ScreenCaptureKit — which composites the window
//  whether or not it is in front, and delivers frames on its own thread.
//
//  The cost is ONE PERMISSION, granted once, and the honest failure when it is not:
//  the panel says what is missing rather than showing a black rectangle.
//
//  ── AND WHY IT CANNOT JITTER THE MIX ────────────────────────────────────────────
//
//  Capture runs on its own queue and writes the newest frame into a slot behind a
//  lock. The render loop takes whatever is there. It never waits for a frame, never
//  asks the emulator for one, and never blocks on the capture queue — a machine that
//  has stalled shows its last frame rather than stalling the mixer with it.
//

import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import VideoboyCore

/// FS-UAE, launched and captured.
final class FSUAEHost: NSObject, EmulatorHost, SCStreamOutput, SCStreamDelegate {

    /// Why it cannot run, or nil when it can.
    private(set) var unavailableReason: String?

    /// Whether a machine is running and frames are arriving.
    var isReady: Bool { process?.isRunning == true }

    /// FS-UAE has no script port of its own; the commands go through the shared
    /// drawer and the ARexx listener inside the machine. See `AmigaCommandBridge`.
    var supportsCommands: Bool { true }

    /// Called on the main thread when the running state changes, for the panel.
    var onStateChanged: (() -> Void)?

    private var process: Process?
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "com.videoboy.fsuae-capture", qos: .userInitiated)

    private let frameLock = NSLock()
    private var newestFrame: ImageBuffer?
    private var framesCaptured = 0

    /// The window title FS-UAE is asked for, which is how the capture finds it.
    ///
    /// Matched as a PREFIX: FS-UAE appends the machine to whatever title it is given,
    /// so "Videoboy Amiga" becomes "Videoboy Amiga · Amiga 1200". An exact match here
    /// silently finds nothing, which looks exactly like the permission being denied.
    private let windowTitlePrefix: String

    private(set) var bootedProgram: TitlerProgram?

    /// Where the config and the shared drawer live.
    let workspace: URL

    init(workspace: URL, windowTitlePrefix: String = "Videoboy Amiga") {
        self.workspace = workspace
        self.windowTitlePrefix = windowTitlePrefix
        super.init()
        if !FSUAEInstallation.isInstalled() {
            unavailableReason = FSUAEInstallation.installationHint
        }
    }

    // MARK: - Running

    @discardableResult
    func boot(_ program: TitlerProgram) -> Bool {
        guard FSUAEInstallation.isInstalled() else {
            unavailableReason = FSUAEInstallation.installationHint
            Log.warn(.titler, unavailableReason ?? "")
            return false
        }
        let config = workspace.appendingPathComponent("videoboy-amiga.fs-uae")
        guard FileManager.default.fileExists(atPath: config.path) else {
            unavailableReason = "No machine has been set up yet. Press SET UP, or run "
                + "scripts/amiga.sh setup."
            Log.warn(.titler, unavailableReason ?? "")
            return false
        }

        shutdown()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: FSUAEInstallation.executablePath)
        process.arguments = [config.path]
        // FS-UAE is chatty and none of it is ours. Its own log file keeps whatever
        // matters; this keeps it out of the app's.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                Log.info(.titler, "FS-UAE exited")
                self?.stopCapture()
                self?.onStateChanged?()
            }
        }

        do {
            try process.run()
        } catch {
            unavailableReason = "Could not start FS-UAE: \(error.localizedDescription)"
            Log.error(.titler, unavailableReason ?? "")
            return false
        }

        self.process = process
        self.bootedProgram = program
        self.unavailableReason = nil
        Log.info(.titler, "FS-UAE started for \(program.name) (pid \(process.processIdentifier))")

        // The window does not exist the instant the process does. Rather than sleeping
        // a guessed interval on the main thread, the capture retries until it appears.
        startCapture(attempt: 0)
        return true
    }

    func shutdown() {
        stopCapture()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        bootedProgram = nil
        frameLock.lock()
        newestFrame = nil
        framesCaptured = 0
        frameLock.unlock()
    }

    /// Brings the emulator's own window to the front, so a person can use it directly.
    ///
    /// The whole machine being reachable matters: the panel drives the handful of
    /// things a performance needs, and everything else — loading a script, fixing a
    /// page — is done in the software itself.
    func bringToFront() {
        guard let process, process.isRunning else { return }
        let identifier = process.processIdentifier
        NSRunningApplication(processIdentifier: identifier)?
            .activate(options: [.activateAllWindows])
    }

    // MARK: - Frames

    func latestFrame() -> ImageBuffer? {
        frameLock.lock(); defer { frameLock.unlock() }
        return newestFrame
    }

    /// How many frames have arrived, for the panel's readout.
    var capturedFrameCount: Int {
        frameLock.lock(); defer { frameLock.unlock() }
        return framesCaptured
    }

    func send(_ step: TitlerBootStep) {
        // Commands reach the machine through the shared drawer, not through here —
        // see AmigaCommandBridge. This exists for the EmulatorHost protocol and is
        // deliberately not a second, quieter path into the machine.
        Log.info(.titler, "FS-UAE host ignoring \(step.description); "
            + "commands go through the shared drawer")
    }

    // MARK: - Capture

    private func startCapture(attempt: Int) {
        // Up to ten seconds of retries. An Amiga takes a few seconds to put a window
        // up, and a machine under load can take longer; failing at the first look
        // would report "no window" for a machine that is simply still starting.
        let maximumAttempts = 20

        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
                guard let window = content.windows.first(where: {
                    ($0.title ?? "").hasPrefix(self.windowTitlePrefix)
                }) else {
                    if attempt < maximumAttempts, self.process?.isRunning == true {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        self.startCapture(attempt: attempt + 1)
                    } else {
                        await MainActor.run {
                            self.unavailableReason =
                                "The emulator is running but its window could not be "
                                + "found to capture."
                            self.onStateChanged?()
                        }
                    }
                    return
                }
                try await self.beginStream(on: window)
            } catch {
                await MainActor.run {
                    // The overwhelmingly likely cause, and the only one the person can
                    // do anything about — so it is named rather than reported as a
                    // generic failure.
                    self.unavailableReason =
                        "Screen Recording permission is needed to capture the "
                        + "emulator's window. System Settings > Privacy & Security > "
                        + "Screen Recording, then switch Videoboy on. "
                        + "(\(error.localizedDescription))"
                    Log.error(.titler, self.unavailableReason ?? "")
                    self.onStateChanged?()
                }
            }
        }
    }

    private func beginStream(on window: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)

        let configuration = SCStreamConfiguration()
        // Captured at the PROJECT'S geometry, not the window's. Everything in this
        // graph is 720x480, and resampling once here is cheaper and cleaner than
        // carrying an odd-sized texture through the chain to be resampled later.
        configuration.width = StandardDefinition.width
        configuration.height = StandardDefinition.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.queueDepth = 3
        // The emulator's own rate, not ours. Asking for more produces duplicates and
        // wastes work; asking for less makes it stutter independently of the mix.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(
            self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        self.stream = stream

        await MainActor.run {
            Log.info(.titler, "capturing \"\(window.title ?? "")\"")
            self.unavailableReason = nil
            self.onStateChanged?()
        }
    }

    private func stopCapture() {
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        guard let image = FSUAEHost.imageBuffer(from: pixelBuffer) else { return }
        frameLock.lock()
        newestFrame = image
        framesCaptured += 1
        frameLock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            Log.error(.titler, "capture stopped: \(error.localizedDescription)")
            self?.unavailableReason = "The capture stopped: \(error.localizedDescription)"
            self?.onStateChanged?()
        }
    }

    /// Turns a captured BGRA buffer into the graph's RGBA one.
    ///
    /// Row by row rather than pixel by pixel where possible: a captured buffer is
    /// padded to a row alignment, so the rows have to be walked, but the swap inside a
    /// row is a tight loop over bytes rather than a call per pixel.
    static func imageBuffer(from pixelBuffer: CVPixelBuffer) -> ImageBuffer? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let source = base.assumingMemoryBound(to: UInt8.self)

        // Built as one array and handed to the buffer, rather than written into an
        // existing one: `pixels` is private(set), and the whole-array initialiser is
        // both the supported route and a single allocation.
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        rgba.withUnsafeMutableBufferPointer { destination in
            guard let out = destination.baseAddress else { return }
            for y in 0..<height {
                let row = source + y * stride
                let outRow = out + y * width * 4
                for x in 0..<width {
                    let i = x * 4
                    // BGRA in, RGBA out.
                    outRow[i] = row[i + 2]
                    outRow[i + 1] = row[i + 1]
                    outRow[i + 2] = row[i]
                    outRow[i + 3] = 255
                }
            }
        }
        return ImageBuffer(width: width, height: height, pixels: rgba)
    }
}

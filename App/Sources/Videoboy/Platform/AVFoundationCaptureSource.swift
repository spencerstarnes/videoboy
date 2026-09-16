//
//  AVFoundationCaptureSource.swift — the real DVC100 loopback capture.
//
//  Purpose : Verification channel 2 from docs/SELF-QA-HARNESS.md. Opens the DVC100
//            (which presents as a UVC camera), pulls frames, and hands them to the
//            shared metrics builder. This is how Claude sees the actual
//            analog-facing signal rather than what it hoped it rendered.
//  Inputs  : a `CaptureRequest` naming the device and a frame count.
//  Outputs : a `CapturedSequence` — frames plus metrics.
//  Connects: conforms to Core's `CaptureSource`, so the harness treats it and
//            `MockCaptureSource` identically. Lives in App because camera
//            permission is granted to the app bundle, not to a test binary.
//  Extend  : to support another grabber, widen `discoverDevices()`; the frame path
//            below is format-agnostic as long as CoreVideo can give BGRA.
//

import AVFoundation
import CoreVideo
import Foundation
import VideoboyCore

/// Captures from a real UVC/AVCapture device.
final class AVFoundationCaptureSource: NSObject, CaptureSource {

    /// Frames collected so far, guarded by `lock`. The delegate callback runs on a
    /// capture queue while `capture(_:)` waits on the calling thread.
    private var collected: [CapturedFrame] = []
    private let lock = NSLock()
    private var wanted = 0
    private let finished = DispatchSemaphore(value: 0)
    private var hasSignalled = false

    /// Devices that can produce video: built-in cameras plus anything external,
    /// which is where a USB grabber like the DVC100 appears.
    private func discoverDevices() -> [AVCaptureDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices
    }

    func enumerateDeviceNames() -> [String] {
        discoverDevices().map(\.localizedName)
    }

    /// Requests camera access and blocks until the user (or a previous decision)
    /// answers. Returns false when access is denied or restricted.
    private func ensureAuthorised() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            Log.info(.selfqa, "requesting camera access (the DVC100 presents as a camera)")
            let gate = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { allowed in
                granted = allowed
                gate.signal()
            }
            // A prompt the user never sees would hang forever; bound the wait.
            if gate.wait(timeout: .now() + 60) == .timedOut {
                Log.error(.selfqa, "camera permission prompt was not answered within 60s")
                return false
            }
            return granted
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func capture(_ request: CaptureRequest) throws -> CapturedSequence {
        guard ensureAuthorised() else { throw CaptureError.permissionDenied }

        let devices = discoverDevices()
        Log.info(.selfqa, "capture devices seen: \(devices.map(\.localizedName).joined(separator: ", "))")

        // Match by substring so config/devices.json can hold a short, stable name.
        guard let device = devices.first(where: {
            $0.localizedName.localizedCaseInsensitiveContains(request.deviceNameContains)
        }) else {
            throw CaptureError.deviceNotFound(request.deviceNameContains)
        }
        Log.info(.selfqa, "capturing from '\(device.localizedName)'")

        let session = AVCaptureSession()
        session.beginConfiguration()
        // The grabber's own format is the reference (SPEC: the DVC100 captures
        // NTSC-rate SD), so no preset is imposed on it.
        session.sessionPreset = .high

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureError.configurationFailed("cannot open \(device.localizedName): \(error)")
        }
        guard session.canAddInput(input) else {
            throw CaptureError.configurationFailed("session refused input from \(device.localizedName)")
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // Dropping late frames keeps the measured timing honest: a queued backlog
        // would report a rate the signal never actually had.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoboy.selfqa.capture"))
        guard session.canAddOutput(output) else {
            throw CaptureError.configurationFailed("session refused a video data output")
        }
        session.addOutput(output)
        session.commitConfiguration()

        lock.lock()
        collected.removeAll()
        wanted = request.frameCount
        hasSignalled = false
        lock.unlock()

        session.startRunning()
        // Generous timeout: enough for the requested frames at SD rates, plus slack
        // for a grabber that takes a moment to lock to the incoming signal.
        let expectedSeconds = Double(request.frameCount) / max(request.expectedFrameRate, 1.0)
        let timeout = DispatchTime.now() + expectedSeconds + 10.0
        let waitResult = finished.wait(timeout: timeout)
        session.stopRunning()

        lock.lock()
        let frames = collected
        lock.unlock()

        if waitResult == .timedOut {
            Log.warn(.selfqa, "capture timed out with \(frames.count)/\(request.frameCount) frames")
        }
        guard !frames.isEmpty else {
            throw CaptureError.noFramesArrived("device '\(device.localizedName)' delivered nothing")
        }

        let metrics = CaptureMetricsBuilder.summarise(
            frames: frames,
            expectedFrameRate: request.expectedFrameRate,
            loggedOutputMode: request.loggedOutputMode,
            deviceName: device.localizedName
        )
        return CapturedSequence(frames: frames, metrics: metrics)
    }
}

// MARK: - Frame delivery

extension AVFoundationCaptureSource: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock()
        let enough = collected.count >= wanted
        lock.unlock()
        if enough { return }

        guard let image = Self.imageBuffer(from: pixelBuffer) else { return }
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        lock.lock()
        collected.append(CapturedFrame(image: image, timestamp: timestamp))
        let reachedTarget = collected.count >= wanted && !hasSignalled
        if reachedTarget { hasSignalled = true }
        lock.unlock()

        if reachedTarget { finished.signal() }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Logged rather than counted: the metrics builder derives drops from
        // timestamp gaps, which also catches frames the device never sent at all.
        Log.warn(.selfqa, "capture pipeline dropped a frame")
    }

    /// Copies a CoreVideo BGRA pixel buffer into an `ImageBuffer`.
    ///
    /// Row padding is real here — CoreVideo aligns rows — so the copy goes row by
    /// row rather than in one block.
    private static func imageBuffer(from pixelBuffer: CVPixelBuffer) -> ImageBuffer? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let sourceBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destinationBytesPerRow = width * ImageBuffer.bytesPerPixel

        var bgra = [UInt8](repeating: 0, count: height * destinationBytesPerRow)
        let source = base.assumingMemoryBound(to: UInt8.self)
        bgra.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    destinationBase.advanced(by: row * destinationBytesPerRow),
                    source.advanced(by: row * sourceBytesPerRow),
                    destinationBytesPerRow
                )
            }
        }
        return ImageBuffer.fromBGRA(width: width, height: height, bgra: bgra)
    }
}

//
//  LiveAVFoundationCapture.swift — a configured AVFoundation source, running.
//
//  Purpose : Opens a real, CONTINUOUS AVCaptureSession for one configured source
//            (a webcam, Continuity Camera, or a UVC grabber like the DVC100) and
//            feeds every frame to that source's `CaptureSourceNode`, so it plays into
//            a channel like any other source.
//  Inputs  : a device name (matched the way `Preferences` already stores one — by
//            localized name, not a port-specific unique ID) and the node to feed.
//  Outputs : frames, via `CaptureSourceNode.submit(frame:deviceName:)`.
//  Connects: `ConfiguredSource` (.avfoundation), `SourceSessionManager`,
//            `CaptureSourceNode`.
//  Extend  : this is deliberately separate from `AVFoundationCaptureSource`, which
//            captures a bounded sequence for the self-QA loopback check and has a
//            different lifecycle (start, collect N frames, stop). A little
//            duplication between the two — device discovery, the CVPixelBuffer copy —
//            is the right trade against coupling a live UI-driven session to a
//            self-QA-specific one.
//
//  Threading: the sample-buffer delegate runs on its own capture queue and hands the
//  frame straight to `CaptureSourceNode.submit`, which is itself lock-protected and
//  safe to call off the main thread — see that type's own header.
//

import AVFoundation
import CoreVideo
import Foundation
import VideoboyCore

/// A running AVFoundation capture session feeding one `CaptureSourceNode`.
final class LiveAVFoundationCapture: NSObject {

    private var session: AVCaptureSession?
    private weak var node: CaptureSourceNode?
    private let deviceName: String

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    /// Every device that can produce video — the same device types
    /// `AVFoundationCaptureSource` enumerates for the self-QA path, so a name chosen
    /// in Settings (from that same enumeration) is guaranteed findable here too.
    static func discoverDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [
            .external, .builtInWideAngleCamera, .continuityCamera, .deskViewCamera
        ]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified)
        var seen: Set<String> = []
        return session.devices.filter { seen.insert($0.uniqueID).inserted }
    }

    /// Opens the named device and starts delivering frames to `node`. Returns false
    /// when the device cannot be found or opened — the node is left exactly as it
    /// was, which renders as its existing empty/greyed state rather than a crash.
    @discardableResult
    func start(feeding node: CaptureSourceNode) -> Bool {
        guard session == nil else { return true }

        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            Log.warn(.output, "camera '\(deviceName)' not started — camera access not granted")
            return false
        }
        guard let device = Self.discoverDevices().first(where: {
            $0.localizedName.localizedCaseInsensitiveContains(deviceName)
        }) else {
            Log.warn(.output, "camera '\(deviceName)' not found among connected devices")
            return false
        }

        let newSession = AVCaptureSession()
        newSession.beginConfiguration()
        newSession.sessionPreset = .high
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard newSession.canAddInput(input) else {
                Log.warn(.output, "session refused input from '\(device.localizedName)'")
                return false
            }
            newSession.addInput(input)
        } catch {
            Log.warn(.output, "cannot open '\(device.localizedName)': \(error)")
            return false
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoboy.capture.\(deviceName)"))
        guard newSession.canAddOutput(output) else {
            Log.warn(.output, "session refused a video data output for '\(device.localizedName)'")
            return false
        }
        newSession.addOutput(output)
        newSession.commitConfiguration()

        self.node = node
        self.session = newSession
        newSession.startRunning()
        Log.info(.output, "camera '\(device.localizedName)' now feeding \(node.identifier)")
        return true
    }

    func stop() {
        session?.stopRunning()
        session = nil
        node = nil
    }
}

extension LiveAVFoundationCapture: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let image = Self.imageBuffer(from: pixelBuffer) else { return }
        node?.submit(frame: image, deviceName: deviceName)
    }

    /// Copies a CoreVideo BGRA pixel buffer into an `ImageBuffer`. Row by row: CoreVideo
    /// pads rows to its own alignment, which rarely matches `width * bytesPerPixel`.
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
                    destinationBytesPerRow)
            }
        }
        return ImageBuffer.fromBGRA(width: width, height: height, bgra: bgra)
    }
}

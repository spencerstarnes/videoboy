//
//  WindowCaptureSource.swift — any on-screen window, as a configured source.
//
//  Purpose : The general case of what `FSUAEHost.swift` already does for one specific
//            window (the emulator's own). Lets the person pick ANY window — "the same
//            pipes that macOS uses for screenshot or for deciding which window to
//            share" — and stream it continuously into a `CaptureSourceNode`.
//  Inputs  : a window title + owning app name (how a `ConfiguredSource.windowCapture`
//            entry is persisted — a `CGWindowID` does not survive a relaunch, let
//            alone the window itself closing and reopening).
//  Outputs : frames, via `CaptureSourceNode.submit(frame:deviceName:)`.
//  Connects: `ConfiguredSource` (.windowCapture), `SourceSessionManager`,
//            `CaptureSourceNode`, the Settings "+" window picker.
//  Extend  : `FSUAEHost.swift` runs the same `SCStream`/`SCContentFilter` machinery
//            for one hardcoded titler window; this is deliberately a separate class
//            rather than a shared base, because the two have different reacquisition
//            rules (a title PREFIX match against a small fixed list of programs, vs.
//            an exact app+title match against whatever the person picked) and
//            coupling them would make either change risk breaking the other.
//

import AppKit
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import VideoboyCore

/// One capturable window, for the Settings picker.
struct WindowCandidate: Identifiable {
    var id: CGWindowID
    var title: String
    var ownerName: String

    var displayName: String { "\(title.isEmpty ? "Untitled" : title) — \(ownerName)" }
}

/// A running ScreenCaptureKit capture of one window, feeding one `CaptureSourceNode`.
final class WindowCaptureSession: NSObject {

    private var stream: SCStream?
    private weak var node: CaptureSourceNode?
    private let captureQueue = DispatchQueue(label: "videoboy.capture.window")
    private let title: String
    private let ownerName: String?

    init(title: String, ownerName: String?) {
        self.title = title
        self.ownerName = ownerName
    }

    /// Every on-screen window that could plausibly be picked, excluding Videoboy's
    /// own windows — capturing yourself is a feedback loop nobody asked for here
    /// (the deliberate one lives in `FeedbackNode`, with its own controls).
    static func availableWindows() async throws -> [WindowCandidate] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier
        return content.windows.compactMap { window -> WindowCandidate? in
            guard let app = window.owningApplication,
                  app.bundleIdentifier != ownBundleID,
                  window.frame.width > 50, window.frame.height > 50 else { return nil }
            return WindowCandidate(
                id: window.windowID, title: window.title ?? "", ownerName: app.applicationName)
        }
    }

    /// Finds the configured window and starts streaming it into `node`. Returns false
    /// when no matching window is currently on screen — the node is left as it was,
    /// which is its existing empty/greyed state, not a crash.
    @discardableResult
    func start(feeding node: CaptureSourceNode) async -> Bool {
        guard stream == nil else { return true }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { candidate in
                (candidate.title ?? "") == title
                    && (ownerName == nil || candidate.owningApplication?.applicationName == ownerName)
            }) else {
                Log.warn(.output, "window '\(title)' not found on screen")
                return false
            }
            try await beginStream(on: window, feeding: node)
            return true
        } catch {
            Log.warn(.output, "could not capture window '\(title)': \(error)")
            return false
        }
    }

    private func beginStream(on window: SCWindow, feeding node: CaptureSourceNode) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()

        // Captured at the project's geometry, same reasoning as `FSUAEHost`: every
        // node downstream of a source in this graph is 720x480, and resampling once
        // here is cheaper than carrying an odd-sized texture through the chain.
        configuration.width = StandardDefinition.width
        configuration.height = StandardDefinition.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(
            value: 1, timescale: Int32(StandardDefinition.frameRate.rounded()))

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await newStream.startCapture()
        self.stream = newStream
        self.node = node
        Log.info(.output, "capturing window '\(window.title ?? "")' into \(node.identifier)")
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        node = nil
        Task { try? await stream.stopCapture() }
    }
}

extension WindowCaptureSession: SCStreamOutput, SCStreamDelegate {

    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let image = Self.imageBuffer(from: pixelBuffer) else { return }
        node?.submit(frame: image, deviceName: title)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.warn(.output, "window capture '\(title)' stopped: \(error)")
        self.stream = nil
    }

    /// Copies a CoreVideo BGRA pixel buffer into an `ImageBuffer`. Same row-by-row
    /// copy `LiveAVFoundationCapture` and `FSUAEHost` both use — CoreVideo pads rows
    /// to its own alignment, which rarely matches `width * bytesPerPixel`.
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

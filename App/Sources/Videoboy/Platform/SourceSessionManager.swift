//
//  SourceSessionManager.swift — starts and stops live sessions for configured sources.
//
//  Purpose : One place that knows how to turn a `ConfiguredSource` into a running
//            capture feeding the engine's graph, for whichever of the two
//            implemented kinds it is. Keeps `ShellController` from needing to know
//            AVFoundation or ScreenCaptureKit exist.
//  Inputs  : a `ConfiguredSource` and the `Engine` to feed.
//  Outputs : a running `LiveAVFoundationCapture` or `WindowCaptureSession`, feeding
//            the engine's `CaptureSourceNode` for that source's id.
//  Connects: `ConfiguredSource`, `Engine.ensureCaptureNode`, `LiveAVFoundationCapture`,
//            `WindowCaptureSession`.
//  Extend  : a third implemented kind gets a third dictionary and a third branch in
//            `start`. `.ipCamera` deliberately has no branch — it is
//            not started, ever, until a real decode backend exists for them.
//

import Foundation
import VideoboyCore

/// Owns every running live-capture session, by `ConfiguredSource.id`.
final class SourceSessionManager {

    private var avfoundationSessions: [String: LiveAVFoundationCapture] = [:]
    private var windowSessions: [String: WindowCaptureSession] = [:]

    /// Starts (or confirms already running) the session for a configured source,
    /// feeding the engine's node for its id. Does nothing for `.ipCamera` —
    /// see `ConfiguredSourceKind.isImplemented`.
    func start(_ source: ConfiguredSource, engine: Engine) {
        let node = engine.ensureCaptureNode(id: source.id)
        switch source.kind {
        case .avfoundation:
            let session = avfoundationSessions[source.id] ?? LiveAVFoundationCapture(deviceName: source.target)
            avfoundationSessions[source.id] = session
            session.start(feeding: node)

        case .windowCapture:
            let session = windowSessions[source.id]
                ?? WindowCaptureSession(title: source.target, ownerName: source.windowOwnerName)
            windowSessions[source.id] = session
            Task { await session.start(feeding: node) }

        case .ipCamera:
            Log.warn(.output, "'\(source.name)' is a \(source.kind.displayName) — "
                + "not connectable yet, see ConfiguredSourceKind.unimplementedReason")
        }
    }

    /// Stops a source's session, if one is running. The engine's node is left in
    /// place — see `Engine.ensureCaptureNode`'s header — so a channel still pointed
    /// at it simply stops receiving new frames rather than losing its routing.
    func stop(id: String) {
        avfoundationSessions.removeValue(forKey: id)?.stop()
        windowSessions.removeValue(forKey: id)?.stop()
    }

    /// Stops every running session — called at quit, alongside the other things
    /// `ShellController.shutdown()` already tears down.
    func stopAll() {
        for id in Array(avfoundationSessions.keys) { stop(id: id) }
        for id in Array(windowSessions.keys) { stop(id: id) }
    }
}

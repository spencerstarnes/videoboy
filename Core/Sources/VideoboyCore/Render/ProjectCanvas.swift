//
//  ProjectCanvas.swift — the canvas a project renders at (proposal §6).
//
//  Purpose : Names the canvases Settings ▸ Project offers and maps each to the pixel
//            size the graph renders at. SD NTSC is the default and the reference;
//            Vertical 1080×1920 (9:16) is the first other canvas that is built.
//  Inputs  : the stored preference (`Preferences.projectCanvas`).
//  Outputs : a `CanvasGeometry`, installed once at launch as `CanvasGeometry.project`.
//  Connects: Preferences (stores the choice), AppDelegate (installs it before the
//            engine and windows exist), Engine (render size), ClipSourceNode (decode
//            size), MetalPreviewView (picture shape), FrameRecorder and
//            MPEGTSStreamer (file and stream size), SetupPanes (the pop-up).
//  Extend  : a canvas becomes selectable by setting `isAvailable` once it has passed
//            `stress` and `soak` on its own size. Frame rate is not part of this yet:
//            every canvas runs at 29.97.
//
//  CHOSEN AT LAUNCH, NOT LIVE. Every render target, decode size and recorder is sized
//  from the canvas. Changing it under a running show would resize all of them mid-
//  frame, so a change is stored and takes effect the next time Videoboy opens — the
//  same rule as the library location.
//

import Foundation

/// A canvas a project can be set to.
public enum ProjectCanvas: String, CaseIterable, Codable, Sendable {
    case sdNTSC
    case sdPAL
    case hd
    case square
    case vertical

    /// The name Settings shows.
    public var title: String {
        switch self {
        case .sdNTSC: "SD NTSC 720×480"
        case .sdPAL: "SD PAL 720×576"
        case .hd: "HD 1920×1080"
        case .square: "Square 1080×1080"
        case .vertical: "Vertical 1080×1920 (9:16)"
        }
    }

    /// The raster the graph renders at.
    public var geometry: CanvasGeometry {
        switch self {
        case .sdNTSC: .standardDefinition
        case .sdPAL: CanvasGeometry(width: 720, height: 576)
        case .hd: CanvasGeometry(width: 1920, height: 1080)
        case .square: CanvasGeometry(width: 1080, height: 1080)
        case .vertical: CanvasGeometry(width: 1080, height: 1920)
        }
    }

    /// Whether this canvas is built. The rest are listed, disabled (SPEC §14: present,
    /// never omitted).
    public var isAvailable: Bool {
        switch self {
        case .sdNTSC, .vertical: true
        case .sdPAL, .hd, .square: false
        }
    }

    /// The canvas to run at: `VIDEOBOY_CANVAS` (a raw value, e.g. `vertical`) when it
    /// names an available canvas — so `selfqa stress` can be timed per canvas without
    /// touching anyone's preferences — otherwise the stored choice.
    public static func atLaunch(
        stored: ProjectCanvas,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ProjectCanvas {
        guard let raw = environment["VIDEOBOY_CANVAS"] else { return stored }
        guard let named = ProjectCanvas(rawValue: raw), named.isAvailable else {
            Log.warn(.app, "VIDEOBOY_CANVAS=\(raw) is not an available canvas; using \(stored.title)")
            return stored
        }
        return named
    }
}

extension CanvasGeometry {
    /// The canvas this run of the app renders at. Set once at launch from the stored
    /// preference, before the engine or any window is built, and never changed after
    /// (see `ProjectCanvas`). Self-QA and tests that never set it get SD NTSC.
    public static var project: CanvasGeometry = .standardDefinition
}

//
//  ConfiguredSource.swift — a live input the person has set up (SPEC 6, SPEC 10).
//
//  Purpose : What used to be a single `captureDeviceName` string is now a LIST: any
//            number of cameras, windows, IP cameras and DV decks, each added once in
//            Settings and then available everywhere — the Sources tab, a channel's
//            source picker, a template. One entry here is one addressable thing.
//  Inputs  : the Settings "Sources" pane's + flow.
//  Outputs : an entry in `Preferences.configuredSources`, persisted the same way
//            everything else in that file is.
//  Connects: `Preferences`; the App's live capture sessions (AVFoundation,
//            ScreenCaptureKit) that actually feed one of these; `Engine`'s
//            `ChannelSourceKind.capture(id)`, which is how a channel points at one.
//  Extend  : a new source type is a new `ConfiguredSourceKind` case plus whatever the
//            App needs to actually open it — this file only holds the identity and
//            configuration, never a live session or a device handle.
//

import Foundation

/// What kind of thing a configured source is.
///
/// `isImplemented` is the honest half of this: AVFoundation devices and window
/// capture have a real, continuous capture path in the App target. IP cameras and DV
/// decks do not yet — adding one here records the intent (a name, a URL) and shows up
/// in the Sources tab greyed with a reason, the same "missing dep degrades to a
/// labeled, greyed state, never a crash" rule every other unfinished source kind in
/// this app already follows (see `PanelSet.futureSourceKinds()`'s history).
public enum ConfiguredSourceKind: String, CaseIterable, Codable, Sendable {
    /// A webcam, a UVC grabber (the DVC100 presents this way), Continuity Camera —
    /// anything macOS itself enumerates as a capture device. Auto-populated, never
    /// typed in: see the user's own framing, "only the AVFoundation stuff that macOS
    /// natively sees should be auto-populated."
    case avfoundation
    /// Any on-screen window, picked the same way macOS's own screen-sharing picker
    /// works (`SCShareableContent`). Real, continuous, via ScreenCaptureKit.
    case windowCapture
    /// A network camera. Name + URL, saved. No live decode yet — CLAUDE.md's
    /// runtime-network guardrail treats an IP feed as its own explicit phase, and
    /// BUILD-PLAN.md's backlog already marks IP in/out as not built.
    case ipCamera
    /// A tape deck fed in over FireWire/IIDC. Name, saved. NOT the same thing as the
    /// DVC100, which is UVC and goes through `.avfoundation` — this is the literal
    /// FireWire path, and whether modern Apple Silicon + current macOS has one at all
    /// without extra hardware is a genuinely open question, written down rather than
    /// guessed at (see docs/BUILD-PLAN.md's backlog).
    case dvDeck

    public var displayName: String {
        switch self {
        case .avfoundation: "Camera"
        case .windowCapture: "Window Capture"
        case .ipCamera: "IP Camera"
        case .dvDeck: "DV Deck"
        }
    }

    /// The three-letter badge shown on the source's tile (`LibraryItem.badge`).
    ///
    /// `.avfoundation` uses "CAP" and `.windowCapture` uses "SCR" — both already
    /// meant exactly this in `LibraryItem.kind` before this type existed. `.dvDeck`
    /// deliberately does NOT use "DV": that badge already means a decoded .dv file
    /// clip, and a deck entry showing up looking like a playable clip would be a real
    /// bug, not a cosmetic one.
    public var badge: String {
        switch self {
        case .avfoundation: "CAP"
        case .windowCapture: "SCR"
        case .ipCamera: "IP"
        case .dvDeck: "FW"
        }
    }

    /// Whether the App target can actually open a live session for this kind today.
    public var isImplemented: Bool {
        switch self {
        case .avfoundation, .windowCapture: true
        case .ipCamera, .dvDeck: false
        }
    }

    /// Why an unimplemented kind is greyed, for the tile's tooltip — matches how
    /// every other "advertised but not built" item in this app explains itself.
    public var unimplementedReason: String? {
        switch self {
        case .avfoundation, .windowCapture: nil
        case .ipCamera: "IP camera decode is not built yet (SPEC §6/§15) — saved, not live"
        case .dvDeck: "Live FireWire/IIDC capture is not built — saved, not live"
        }
    }
}

/// One source the person has added in Settings.
///
/// Shape deliberately mirrors `OutputDestination`: an id, a kind, a name, and one
/// free-form `target` string whose meaning depends on the kind — a device name for
/// `.avfoundation`, a window title for `.windowCapture`, a URL for `.ipCamera`, a
/// free note for `.dvDeck`. One field rather than four optional ones, because only
/// one is ever meaningful at a time and `OutputDestination` already proved the pattern
/// reads fine.
public struct ConfiguredSource: Codable, Equatable, Identifiable, Sendable {

    public var id: String
    public var kind: ConfiguredSourceKind
    public var name: String
    /// Kind-specific: an AVFoundation device's localized name, a captured window's
    /// title, an IP camera's URL, or a DV deck's note. Matched by VALUE, not by a
    /// system-assigned identifier — the same reasoning `Preferences.captureDeviceName`
    /// already used: a USB grabber gets a different unique ID on a different port, and
    /// a captured window's `CGWindowID` does not survive the app relaunching, let
    /// alone the window itself closing and reopening.
    public var target: String
    /// For `.windowCapture` only: the owning application's name, so re-acquiring the
    /// window on reconnect can match app + title rather than title alone (two
    /// different apps can easily have a window titled the same thing).
    public var windowOwnerName: String?

    public init(
        id: String = UUID().uuidString, kind: ConfiguredSourceKind, name: String,
        target: String = "", windowOwnerName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.target = target
        self.windowOwnerName = windowOwnerName
    }
}

//
//  NowPlaying.swift — what is playing, and how to put it on screen.
//
//  Purpose : A lower-third showing the track that is playing: title, artist, album,
//            artwork and how far through it is. Where that information comes FROM is
//            deliberately not this file's business — see `NowPlayingSource`.
//  Inputs  : a `NowPlayingTrack`, from whichever source is connected.
//  Outputs : the layout for one, which the titler draws.
//  Connects: CharacterGeneratorNode (the text is drawn by the same Core Text path as
//            every other title), the App's source adapters.
//  Extend  : a new LOOK is a case on `NowPlayingTemplate`. A new SOURCE is a type
//            conforming to `NowPlayingSource` — those are the two axes, and they do
//            not need to know about each other.
//

import Foundation

/// One track, as much as any source can tell us about it.
///
/// Everything except the title is optional, because the sources genuinely differ:
/// a DJ player may know the BPM and not the album, a streaming app the reverse.
public struct NowPlayingTrack: Equatable, @unchecked Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    /// 0...1 through the track, when the source reports position.
    public var progress: Double?
    /// Artwork as raw image bytes, when the source provides it.
    public var artwork: ImageBuffer?

    public init(
        title: String, artist: String? = nil, album: String? = nil,
        progress: Double? = nil, artwork: ImageBuffer? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.progress = progress
        self.artwork = artwork
    }

    /// Compared on what IDENTIFIES a track, not on its artwork.
    ///
    /// The artwork is a raster derived from the track — two tracks with the same
    /// title, artist and album are the same track whatever bytes their cover art
    /// happens to be, and comparing a few hundred kilobytes of pixels every frame to
    /// learn something the strings already say would be wasteful as well as wrong.
    public static func == (lhs: NowPlayingTrack, rhs: NowPlayingTrack) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.progress == rhs.progress
    }

    /// Whether this is a DIFFERENT track from another, ignoring progress.
    ///
    /// Progress changes every frame; the track does not. Fade-on-change has to ask
    /// this question rather than comparing whole values, or it would re-trigger
    /// continuously for the length of the song.
    public func isDifferentTrack(from other: NowPlayingTrack?) -> Bool {
        guard let other else { return true }
        return title != other.title || artist != other.artist || album != other.album
    }
}

/// Where now-playing information comes from.
///
/// A protocol so Core neither knows nor cares whether the answer arrived from Apple
/// Music over AppleEvents, from a DJ player over the network, or from a mock in a
/// test — and so the whole overlay can be built and tested without any of them.
public protocol NowPlayingSource: AnyObject {
    /// A short name for the settings UI: "Apple Music", "Engine DJ".
    var displayName: String { get }
    /// What is playing, or nil when nothing is.
    var currentTrack: NowPlayingTrack? { get }
    /// Whether this source is actually connected and answering.
    var isAvailable: Bool { get }
}

/// A source that returns whatever it is told to.
///
/// Not only for tests: it is also what the overlay runs against while a real source
/// is unavailable, so the templates can be designed and looked at without needing a
/// DJ player on the network or a permission prompt answered.
public final class MockNowPlayingSource: NowPlayingSource {
    public var displayName: String { "Mock" }
    public var currentTrack: NowPlayingTrack?
    public var isAvailable: Bool = true

    public init(track: NowPlayingTrack? = nil) {
        self.currentTrack = track
    }
}

/// How the overlay looks.
public enum NowPlayingTemplate: String, CaseIterable, Codable, Sendable {
    /// Title and artist over a translucent slab, artwork on the left. The default,
    /// and the one that reads on any footage.
    case lowerThird
    /// A single line in the OSD face, no slab — for footage you do not want to cover.
    case ticker
    /// Bigger, centred, with the album as well. For between tracks rather than over
    /// a performance.
    case card

    public var displayName: String {
        switch self {
        case .lowerThird: "Lower Third"
        case .ticker: "Ticker"
        case .card: "Card"
        }
    }

    /// Whether this template draws a background slab behind the text.
    public var hasSlab: Bool { self != .ticker }

    /// Whether the artwork is shown.
    public var showsArtwork: Bool { self != .ticker }

    public static func from(normalised value: Double) -> NowPlayingTemplate {
        let all = allCases
        return all[NormalisedSweep.index(value, count: all.count)]
    }

    public var normalisedPosition: Double {
        let all = NowPlayingTemplate.allCases
        guard all.count > 1, let index = all.firstIndex(of: self) else { return 0 }
        return Double(index) / Double(all.count - 1)
    }
}

/// Decides how visible the overlay should be at a given moment.
///
/// Split out from the drawing so the RULE — always on, or only around a track change
/// — can be reasoned about and tested without rendering anything.
public struct NowPlayingVisibility: Equatable, Sendable {

    /// Seconds the overlay stays up after a track change, when it is not always-on.
    public var holdSeconds: Double
    /// Seconds spent fading in and out.
    public var fadeSeconds: Double
    /// When false the overlay is permanently visible and the timings do not apply.
    public var onlyOnTrackChange: Bool

    public init(
        holdSeconds: Double = 6, fadeSeconds: Double = 0.8, onlyOnTrackChange: Bool = true
    ) {
        self.holdSeconds = holdSeconds
        self.fadeSeconds = fadeSeconds
        self.onlyOnTrackChange = onlyOnTrackChange
    }

    /// Opacity 0...1, given how long ago the track changed.
    ///
    /// Fades in, holds, fades out. Returns 1 throughout when the overlay is set to be
    /// always on, so the caller never has to special-case that mode.
    public func opacity(secondsSinceChange seconds: Double) -> Double {
        guard onlyOnTrackChange else { return 1 }
        guard seconds.isFinite, seconds >= 0 else { return 0 }

        let fade = max(fadeSeconds, 0.0001)
        if seconds < fade { return seconds / fade }

        let holdEnds = fade + max(holdSeconds, 0)
        if seconds < holdEnds { return 1 }

        let fadeOutElapsed = seconds - holdEnds
        if fadeOutElapsed < fade { return 1 - fadeOutElapsed / fade }
        return 0
    }
}


/// Where the live now-playing answer lives: written by whichever adapter is running
/// (Apple Music, Spotify — App side, off the main thread), read by the Now Playing
/// generator on the render path. Locked, and cheap to read every frame.
public final class NowPlayingHub: @unchecked Sendable {

    public static let shared = NowPlayingHub()

    private let lock = NSLock()
    private var _track: NowPlayingTrack?
    private var _changedAt: Double = 0
    private var _status = "Not connected"
    private var _generation = 0

    public init() {}

    /// Publishes what is playing now (nil when nothing is). A different track restarts
    /// the on-change fade.
    public func publish(_ track: NowPlayingTrack?, status: String, at time: Double) {
        lock.lock(); defer { lock.unlock() }
        let different = track.map { $0.isDifferentTrack(from: _track) } ?? (_track != nil)
        if different { _changedAt = time }
        if track != _track || track?.progress != _track?.progress || status != _status || different {
            _generation += 1
        }
        _track = track
        _status = status
    }

    /// A consistent view: the track, when it changed, the source's status, and a
    /// counter that moves whenever anything worth redrawing did.
    public func snapshot() -> (track: NowPlayingTrack?, changedAt: Double, status: String, generation: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_track, _changedAt, _status, _generation)
    }
}

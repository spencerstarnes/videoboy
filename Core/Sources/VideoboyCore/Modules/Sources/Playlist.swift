//
//  Playlist.swift — a per-source queue, on Up Next's rules.
//
//  Purpose : Each of the four sources (A, B, C, D) has one of these. When a source is
//            in ONE SHOT and its clip runs out, it pulls the next item off its own
//            playlist instead of simply stopping. Loop and ping-pong never consult
//            it — they have their own answer to "what happens at the end" and a
//            playlist that overrode them would take the shuttle key's meaning away.
//  Inputs  : file URLs, added from a library's context menu.
//  Outputs : the next URL to load, once, when asked.
//  Connects: ClipSourceNode (which says when a one-shot clip has finished),
//            ShellController (which owns the four of these and does the loading),
//            the library panels (which fill them).
//  Extend  : shuffle would go here as a mode on the queue, NOT as a second queue
//            type — `takeNext` stays the one way anything leaves the front.
//
//  Up Next semantics, deliberately: taking an item PLAYS it and moves it off the
//  FRONT. With REPEAT on (the default, owner request 2026-09-29 — a DJ set ran out of
//  queued content fast) it goes to the BOTTOM, so the queue cycles; with REPEAT off
//  it is removed. Either way there is no separate cursor: the front of the list is
//  always literally next, so "what is next" and "where am I" can never disagree.
//

import Foundation

/// One entry in a source's queue.
public struct PlaylistItem: Equatable, Codable, Sendable, Identifiable {
    /// Stable across reorders, so a view can animate a move rather than a
    /// delete-and-insert that happens to look the same.
    public let id: UUID
    public let url: URL

    public init(url: URL, id: UUID = UUID()) {
        self.id = id
        self.url = url
    }

    /// What a library row shows.
    public var displayName: String { url.lastPathComponent }
}

/// An ordered queue of clips for one source.
public struct Playlist: Equatable, Codable, Sendable {

    public private(set) var items: [PlaylistItem]

    /// REPEAT: a taken item goes to the bottom of the queue instead of leaving it.
    /// On by default, so a queue never runs dry mid-set.
    public var repeats: Bool

    public init(items: [PlaylistItem] = [], repeats: Bool = true) {
        self.items = items
        self.repeats = repeats
    }

    private enum CodingKeys: String, CodingKey { case items, repeats }

    /// Reads queues written before REPEAT existed as repeating (the default).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([PlaylistItem].self, forKey: .items)
        repeats = try container.decodeIfPresent(Bool.self, forKey: .repeats) ?? true
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// What would play next, without consuming it — for showing "up next" in the UI.
    public var peekNext: PlaylistItem? { items.first }

    /// Adds to the END of the queue. The ordinary "add to playlist" gesture.
    public mutating func append(url: URL) {
        items.append(PlaylistItem(url: url))
    }

    /// Puts something at the FRONT, so it plays after the current clip and before
    /// whatever was already queued — Apple Music's "Play Next" as against "Play
    /// Last". Worth having separately: during a set the useful question is almost
    /// always "what comes immediately after this", not "what comes eventually".
    public mutating func insertNext(url: URL) {
        items.insert(PlaylistItem(url: url), at: 0)
    }

    /// Takes the next item off the front. With REPEAT on it goes back in at the
    /// bottom (same id, so a view can show it as a move); with REPEAT off it is gone.
    /// Returns nil only when the queue is empty, which is how a one-shot clip knows
    /// to just stop the way it always did.
    public mutating func takeNext() -> PlaylistItem? {
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        if repeats { items.append(item) }
        return item
    }

    public mutating func remove(id: PlaylistItem.ID) {
        items.removeAll { $0.id == id }
    }

    /// Moves an item, for drag-reordering. Out-of-range indices are ignored rather
    /// than trapping: a reorder is a gesture, and a gesture that lands badly should
    /// do nothing, not take the app down mid-set.
    public mutating func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source) else { return }
        let clamped = min(max(destination, 0), items.count - 1)
        guard clamped != source else { return }
        let item = items.remove(at: source)
        items.insert(item, at: clamped)
    }

    public mutating func clear() {
        items.removeAll()
    }
}

/// The four playlists, one per source, keyed by channel letter.
public struct PlaylistSet: Equatable, Codable, Sendable {

    /// Channel letters that have a playlist. Fixed at four: SPEC 2's graph has
    /// exactly these sources, and a fifth playlist would have nothing to play into.
    public static let channels = ["A", "B", "C", "D"]

    private var playlists: [String: Playlist]

    public init() {
        playlists = Dictionary(uniqueKeysWithValues: Self.channels.map { ($0, Playlist()) })
    }

    public subscript(channel: String) -> Playlist {
        get { playlists[channel] ?? Playlist() }
        set { playlists[channel] = newValue }
    }

    /// Total queued across all four, for a status readout.
    public var totalCount: Int {
        playlists.values.reduce(0) { $0 + $1.count }
    }
}

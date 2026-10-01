//
//  ClipQueue.swift — a channel's Queue, on Up Next's rules.
//
//  Names   : the UI calls this the **Queue**: the live list Play Next drops clips into.
//            A **Playlist** is a SAVED queue and a **Setlist** is two Playlists plus a
//            bank's effects and pads (docs/PROPOSAL-2026-09-28-setlist.md §1). The
//            type was called `Playlist` until 2026-09-29; the name now belongs to the
//            saved kind.
//  Purpose : Each of the four sources (A, B, C, D) has one of these. When a source is
//            in ONE SHOT and its clip runs out, it pulls the next item off its own
//            queue instead of simply stopping. Loop and ping-pong never consult
//            it — they have their own answer to "what happens at the end" and a
//            queue that overrode them would take the shuttle key's meaning away.
//  Inputs  : file URLs, from a library's context menu (Play Next / Play Last) or a
//            drop on the queue.
//  Outputs : the next URL to load, once, when asked.
//  Connects: ClipSourceNode (which says when a one-shot clip has finished),
//            ShellController (which owns the four of these and does the loading),
//            the library panels (which fill them).
//  Extend  : shuffle or repeat-all would go here as a mode on the queue, NOT as a
//            second queue type — `takeNext` stays the one way anything leaves.
//
//  Up Next semantics, deliberately: taking an item PLAYS it and therefore REMOVES it.
//  A queue that kept what it had already played would need a separate cursor, and
//  then "what is next" and "where am I" could disagree — which is the bug that makes
//  queue UIs confusing. Here the front of the list is always literally next.
//

import Foundation

/// One entry in a source's queue.
public struct QueueItem: Equatable, Codable, Sendable, Identifiable {
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
public struct ClipQueue: Equatable, Codable, Sendable {

    public private(set) var items: [QueueItem]

    public init(items: [QueueItem] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// What would play next, without consuming it — for showing "up next" in the UI.
    public var peekNext: QueueItem? { items.first }

    /// Adds to the END of the queue — the menu's "Play Last".
    public mutating func append(url: URL) {
        items.append(QueueItem(url: url))
    }

    /// Puts something at the FRONT, so it plays after the current clip and before
    /// whatever was already queued — Apple Music's "Play Next" as against "Play
    /// Last". Worth having separately: during a set the useful question is almost
    /// always "what comes immediately after this", not "what comes eventually".
    public mutating func insertNext(url: URL) {
        items.insert(QueueItem(url: url), at: 0)
    }

    /// Takes the next item off the front. Returns nil when the queue is empty, which
    /// is how a one-shot clip knows to just stop the way it always did.
    public mutating func takeNext() -> QueueItem? {
        items.isEmpty ? nil : items.removeFirst()
    }

    public mutating func remove(id: QueueItem.ID) {
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

/// The four queues, one per source, keyed by channel letter.
public struct QueueSet: Equatable, Codable, Sendable {

    /// Channel letters that have a queue. Fixed at four: SPEC 2's graph has
    /// exactly these sources, and a fifth queue would have nothing to play into.
    public static let channels = ["A", "B", "C", "D"]

    private var queues: [String: ClipQueue]

    public init() {
        queues = Dictionary(uniqueKeysWithValues: Self.channels.map { ($0, ClipQueue()) })
    }

    public subscript(channel: String) -> ClipQueue {
        get { queues[channel] ?? ClipQueue() }
        set { queues[channel] = newValue }
    }

    /// Total queued across all four, for a status readout.
    public var totalCount: Int {
        queues.values.reduce(0) { $0 + $1.count }
    }

    /// What the show file keeps: each non-empty queue's files, in play order, by
    /// channel letter. Paths rather than items — an item's id only has to be stable
    /// while the app is running, and a saved show should read as plain file lists.
    public var savedPaths: [String: [String]] {
        var saved: [String: [String]] = [:]
        for (channel, queue) in queues where !queue.isEmpty {
            saved[channel] = queue.items.map(\.url.path)
        }
        return saved
    }

    /// The queues a show file saved. Channels it does not mention start empty, and a
    /// letter that is not a channel is ignored rather than inventing a fifth queue.
    public init(savedPaths: [String: [String]]) {
        self.init()
        for (channel, paths) in savedPaths where Self.channels.contains(channel) {
            var queue = ClipQueue()
            for path in paths { queue.append(url: URL(fileURLWithPath: path)) }
            queues[channel] = queue
        }
    }
}

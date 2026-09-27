//
//  ABRoll.swift — A/B ROLL and ADV: what a take does to the two sources of a sub-mix.
//
//  Purpose : Broadcast A/B roll on a playable crossfader (design agreed 2026-09-24,
//            docs/specs/ab-roll-adv.md). Two independent keys per sub-mix fader:
//              • ROLL decides WHEN: the incoming source rolls (plays) on take; the
//                outgoing source pauses and re-cues to its head when it leaves air.
//              • ADV decides WHAT: when a source leaves air it loads the next clip —
//                its Up Next queue first, then the library fallback.
//            This file is the pure logic: which side is incoming, and which clip is
//            next. The App does the loading and playing.
//  Inputs  : a crossfader target, a queue, the library as its panel shows it.
//  Outputs : `ABRoll.Take` (incoming/outgoing channel) and `NextClipPicker.Pick`.
//  Connects: ShellController (on CUT, FADE, the bus keys and their MIDI triggers).
//  Extend  : a new fallback is a case in `ABRollFallback` and a branch in `pick`.
//

import Foundation

/// A take on one sub-mix: which of its two channels goes on air and which leaves.
public enum ABRoll {

    public struct Take: Equatable, Sendable {
        public let incoming: String
        public let outgoing: String
    }

    /// The take a crossfader move makes. 0 is entirely the left channel, 1 the right.
    ///
    /// - Parameters:
    ///   - channels: the sub-mix's (left, right) channels, e.g. ("A", "B").
    ///   - target: where the move lands.
    public static func take(channels: (left: String, right: String), target: Double) -> Take {
        target >= 0.5
            ? Take(incoming: channels.right, outgoing: channels.left)
            : Take(incoming: channels.left, outgoing: channels.right)
    }
}

/// What ADV loads when a channel's Up Next queue is empty.
public enum ABRollFallback: String, CaseIterable, Codable, Sendable {
    /// Nothing: the outgoing clip stays (and re-cues if ROLL is on).
    case off
    /// The next clip down the library as its panel is sorted, back to the top at the end.
    case inOrder
    /// A shuffle (no repeats until every clip has been dealt) within the outgoing
    /// clip's bin.
    case shuffleBin
    /// A shuffle across everything the library panel shows.
    case shuffleAll

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .inOrder: "In order"
        case .shuffleBin: "Shuffle bin"
        case .shuffleAll: "Shuffle all"
        }
    }
}

/// A clip the library could hand to ADV.
public struct LibraryCandidate: Equatable, Sendable {
    public let url: URL
    public let bin: String?
    public init(url: URL, bin: String?) {
        self.url = url
        self.bin = bin
    }
}

/// Chooses the next clip for one sub-mix. Keeps its own library cursor and shuffle
/// deck, so In order walks down the list instead of repeating the top clip, and a
/// shuffle deals every clip once before any comes back.
public struct NextClipPicker: Sendable {

    public struct Pick: Equatable, Sendable {
        public let url: URL
        /// True when it came from the Up Next queue; false for a library fallback.
        public let fromQueue: Bool
        public let fallback: ABRollFallback?
    }

    /// The last library clip In order handed out, by path.
    private var cursorPath: String?
    /// Paths already dealt in the current shuffle, keyed by the pool they came from.
    private var dealt: [String: Set<String>] = [:]

    public init() {}

    /// The next clip, or nil when there is nothing to load.
    ///
    /// - Parameters:
    ///   - queue: the outgoing channel's Up Next; the queue always wins.
    ///   - library: what the library panel shows, in its current order.
    ///   - onAir: the clip on air on the other side — never cued twice at once.
    ///   - outgoing: the clip leaving air — its bin is "the bin" for Shuffle bin.
    ///   - isLoadable: skip anything that cannot be loaded (missing files).
    ///   - random: a number in 0..<1, injected so tests are repeatable.
    public mutating func pick(
        queue: inout Playlist,
        library: [LibraryCandidate],
        fallback: ABRollFallback,
        onAir: URL?,
        outgoing: LibraryCandidate?,
        isLoadable: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        random: () -> Double = { Double.random(in: 0..<1) }
    ) -> Pick? {
        while let next = queue.takeNext() {
            if isLoadable(next.url) { return Pick(url: next.url, fromQueue: true, fallback: nil) }
        }
        // Never the clip on air opposite, and never the clip that is leaving — cueing
        // it again is no advance at all (unless it is the only thing there is).
        let onAirPath = onAir?.standardizedFileURL.path
        let leavingPath = outgoing?.url.standardizedFileURL.path
        let loadable = library.filter {
            $0.url.standardizedFileURL.path != onAirPath && isLoadable($0.url)
        }
        let usable = loadable.count > 1
            ? loadable.filter { $0.url.standardizedFileURL.path != leavingPath }
            : loadable
        guard !usable.isEmpty else { return nil }

        switch fallback {
        case .off:
            return nil
        case .inOrder:
            let paths = usable.map { $0.url.standardizedFileURL.path }
            let start = cursorPath.flatMap { paths.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            let chosen = usable[start % usable.count]
            cursorPath = chosen.url.standardizedFileURL.path
            return Pick(url: chosen.url, fromQueue: false, fallback: .inOrder)
        case .shuffleBin, .shuffleAll:
            var pool = usable
            var poolKey = "all"
            if fallback == .shuffleBin, let bin = outgoing?.bin {
                let inBin = usable.filter { $0.bin == bin }
                if !inBin.isEmpty { pool = inBin; poolKey = "bin:\(bin)" }
            }
            var used = dealt[poolKey] ?? []
            var fresh = pool.filter { !used.contains($0.url.standardizedFileURL.path) }
            if fresh.isEmpty {
                // The deck is dealt: reshuffle, but not straight back to the clip
                // that just left air when anything else is available.
                used = []
                let leaving = outgoing?.url.standardizedFileURL.path
                fresh = pool.count > 1 ? pool.filter { $0.url.standardizedFileURL.path != leaving } : pool
            }
            let index = min(Int(random() * Double(fresh.count)), fresh.count - 1)
            let chosen = fresh[index]
            used.insert(chosen.url.standardizedFileURL.path)
            dealt[poolKey] = used
            return Pick(url: chosen.url, fromQueue: false, fallback: fallback)
        }
    }
}

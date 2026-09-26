//
//  ClipPrefetcher.swift — decodes a clip's next frames before the playhead needs them.
//
//  Purpose : Decoding ran inside the render tick, on the main thread: every loop
//            wrap, reader restart and heavy frame landed on the frame it was needed
//            for (audit 09-26 F1/F4: 26–77 ms ticks, all `source.*`). The playhead
//            still advances on the tick — the graph is frame-clocked — but the
//            decoding now happens a few frames AHEAD, on this source's own serial
//            queue, so the tick only picks up a finished picture.
//  Inputs  : the frames the node predicts it will want (`prefetch`), and the frame it
//            wants now (`image(at:damage:)`).
//  Outputs : decoded `ImageBuffer`s.
//  Connects: ClipSourceNode (the only owner), any `ClipDecoding`.
//  Extend  : the ring's capacity is the one tuning knob. Keep a decode per queue
//            block, so an urgent request never waits behind more than one frame.
//
//  THREADING. The decoder is touched ONLY on `queue`. The ready ring and the wish list
//  are guarded by `lock`. The main thread never decodes on its own: a miss asks the
//  queue synchronously (`queue.sync`), which waits for at most the one decode already
//  running, then decodes the wanted frame. Misses are expected on a load, a seek and
//  when the damage changes (the wedge reseeds on the beat); steady playback, loop
//  wraps and ping-pong turns are prefetched.
//

import Foundation

/// Decodes ahead of a source's playhead on a background queue.
public final class ClipPrefetcher {

    /// The decoder. Read-only facts (length, rate, shape) may be read anywhere; every
    /// decode goes through this object, never directly.
    public let decoder: ClipDecoding

    /// Frames kept decoded. Enough to cover a few frames ahead plus a loop's far side;
    /// at a canvas-sized SD frame (~1.4 MB) this is ~11 MB per source.
    public static let capacity = 8

    private let queue: DispatchQueue
    private let lock = NSLock()

    private struct Entry {
        let index: Int
        let damage: CorruptionSettings
        let image: ImageBuffer
    }

    // Guarded by `lock`.
    private var ready: [Entry] = []
    private var wanted: [Int] = []
    private var wantedDamage = CorruptionSettings.inert
    private var pumping = false
    private var counters = Statistics()
    /// A frame the tick is waiting for right now; decoded before anything on the
    /// wish list. Its semaphore is signalled when it lands.
    private var urgent: (index: Int, damage: CorruptionSettings, done: DispatchSemaphore)?

    /// How the prefetcher is doing, for self-QA and the debug overlay.
    public struct Statistics: Equatable {
        /// Frames the tick found ready.
        public var hits = 0
        /// Frames the tick had to wait for.
        public var misses = 0
        /// Frames decoded in the background.
        public var prefetched = 0
        /// Ticks that could not wait any longer and held the previous picture.
        public var held = 0
    }

    /// What a bounded request found.
    public enum Fetch {
        case ready(ImageBuffer)
        /// Still decoding; it will be in the ring for a later tick.
        case pending
        /// The decoder produced nothing for this frame.
        case failed
    }

    public var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        return counters
    }

    public init(decoder: ClipDecoding, label: String) {
        self.decoder = decoder
        self.queue = DispatchQueue(label: "videoboy.decode.\(label)", qos: .userInteractive)
    }

    /// The picture for a frame: ready if it was prefetched, decoded now (waiting for the
    /// queue) if not. Nil only when the decoder produced nothing.
    public func image(at index: Int, damage: CorruptionSettings) -> ImageBuffer? {
        lock.lock()
        if let entry = ready.first(where: { $0.index == index && $0.damage == damage }) {
            counters.hits += 1
            lock.unlock()
            return entry.image
        }
        counters.misses += 1
        lock.unlock()

        let decoded: ImageBuffer? = queue.sync { decoder.image(at: index, corruption: damage) }
        if let decoded { store(Entry(index: index, damage: damage, image: decoded)) }
        return decoded
    }

    /// The picture for a frame, waiting at most `limit` for a miss. For the LIVE tick:
    /// a decode that takes longer (the first frame of a freshly opened HD file, a
    /// reader seek) must not hold up the whole frame, so the tick is told `.pending`,
    /// holds its previous picture, and finds the frame ready next time.
    public func image(at index: Int, damage: CorruptionSettings, waitingAtMost limit: TimeInterval) -> Fetch {
        lock.lock()
        if let entry = ready.first(where: { $0.index == index && $0.damage == damage }) {
            counters.hits += 1
            lock.unlock()
            return .ready(entry.image)
        }
        counters.misses += 1
        let done: DispatchSemaphore
        if let current = urgent, current.index == index, current.damage == damage {
            done = current.done
        } else {
            done = DispatchSemaphore(value: 0)
            urgent = (index, damage, done)
        }
        let start = !pumping
        if start { pumping = true }
        lock.unlock()
        if start { queue.async { [weak self] in self?.pump() } }

        guard done.wait(timeout: .now() + limit) == .success else {
            lock.lock(); counters.held += 1; lock.unlock()
            return .pending
        }
        lock.lock(); defer { lock.unlock() }
        if let entry = ready.first(where: { $0.index == index && $0.damage == damage }) {
            return .ready(entry.image)
        }
        return .failed
    }

    /// Replaces the wish list: decode these frames, in this order, with this damage.
    /// Returns at once; the work happens on the queue.
    public func prefetch(_ indices: [Int], damage: CorruptionSettings) {
        lock.lock()
        wanted = indices
        wantedDamage = damage
        let start = !pumping && nextWanted() != nil
        if start { pumping = true }
        lock.unlock()
        if start { queue.async { [weak self] in self?.pump() } }
    }

    /// The first wished-for frame not yet decoded. Call with `lock` held.
    private func nextWanted() -> Int? {
        wanted.first { index in !ready.contains { $0.index == index && $0.damage == wantedDamage } }
    }

    /// Decodes ONE wished-for frame, then queues itself again if more remain — one
    /// decode per block, so `image(at:)`'s `queue.sync` waits for at most one.
    private func pump() {
        lock.lock()
        // The tick's own request goes first.
        if let request = urgent {
            urgent = nil
            lock.unlock()
            if let image = decoder.image(at: request.index, corruption: request.damage) {
                store(Entry(index: request.index, damage: request.damage, image: image))
            }
            request.done.signal()
            queue.async { [weak self] in self?.pump() }
            return
        }
        guard let index = nextWanted() else {
            pumping = false
            lock.unlock()
            return
        }
        let damage = wantedDamage
        lock.unlock()

        if let image = decoder.image(at: index, corruption: damage) {
            store(Entry(index: index, damage: damage, image: image))
            lock.lock(); counters.prefetched += 1; lock.unlock()
        } else {
            // A frame that will not decode is dropped from the list, or the pump would
            // retry it forever; the tick's own request reports the failure.
            lock.lock(); wanted.removeAll { $0 == index }; lock.unlock()
        }
        queue.async { [weak self] in self?.pump() }
    }

    /// Adds a decoded frame, evicting what is no longer wanted first, oldest first.
    private func store(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        ready.removeAll { $0.index == entry.index && $0.damage == entry.damage }
        ready.append(entry)
        while ready.count > Self.capacity {
            if let stale = ready.firstIndex(where: { candidate in
                !(wanted.contains(candidate.index) && candidate.damage == wantedDamage)
            }), stale < ready.count - 1 {
                ready.remove(at: stale)
            } else {
                ready.removeFirst()
            }
        }
    }
}

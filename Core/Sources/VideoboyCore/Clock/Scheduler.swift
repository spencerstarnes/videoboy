//
//  Scheduler.swift — lookahead scheduling with latency compensation (SPEC 4b).
//
//  Purpose : Turns "do this on the next 1/4 note" into "fire this callback at host
//            time T minus the module's latency", so the *visible* result lands on the
//            beat. This is the piece that goes silently wrong if skipped, which is
//            why it is unit-tested.
//  Inputs  : a Transport, subscriptions, and host time advancing via `advance(to:)`.
//  Outputs : callbacks, fired in time order.
//  Connects: Transport (musical/host time conversion), any node that acts on a beat.
//  Extend  : add a subscription kind, not a second scheduler. The compensation rule
//            below must apply to every kind or events will drift apart.
//

import Foundation

/// A scheduled musical event.
public struct ScheduledEvent: Equatable {
    /// Which subscription fired.
    public let subscriptionID: Int
    /// The musical position the event is *for*.
    public let targetBeat: Double
    /// Host time the action must be taken at: the target's host time minus latency.
    public let fireHostTime: Double
    /// Host time the result is intended to become visible at.
    public let targetHostTime: Double

    public init(subscriptionID: Int, targetBeat: Double, fireHostTime: Double, targetHostTime: Double) {
        self.subscriptionID = subscriptionID
        self.targetBeat = targetBeat
        self.fireHostTime = fireHostTime
        self.targetHostTime = targetHostTime
    }
}

/// Schedules actions onto beat boundaries, compensated for module latency.
public final class Scheduler {

    /// One subscriber: a subdivision, a latency, and what to do.
    private struct Subscription {
        let id: Int
        let subdivision: Subdivision
        /// This module's processing latency, in seconds.
        let latencySeconds: Double
        let action: (ScheduledEvent) -> Void
        /// The last boundary already scheduled, so each one fires exactly once.
        var lastScheduledBeat: Double
    }

    private let transport: Transport
    private var subscriptions: [Int: Subscription] = [:]
    private var nextSubscriptionID = 1

    /// How far ahead boundaries are computed. A window rather than an instant is what
    /// lets an action with latency be fired *before* its target time.
    public var lookaheadSeconds: Double = 0.2

    /// Events fired so far, newest last. Kept for tests and the debug overlay.
    ///
    /// BOUNDED. This used to grow for the life of the process: seven subscriptions on
    /// quarter notes at 120 BPM is 14 events a second, so a four-hour show appended
    /// ~200,000 of them — several megabytes, and a full-array copy on whichever single
    /// frame happened to hit a capacity doubling. Nothing outside the tests ever read
    /// more than the last handful, so the growth was pure cost.
    private(set) public var firedEvents: [ScheduledEvent] = []

    /// How many fired events to keep. Comfortably more than the debug overlay shows or
    /// any test asserts over, and small enough that the array never has to grow again.
    private static let firedEventCapacity = 512

    public init(transport: Transport) {
        self.transport = transport
    }

    /// Subscribes to a subdivision.
    ///
    /// - Parameters:
    ///   - subdivision: which boundaries to fire on.
    ///   - latencyInFrames: the module's declared latency. Converted to seconds at
    ///     the project frame rate, because latency is a property of the render path,
    ///     not of the tempo.
    ///   - frameRate: the project rate used for that conversion.
    ///   - action: run when the event fires.
    /// - Returns: a subscription ID for `unsubscribe`.
    @discardableResult
    public func subscribe(
        subdivision: Subdivision,
        latencyInFrames: Int = 0,
        frameRate: Double = StandardDefinition.frameRate,
        action: @escaping (ScheduledEvent) -> Void
    ) -> Int {
        let id = nextSubscriptionID
        nextSubscriptionID += 1
        let latencySeconds = frameRate > 0 ? Double(latencyInFrames) / frameRate : 0
        subscriptions[id] = Subscription(
            id: id,
            subdivision: subdivision,
            latencySeconds: latencySeconds,
            action: action,
            // Start from the current position so a late subscriber does not
            // immediately fire for every boundary since the transport started.
            lastScheduledBeat: transport.beats(atHostTime: currentHostTime)
        )
        Log.info(.clock, "subscription \(id): \(subdivision.rawValue), latency \(latencyInFrames) frames (\(String(format: "%.1f", latencySeconds * 1000))ms)")
        return id
    }

    /// Removes a subscription.
    public func unsubscribe(_ id: Int) {
        subscriptions.removeValue(forKey: id)
    }

    /// How many beats behind `now` a subscription may be and still have its missed
    /// boundaries fired. Further behind than this, they are skipped (see `advance`).
    public static let maximumCatchUpBeats = 2.0

    /// Most recent host time seen by `advance(to:)`.
    private(set) public var currentHostTime: Double = 0

    /// Advances the scheduler to `hostTime`, firing everything due.
    ///
    /// The compensation rule, which is the whole point of this file: an event whose
    /// *target* is host time T is fired at `T − latency`, so a module that takes
    /// `latency` to produce a visible result produces it at T.
    public func advance(to hostTime: Double) {
        currentHostTime = hostTime
        guard transport.isRunning else { return }

        let nowBeats = transport.beats(atHostTime: hostTime)
        let horizonBeats = transport.beats(atHostTime: hostTime + lookaheadSeconds)

        var due: [(Subscription, ScheduledEvent)] = []

        // A very late advance — the Mac slept mid-show, or the app was suspended —
        // must not replay every missed boundary in this one tick: after an 8-hour
        // sleep that was 57,600 closures before the next frame could render
        // (BUGHUNT S5). Anything older than `maximumCatchUpBeats` is skipped, not
        // replayed; the few boundaries nearest now still fire so beat-driven state
        // lands where it should.
        let catchUpFloor = nowBeats - Self.maximumCatchUpBeats

        for (id, var subscription) in subscriptions {
            if subscription.lastScheduledBeat < catchUpFloor {
                let skipped = catchUpFloor - subscription.lastScheduledBeat
                Log.warn(.clock, "subscription \(id) was "
                    + String(format: "%.1f", skipped + Self.maximumCatchUpBeats)
                    + " beats behind (the app was asleep or suspended); skipped "
                    + String(format: "%.1f", skipped) + " beats instead of replaying them")
                subscription.lastScheduledBeat = catchUpFloor
            }
            // Walk every boundary between what we last scheduled and the horizon.
            var boundary = transport.nextBoundary(
                after: subscription.lastScheduledBeat, subdivision: subscription.subdivision
            )
            while boundary <= horizonBeats {
                let targetHostTime = transport.hostTime(forBeat: boundary)
                let fireHostTime = targetHostTime - subscription.latencySeconds

                // Fire once the compensated time has arrived. A boundary whose
                // compensated time is still in the future waits for a later advance.
                if fireHostTime <= hostTime {
                    due.append((subscription, ScheduledEvent(
                        subscriptionID: id,
                        targetBeat: boundary,
                        fireHostTime: fireHostTime,
                        targetHostTime: targetHostTime
                    )))
                    subscription.lastScheduledBeat = boundary
                    boundary = transport.nextBoundary(
                        after: boundary, subdivision: subscription.subdivision
                    )
                } else {
                    break
                }
            }
            subscriptions[id] = subscription
        }

        // Fire in time order so two subscriptions on the same beat behave predictably.
        due.sort { $0.1.fireHostTime < $1.1.fireHostTime }
        for (subscription, event) in due {
            firedEvents.append(event)
            subscription.action(event)
        }
        if firedEvents.count > Self.firedEventCapacity {
            firedEvents.removeFirst(firedEvents.count - Self.firedEventCapacity)
        }

    }
}

//
//  BeatNetParticleFilter.swift — where the beats are, from BeatNet's activations.
//
//  Purpose : The network says, frame by frame, how beat-like the sound is. This
//            decides which frames ARE beats, causally, by tracking 1,500 guesses
//            ("particles") of the current tempo and position within the beat, and
//            keeping the guesses the activations agree with. It is the beat half of
//            BeatNet's cascade particle filter (particle_filtering_cascade.py),
//            itself built on madmom's bar-pointer state space (Krebs, Böck &
//            Widmer, ISMIR 2015).
//  Inputs  : one `BeatNetActivation` per 20 ms frame.
//  Outputs : `process(_:)` returns true on a frame judged to be a beat.
//  Connects: BeatNetTracker, which turns these beats into a tempo and a phase.
//  Extend  : the numbers are BeatNet's own. Where this differs from the Python, it
//            is listed below — each on purpose.
//
//  ── THE STATE SPACE ─────────────────────────────────────────────────────────────
//
//  Tempos are beat intervals of 14…55 frames (215…55 BPM), one per whole frame, as
//  madmom builds them for this range. An interval of n frames has n states, one per
//  frame of the beat. A particle steps one state per frame; at the last state of a
//  beat it jumps to the first state of some interval, preferring the one it came
//  from (exponential tempo change, lambda 60). Tempo here is therefore coarse — 120
//  BPM sits between 115 and 125 — which is why BeatNetTracker measures tempo from
//  the beat times, not from the particles.
//
//  ── DIFFERENCES FROM THE PYTHON ─────────────────────────────────────────────────
//
//  - The downbeat half of the cascade is left out. It only labels a beat "1"; it
//    never moves or removes one, so the beat times are unchanged without it.
//  - The particle count stays at 1,500. The Python adds a few particles on every
//    strong activation and never removes them (its np.delete result is discarded),
//    so the swarm grows through a song. Here the injected particles are resampled
//    back down to 1,500.
//  - The random source is seeded, so a run is repeatable in tests.
//

import Foundation

/// BeatNet's causal beat inference.
public final class BeatNetParticleFilter {

    public static let minimumBPM = 55.0
    public static let maximumBPM = 215.0
    public static let particleCount = 1_500
    /// How strongly a beat's tempo prefers the previous beat's (madmom's lambda).
    private static let transitionLambda = 60.0
    /// Activations below this are "no evidence" (BeatNet's information gate).
    private static let informationGate: Float = 0.4
    /// What a non-beat state, or a gated activation, weighs.
    private static let floorWeight: Float = 0.03
    /// Above this, fresh particles are seeded at the start of a beat.
    private static let injectionLevel: Float = 0.8
    /// A beat may be declared while the swarm is this many seconds into its beat.
    private static let beatWindowSeconds = 0.07

    private let frameSeconds = 1 / BeatNetFeatures.framesPerSecond

    /// Beat interval, in frames, of each tempo.
    public let intervals: [Int]
    /// First and last state of each tempo.
    private let firstStates: [Int]
    private let lastStates: [Int]
    /// For each state: which tempo it belongs to, and how far into the beat it is.
    private let stateTempo: [Int]
    private let stateOffset: [Int]
    /// Cumulative transition probabilities, per tempo, to each tempo.
    private let cumulativeTransitions: [[Double]]

    private var particles: [Int]
    private var random: SplitMix64
    /// Frames processed so far; frame i is at time i × 20 ms.
    private(set) public var frameIndex = -1
    /// Time of the last beat declared (0 before any, as in the Python).
    private var lastBeatTime = 0.0

    public init(seed: UInt64 = 1) {
        let fps = BeatNetFeatures.framesPerSecond
        let minimumInterval = 60 * fps / Self.maximumBPM
        let maximumInterval = 60 * fps / Self.minimumBPM
        // madmom's BeatStateSpace: every whole interval between the rounded ends.
        // (It only thins to log spacing when asked for fewer than that; BeatNet asks
        // for 300, which is more.) numpy rounds halves to even; neither end is a half.
        let intervals = Array(Int(minimumInterval.rounded())...Int(maximumInterval.rounded()))
        self.intervals = intervals

        var firstStates: [Int] = [], lastStates: [Int] = []
        var stateTempo: [Int] = [], stateOffset: [Int] = []
        for (tempo, interval) in intervals.enumerated() {
            firstStates.append(stateTempo.count)
            for offset in 0..<interval {
                stateTempo.append(tempo)
                stateOffset.append(offset)
            }
            lastStates.append(stateTempo.count - 1)
        }
        self.firstStates = firstStates
        self.lastStates = lastStates
        self.stateTempo = stateTempo
        self.stateOffset = stateOffset

        // madmom's exponential_transition, normalised per row, as cumulative sums.
        cumulativeTransitions = intervals.map { from in
            var row = intervals.map { to -> Double in
                let probability = exp(-Self.transitionLambda * abs(Double(to) / Double(from) - 1))
                return probability <= Double.ulpOfOne ? 0 : probability
            }
            let total = row.reduce(0, +)
            var running = 0.0
            for index in row.indices {
                running += row[index] / total
                row[index] = running
            }
            return row
        }

        random = SplitMix64(seed: seed)
        let stateCount = stateTempo.count
        // Uniform over every state but the last, as the Python does.
        particles = (0..<Self.particleCount).map { _ in 0 }
        for index in particles.indices {
            particles[index] = Int(random.next() % UInt64(stateCount - 1))
        }
    }

    /// Total states in the space.
    public var stateCount: Int { stateTempo.count }

    /// The swarm's tempo, in BPM, by the median particle. Coarse; see the header.
    public var swarmTempo: Double {
        let median = medianState()
        return 60 * BeatNetFeatures.framesPerSecond / Double(intervals[stateTempo[median]])
    }

    /// Feeds one frame. Returns true when this frame is a beat.
    public func process(_ activation: BeatNetActivation) -> Bool {
        frameIndex += 1
        let time = Double(frameIndex) * frameSeconds
        var level = activation.anyBeat
        if level < Self.informationGate { level = Self.floorWeight }

        // Is the swarm at the start of a beat, and has it been long enough since the
        // last one? Then a strong activation now is a beat.
        var isBeat = false
        let gathering = medianState()
        let interval = intervals[stateTempo[gathering]]
        let atBeatStart = stateOffset[gathering] < Int(Self.beatWindowSeconds / frameSeconds) + 1
        let longEnough = time - lastBeatTime > 0.4 * frameSeconds * Double(interval)
        if atBeatStart && longEnough && level > Self.informationGate {
            isBeat = true
            lastBeatTime = time
        }

        // Motion: one state along, or on to the start of a (possibly new) tempo.
        for index in particles.indices {
            let state = particles[index]
            let tempo = stateTempo[state]
            if state == lastStates[tempo] {
                let draw = random.nextUnit()
                let row = cumulativeTransitions[tempo]
                var next = row.firstIndex { $0 >= draw } ?? (row.count - 1)
                if row[next] == 0 { next = tempo }
                particles[index] = firstStates[next]
            } else {
                particles[index] = state + 1
            }
        }

        // Correction: only when there is something to correct with.
        if level > 0.1 {
            var candidates = particles
            if level > Self.injectionLevel {
                // A strong beat: seed particles at beat starts across the tempo range,
                // so a tempo the swarm has lost can be found again.
                var tempo = Int(random.next() % 4)
                while tempo < firstStates.count {
                    candidates.append(firstStates[tempo])
                    tempo += 6
                }
            }
            let weights = candidates.map { stateOffset[$0] == 0 ? level : Self.floorWeight }
            particles = resample(candidates, weights: weights, count: Self.particleCount)
        }
        return isBeat
    }

    /// The median particle's state, as numpy's median then int() gives it.
    private func medianState() -> Int {
        let sorted = particles.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// BeatNet's `universal_resample`: stratified — one uniform draw in each of
    /// `count` equal slices of the cumulative weight.
    private func resample(_ candidates: [Int], weights: [Float], count: Int) -> [Int] {
        let total = weights.reduce(0, +)
        var cumulative = [Double](repeating: 0, count: weights.count)
        var running = 0.0
        for index in weights.indices {
            running += Double(weights[index] / total)
            cumulative[index] = running
        }
        var result = [Int](repeating: 0, count: count)
        var source = 0
        for slot in 0..<count {
            let target = (Double(slot) + random.nextUnit()) / Double(count)
            while source < cumulative.count - 1 && cumulative[source] < target { source += 1 }
            result[slot] = candidates[source]
        }
        return result
    }
}

/// A small, fast, seedable random source (Steele, Lea & Flood's SplitMix64).
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

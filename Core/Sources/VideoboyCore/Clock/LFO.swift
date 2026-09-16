//
//  LFO.swift — transport-locked low-frequency oscillation (SPEC 6A).
//
//  Purpose : Any parameter can be driven by an oscillator locked to the musical
//            clock, so motion stays musical: a checkerboard flipping every 1/4, a
//            plasma breathing on the 1/1, a colour strobing on the beat.
//  Inputs  : a musical position (or a free-running time) and the LFO's settings.
//  Outputs : a value in 0...1, ready to be written into a param code.
//  Connects: Transport (which supplies beats), ParamRegistry (where the value lands),
//            Scheduler (which supplies the latency compensation).
//  Extend  : add a shape to `LFOShape` and a branch in `rawValue(atPhase:)`. The
//            shape set is deliberately identical to the audio-reactivity shapes so
//            the two feel the same to use (SPEC 6A, SPEC 13).
//
//  Everything here is a pure function of phase. That is what makes it testable
//  without a clock, and what lets the same LFO be evaluated at a *future* time for
//  latency compensation — ask it for its value at the moment the frame will be seen,
//  not the moment it is computed.
//

import Foundation

/// The oscillator shapes. Shared with audio-reactivity so the vocabulary is one set.
public enum LFOShape: String, CaseIterable, Codable, Sendable {
    case sine
    case triangle
    case rampUp
    case rampDown
    case square
    /// Holds a random value for the whole of each cycle.
    case sampleAndHold
    /// Smoothly interpolated random values — drifting rather than stepping.
    case noise

    public var displayName: String {
        switch self {
        case .sine: "Sine"
        case .triangle: "Triangle"
        case .rampUp: "Ramp Up"
        case .rampDown: "Ramp Down"
        case .square: "Square"
        case .sampleAndHold: "Sample & Hold"
        case .noise: "Noise"
        }
    }

    /// Selects a shape from a 0...1 parameter.
    public static func from(normalised value: Double) -> LFOShape {
        let all = allCases
        let index = Int((min(max(value, 0), 1) * Double(all.count - 1)).rounded())
        return all[min(index, all.count - 1)]
    }
}

/// How fast the oscillator runs.
public enum LFORate: Equatable, Codable, Sendable {
    /// Locked to the transport: one cycle per this many beats.
    case subdivision(Subdivision)
    /// Free-running, unlocked from the music.
    case free(hertz: Double)

    /// Cycle length in beats, or nil when free-running.
    public var beatsPerCycle: Double? {
        switch self {
        case .subdivision(let subdivision): subdivision.beats
        case .free: nil
        }
    }

    /// A short label for the UI.
    public var displayName: String {
        switch self {
        case .subdivision(let subdivision): subdivision.rawValue
        case .free(let hertz): String(format: "%.2f Hz", hertz)
        }
    }
}

/// One transport-locked oscillator.
public struct LFO: Equatable, Codable, Sendable {

    public var shape: LFOShape
    public var rate: LFORate
    /// How far the oscillation swings, 0...1. At 0 the LFO outputs its centre.
    public var depth: Double
    /// Offset in cycles, 0...1, so two LFOs on the same rate can run out of step.
    public var phaseOffset: Double
    /// When true the output swings either side of 0.5; when false it runs 0 up to
    /// `depth`. Unipolar is what you want for something like brightness; bipolar for
    /// something like position.
    public var bipolar: Bool
    /// Flips the output.
    public var invert: Bool
    /// Seed for the random shapes, so a performance repeats.
    public var seed: UInt64

    public init(
        shape: LFOShape = .sine,
        rate: LFORate = .subdivision(.quarter),
        depth: Double = 1.0,
        phaseOffset: Double = 0.0,
        bipolar: Bool = false,
        invert: Bool = false,
        seed: UInt64 = 1
    ) {
        self.shape = shape
        self.rate = rate
        self.depth = depth
        self.phaseOffset = phaseOffset
        self.bipolar = bipolar
        self.invert = invert
        self.seed = seed
    }

    /// The oscillator's position in its cycle, 0..<1, at a musical position.
    ///
    /// - Parameters:
    ///   - beats: total beats elapsed, from the transport.
    ///   - seconds: wall-clock seconds, used only by a free-running LFO.
    public func phase(atBeats beats: Double, seconds: Double) -> Double {
        let cycles: Double
        switch rate {
        case .subdivision(let subdivision):
            let beatsPerCycle = subdivision.beats
            cycles = beatsPerCycle > 0 ? beats / beatsPerCycle : 0
        case .free(let hertz):
            cycles = seconds * hertz
        }
        let shifted = cycles + phaseOffset
        // `truncatingRemainder` keeps this correct for negative positions, which a
        // phase offset or a nudged transport can produce.
        let wrapped = shifted.truncatingRemainder(dividingBy: 1.0)
        return wrapped < 0 ? wrapped + 1.0 : wrapped
    }

    /// The raw shape value in 0...1, before depth, polarity or inversion.
    ///
    /// Takes the cycle as well as the phase because the two random shapes are not
    /// functions of phase alone: sample-and-hold holds one value for a whole cycle,
    /// and noise interpolates between this cycle's value and the next one's. Passing
    /// only the phase would make those two shapes unrepresentable, which is how they
    /// end up quietly returning nothing.
    public func rawValue(atPhase phase: Double, cycle: Int) -> Double {
        let p = min(max(phase, 0), 1)
        switch shape {
        case .sine:
            // Shifted and scaled so a sine runs 0 to 1 rather than -1 to 1.
            return 0.5 - 0.5 * cos(2.0 * Double.pi * p)
        case .triangle:
            return p < 0.5 ? p * 2.0 : 2.0 - p * 2.0
        case .rampUp:
            return p
        case .rampDown:
            return 1.0 - p
        case .square:
            return p < 0.5 ? 0.0 : 1.0
        case .sampleAndHold:
            // One value per cycle, held for the whole of it.
            return randomValue(forCycle: cycle)
        case .noise:
            // Smoothstep between this cycle's value and the next, so it drifts
            // rather than stepping.
            let from = randomValue(forCycle: cycle)
            let to = randomValue(forCycle: cycle + 1)
            let eased = p * p * (3.0 - 2.0 * p)
            return from + (to - from) * eased
        }
    }

    /// The oscillator's output at a musical position, with depth and polarity applied.
    ///
    /// - Returns: a value in 0...1, ready to write into a parameter.
    public func value(atBeats beats: Double, seconds: Double) -> Double {
        let cycleIndex = cycleNumber(atBeats: beats, seconds: seconds)
        let p = phase(atBeats: beats, seconds: seconds)
        var raw = rawValue(atPhase: p, cycle: cycleIndex)

        if invert { raw = 1.0 - raw }

        if bipolar {
            // Swing either side of the centre by depth.
            return min(max(0.5 + (raw - 0.5) * depth, 0), 1)
        }
        return min(max(raw * depth, 0), 1)
    }

    /// Which cycle the oscillator is in, used by the random shapes.
    public func cycleNumber(atBeats beats: Double, seconds: Double) -> Int {
        let cycles: Double
        switch rate {
        case .subdivision(let subdivision):
            let beatsPerCycle = subdivision.beats
            cycles = beatsPerCycle > 0 ? beats / beatsPerCycle : 0
        case .free(let hertz):
            cycles = seconds * hertz
        }
        return Int((cycles + phaseOffset).rounded(.down))
    }

    /// A stable pseudo-random value for a cycle index.
    ///
    /// Derived from the seed and the index rather than from a running generator, so
    /// asking for cycle 100 gives the same answer whether or not cycles 0-99 were
    /// ever evaluated. That matters because the LFO is sampled at future times for
    /// latency compensation, and sometimes not sampled at all when a frame is late.
    private func randomValue(forCycle index: Int) -> Double {
        var generator = SeededRandom(seed: seed &+ UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9)
        return generator.nextUnitValue()
    }
}

/// Binds LFOs to parameters and writes their values in each frame.
public final class LFOBank {

    /// One LFO driving one parameter.
    public struct Assignment: Equatable {
        public let lfo: LFO
        public let slot: String
        public let code: ParamCode
        /// The node's own latency, so the LFO is evaluated at the moment the result
        /// will actually be seen rather than the moment it is computed (SPEC 6A).
        public let latencyInFrames: Int

        public init(lfo: LFO, slot: String, code: ParamCode, latencyInFrames: Int = 0) {
            self.lfo = lfo
            self.slot = slot
            self.code = code
            self.latencyInFrames = latencyInFrames
        }
    }

    private(set) public var assignments: [Assignment] = []
    private let transport: Transport

    public init(transport: Transport) {
        self.transport = transport
    }

    /// Assigns an LFO to a parameter, replacing any existing one on that parameter.
    ///
    /// One LFO per parameter: two oscillators fighting over the same value is never
    /// what anyone means, and the result would depend on evaluation order.
    public func assign(_ assignment: Assignment) {
        assignments.removeAll { $0.slot == assignment.slot && $0.code == assignment.code }
        assignments.append(assignment)
        Log.info(.clock, "LFO \(assignment.lfo.shape.rawValue) at \(assignment.lfo.rate.displayName) -> \(assignment.slot)/\(assignment.code.rawValue)")
    }

    /// Removes the LFO driving a parameter, if any.
    public func remove(slot: String, code: ParamCode) {
        assignments.removeAll { $0.slot == slot && $0.code == code }
    }

    /// True when a parameter is being driven by an LFO — the UI lights the `C` badge.
    public func isDriven(slot: String, code: ParamCode) -> Bool {
        assignments.contains { $0.slot == slot && $0.code == code }
    }

    /// Evaluates every LFO and writes its value into the registry.
    ///
    /// - Parameters:
    ///   - hostTime: now.
    ///   - registry: where the values land.
    ///   - frameRate: used to turn a node's frame latency into seconds.
    public func update(
        atHostTime hostTime: Double,
        into registry: ParamRegistry,
        frameRate: Double = StandardDefinition.frameRate
    ) {
        for assignment in assignments {
            // Look ahead by the node's latency so the value that lands is the one
            // wanted at the moment the frame becomes visible.
            let lookahead = frameRate > 0 ? Double(assignment.latencyInFrames) / frameRate : 0
            let futureTime = hostTime + lookahead
            let beats = transport.beats(atHostTime: futureTime)
            let normalised = assignment.lfo.value(atBeats: beats, seconds: futureTime)

            // The registry scales the 0...1 output into the parameter's own range.
            guard let parameter = registry.parameter(slot: assignment.slot, code: assignment.code) else {
                continue
            }
            registry.setValue(
                parameter.denormalise(normalised), slot: assignment.slot, code: assignment.code)
        }
    }
}

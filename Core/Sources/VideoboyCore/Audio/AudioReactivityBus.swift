//
//  AudioReactivityBus.swift — audio driving parameters (SPEC 4c, SPEC 13).
//
//  Purpose : Distributes the analyser's measurements to parameters, through the same
//            param-code surface that MIDI and the LFOs use. SPEC 13 asks for the
//            same shape vocabulary as the LFO, so the two feel identical to use.
//  Inputs  : `AudioFrame`s from the analyser.
//  Outputs : values written into a `ParamRegistry`.
//  Connects: AudioAnalyzer, ParamRegistry, and the `S` mapping badge in the UI.
//  Extend  : add a tap to `ReactivityTap` or a shape to `ReactivityShape`. Do not
//            add a second distribution mechanism — MIDI, LFO and audio all land in
//            the registry by code, and that is what keeps mappings interchangeable.
//

import Foundation

/// Which measurement drives a parameter.
public enum ReactivityTap: Equatable, Codable, Sendable {
    /// Overall level.
    case rms
    /// Peak level in the window.
    case peak
    /// One frequency band, by index into `AudioAnalyzer.bandEdges`.
    case band(index: Int)
    /// Fires on detected onsets.
    case onset

    public var displayName: String {
        switch self {
        case .rms: "RMS"
        case .peak: "Peak"
        case .band(let index): "Band \(index + 1)"
        case .onset: "Onset"
        }
    }
}

/// How a tap's value is shaped before it reaches the parameter.
///
/// Deliberately the same vocabulary as the LFO shapes where they overlap (SPEC 13).
public enum ReactivityShape: String, CaseIterable, Codable, Sendable {
    /// The value straight through.
    case direct
    /// Jumps to full on a trigger and falls back — the classic "pump on the kick".
    case pulse
    /// Rises with the signal but falls slowly.
    case envelope
    /// One over the value.
    case invert
    /// Holds the value at each trigger until the next.
    case sampleHold
    /// Full or nothing, either side of a threshold.
    case gate

    public var displayName: String {
        switch self {
        case .direct: "Direct"
        case .pulse: "Pulse"
        case .envelope: "Envelope"
        case .invert: "Invert"
        case .sampleHold: "Sample & Hold"
        case .gate: "Gate"
        }
    }
}

/// One audio tap bound to one parameter.
public struct ReactivityAssignment: Equatable {
    public let tap: ReactivityTap
    public let shape: ReactivityShape
    public let slot: String
    public let code: ParamCode
    /// Scales the tap before shaping. Audio rarely reaches full scale.
    public var gain: Double
    /// Below this, the tap reads as zero. Keeps room noise from wobbling everything.
    public var threshold: Double
    /// How fast `pulse` and `envelope` fall, per update, 0...1.
    public var decay: Double

    public init(
        tap: ReactivityTap,
        shape: ReactivityShape = .direct,
        slot: String,
        code: ParamCode,
        gain: Double = 3.0,
        threshold: Double = 0.02,
        decay: Double = 0.12
    ) {
        self.tap = tap
        self.shape = shape
        self.slot = slot
        self.code = code
        self.gain = gain
        self.threshold = threshold
        self.decay = decay
    }
}

/// Holds the latest analysis and pushes shaped values into parameters.
public final class AudioReactivityBus {

    /// The most recent measurements. Read by the UI meters.
    public private(set) var latest: AudioFrame = .silent()

    /// Whether audio input is actually running. False means every tap reads zero,
    /// which is what makes a mapping harmless when no input is connected.
    public var isRunning = false

    private(set) public var assignments: [ReactivityAssignment] = []
    /// Per-assignment running state for the shapes that have memory.
    private var shapeState: [String: Double] = [:]

    public init() {}

    /// Binds a tap to a parameter, replacing any existing binding on that parameter.
    public func assign(_ assignment: ReactivityAssignment) {
        assignments.removeAll { $0.slot == assignment.slot && $0.code == assignment.code }
        assignments.append(assignment)
        Log.info(.clock, "audio \(assignment.tap.displayName) (\(assignment.shape.rawValue)) -> \(assignment.slot)/\(assignment.code.rawValue)")
    }

    /// Removes the audio binding on a parameter.
    public func remove(slot: String, code: ParamCode) {
        assignments.removeAll { $0.slot == slot && $0.code == code }
        shapeState.removeValue(forKey: "\(slot)/\(code.rawValue)")
    }

    /// True when a parameter is audio-driven — the UI lights the `S` badge.
    public func isDriven(slot: String, code: ParamCode) -> Bool {
        assignments.contains { $0.slot == slot && $0.code == code }
    }

    /// The raw value of a tap in the current frame, before gain or shaping.
    public func rawValue(of tap: ReactivityTap) -> Double {
        guard isRunning else { return 0 }
        switch tap {
        case .rms: return latest.rms
        case .peak: return latest.peak
        case .band(let index):
            guard index >= 0, index < latest.bands.count else { return 0 }
            return latest.bands[index]
        case .onset: return latest.onset ? 1 : 0
        }
    }

    /// Takes a new analysis frame and updates every bound parameter.
    public func update(with frame: AudioFrame, into registry: ParamRegistry) {
        latest = frame
        guard isRunning else { return }

        for assignment in assignments {
            let key = "\(assignment.slot)/\(assignment.code.rawValue)"
            let raw = rawValue(of: assignment.tap)
            // Gain first, then the noise gate, then clamp: audio rarely reaches full
            // scale, so without gain most taps would barely move a parameter.
            let amplified = raw * assignment.gain
            let gated = amplified < assignment.threshold ? 0 : amplified
            let value = min(max(gated, 0), 1)

            let shaped = shape(value, assignment: assignment, key: key, onset: frame.onset)
            shapeState[key] = shaped

            guard let parameter = registry.parameter(slot: assignment.slot, code: assignment.code) else {
                continue
            }
            registry.setValue(
                parameter.denormalise(shaped), slot: assignment.slot, code: assignment.code)
        }
    }

    /// Applies the assignment's shape to a gated value.
    private func shape(
        _ value: Double, assignment: ReactivityAssignment, key: String, onset: Bool
    ) -> Double {
        let previous = shapeState[key] ?? 0

        switch assignment.shape {
        case .direct:
            return value

        case .invert:
            return 1.0 - value

        case .pulse:
            // Snap to full on a trigger, then fall. An onset tap triggers on onsets;
            // a level tap triggers when it rises.
            let triggered = assignment.tap == .onset ? onset : value > previous
            return triggered ? 1.0 : max(previous - assignment.decay, 0)

        case .envelope:
            // Follows the signal up instantly and falls slowly, so a parameter tracks
            // loudness without chattering on every dip.
            return value > previous ? value : max(previous - assignment.decay, value)

        case .sampleHold:
            // Holds until the next onset.
            return onset ? value : previous

        case .gate:
            return value > assignment.threshold ? 1.0 : 0.0
        }
    }

    /// Clears running shape state. Used when the input changes.
    public func reset() {
        shapeState.removeAll()
        latest = .silent()
    }
}

//
//  VideoboyCore.swift — library entry point, version, and feature flags.
//
//  Purpose : One obvious place to ask "what version is this?" and "is subsystem X
//            switched on?". Phase work lands behind a flag here so half-built
//            subsystems ship disabled instead of destabilising the app (SPEC 1.5).
//  Inputs  : none at runtime; flags are compile-time defaults overridable by the
//            VIDEOBOY_FLAGS environment variable (comma-separated flag names).
//  Outputs : `Videoboy.version`, `FeatureFlags.current`.
//  Connects: read by App at launch (to title the window and grey out panels) and
//            by the self-QA harness (to record which flags an artifact was made under).
//  Extend  : add a `case` to `FeatureFlag` plus a default in `defaultsForPhase`.
//            Never branch on a phase number anywhere else — branch on a flag.
//

import Foundation

/// Namespace for library-wide identity.
public enum Videoboy {
    /// Semantic version of the Core library. Bumped per phase.
    public static let version = "0.4.5"

    /// Human-readable build banner, logged once at startup.
    public static var banner: String {
        "Videoboy Core \(version) (\(FeatureFlags.current.enabled.count) flags on)"
    }
}

/// A switchable subsystem. Anything not finished in the current phase is listed
/// here and defaults to `false`, so its UI renders disabled rather than absent.
public enum FeatureFlag: String, CaseIterable, Sendable {
    /// DV demux + decode through the vendored libav shim.
    case dvDecode
    /// The pre-decode DIF bitstream corruptor.
    ///
    /// OFF, and deliberately so. It is the thing this app was built around, and it is
    /// switched off because it cannot currently be JUDGED: there is no DV hardware here
    /// to see its output on an analog chain, and an effect whose whole point is what it
    /// does to a real signal is one you cannot tune by looking at a preview.
    ///
    /// It is off rather than deleted. Every node, shader, parameter and test is intact;
    /// this flag is the only thing standing between the app and all of it. Whatever it
    /// becomes next will start from the working version rather than from a rewrite.
    case bitstreamCorruptor
    /// Re-encoding a mixed bus so data effects can run on it.
    ///
    /// The other half of the same decision: a bus has no bitstream until it is
    /// re-encoded, and the controls for that only mean anything if the corruptor they
    /// feed is running.
    case busDataStage
    /// The NTSC and DV toggles on the output bar.
    ///
    /// Signal character applied to what LEAVES the app. Same reason as the corruptor:
    /// it is judged on a monitor at the end of an analog chain, not in a preview.
    case outputSignalEmulation
    /// Musical transport + subdivision scheduler driving parameter changes.
    case musicalClock
    /// Core MIDI input and shift-to-detect learn.
    case midiControl
    /// Borderless output window on an external display.
    case displayOutput
    /// Analog composite/NTSC emulation passes (Phase 3).
    case compositeCodec
    /// Echo/trails and internal/external feedback (Phase 3).
    case feedback
    /// ISF shader host (Phase 4+).
    case isfHost
    /// Synthetic generators and transport LFO (Phase 4+).
    case generators
    /// Emulated titler library, out-of-process (Phase 4+).
    case emulatedTitler
    /// Recording and streaming of PRIMARY / discrete channels (Phase 4+).
    case recording
    /// IP video in/out (Phase 4+).
    case ipVideo
}

/// The set of flags this build runs with.
public struct FeatureFlags: Sendable {
    /// Flags currently switched on.
    public let enabled: Set<FeatureFlag>

    /// Flags earned by the phases completed so far. Everything else stays off.
    private static let defaultsForPhase: Set<FeatureFlag> = [
        // dvDecode stays ON: reading a .dv file is how the samples play at all, and it
        // has nothing to do with corrupting one.
        .dvDecode,
        // bitstreamCorruptor, busDataStage and outputSignalEmulation are OFF — see
        // their declarations. `VIDEOBOY_FLAGS=bitstreamCorruptor,busDataStage,
        // outputSignalEmulation` brings all three back for one launch.
        .musicalClock,
        .midiControl,
        .displayOutput,
        .compositeCodec,
        .feedback
    ]

    /// The process-wide flag set, resolved once from defaults + `VIDEOBOY_FLAGS`.
    public static let current: FeatureFlags = FeatureFlags(
        environment: ProcessInfo.processInfo.environment["VIDEOBOY_FLAGS"]
    )

    /// Builds a flag set from the phase defaults, then applies an optional override list.
    ///
    /// The override string is a comma-separated list of flag names. A leading `-`
    /// turns a flag off, anything else turns it on. Unknown names are logged and
    /// ignored rather than trapping, so a stale template can never stop a launch.
    public init(environment override: String?) {
        var flags = FeatureFlags.defaultsForPhase
        guard let override, !override.isEmpty else {
            self.enabled = flags
            return
        }
        for rawToken in override.split(separator: ",") {
            let token = rawToken.trimmingCharacters(in: .whitespaces)
            let turningOff = token.hasPrefix("-")
            let name = turningOff ? String(token.dropFirst()) : token
            guard let flag = FeatureFlag(rawValue: name) else {
                Log.warn(.app, "ignoring unknown feature flag '\(name)' in VIDEOBOY_FLAGS")
                continue
            }
            if turningOff { flags.remove(flag) } else { flags.insert(flag) }
        }
        self.enabled = flags
    }

    /// True when `flag` is switched on in this build.
    public func isOn(_ flag: FeatureFlag) -> Bool { enabled.contains(flag) }
}

public extension FeatureFlag {
    /// Convenience so call sites read `FeatureFlag.dvDecode.isOn`.
    var isOn: Bool { FeatureFlags.current.isOn(self) }
}

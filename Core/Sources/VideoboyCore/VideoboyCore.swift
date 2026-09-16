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
    public static let version = "0.2.0"

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
    /// The pre-decode DIF bitstream corruptor (the wedge).
    case bitstreamCorruptor
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
        .dvDecode,
        .bitstreamCorruptor,
        .musicalClock,
        .midiControl,
        .displayOutput
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

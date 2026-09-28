//
//  CorruptionSettings.swift — how much, and how, to damage a clip's bitstream.
//
//  Purpose : The wedge's damage, as the source nodes and the corruptor card hold it:
//            an amount, a seed, and a 0...1 mode position that each bitstream
//            family reads as its own mode (MPEG: frame drop, motion-vector corrupt,
//            reference hold — `MPEGCorruptionMode`). Kept free of any one codec, so a
//            family added later reads the same three numbers.
//  Inputs  : the corruptor card's parameters (31B amount, 32B mode, 34B seed).
//  Outputs : settings, and their reading for the MPEG family (`asMPEG`).
//  Connects: ClipSourceNode (applies them), MPEGCorruptor, the scheduler (re-seeds).
//  Extend  : a new family adds its own `as…` reading of `modePosition`.
//

import Foundation

/// Damage to apply to a clip's compressed bitstream.
public struct CorruptionSettings: Equatable, Codable, Sendable {
    /// 0 is untouched, 1 is maximum damage (param code `31B`).
    public var amount: Double
    /// Reproducibility (param code `34B`). Re-rolled on a beat by the scheduler.
    public var seed: UInt64
    /// Where the mode fader sits, 0...1 (param code `32B`); each family picks its
    /// own mode from it.
    public var modePosition: Double

    public init(amount: Double = 0, seed: UInt64 = 1, modePosition: Double = 0) {
        self.amount = amount
        self.seed = seed
        self.modePosition = modePosition
    }

    /// Settings that do nothing, used as the default and as the "dry" end of a mix.
    public static let inert = CorruptionSettings(amount: 0, seed: 1, modePosition: 0)

    /// This damage as the MPEG family reads it.
    public var asMPEG: MPEGCorruptionSettings {
        MPEGCorruptionSettings(
            amount: amount,
            mode: MPEGCorruptionMode.from(normalised: modePosition),
            seed: seed
        )
    }
}

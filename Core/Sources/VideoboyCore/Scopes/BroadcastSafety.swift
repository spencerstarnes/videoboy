//
//  BroadcastSafety.swift — NTSC legal levels, and what is outside them (SPEC 19).
//
//  Purpose : An analog chain has hard limits. Luma below 7.5 IRE crushes to black on
//            a CRT, above 100 IRE blooms and can distort sync; oversaturated chroma
//            produces colour that simply cannot be encoded. This is the arithmetic
//            for spotting that.
//  Inputs  : an `ImageBuffer`.
//  Outputs : counts and percentages.
//  Connects: the scopes, the settings-bar warnings, and the character generator's
//            NTSC-legal fill check (SPEC 18.1), which asks this the same question
//            about one colour that the scopes ask about a whole frame.
//
//  IRE and 8-bit. NTSC video runs 7.5 IRE (black) to 100 IRE (white) — the "setup"
//  or pedestal. In 8-bit studio-swing terms that is 16 to 235, which is where the
//  numbers below come from. Full-range 0 and 255 are both illegal.
//

import Foundation

/// Where the legal range sits, in 8-bit terms.
public enum BroadcastLevels {
    /// 7.5 IRE — NTSC black. Anything below this crushes.
    public static let black: Double = 16
    /// 100 IRE — NTSC white. Anything above this blooms.
    public static let white: Double = 235
    /// Converts an 8-bit level to IRE, for readouts that speak the analog language.
    public static func ire(from level: Double) -> Double {
        // 16 maps to 7.5 IRE and 235 maps to 100 IRE; linear between.
        let span = white - black
        guard span > 0 else { return 0 }
        return 7.5 + (level - black) / span * (100.0 - 7.5)
    }
}

/// What a frame's levels look like against the broadcast limits.
public struct BroadcastSafetyReport: Equatable, Sendable {
    /// Fraction of sampled pixels below legal black, 0...1.
    public let belowBlack: Double
    /// Fraction above legal white.
    public let aboveWhite: Double
    /// The highest luma found, in IRE.
    public let peakIRE: Double
    /// The lowest luma found, in IRE.
    public let floorIRE: Double

    public init(belowBlack: Double, aboveWhite: Double, peakIRE: Double, floorIRE: Double) {
        self.belowBlack = belowBlack
        self.aboveWhite = aboveWhite
        self.peakIRE = peakIRE
        self.floorIRE = floorIRE
    }

    /// True when enough of the picture is outside the legal range to be worth saying
    /// so. A handful of pixels is normal and warning about them would train the
    /// operator to ignore the warning.
    public var isIllegal: Bool {
        belowBlack > 0.01 || aboveWhite > 0.01
    }

    /// A short line for the status bar.
    public var summary: String {
        guard isIllegal else {
            return String(format: "legal · %.0f–%.0f IRE", floorIRE, peakIRE)
        }
        var parts: [String] = []
        if aboveWhite > 0.01 { parts.append(String(format: "%.1f%% hot", aboveWhite * 100)) }
        if belowBlack > 0.01 { parts.append(String(format: "%.1f%% crushed", belowBlack * 100)) }
        return parts.joined(separator: " · ")
    }
}

/// Measures broadcast legality.
public enum BroadcastSafety {

    /// Measures a frame against the NTSC legal range.
    public static func analyse(_ image: ImageBuffer) -> BroadcastSafetyReport {
        var below = 0.0
        var above = 0.0
        var counted = 0.0
        var peak = 0.0
        var floor = 255.0

        // Every row, every other column: the same reasoning as the variance sampler —
        // skipping rows aliases with the 2-row patterns this app is full of.
        for y in 0..<image.height {
            for x in stride(from: 0, to: image.width, by: 2) {
                let pixel = image.pixel(x: x, y: y)
                let luma = 0.299 * Double(pixel.r) + 0.587 * Double(pixel.g) + 0.114 * Double(pixel.b)
                if luma < BroadcastLevels.black { below += 1 }
                if luma > BroadcastLevels.white { above += 1 }
                peak = max(peak, luma)
                floor = min(floor, luma)
                counted += 1
            }
        }
        guard counted > 0 else {
            return BroadcastSafetyReport(belowBlack: 0, aboveWhite: 0, peakIRE: 0, floorIRE: 0)
        }
        return BroadcastSafetyReport(
            belowBlack: below / counted,
            aboveWhite: above / counted,
            peakIRE: BroadcastLevels.ire(from: peak),
            floorIRE: BroadcastLevels.ire(from: floor)
        )
    }
}

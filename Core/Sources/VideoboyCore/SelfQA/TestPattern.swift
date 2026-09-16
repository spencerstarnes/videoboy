//
//  TestPattern.swift — synthetic images with known, assertable content.
//
//  Purpose : Gives the harness something whose correct appearance is known exactly,
//            so an offscreen render or a capture round-trip can be checked by
//            arithmetic rather than by eye. Also doubles as the app's "Test Pat"
//            output toggle (SPEC 14.2 settings bar).
//  Inputs  : dimensions.
//  Outputs : `ImageBuffer`s.
//  Connects: OffscreenRenderer proof-of-life, DVC100 loopback reference frames,
//            FrameAssertions (which know these patterns' expected colours).
//  Extend  : add a `static func` returning an ImageBuffer, and a matching expected-
//            value table if assertions need to know its content.
//

import Foundation

/// Standard-definition project geometry (SPEC 3). Used as the default everywhere
/// a size is not otherwise specified, so no magic 720/480 literals appear inline.
public enum StandardDefinition {
    public static let width = 720
    public static let height = 480
    /// NTSC broadcast rate, 30000/1001.
    public static let frameRate = 30000.0 / 1001.0
}

/// Builders for known test images.
public enum TestPattern {

    /// The eight SMPTE top-bar colours, left to right, at 75% amplitude.
    /// Kept as a table so assertions can compare against the same source of truth.
    public static let smpteBarColors: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (191, 191, 191),  // grey
        (191, 191, 0),    // yellow
        (0, 191, 191),    // cyan
        (0, 191, 0),      // green
        (191, 0, 191),    // magenta
        (191, 0, 0),      // red
        (0, 0, 191),      // blue
        (0, 0, 0)         // black
    ]

    /// Classic vertical colour bars. The single most useful pattern: every bar has a
    /// distinct, widely separated colour, so a wrong channel order, a flipped image,
    /// or a wrong size all show up immediately in assertions.
    public static func colorBars(
        width: Int = StandardDefinition.width,
        height: Int = StandardDefinition.height
    ) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        let barCount = smpteBarColors.count
        for y in 0..<height {
            for x in 0..<width {
                // Integer bar index; the last bar absorbs any rounding remainder.
                let bar = min(x * barCount / width, barCount - 1)
                let color = smpteBarColors[bar]
                image.setPixel(x: x, y: y, r: color.r, g: color.g, b: color.b)
            }
        }
        return image
    }

    /// A flat field of one colour. Used to prove "signal present" logic and to give
    /// the crossfade test two unambiguous endpoints.
    public static func solid(
        width: Int = StandardDefinition.width,
        height: Int = StandardDefinition.height,
        r: UInt8, g: UInt8, b: UInt8
    ) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                image.setPixel(x: x, y: y, r: r, g: g, b: b)
            }
        }
        return image
    }

    /// Alternating black/white rows. Its comb score is the maximum a real signal can
    /// reach, so it calibrates the interlace detector's upper end.
    public static func horizontalLines(
        width: Int = StandardDefinition.width,
        height: Int = StandardDefinition.height
    ) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            let value: UInt8 = (y % 2 == 0) ? 255 : 0
            for x in 0..<width {
                image.setPixel(x: x, y: y, r: value, g: value, b: value)
            }
        }
        return image
    }

    /// A horizontal luminance ramp. Smooth vertically, so its comb score is the
    /// floor — this calibrates the interlace detector's lower end.
    public static func grayscaleRamp(
        width: Int = StandardDefinition.width,
        height: Int = StandardDefinition.height
    ) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8(x * 255 / max(width - 1, 1))
                image.setPixel(x: x, y: y, r: value, g: value, b: value)
            }
        }
        return image
    }
}

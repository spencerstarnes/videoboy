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

/// An analog SD video standard: what a composite signal (the DVC100 grabber, the
/// output card's SD mode) carries. The raster and rate, nothing codec-specific.
public enum AnalogStandard: String, Codable, Sendable {
    case ntsc
    case pal

    /// Active picture size in pixels.
    public var size: (width: Int, height: Int) {
        switch self {
        case .ntsc: (StandardDefinition.width, StandardDefinition.height)
        case .pal: (720, 576)
        }
    }

    /// Frames per second.
    public var frameRate: Double {
        switch self {
        case .ntsc: StandardDefinition.frameRate
        case .pal: 25.0
        }
    }
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
        ImageBuffer(width: width, height: height, r: r, g: g, b: b)
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

    /// Crosshatch / grid. Used for CRT geometry checks and, per SPEC 11, for seeding
    /// feedback loops — a grid gives the loop hard edges to chew on.
    public static func crosshatch(
        width: Int = StandardDefinition.width,
        height: Int = StandardDefinition.height,
        spacing: Int = 40
    ) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                // Lines on the grid, plus a border, drawn white on black.
                let onGrid = x % spacing == 0 || y % spacing == 0
                    || x == width - 1 || y == height - 1
                let value: UInt8 = onGrid ? 255 : 0
                image.setPixel(x: x, y: y, r: value, g: value, b: value)
            }
        }
        return image
    }

    /// PLUGE: black, below-black and above-black bars for setting CRT brightness.
    ///
    /// NTSC black sits at 7.5 IRE, so the reference patches straddle it — the
    /// just-below patch should be invisible on a correctly set monitor and the
    /// just-above one barely visible.
    public static func pluge(
        width: Int = StandardDefinition.width,
        height: Int = StandardDefinition.height
    ) -> ImageBuffer {
        // 7.5 IRE of a 0...100 IRE range, in 8-bit terms.
        let blackLevel = UInt8(0.075 * 255)
        var image = solid(width: width, height: height, r: blackLevel, g: blackLevel, b: blackLevel)
        let patchWidth = width / 6
        let patches: [(index: Int, value: UInt8)] = [
            (1, max(blackLevel, 4) - 4),   // below black
            (2, blackLevel),               // black
            (3, blackLevel + 8),           // just above black
            (4, 191)                       // a 75% white reference
        ]
        for patch in patches {
            for y in height / 4..<(height * 3 / 4) {
                for x in (patch.index * patchWidth)..<((patch.index + 1) * patchWidth) {
                    image.setPixel(x: x, y: y, r: patch.value, g: patch.value, b: patch.value)
                }
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

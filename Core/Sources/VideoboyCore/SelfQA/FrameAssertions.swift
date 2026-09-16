//
//  FrameAssertions.swift — the numeric checks Claude runs on a frame it cannot see.
//
//  Purpose : Turns "does this look right?" into arithmetic. Every visual acceptance
//            item in BUILD-PLAN.md is ultimately one of these calls, so a phase can
//            be judged done without a human looking at a screen.
//  Inputs  : `ImageBuffer`s (rendered or captured) and expected values.
//  Outputs : plain values (scores, booleans, differences) plus `AssertionResult`s
//            carrying a human-readable reason for a failure.
//  Connects: SelfQACheck (which aggregates results into result.txt), the unit tests,
//            and CaptureMetrics (which reuses combing/signal maths).
//  Extend  : add a `static func` returning `AssertionResult`. Keep each one about a
//            single property, and always put the observed number in the message —
//            a failure must explain itself without a rerun.
//

import Foundation

/// Outcome of one check, with a reason good enough to debug from.
public struct AssertionResult {
    public let name: String
    public let passed: Bool
    public let detail: String

    public init(name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }

    /// One-line rendering used in `result.txt`.
    public var line: String { "\(passed ? "PASS" : "FAIL")  \(name) — \(detail)" }
}

/// Checks over a single frame or a pair of frames.
public enum FrameAssertions {

    // MARK: - Geometry

    /// Asserts exact pixel dimensions. A silent resize is one of the easiest ways
    /// for an output path to go wrong, so this is checked everywhere.
    public static func hasDimensions(
        _ image: ImageBuffer, width: Int, height: Int
    ) -> AssertionResult {
        let matches = image.width == width && image.height == height
        return AssertionResult(
            name: "dimensions",
            passed: matches,
            detail: "expected \(width)x\(height), got \(image.width)x\(image.height)"
        )
    }

    // MARK: - Colour

    /// Mean colour of a rectangular region, as floating-point 0...255 per channel.
    /// Defaults to the whole image.
    public static func meanColor(
        _ image: ImageBuffer, region: (x: Int, y: Int, width: Int, height: Int)? = nil
    ) -> (r: Double, g: Double, b: Double) {
        let area = region ?? (x: 0, y: 0, width: image.width, height: image.height)
        var totals = (r: 0.0, g: 0.0, b: 0.0)
        var counted = 0
        for y in area.y..<min(area.y + area.height, image.height) {
            for x in area.x..<min(area.x + area.width, image.width) {
                let pixel = image.pixel(x: x, y: y)
                totals.r += Double(pixel.r)
                totals.g += Double(pixel.g)
                totals.b += Double(pixel.b)
                counted += 1
            }
        }
        guard counted > 0 else { return (0, 0, 0) }
        return (totals.r / Double(counted), totals.g / Double(counted), totals.b / Double(counted))
    }

    /// Asserts a region's mean colour is within `tolerance` (per channel, 0...255)
    /// of an expected colour. Tolerant by design: capture paths shift levels slightly.
    public static func regionIsApproximately(
        _ image: ImageBuffer,
        region: (x: Int, y: Int, width: Int, height: Int)? = nil,
        r: UInt8, g: UInt8, b: UInt8,
        tolerance: Double = 24.0,
        name: String = "region color"
    ) -> AssertionResult {
        let mean = meanColor(image, region: region)
        let deltas = (
            abs(mean.r - Double(r)),
            abs(mean.g - Double(g)),
            abs(mean.b - Double(b))
        )
        let worst = max(deltas.0, max(deltas.1, deltas.2))
        let formatted = String(format: "mean(%.1f, %.1f, %.1f)", mean.r, mean.g, mean.b)
        return AssertionResult(
            name: name,
            passed: worst <= tolerance,
            detail: "\(formatted) vs expected(\(r), \(g), \(b)); worst delta \(String(format: "%.1f", worst)), tolerance \(tolerance)"
        )
    }

    /// Asserts an image carries the SMPTE colour bars, by sampling the centre of
    /// each bar. This is the proof-of-life check for any render or capture path.
    public static func looksLikeColorBars(
        _ image: ImageBuffer, tolerance: Double = 24.0
    ) -> AssertionResult {
        let barCount = TestPattern.smpteBarColors.count
        let barWidth = image.width / barCount
        // Sample the middle half of each bar, avoiding edges where a resample blurs.
        let sampleWidth = max(barWidth / 2, 1)
        var worstBar = -1
        var worstDelta = 0.0
        for bar in 0..<barCount {
            let expected = TestPattern.smpteBarColors[bar]
            let region = (
                x: bar * barWidth + (barWidth - sampleWidth) / 2,
                y: image.height / 4,
                width: sampleWidth,
                height: image.height / 2
            )
            let mean = meanColor(image, region: region)
            let delta = max(
                abs(mean.r - Double(expected.r)),
                max(abs(mean.g - Double(expected.g)), abs(mean.b - Double(expected.b)))
            )
            if delta > worstDelta {
                worstDelta = delta
                worstBar = bar
            }
        }
        return AssertionResult(
            name: "color bars",
            passed: worstDelta <= tolerance,
            detail: "worst bar \(worstBar) off by \(String(format: "%.1f", worstDelta)) (tolerance \(tolerance))"
        )
    }

    /// Asserts the expected bar colours are present somewhere in the frame, judged by
    /// colour *identity* rather than absolute level.
    ///
    /// `looksLikeColorBars` compares absolute values at fixed positions, which is
    /// right for an offscreen render whose geometry and levels are exact. It is the
    /// wrong test for a frame that has been through an analog chain, for two reasons:
    ///
    /// 1. **Position moves.** The picture is scaled and pillarboxed, so fixed sample
    ///    points no longer land on the bars.
    /// 2. **Amplitude drops, legitimately.** NTSC gives chroma far less bandwidth
    ///    than luma, and the saturated primaries lose the most. Measured on this rig,
    ///    a 191-level blue came back at 111 and red at 124 while the hues stayed
    ///    correct. That is composite video behaving normally, not a fault, and a
    ///    tolerance loose enough to accept it would accept almost anything.
    ///
    /// So this tests what actually matters: for each expected bar, is there a strip
    /// whose *channel signature* matches — the channels that should be bright are
    /// clearly brighter than the channels that should be dark? That identifies the
    /// colour and the bar order while staying indifferent to saturation loss.
    ///
    /// - Parameters:
    ///   - image: the captured frame.
    ///   - separation: how far a "bright" channel must exceed a "dark" one, 0...255.
    ///   - requiredMatches: how many of the six saturated bars must be found.
    public static func containsColorBarHues(
        _ image: ImageBuffer,
        separation: Double = 40.0,
        requiredMatches: Int = 5,
        name: String = "captured picture contains the bar colours"
    ) -> AssertionResult {
        // The six saturated bars. Grey, white and black are skipped: letterbox bars
        // and surrounding chrome would satisfy a neutral expectation trivially.
        let wanted = TestPattern.smpteBarColors.filter { color in
            !(color.r == color.g && color.g == color.b)
        }

        let stripCount = 72
        let stripWidth = max(image.width / stripCount, 1)
        // Sample the vertical middle, clear of a menu bar or a letterbox edge.
        let sampleTop = image.height / 3
        let sampleHeight = image.height / 3

        var stripMeans: [(r: Double, g: Double, b: Double)] = []
        for strip in 0..<stripCount {
            let x = strip * stripWidth
            guard x < image.width else { break }
            stripMeans.append(meanColor(image, region: (
                x: x, y: sampleTop, width: min(stripWidth, image.width - x), height: sampleHeight
            )))
        }

        /// True when `mean` carries the same bright/dark channel pattern as `expected`.
        func signatureMatches(
            _ mean: (r: Double, g: Double, b: Double),
            _ expected: (r: UInt8, g: UInt8, b: UInt8)
        ) -> Bool {
            // Split the expected colour's channels into bright and dark.
            var bright: [Double] = []
            var dark: [Double] = []
            let pairs: [(UInt8, Double)] = [
                (expected.r, mean.r), (expected.g, mean.g), (expected.b, mean.b)
            ]
            for (expectedChannel, measuredChannel) in pairs {
                if expectedChannel >= 128 { bright.append(measuredChannel) }
                else { dark.append(measuredChannel) }
            }
            guard let dimmestBright = bright.min(), let brightestDark = dark.max() else { return false }
            // The bright channels must be clearly above the dark ones, and must carry
            // real signal rather than being three shades of near-black.
            return dimmestBright > brightestDark + separation && dimmestBright > 55
        }

        var found: [String] = []
        var missing: [String] = []
        for color in wanted {
            let label = "(\(color.r),\(color.g),\(color.b))"
            if stripMeans.contains(where: { signatureMatches($0, color) }) {
                found.append(label)
            } else {
                missing.append(label)
            }
        }

        return AssertionResult(
            name: name,
            passed: found.count >= requiredMatches,
            detail: "matched \(found.count) of \(wanted.count) saturated bars by channel signature (needed \(requiredMatches))"
                + (missing.isEmpty ? "" : "; missing \(missing.joined(separator: " "))")
        )
    }

    // MARK: - Signal presence

    /// Per-channel-averaged luminance variance across the frame. A black or
    /// disconnected input sits near zero; any real picture is far above it.
    public static func luminanceVariance(_ image: ImageBuffer) -> Double {
        var sum = 0.0
        var sumOfSquares = 0.0
        var counted = 0.0
        // EVERY row, and every other column.
        //
        // Skipping rows would be faster, but this app's output is full of 2-row
        // patterns — interlaced fields, scanline overlays, comb artefacts — and a
        // row stride of 2 aliases with them perfectly, sampling only the identical
        // rows and reporting a strongly patterned frame as flat black. A "signal
        // present" check that can miss a scanline pattern is worse than useless here.
        // Columns are safe to skip: nothing in the signal path is 2-px periodic
        // horizontally.
        for y in 0..<image.height {
            for x in stride(from: 0, to: image.width, by: 2) {
                let pixel = image.pixel(x: x, y: y)
                // Rec.601 luma, matching the standard-definition colour space.
                let luma = 0.299 * Double(pixel.r) + 0.587 * Double(pixel.g) + 0.114 * Double(pixel.b)
                sum += luma
                sumOfSquares += luma * luma
                counted += 1
            }
        }
        guard counted > 0 else { return 0 }
        let mean = sum / counted
        return max(0, sumOfSquares / counted - mean * mean)
    }

    /// True when the frame carries an actual picture rather than black or noise floor.
    /// The threshold is a variance, so it is resolution-independent.
    public static func signalPresent(_ image: ImageBuffer, varianceThreshold: Double = 25.0) -> Bool {
        luminanceVariance(image) > varianceThreshold
    }

    /// Assertion wrapper around `signalPresent`.
    public static func hasSignal(
        _ image: ImageBuffer, varianceThreshold: Double = 25.0
    ) -> AssertionResult {
        let variance = luminanceVariance(image)
        return AssertionResult(
            name: "signal present",
            passed: variance > varianceThreshold,
            detail: "luminance variance \(String(format: "%.1f", variance)), threshold \(varianceThreshold)"
        )
    }

    // MARK: - Interlace / combing

    /// Combing score in 0...1: how strongly each row is a local vertical extremum
    /// relative to the rows above and below.
    ///
    /// For each interior pixel we take `(above - here) * (below - here)`. When a row
    /// is displaced from both neighbours in the same direction — exactly what a comb
    /// tooth looks like — that product is positive and large. Smooth vertical
    /// gradients give a product near zero or negative. Normalising by the squared
    /// 8-bit range puts a full-amplitude comb at 1.0.
    public static func combingScore(_ image: ImageBuffer) -> Double {
        guard image.height >= 3 else { return 0 }
        var total = 0.0
        var counted = 0.0
        let fullScaleSquared = 255.0 * 255.0
        for y in 1..<(image.height - 1) {
            for x in stride(from: 0, to: image.width, by: 2) {
                let here = luma(image, x, y)
                let above = luma(image, x, y - 1)
                let below = luma(image, x, y + 1)
                let product = (above - here) * (below - here)
                // Only same-direction displacement counts as combing.
                if product > 0 { total += product }
                counted += 1
            }
        }
        guard counted > 0 else { return 0 }
        return min(1.0, total / counted / fullScaleSquared)
    }

    /// Rec.601 luma of one pixel, as a Double.
    private static func luma(_ image: ImageBuffer, _ x: Int, _ y: Int) -> Double {
        let pixel = image.pixel(x: x, y: y)
        return 0.299 * Double(pixel.r) + 0.587 * Double(pixel.g) + 0.114 * Double(pixel.b)
    }

    // MARK: - Detail

    /// Mean absolute horizontal luma gradient — how much fine detail a frame carries.
    ///
    /// This is the right way to measure generation loss. Raw pixel difference is not:
    /// each pass of the composite codec low-passes the picture, so a heavily dubbed
    /// frame converges toward a smooth average and can end up *closer* to the source
    /// by pixel difference while obviously being more degraded. Lost detail is what
    /// a dub actually costs, so lost detail is what gets measured.
    public static func horizontalDetail(_ image: ImageBuffer) -> Double {
        guard image.width >= 2 else { return 0 }
        var total = 0.0
        var counted = 0.0
        for y in stride(from: 0, to: image.height, by: 2) {
            for x in 1..<image.width {
                total += abs(luma(image, x, y) - luma(image, x - 1, y))
                counted += 1
            }
        }
        guard counted > 0 else { return 0 }
        return total / counted
    }

    // MARK: - Difference

    /// Fraction of pixels (0...1) whose luma differs by more than `threshold`.
    ///
    /// This is the workhorse for the bitstream wedge: "did the corruptor actually
    /// change the picture, and by roughly how much?" Both images must be the same size.
    public static func differingPixelFraction(
        _ first: ImageBuffer, _ second: ImageBuffer, threshold: Double = 8.0
    ) -> Double {
        guard first.width == second.width, first.height == second.height else {
            Log.warn(.selfqa, "differingPixelFraction on mismatched sizes \(first.width)x\(first.height) vs \(second.width)x\(second.height)")
            return 1.0
        }
        var differing = 0.0
        var counted = 0.0
        for y in stride(from: 0, to: first.height, by: 2) {
            for x in stride(from: 0, to: first.width, by: 2) {
                if abs(luma(first, x, y) - luma(second, x, y)) > threshold { differing += 1 }
                counted += 1
            }
        }
        guard counted > 0 else { return 0 }
        return differing / counted
    }

    /// Asserts two frames differ over at least `minimumFraction` of the picture.
    /// Used to prove a corruption or a cut genuinely changed the output.
    public static func framesDiffer(
        _ first: ImageBuffer, _ second: ImageBuffer,
        minimumFraction: Double = 0.01,
        name: String = "frames differ"
    ) -> AssertionResult {
        let fraction = differingPixelFraction(first, second)
        return AssertionResult(
            name: name,
            passed: fraction >= minimumFraction,
            detail: "\(String(format: "%.3f", fraction)) of sampled pixels differ, needed >= \(minimumFraction)"
        )
    }

    /// Asserts two frames are effectively identical — the determinism check for a
    /// seeded corruptor.
    public static func framesMatch(
        _ first: ImageBuffer, _ second: ImageBuffer,
        maximumFraction: Double = 0.001,
        name: String = "frames match"
    ) -> AssertionResult {
        let fraction = differingPixelFraction(first, second)
        return AssertionResult(
            name: name,
            passed: fraction <= maximumFraction,
            detail: "\(String(format: "%.4f", fraction)) of sampled pixels differ, allowed <= \(maximumFraction)"
        )
    }

    // MARK: - Rate

    /// Asserts a measured frame rate sits within `tolerance` fps of the expected rate.
    public static func frameRateWithinTolerance(
        measured: Double, expected: Double, tolerance: Double = 1.0
    ) -> AssertionResult {
        let delta = abs(measured - expected)
        return AssertionResult(
            name: "frame rate",
            passed: delta <= tolerance,
            detail: "measured \(String(format: "%.3f", measured)) fps vs expected \(String(format: "%.3f", expected)), delta \(String(format: "%.3f", delta)), tolerance \(tolerance)"
        )
    }
}

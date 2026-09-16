//
//  CRTGeometry.swift — safe zones, overscan, BFI and field order (SPEC 11).
//
//  Purpose : A CRT does not show the whole frame, and an interlaced chain wants
//            fields rather than frames. These are the numbers and rules for both,
//            in one place, so the preview overlay and the actual output path cannot
//            disagree about where the safe area is.
//  Inputs  : a frame size, an overscan amount, a frame index.
//  Outputs : rectangles, scale factors, and per-frame decisions.
//  Connects: the preview overlays in the UI, the output stage, and the scheduler
//            (which decides when a black frame is inserted).
//  Extend  : PAL safe areas differ slightly; add a standard parameter when PAL
//            output is actually built.
//

import Foundation

/// A rectangle in normalised 0...1 coordinates, origin top-left.
public struct NormalisedRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The same rectangle in pixels for a given frame size.
    public func inPixels(width frameWidth: Int, height frameHeight: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        (
            x: Int((x * Double(frameWidth)).rounded()),
            y: Int((y * Double(frameHeight)).rounded()),
            width: Int((width * Double(frameWidth)).rounded()),
            height: Int((height * Double(frameHeight)).rounded())
        )
    }
}

/// CRT-target geometry.
public enum CRTGeometry {

    /// Action-safe: 90% of width and height, centred. Anything important to see
    /// belongs inside this on a 4:3 tube.
    public static let actionSafe = NormalisedRect(x: 0.05, y: 0.05, width: 0.90, height: 0.90)

    /// Title-safe: 80%. Text outside this risks being cut off.
    public static let titleSafe = NormalisedRect(x: 0.10, y: 0.10, width: 0.80, height: 0.80)

    /// The most overscan that can be dialled in, as a fraction of the frame.
    ///
    /// Consumer sets historically hid 5-10% per edge. Allowing a little beyond that
    /// gives room to match a badly aligned tube without being able to zoom the
    /// picture into abstraction.
    public static let maximumOverscan = 0.15

    /// The scale an output must apply so that `overscan` of each edge falls outside
    /// the visible screen.
    ///
    /// - Parameter overscan: 0...1, mapped onto 0...`maximumOverscan`.
    public static func overscanScale(_ overscan: Double) -> Double {
        let amount = min(max(overscan, 0), 1) * maximumOverscan
        // Losing `amount` from each edge means showing 1 - 2*amount of the picture,
        // so the picture has to be scaled up by the reciprocal.
        return 1.0 / (1.0 - 2.0 * amount)
    }

    /// The part of the source frame that survives a given overscan.
    public static func visibleRect(overscan: Double) -> NormalisedRect {
        let amount = min(max(overscan, 0), 1) * maximumOverscan
        return NormalisedRect(x: amount, y: amount, width: 1 - 2 * amount, height: 1 - 2 * amount)
    }
}

/// Which field of an interlaced frame comes first.
public enum FieldOrder: String, CaseIterable, Codable, Sendable {
    /// NTSC standard-definition is bottom-field-first.
    case bottomFieldFirst
    case topFieldFirst

    /// Whether the field carrying even-numbered rows leads.
    public var evenFieldLeads: Bool { self == .topFieldFirst }
}

/// Software interlacing: builds one frame from two fields (SPEC 11).
public enum SoftwareInterlace {

    /// Weaves two progressive frames into one interlaced frame.
    ///
    /// The first field supplies one set of alternating rows and the second supplies
    /// the other, which is what an interlaced-expecting chain wants when it is being
    /// fed from progressive sources.
    ///
    /// - Parameters:
    ///   - firstField: the frame captured earlier in time.
    ///   - secondField: the frame captured later.
    ///   - order: which field leads.
    public static func weave(
        firstField: ImageBuffer,
        secondField: ImageBuffer,
        order: FieldOrder = .bottomFieldFirst
    ) -> ImageBuffer? {
        guard firstField.width == secondField.width,
              firstField.height == secondField.height else {
            Log.error(.output, "cannot weave fields of different sizes")
            return nil
        }

        var woven = firstField
        for y in 0..<woven.height {
            // With bottom-field-first the later field supplies the even rows.
            let rowIsEven = (y % 2 == 0)
            let takeFromSecond = order.evenFieldLeads ? !rowIsEven : rowIsEven
            guard takeFromSecond else { continue }
            for x in 0..<woven.width {
                let pixel = secondField.pixel(x: x, y: y)
                woven.setPixel(x: x, y: y, r: pixel.r, g: pixel.g, b: pixel.b, a: pixel.a)
            }
        }
        return woven
    }
}

/// Black-frame insertion, clock-timed (SPEC 11).
///
/// Used both for the motion feel BFI gives on a sample-and-hold display, and to seed
/// a feedback loop with a hard edge in time.
public struct BlackFrameInsertion {

    /// How often a black frame is inserted, as one in every N frames. 0 disables it.
    public var everyNFrames: Int

    public init(everyNFrames: Int = 0) {
        self.everyNFrames = max(0, everyNFrames)
    }

    /// Whether the frame at `frameIndex` should be black.
    ///
    /// Insertion lands on the frame *before* each boundary rather than on it, so the
    /// black frame precedes the beat and the picture returns on it.
    public func isBlackFrame(_ frameIndex: Int) -> Bool {
        guard everyNFrames > 1 else { return false }
        return frameIndex % everyNFrames == everyNFrames - 1
    }

    /// Builds a setting from a 0...1 parameter (code `83A`).
    ///
    /// 0 is off; the rest maps onto inserting one black frame in every 2 to 16.
    public static func from(normalised value: Double) -> BlackFrameInsertion {
        let clamped = min(max(value, 0), 1)
        guard clamped > 0.01 else { return BlackFrameInsertion(everyNFrames: 0) }
        // Inverted so a higher value means more frequent insertion.
        let period = Int((16.0 - clamped * 14.0).rounded())
        return BlackFrameInsertion(everyNFrames: max(2, period))
    }
}

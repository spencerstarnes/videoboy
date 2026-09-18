//
//  PictureVariety.swift — has the machine actually drawn a picture yet?
//
//  Purpose : One measure, used in two places that both need the same answer: the EMU
//            panel, which should say "booting" rather than show an empty window, and
//            the emu self-QA check, which must not pass on one.
//  Inputs  : an ImageBuffer captured from an emulator window.
//  Outputs : a 0...1 score — how much of the picture differs from its commonest colour.
//  Connects: EmuSelfQA, EmuScreenView, FSUAEHost.
//  Extend  : if a machine ever legitimately shows a flat single-colour screen that must
//            count as ready, do NOT lower the threshold — give the caller a separate
//            signal. The threshold existing is the only thing keeping a blank window
//            from reading as a working emulator.
//
//  WHY THIS EXISTS, so it is not undone. The check here used to measure BRIGHTNESS:
//  what fraction of the picture was above a luminance floor. That was written to catch
//  a machine still showing black, and it did. It did not catch WHITE. Amiberry's window
//  is blank white for the first seconds after launch, which scored 96% and passed, so
//  the self-QA reported a working machine, with a captured PNG of an empty rectangle,
//  while the operator pressed START and watched nothing happen. Brightness was never
//  the property wanted. A picture has many colours; an unpainted window has one,
//  whatever that one happens to be.
//
//  Colour variety alone was not enough either, and the second attempt is recorded here
//  so it is not made a third time: mid-launch the window is white on top and black
//  below, which is two flat colours and scored 18% variety — still not a picture. What
//  separates a drawn screen from an undrawn window is LOCAL DETAIL. Text, icons, a
//  backdrop and a palette all produce edges everywhere; a blank window, or one split
//  into bands, has almost none.
//

import Foundation

public enum PictureVariety {

    /// Below this share of neighbouring pixels differing, treat the capture as a
    /// window that has not drawn yet.
    ///
    /// A booted Amiga screen — Workbench with its icons, a Kickstart prompt, a Scala
    /// page — carries detail across the frame and scores well above this. A blank
    /// window scores near zero, and so does one split into flat bands.
    public static let readyThreshold = 0.01

    /// How much local detail the PICTURE has, 0...1.
    ///
    /// Measured as the fraction of sampled pixels that differ appreciably from the
    /// pixel to their right or below. The outer eighth is ignored: window chrome and
    /// letterboxing live there and are present whether or not the machine has drawn.
    public static func score(of frame: ImageBuffer) -> Double {
        // Every pixel compared is one that is also sampled. Comparing against the
        // IMMEDIATE neighbour while sampling every second pixel leaves half the
        // columns unexamined, and an edge that falls in one of them is invisible —
        // which is how a frame full of detail measured as blank.
        let step = 2
        let insetX = frame.width / 8
        let insetY = frame.height / 8
        let maxX = frame.width - insetX - step
        let maxY = frame.height - insetY - step
        guard maxX > insetX, maxY > insetY else { return 0 }

        // A gap this size ignores capture noise and rescaling ring, and still catches
        // the edge of a glyph.
        let edge = 24
        var detailed = 0
        var total = 0
        for y in stride(from: insetY, to: maxY, by: step) {
            for x in stride(from: insetX, to: maxX, by: step) {
                let here = frame.pixel(x: x, y: y)
                let right = frame.pixel(x: x + step, y: y)
                let below = frame.pixel(x: x, y: y + step)
                total += 1
                if Self.differs(here, right, by: edge) || Self.differs(here, below, by: edge) {
                    detailed += 1
                }
            }
        }
        return total > 0 ? Double(detailed) / Double(total) : 0
    }

    private static func differs(
        _ a: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
        _ b: (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
        by threshold: Int
    ) -> Bool {
        abs(Int(a.r) - Int(b.r)) > threshold
            || abs(Int(a.g) - Int(b.g)) > threshold
            || abs(Int(a.b) - Int(b.b)) > threshold
    }

    /// Whether this frame looks like a machine that has drawn something.
    public static func isPicture(_ frame: ImageBuffer) -> Bool {
        score(of: frame) > readyThreshold
    }
}

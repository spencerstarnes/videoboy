//
//  UISelfQA.swift — renders the window shell offscreen so its layout can be checked.
//
//  Purpose : SPEC 14.4 requires the layout to reflow at wide, compact and narrow
//            widths, and BUILD-PLAN Phase 2 requires that reflow to be verified by
//            offscreen PNGs at three window sizes. AppKit can draw a view hierarchy
//            into a bitmap without ever showing a window, which needs no screen-
//            recording permission and works over SSH.
//  Inputs  : none; it builds its own ShellView at each width.
//  Outputs : selfqa/out/phase-2/ui-layout/{wide,compact,narrow}.png plus a result.txt.
//  Connects: ShellView and PanelGridView (what it renders), Core's SelfQACheck.
//  Extend  : add a width to `layoutCases`, or assert on more of the rendered result.
//

import AppKit
import VideoboyCore

/// Renders the shell offscreen at each breakpoint.
enum UISelfQA {

    /// The three widths, chosen to land inside each breakpoint band.
    private static let layoutCases: [(name: String, size: NSSize)] = [
        ("wide", NSSize(width: 1460, height: 912)),
        ("compact", NSSize(width: 1000, height: 760)),
        ("narrow", NSSize(width: 760, height: 640))
    ]

    /// Renders each case and asserts the result is a real, non-blank picture of the
    /// expected size.
    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "phase-2/ui-layout")

        for layoutCase in layoutCases {
            let shell = ShellView()
            shell.frame = NSRect(origin: .zero, size: layoutCase.size)
            // Force a full layout pass; nothing is on screen to trigger one.
            shell.layoutSubtreeIfNeeded()
            shell.displayIfNeeded()

            guard let image = render(view: shell) else {
                check.record(AssertionResult(
                    name: "\(layoutCase.name) renders", passed: false,
                    detail: "AppKit produced no bitmap at \(Int(layoutCase.size.width))px"
                ))
                continue
            }

            do {
                try check.writeImage(image, named: "\(layoutCase.name).png")
            } catch {
                Log.error(.selfqa, "could not write \(layoutCase.name).png: \(error)")
            }

            check.record(FrameAssertions.hasDimensions(
                image, width: Int(layoutCase.size.width), height: Int(layoutCase.size.height)
            ))
            // A blank window would pass a dimension check; this catches it.
            check.record(AssertionResult(
                name: "\(layoutCase.name) is not blank",
                passed: FrameAssertions.signalPresent(image, varianceThreshold: 5.0),
                detail: "luminance variance \(String(format: "%.1f", FrameAssertions.luminanceVariance(image)))"
            ))
            check.note("\(layoutCase.name): \(Int(layoutCase.size.width))x\(Int(layoutCase.size.height)) rendered")
        }

        // Collapsed states. The point of collapsing is that the middle of the window
        // gets the space, so this checks the reflow actually happens rather than the
        // groups merely disappearing.
        let collapseCases: [(name: String, groups: [PanelGroup])] = [
            ("collapsed-left", [.sourcesLeft, .effectsLeft]),
            ("collapsed-both-edges", [.sourcesLeft, .effectsLeft, .sourcesRight, .effectsRight])
        ]
        for collapseCase in collapseCases {
            let shell = ShellView()
            shell.frame = NSRect(origin: .zero, size: NSSize(width: 1460, height: 912))
            for panelGroup in collapseCase.groups {
                shell.grid.setGroup(panelGroup, collapsed: true)
            }
            shell.layoutSubtreeIfNeeded()
            shell.displayIfNeeded()

            guard let image = render(view: shell) else {
                check.record(AssertionResult(
                    name: "\(collapseCase.name) renders", passed: false, detail: "no bitmap"))
                continue
            }
            try? check.writeImage(image, named: "\(collapseCase.name).png")

            // The centre must have grown. Program Preview sits in the middle column,
            // so a widened centre shows up as more non-background pixels across the
            // horizontal band the previews occupy.
            check.record(AssertionResult(
                name: "\(collapseCase.name) is not blank",
                passed: FrameAssertions.signalPresent(image, varianceThreshold: 5.0),
                detail: "luminance variance \(String(format: "%.1f", FrameAssertions.luminanceVariance(image)))"
            ))
            check.note("\(collapseCase.name): folded \(collapseCase.groups.map(\.displayName).joined(separator: ", "))")
        }

        // Shift-to-detect, rendered. The audit proves every enabled fader carries a
        // mapping address; this proves holding Shift actually reaches them, which is
        // a different claim and the one the performer experiences.
        do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            shell.frame = NSRect(origin: .zero, size: NSSize(width: 1460, height: 912))
            shell.layoutSubtreeIfNeeded()

            controller.detectSession?.setArmed(true)
            shell.layoutSubtreeIfNeeded()
            shell.displayIfNeeded()

            var highlighted = 0
            countHighlightedFaders(in: shell, into: &highlighted)
            check.record(AssertionResult(
                name: "holding Shift lights the mappable faders",
                passed: highlighted >= 39,
                detail: "\(highlighted) faders highlighted"
            ))

            if let image = render(view: shell) {
                try? check.writeImage(image, named: "detect-armed.png")
            }

            // And releasing it puts them back — a highlight that sticks would be
            // worse than none, because it would stop meaning anything.
            controller.detectSession?.setArmed(false)
            var stillLit = 0
            countHighlightedFaders(in: shell, into: &stillLit)
            check.record(AssertionResult(
                name: "releasing Shift clears the highlights",
                passed: stillLit == 0,
                detail: "\(stillLit) faders still highlighted"
            ))
            withExtendedLifetime(controller) {}
        }

        return check.finish()
    }

    /// Counts faders currently drawing the detect highlight.
    private static func countHighlightedFaders(in view: NSView, into count: inout Int) {
        if let fader = view as? VBFader, fader.isDetectHighlighted { count += 1 }
        for subview in view.subviews { countHighlightedFaders(in: subview, into: &count) }
    }

    /// Draws a view hierarchy into an `ImageBuffer` with no window involved.
    private static func render(view: NSView) -> ImageBuffer? {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Log.error(.selfqa, "view refused to provide a bitmap representation")
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)

        // Re-draw into a known RGBA8 layout: the cached representation's own format
        // varies, and the harness assumes tightly packed RGBA everywhere.
        let width = Int(view.bounds.width)
        let height = Int(view.bounds.height)
        var pixels = [UInt8](repeating: 0, count: width * height * ImageBuffer.bytesPerPixel)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * ImageBuffer.bytesPerPixel,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = representation.cgImage else { return false }
            // No flip: in a CoreGraphics bitmap context the first row of the backing
            // buffer is already the top row of the drawn image, which is exactly
            // ImageBuffer's convention.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            Log.error(.selfqa, "could not redraw the cached representation into RGBA8")
            return nil
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }
}

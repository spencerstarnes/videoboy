//
//  BarsSelfQA.swift — a clip that is not 4:3: black bars on air, striped in the monitor.
//
//  Purpose : Sources are fitted to the canvas (CanvasFit): a 16:9 clip on the SD canvas
//            is letterboxed, and its bars are part of the picture that goes to air, so
//            they must be BLACK in the graph. The source monitor marks the same bars
//            with grey caution stripes so nobody mistakes them for picture. A 4:3 clip
//            gets neither. This proves all three in the real window.
//  Inputs  : VIDEOBOY_BARS_CLIP — a 16:9 clip (blocked without one); samples/motion.dv.
//  Outputs : selfqa/out/ui/bars/{result.txt, graph-a.png, stripes-a.png, window.png}.
//  Connects: MainWindowController, ClipSourceNode.picturePlacement, MetalPreviewView bars.
//

import AppKit
import Metal
import VideoboyCore

enum BarsSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "ui/bars")
        guard let widePath = ProcessInfo.processInfo.environment["VIDEOBOY_BARS_CLIP"],
              FileManager.default.fileExists(atPath: widePath) else {
            return check.finish(blockedReason: "set VIDEOBOY_BARS_CLIP to a 16:9 clip")
        }
        let wide = URL(fileURLWithPath: widePath)
        let sd = RepoPaths.samples.appendingPathComponent("motion.dv")
        let store = PreferenceStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoboy-bars-prefs.json"))
        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let screen = NSScreen.main,
              let shell = controller.shellController else {
            return check.finish(blockedReason: "no window to run in")
        }
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let engine = controller.engine
        let panels = shell.shell.grid.panels

        // Through the panels' drop handler, as a dragged clip arrives.
        panels.sourceBodies["A"]?.onClipDropped?(wide, nil)
        panels.sourceBodies["B"]?.onClipDropped?(sd, nil)
        engine.setPlaying(true, channel: "A")
        engine.setPlaying(true, channel: "B")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        guard let previewA = panels.sourceBodies["A"]?.preview,
              let previewB = panels.sourceBodies["B"]?.preview else {
            return check.finish(blockedReason: "no source monitors")
        }

        // 1. The GRAPH: the wide clip is letterboxed with black bars (what goes to air).
        let placement = engine.sources["A"]?.picturePlacement
        check.note("A placement: \(placement.map { "\($0)" } ?? "nil")")
        check.record(AssertionResult(
            name: "a 16:9 clip sits letterboxed in the 4:3 canvas",
            passed: placement.map { abs($0.height - 0.75) < 0.01 && abs($0.minY - 0.125) < 0.01 } ?? false,
            detail: placement.map { "picture \($0)" } ?? "no placement"))
        if let texture = engine.texture(for: "source.a"), let metal = MetalContext.shared,
           let image = OffscreenRenderer(context: metal)?.readback(texture) {
            try? check.writeImage(image, named: "graph-a.png")
            // Mid-width, well inside the top bar and in the middle of the picture.
            let bar = image.pixel(x: image.width / 2, y: image.height / 16)
            let picture = image.pixel(x: image.width / 2, y: image.height / 2)
            check.record(AssertionResult(
                name: "the bars that go to air are black",
                passed: max(bar.r, bar.g, bar.b) <= 20,
                detail: "top bar pixel \(bar)"))
            check.record(AssertionResult(
                name: "the picture itself is not black",
                passed: max(picture.r, picture.g, picture.b) > 40,
                detail: "centre pixel \(picture)"))
        }

        // 2. The MONITOR: the same bars striped, only on the wide clip.
        let barsA = previewA.barRectsForChecks
        let barsB = previewB.barRectsForChecks
        check.note("A monitor bars: \(barsA)")
        let height = previewA.bounds.height
        let expected = height * 0.125
        check.record(AssertionResult(
            name: "the wide clip's monitor stripes exactly its two bars",
            passed: barsA.count == 2 && barsA.allSatisfy { abs($0.height - expected) <= 2 },
            detail: "\(barsA.count) bars, heights \(barsA.map { Int($0.height) }), expected ~\(Int(expected))"))
        check.record(AssertionResult(
            name: "a 4:3 clip's monitor has no bars",
            passed: barsB.isEmpty, detail: "\(barsB.count) bars"))

        if let stripes = previewA.renderBarsForChecks() {
            try? check.writeImage(stripes, named: "stripes-a.png")
            // Along one row through the middle of the top bar (layers are bottom-up,
            // the image top-down), within the bar's width: both greys, nothing black.
            let top = barsA.max { $0.midY < $1.midY } ?? .zero
            let row = min(max(stripes.height - Int(top.midY), 0), stripes.height - 1)
            var shades = Set<Int>()
            for x in Int(top.minX)..<max(Int(top.maxX), Int(top.minX) + 1) {
                let p = stripes.pixel(x: x, y: row)
                shades.insert(Int(p.r) / 16)
            }
            let light = Int(Theme.Color.barStripeLight.whiteComponent * 255) / 16
            let dark = Int(Theme.Color.barStripeDark.whiteComponent * 255) / 16
            check.record(AssertionResult(
                name: "the monitor's bars are grey caution stripes, not black",
                passed: shades.contains(light) && shades.contains(dark) && !shades.contains(0),
                detail: "shade bands seen: \(shades.sorted()) (light \(light), dark \(dark))"))
        }

        // 3. The real window, for a person to look at (needs Screen Recording; the
        //    capture is blank without it, which the note says).
        let capture = check.artifactURL("window.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", capture.path]
        try? process.run()
        process.waitUntilExit()
        check.note("window capture: \(capture.lastPathComponent) (blank without Screen Recording)")

        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

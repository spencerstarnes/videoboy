//
//  FramingSelfQA.swift — FIT / FILL / STRETCH / CENTRE change the FEED.
//
//  Purpose : The owner found the source panel's key changed only the monitor. This
//            puts a 16:9 HD clip on A, presses the key through every mode, and reads
//            back the channel's picture AND the A/B sub-mix it feeds, asserting each
//            mode is placed differently in what goes to the mix.
//  Outputs : selfqa/out/perf/framing/*.png and result.txt.
//

import AppKit
import VideoboyCore

enum FramingSelfQA {

    /// Mean brightness of a band of rows, 0...255.
    private static func band(_ image: ImageBuffer, rows: ClosedRange<Double>) -> Double {
        let first = Int(rows.lowerBound * Double(image.height)), last = Int(rows.upperBound * Double(image.height)) - 1
        var total = 0, count = 0
        for y in stride(from: first, through: last, by: 2) {
            for x in stride(from: 0, to: image.width, by: 8) {
                let i = (y * image.width + x) * 4
                total += Int(image.pixels[i]) + Int(image.pixels[i + 1]) + Int(image.pixels[i + 2])
                count += 3
            }
        }
        return count > 0 ? Double(total) / Double(count) : 0
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/framing")
        let clip = RepoPaths.samples.appendingPathComponent("hd-h264-2997.mov")
        guard FileManager.default.fileExists(atPath: clip.path), let metal = MetalContext.shared,
              let readback = OffscreenRenderer(context: metal) else {
            return check.finish(blockedReason: "samples/hd-h264-2997.mov or Metal missing")
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-framing-qa-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = PreferenceStore(fileURL: scratch.appendingPathComponent("p.json"))
        let controller = MainWindowController(preferences: store)
        guard let shell = controller.shellController else { return check.finish(blockedReason: "no window") }
        controller.showWindow(nil)
        let engine = controller.engine
        let body = shell.shell.grid.panels.sourceBodies["A"]
        shell.loadForChecks(clip, channel: "A")
        UISelfQA.waitForLoads(engine)
        engine.setPlaying(false, channel: "A")
        engine.registry.setValue(0, slot: GraphTopology.subMixOne, code: .crossfadeAB)   // A on air in ONE
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        var results: [PreviewFill: (top: Double, middle: Double, image: ImageBuffer)] = [:]
        var subMixMatches = 0
        for _ in 0..<PreviewFill.allCases.count {
            body?.cycleFillForChecks()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let mode = body?.fillForChecks,
                  let channelTexture = engine.texture(for: engine.sourceSlot(forChannel: "A")),
                  let channel = readback.readback(channelTexture),
                  let subTexture = engine.texture(for: GraphTopology.subMixOne),
                  let sub = readback.readback(subTexture) else { continue }
            results[mode] = (band(channel, rows: 0...0.08), band(channel, rows: 0.45...0.55), channel)
            // The sub-mix carries the same framing: its top band agrees with the channel's.
            if abs(band(sub, rows: 0...0.08) - band(channel, rows: 0...0.08)) < 12 { subMixMatches += 1 }
            try? channel.writePNG(to: RepoPaths.selfQAOutput.appendingPathComponent("perf/framing/\(mode.rawValue)-channel.png"))
            try? sub.writePNG(to: RepoPaths.selfQAOutput.appendingPathComponent("perf/framing/\(mode.rawValue)-submix.png"))
        }

        let fit = results[.fit], fill = results[.fill], stretch = results[.stretch], centre = results[.centre]
        check.record(AssertionResult(
            name: "every mode was pressed and read back from the feed",
            passed: results.count == 4, detail: "\(results.count) of 4 modes"))
        check.record(AssertionResult(
            name: "FIT letterboxes a 16:9 clip in the feed (black bars top and bottom)",
            passed: (fit?.top ?? 99) < 20 && (fit?.middle ?? 0) > 30,
            detail: String(format: "top band %.0f, middle %.0f", fit?.top ?? -1, fit?.middle ?? -1)))
        check.record(AssertionResult(
            name: "FILL and STRETCH cover the whole canvas in the feed, and differ from each other",
            passed: (fill?.top ?? 0) > 20 && (stretch?.top ?? 0) > 20
                && fill.map { f in stretch.map { f.image.pixels != $0.image.pixels } ?? false } == true,
            detail: String(format: "fill top %.0f, stretch top %.0f", fill?.top ?? -1, stretch?.top ?? -1)))
        check.record(AssertionResult(
            name: "CENTRE shows the HD clip at native size (cropped to its middle), unlike FILL",
            passed: (centre?.top ?? 0) > 20
                && centre.map { c in fill.map { c.image.pixels != $0.image.pixels } ?? false } == true,
            detail: String(format: "centre top %.0f", centre?.top ?? -1)))
        check.record(AssertionResult(
            name: "the A/B sub-mix (what goes to air) carries the same framing as channel A",
            passed: subMixMatches == 4, detail: "\(subMixMatches) of 4 modes matched"))

        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

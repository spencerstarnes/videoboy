//
//  NowPlayingSelfQA.swift — the Now Playing generator on a real channel.
//
//  Purpose : Puts Now Playing on channel A through the same reference a Generators-tab
//            drop sends, publishes a known track (the real watcher is held off), reads
//            the channel's picture back for each look and writes PNGs to look at.
//  Outputs : selfqa/out/perf/now-playing/*.png and result.txt.
//

import AppKit
import VideoboyCore

enum NowPlayingSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/now-playing")
        NowPlayingWatcher.disabledForChecks = true
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-np-qa-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let controller = MainWindowController(preferences: PreferenceStore(fileURL: scratch.appendingPathComponent("p.json")))
        guard let shell = controller.shellController, let metal = MetalContext.shared,
              let readback = OffscreenRenderer(context: metal) else { return check.finish(blockedReason: "no window or Metal") }
        controller.showWindow(nil)
        let engine = controller.engine
        shell.shell.grid.panels.sourceBodies["A"]?.onReferenceDropped?("generator:\(GeneratorKind.nowPlaying.rawValue)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let slot = Engine.generatorSlot(forChannel: "A")
        let node = engine.generators["A"]
        check.record(AssertionResult(
            name: "Now Playing is a generator a channel can show, with its own controls",
            passed: engine.channelSourceKinds["A"] == .generator && node?.generator == .nowPlaying
                && engine.registry.value(slot: slot, code: .nowPlayingTemplate) != nil,
            detail: "A is \(String(describing: engine.channelSourceKinds["A"])), kind \(node?.generator.displayName ?? "-")"))

        let art = ImageBuffer(width: 128, height: 128, r: 190, g: 60, b: 150)
        NowPlayingHub.shared.publish(
            NowPlayingTrack(title: "Blue Monday", artist: "New Order", album: "Power, Corruption & Lies",
                            progress: 0.37, artwork: art),
            status: "Music", at: CACurrentMediaTime())

        var drawn = 0
        for (index, template) in NowPlayingTemplate.allCases.enumerated() {
            engine.registry.setValue(template.normalisedPosition, slot: slot, code: .nowPlayingTemplate)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            guard let texture = engine.texture(for: slot), let image = readback.readback(texture) else { continue }
            try? image.writePNG(to: RepoPaths.selfQAOutput
                .appendingPathComponent("perf/now-playing/\(index)-\(template.rawValue).png"))
            if FrameAssertions.signalPresent(image, varianceThreshold: 2.0) { drawn += 1 }
        }
        check.record(AssertionResult(
            name: "every look draws the track (Lower Third, Ticker, Card)",
            passed: drawn == NowPlayingTemplate.allCases.count,
            detail: "\(drawn) of \(NowPlayingTemplate.allCases.count) looks drew a picture"))

        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

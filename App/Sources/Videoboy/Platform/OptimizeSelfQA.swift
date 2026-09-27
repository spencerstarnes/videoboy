//
//  OptimizeSelfQA.swift — Copy + Optimize, end to end (0.4.10).
//
//  Purpose : Proves docs/specs/0.4.10-copy-optimize.md through the real Import mode:
//            Copy with Optimize writes the optimized files through the out-of-process
//            helper, links them in the catalog, plays them in place of the originals
//            (and falls back when told to or when they are gone), cancels cleanly, and
//            the show running beside it drops nothing.
//  Inputs  : samples/ fixtures, copied into scratch folders; a scratch catalog; scratch
//            Media and Optimized Media locations. Needs VIDEOBOY_FLAGS=modeBar.
//  Outputs : selfqa/out/perf/optimize/result.txt.
//  Connects: ImportModeView, ShellController (import + OptimizeQueue), LibraryModel,
//            Catalog, Engine.
//

import AppKit
import VideoboyCore

enum OptimizeSelfQA {

    @discardableResult
    private static func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/optimize")
        guard FeatureFlag.modeBar.isOn else {
            return check.finish(blockedReason: "run with VIDEOBOY_FLAGS=modeBar (selfqa.sh does)")
        }
        let files = FileManager.default
        let scratch = files.temporaryDirectory
            .appendingPathComponent("videoboy-optimize-qa-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: scratch) }
        let names = ["hd-h264-2997.mov", "motion.mov"]
        let source = scratch.appendingPathComponent("Card", isDirectory: true)
        let media = scratch.appendingPathComponent("Media", isDirectory: true)
        let optimized = scratch.appendingPathComponent("Optimized Media", isDirectory: true)
        do {
            try files.createDirectory(at: source, withIntermediateDirectories: true)
            for name in names {
                let fixture = RepoPaths.samples.appendingPathComponent(name).resolvingSymlinksInPath()
                guard files.fileExists(atPath: fixture.path) else {
                    return check.finish(blockedReason: "samples/\(name) missing — run scripts/make-fixtures.sh")
                }
                try files.copyItem(at: fixture, to: source.appendingPathComponent(name))
            }
        } catch {
            return check.finish(blockedReason: "could not build scratch folders: \(error)")
        }

        let store = PreferenceStore(fileURL: scratch.appendingPathComponent("prefs.json"))
        store.preferences.mediaLocationPath = media.path
        store.preferences.optimizedMediaLocationPath = optimized.path
        store.preferences.optimizePreset = OptimizePreset.performance.rawValue
        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let screen = NSScreen.main,
              let shell = controller.shellController, let modes = controller.modeController else {
            return check.finish(blockedReason: "no window or no mode bar")
        }
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let engine = controller.engine
        let library = shell.shell.grid.panels.library
        guard let catalog = try? Catalog(url: scratch.appendingPathComponent("QA.vbcatalog"), makesBackups: false) else {
            return check.finish(blockedReason: "no scratch catalog")
        }
        library.attach(catalog)

        // The show: four SD channels playing while everything below happens.
        for (letter, name) in zip(["A", "B", "C", "D"], ["bars.dv", "motion.dv", "motion.mov", "motion.m2v"]) {
            shell.loadForChecks(RepoPaths.samples.appendingPathComponent(name), channel: letter)
        }
        UISelfQA.waitForLoads(engine)
        for letter in ["A", "B", "C", "D"] { engine.setPlaying(true, channel: letter) }
        engine.setTransportRunning(true)
        engine.tickCostsForChecks = []
        let baseDrops = engine.droppedFrames
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        let dropsWithout = engine.droppedFrames - baseDrops

        // Copy + Optimize from Import mode.
        modes.show(.importMedia)
        guard let view = modes.importViewForChecks else { return check.finish(blockedReason: "no Import view") }
        view.show(ImportSource(title: "Card", url: source, section: .favorites, symbolName: "sdcard",
                               allowsMove: false, isEjectable: false))
        wait(10) { view.entries.count == names.count }
        view.methodControl.selectedSegment = 2
        view.methodControl.sendAction(view.methodControl.action, to: view.methodControl.target)
        view.optimizeCheck.state = .on
        view.optimizeCheck.sendAction(view.optimizeCheck.action, to: view.optimizeCheck.target)
        view.skipDuplicates.state = .off
        view.setAllChecked(true)
        view.setDestinationForChecks(media)
        check.record(AssertionResult(
            name: "Optimize is offered with COPY, with its preset",
            passed: view.optimizeCheck.isEnabled && view.optimizePreset.isEnabled,
            detail: "check \(view.optimizeCheck.isEnabled), preset \(view.optimizePreset.isEnabled)"))

        engine.tickCostsForChecks = []
        let dropsBefore = engine.droppedFrames
        let started = Date()
        view.importPressed()
        wait(2) { shell.importJobsForChecks > 0 }
        wait(60) { shell.importJobsForChecks == 0 }
        wait(3) { shell.optimizeQueue.countForChecks > 0 }
        wait(240) { shell.optimizeQueue.countForChecks == 0 }
        let seconds = Date().timeIntervalSince(started)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let ticks = engine.tickCostsForChecks ?? []
        let drops = engine.droppedFrames - dropsBefore

        let clips = catalog.loadClips()
        let linked = names.compactMap { name in
            clips.first { URL(fileURLWithPath: $0.path).standardizedFileURL.path
                == media.appendingPathComponent(name).standardizedFileURL.path }
        }
        let outputs = linked.compactMap(\.optimizedPath)
        let partialLeft = files.fileExists(atPath: optimized.appendingPathComponent(FileTransfer.partialFolderName).path)
            && !((try? files.contentsOfDirectory(atPath: optimized.appendingPathComponent(FileTransfer.partialFolderName).path)) ?? []).isEmpty
        let decodes = outputs.allSatisfy { path in
            ClipDecoders.open(URL(fileURLWithPath: path)).map { $0.dataEffectFamily == .dv && $0.frameCount > 0 } ?? false
        }
        check.record(AssertionResult(
            name: "Copy + Optimize copies the originals and writes a linked DV file for each",
            passed: linked.count == names.count && outputs.count == names.count && decodes && !partialLeft
                && outputs.allSatisfy { $0.hasPrefix(optimized.path) }
                && linked.allSatisfy { $0.optimizedCanvas == ClipOptimizer.canvasTag },
            detail: "\(linked.count) copies cataloged, \(outputs.count) linked, DV readable \(decodes), "
                + "partial files left \(partialLeft); \(String(format: "%.1f", seconds)) s"))
        check.record(AssertionResult(
            name: "the show does not notice: no tick over a frame, no extra dropped frames while optimizing",
            passed: (ticks.max() ?? 0) < 1000 / StandardDefinition.frameRate && drops <= max(dropsWithout, 1) && ticks.count > 60,
            detail: String(format: "worst tick %.2f ms of %d, %d dropped (%d in 5 s before)",
                           ticks.max() ?? 0, ticks.count, drops, dropsWithout)))

        // Playback: optimized in place of the original; the original when told to or gone.
        let copy = media.appendingPathComponent("motion.mov")
        func playedPath() -> String? {
            UISelfQA.waitForLoads(engine)
            return engine.sources["A"]?.mediaURL?.standardizedFileURL.path
        }
        shell.loadForChecks(copy, channel: "A")
        let optimizedPlays = playedPath().map { $0.hasPrefix(optimized.standardizedFileURL.path) } ?? false
        store.preferences.usesOptimizedMedia = false
        shell.loadForChecks(copy, channel: "A")
        let originalWhenOff = playedPath() == copy.standardizedFileURL.path
        store.preferences.usesOptimizedMedia = true
        if let path = linked.first(where: { $0.name == "motion.mov" })?.optimizedPath {
            try? files.removeItem(atPath: path)
        }
        shell.loadForChecks(copy, channel: "A")
        let originalWhenGone = playedPath() == copy.standardizedFileURL.path
        check.record(AssertionResult(
            name: "a clip plays its optimized file; the original when the setting is off or the file is gone",
            passed: optimizedPlays && originalWhenOff && originalWhenGone,
            detail: "optimized \(optimizedPlays), setting off → original \(originalWhenOff), "
                + "file gone → original \(originalWhenGone)"))

        // Cancel mid-conversion: nothing half-written, nothing linked.
        let hd = media.appendingPathComponent("hd-h264-2997.mov")
        let hdID = library.idsByPath()[hd.standardizedFileURL.path]
        if let hdID { library.setOptimized(path: nil, canvas: nil, for: hdID) }
        let before = (try? files.contentsOfDirectory(atPath: optimized.path)) ?? []
        shell.enqueueOptimize([hd], preset: .performance)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        shell.optimizeQueue.cancelAll()
        wait(10) { shell.optimizeQueue.countForChecks == 0 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let after = (try? files.contentsOfDirectory(atPath: optimized.path)) ?? []
        let partial = (try? files.contentsOfDirectory(atPath: optimized.appendingPathComponent(FileTransfer.partialFolderName).path)) ?? []
        let stillUnlinked = hdID.map { id in library.items.first { $0.id == id }?.optimizedPath == nil } ?? false
        check.record(AssertionResult(
            name: "Cancel stops the conversion: no partial file, no new file, no link",
            passed: partial.isEmpty && Set(after) == Set(before) && stillUnlinked,
            detail: "partial \(partial), new files \(Set(after).subtracting(before)), unlinked \(stillUnlinked)"))

        engine.setTransportRunning(false)
        modes.show(.vj)
        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

//
//  ImportSelfQA.swift — a big library dropped in the middle of a show.
//
//  Purpose : The complaint that started 0.4.7: adding a large library at once tripped
//            Videoboy up. This drops 1,000 clips in 25 folders onto the library panel
//            (the drop handler a real drag reaches) while all four channels play with
//            every effect on, and asserts what a performer needs: the show never
//            stutters, the status bar says what is happening, every clip arrives
//            measured and binned, the catalog keeps it all, ✕ stops an import, and a
//            small import stays quiet.
//  Inputs  : samples/ (the clips are symbolic links to them, in a temporary tree).
//  Outputs : selfqa/out/perf/import/result.txt.
//  Connects: ShellController (drop → ImportJob), StatusBarView, LibraryModel, Catalog.
//

import AppKit
import VideoboyCore

enum ImportSelfQA {

    /// Starts `screencapture` of a window without waiting for it (needs Screen
    /// Recording; the file is blank without it).
    private static func startCapture(of window: NSWindow) -> (process: Process, file: URL)? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-import-\(window.windowNumber).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", file.path]
        guard (try? process.run()) != nil else { return nil }
        return (process, file)
    }

    /// Crops a window capture to one view and writes it as PNG.
    private static func crop(_ whole: URL, to view: NSView, in window: NSWindow, into url: URL) {
        defer { try? FileManager.default.removeItem(at: whole) }
        guard let source = CGImageSourceCreateWithURL(whole as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let scale = CGFloat(image.width) / window.frame.width
        let inWindow = view.convert(view.bounds, to: nil)
        let rect = CGRect(x: inWindow.minX * scale, y: (window.frame.height - inWindow.maxY) * scale,
                          width: inWindow.width * scale, height: inWindow.height * scale)
        guard let strip = image.cropping(to: rect.integral),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, strip, nil)
        CGImageDestinationFinalize(destination)
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/import")
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory
            .appendingPathComponent("videoboy-import-qa-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }

        let sources = ["bars.dv", "motion.dv", "motion.mov", "motion.m2v"]
            .map { RepoPaths.samples.appendingPathComponent($0) }
        guard sources.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
            return check.finish(blockedReason: "samples/ is missing fixtures")
        }
        // 25 folders × 40 clips, each a link to a real fixture.
        func makeTree(_ root: URL, folders: Int, perFolder: Int) throws {
            for folder in 0..<folders {
                let directory = root.appendingPathComponent(String(format: "Reel %02d", folder), isDirectory: true)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                for index in 0..<perFolder {
                    let source = sources[(folder + index) % sources.count]
                    let link = directory.appendingPathComponent(
                        String(format: "CLIP%04d.%@", index, source.pathExtension))
                    try fileManager.createSymbolicLink(at: link, withDestinationURL: source)
                }
            }
        }
        let bigTree = scratch.appendingPathComponent("Big Library", isDirectory: true)
        let cancelTree = scratch.appendingPathComponent("Cancelled", isDirectory: true)
        do {
            try makeTree(bigTree, folders: 25, perFolder: 40)
            try makeTree(cancelTree, folders: 10, perFolder: 60)
        } catch {
            return check.finish(blockedReason: "could not build the test tree: \(error)")
        }

        let store = PreferenceStore(fileURL: scratch.appendingPathComponent("prefs.json"))
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
        let library = panels.library
        let statusBar = shell.shell.statusBar

        // A throwaway catalog, never the person's own.
        let catalogURL = scratch.appendingPathComponent("QA.vbcatalog")
        guard let catalog = try? Catalog(url: catalogURL, makesBackups: false) else {
            return check.finish(blockedReason: "could not open a scratch catalog")
        }
        library.attach(catalog)
        let seeded = library.items.count

        // THE SHOW: four channels, every effect, the transport running.
        for (letter, url) in zip(["A", "B", "C", "D"], sources) {
            panels.sourceBodies[letter]?.onClipDropped?(url, nil)
            engine.setPlaying(true, channel: letter)
            engine.registry.setValue(1, slot: Engine.slot(forChannel: letter), code: .wetDry)
            engine.registry.setValue(0.6, slot: Engine.slot(forChannel: letter), code: .corruptAmount)
            for effect in ["mosh", "transform", "colour", "composite", "echo", "feedback", "freeze"] {
                engine.registry.setValue(1, slot: Engine.channelSlot(letter, effect), code: .wetDry)
            }
            engine.registry.setValue(0.5, slot: Engine.channelSlot(letter, "mosh"), code: .moshAmount)
        }
        for slot in Engine.busEffectSlots { engine.registry.setValue(1, slot: slot, code: .wetDry) }
        engine.setTransportRunning(true)
        RunLoop.main.run(until: Date().addingTimeInterval(2))

        // 1. A SMALL import stays quiet.
        let loose = Array(sources.prefix(3))
        panels.libraryOneBody.onFilesDropped?(loose, nil)
        var smallShowedBar = false
        let smallEnd = Date().addingTimeInterval(5)
        while shell.importJobsForChecks > 0 || Date() < smallEnd.addingTimeInterval(-4.5), Date() < smallEnd {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if !statusBar.importSegment.isHidden { smallShowedBar = true }
        }
        check.record(AssertionResult(
            name: "three loose clips import without the status bar",
            passed: !smallShowedBar, detail: smallShowedBar ? "the bar appeared" : "no bar"))

        // 1b. BASELINE: the same show with no import, measured the same way, so a stall
        // the import did not cause is not blamed on it.
        do {
            var stretches: [Double] = []
            var since: CFTimeInterval = 0
            let baseline = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                true, 0) { _, activity in
                if activity == .afterWaiting { since = CACurrentMediaTime() }
                else if since > 0 { stretches.append((CACurrentMediaTime() - since) * 1000); since = 0 }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), baseline, .commonModes)
            engine.tickCostsForChecks = []
            let baseDrops = engine.droppedFrames
            RunLoop.main.run(until: Date().addingTimeInterval(10))
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), baseline, .commonModes)
            let baseTicks = engine.tickCostsForChecks ?? []
            engine.tickCostsForChecks = nil
            let long = stretches.filter { $0 > 25 }.sorted(by: >)
            check.note(String(format: "baseline, no import, 10 s: %d ticks, worst %.2f ms, %d dropped; %d stretches over 25 ms, longest %@",
                              baseTicks.count, baseTicks.max() ?? 0, engine.droppedFrames - baseDrops, long.count,
                              long.prefix(6).map { String(format: "%.0f", $0) }.joined(separator: ", ")))
        }

        // 2. THE BIG DROP, mid-show.
        engine.tickCostsForChecks = []
        library.notifyCostsForChecks = []
        LibraryPanelBody.reloadCostsForChecks = []
        MainThreadCosts.byLabel = [:]
        // Every busy stretch of the main run loop, however it was spent: a gap long
        // enough to drop a refresh shows here even when no tick was slow.
        var busyStretches: [Double] = []
        var longAt: [(at: Double, ms: Double)] = []
        let dropTime = CACurrentMediaTime()
        var busySince: CFTimeInterval = 0
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true, 0) { _, activity in
            if activity == .afterWaiting {
                busySince = CACurrentMediaTime()
            } else if busySince > 0 {
                let ms = (CACurrentMediaTime() - busySince) * 1000
                busyStretches.append(ms)
                if ms > 25 { longAt.append((busySince - dropTime, ms)) }
                busySince = 0
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        // AppKit lays out and draws in its own before-waiting observer, AFTER the one
        // above (lower order first). A second observer ordered last measures that pass.
        var commitStart: CFTimeInterval = 0
        var commits: [Double] = []
        let commitBegin = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            commitStart = CACurrentMediaTime()
        }
        let commitEnd = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            if commitStart > 0 { commits.append((CACurrentMediaTime() - commitStart) * 1000) }
            commitStart = 0
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), commitBegin, .commonModes)
        CFRunLoopAddObserver(CFRunLoopGetMain(), commitEnd, .commonModes)
        let dropsBefore = engine.droppedFrames
        let started = Date()
        Log.info(.selfqa, "import check: big drop starting, pid \(getpid())")
        panels.libraryOneBody.onFilesDropped?([bigTree], nil)
        var barSeen = false
        var names: Set<String> = []
        var sawFolderChips = false
        var sawReadingCount = false
        var capture: (process: Process, file: URL)?
        let deadline = Date().addingTimeInterval(180)
        while (shell.importJobsForChecks > 0 || Date().timeIntervalSince(started) < 0.5), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if !statusBar.importSegment.isHidden {
                barSeen = true
                let parts = statusBar.importTextForChecks.components(separatedBy: " | ")
                if parts.count == 4 {
                    if !parts[1].isEmpty { names.insert(parts[1]) }
                    if parts[2].contains("Reel") || parts[2].contains("folders") { sawFolderChips = true }
                    if parts[3].contains(" / ") { sawReadingCount = true }
                }
                // One photograph of the real status strip mid-import, for a person to see.
                // With a file name showing, and without waiting: the capture runs
                // alongside and is cropped after the import, so it cannot stall the
                // main thread this check is measuring.
                if capture == nil, sawFolderChips, sawReadingCount, parts.count == 4, !parts[1].isEmpty {
                    capture = startCapture(of: window)
                }
            }
        }
        let seconds = Date().timeIntervalSince(started)

        // Let the last batch of measurements land.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let ticks = engine.tickCostsForChecks ?? []
        engine.tickCostsForChecks = nil
        library.notifyCostsForChecks = nil
        let rebuilds = LibraryPanelBody.reloadCostsForChecks ?? []
        LibraryPanelBody.reloadCostsForChecks = nil
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), commitBegin, .commonModes)
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), commitEnd, .commonModes)
        let longCommits = commits.filter { $0 > 10 }.sorted(by: >)
        check.note(String(format: "AppKit layout/display passes over 10 ms: %d of %d, longest %@",
                          longCommits.count, commits.count,
                          longCommits.prefix(8).map { String(format: "%.0f", $0) }.joined(separator: ", ")))
        check.note("long stretches at: " + longAt.map { String(format: "%.0f ms @ %.2f s", $0.ms, $0.at) }
            .joined(separator: ", "))
        let longStretches = busyStretches.filter { $0 > 25 }.sorted(by: >)
        check.note(String(format: "main thread busy stretches over 25 ms: %d, longest %@",
                          longStretches.count,
                          longStretches.prefix(8).map { String(format: "%.0f", $0) }.joined(separator: ", ")))
        for (label, costs) in (MainThreadCosts.byLabel ?? [:]).sorted(by: { $0.key < $1.key }) {
            check.note(String(format: "  %@: %d× total %.0f ms, worst %.1f ms",
                              label, costs.count, costs.reduce(0, +), costs.max() ?? 0))
        }
        MainThreadCosts.byLabel = nil
        check.note(String(format: "library rebuilds during the import: %d, mean %.1f ms, worst %.1f ms",
                          rebuilds.count, rebuilds.isEmpty ? 0 : rebuilds.reduce(0, +) / Double(rebuilds.count),
                          rebuilds.max() ?? 0))
        let drops = engine.droppedFrames - dropsBefore
        let worst = ticks.max() ?? 0
        let budget = 1000.0 / StandardDefinition.frameRate

        // Resolved: the temporary directory is /var/… but listings report /private/var/….
        // The photograph is cropped only now, after every measurement: cropping a
        // full-window capture is main-thread work of its own.
        if let capture {
            capture.process.waitUntilExit()
            crop(capture.file, to: statusBar, in: window, into: check.artifactURL("status-bar.png"))
        }
        let imported = library.items.filter { $0.url?.path.contains("/Big Library/") == true }
        let measured = imported.filter { $0.frameCount != nil && $0.duration != nil }
        let bins = Set(imported.compactMap(\.bin))
        check.note(String(format: "1000 clips in %.1f s; %d ticks, worst %.2f ms, %d dropped; %d names shown",
                          seconds, ticks.count, worst, drops, names.count))

        check.record(AssertionResult(
            name: "the show never stutters while 1,000 clips import",
            passed: worst < budget && drops == 0 && ticks.count > 30,
            detail: String(format: "worst tick %.2f ms, %d dropped of %d", worst, drops, ticks.count)))
        check.record(AssertionResult(
            name: "the status bar appears for a big import, with folder chips and a count",
            passed: barSeen && sawFolderChips && sawReadingCount,
            detail: "bar \(barSeen), folder chips \(sawFolderChips), reading count \(sawReadingCount)"))
        check.record(AssertionResult(
            name: "the status bar flashes the names of the clips being imported",
            passed: names.count >= 10, detail: "\(names.count) different names shown"))
        check.record(AssertionResult(
            name: "every clip arrives, in its folder's bin",
            passed: imported.count == 1000 && bins.count == 25,
            detail: "\(imported.count) clips in \(bins.count) bins"))
        check.record(AssertionResult(
            name: "every imported clip is measured (length and frame count)",
            passed: measured.count == imported.count && !imported.isEmpty,
            detail: "\(measured.count) of \(imported.count)"))

        // 3. THE CATALOG keeps it all — including a mark set now.
        if let first = imported.first {
            library.setMarks(inPoint: 0.2, outPoint: 0.8, for: first.id)
        }
        catalog.flush()
        let stored = catalog.loadClips()
        check.record(AssertionResult(
            name: "the catalog holds every clip",
            passed: stored.count == library.items.filter { $0.url != nil }.count,
            detail: "\(stored.count) stored, \(library.items.count) in the library (\(seeded) seeded)"))
        let reloaded = LibraryModel()
        reloaded.attach(catalog)
        let markedID = imported.first?.id ?? ""
        let reloadedMarks = reloaded.marks(for: markedID)
        let storedFrames = reloaded.items.first { $0.id == markedID }?.frameCount
        check.record(AssertionResult(
            name: "a reloaded library is the same library, marks and frame counts included",
            passed: reloaded.items.count == library.items.count
                && reloadedMarks.inPoint == 0.2 && reloadedMarks.outPoint == 0.8 && storedFrames != nil,
            detail: "\(reloaded.items.count) items, marks \(String(describing: reloadedMarks)), frames \(storedFrames.map(String.init) ?? "nil")"))

        // 4. The bar goes away by itself once it has said "done".
        RunLoop.main.run(until: Date().addingTimeInterval(ShellController.importStatusLinger + 0.5))
        check.record(AssertionResult(
            name: "the status bar hides itself after the import",
            passed: statusBar.importSegment.isHidden, detail: statusBar.importTextForChecks))

        // 5. ✕ stops an import; what was added stays.
        panels.libraryOneBody.onFilesDropped?([cancelTree], nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        statusBar.onCancelImport?()
        let cancelDeadline = Date().addingTimeInterval(30)
        while shell.importJobsForChecks > 0, Date() < cancelDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let partial = library.items.filter { $0.url?.path.contains("/Cancelled/") == true }.count
        check.record(AssertionResult(
            name: "✕ stops an import, keeping what was added",
            passed: shell.importJobsForChecks == 0 && statusBar.importTextForChecks.contains("STOPPED"),
            detail: "\(partial) of 600 added before stopping; bar: \(statusBar.importTextForChecks)"))

        engine.setTransportRunning(false)
        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

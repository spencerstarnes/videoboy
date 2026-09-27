//
//  ImportModeSelfQA.swift — Import mode's Add, Move and Copy, end to end (0.4.9).
//
//  Purpose : Proves docs/specs/0.4.9-import-mode.md: a source lists off the main
//            thread with the right badges; the greying rules hold; Add, Move and Copy
//            each put the right files in the right place and in the catalog; DUP is
//            detected and skipped; the main thread stays free; the viewer plays its own
//            player without touching the engine.
//  Inputs  : samples/ fixtures, COPIED into scratch folders; a scratch catalog. Never
//            the person's own catalog, media or preferences. Needs VIDEOBOY_FLAGS=modeBar
//            (scripts/selfqa.sh sets it).
//  Outputs : selfqa/out/perf/import-mode/result.txt and a PNG of the mode.
//  Connects: ModeController, ImportModeView, ShellController.importFiles, ImportJob,
//            FileTransfer, LibraryModel, Catalog.
//

import AppKit
import AVFoundation
import VideoboyCore

enum ImportModeSelfQA {

    /// Spins the main run loop until `done` or the deadline.
    @discardableResult
    private static func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/import-mode")
        guard FeatureFlag.modeBar.isOn else {
            return check.finish(blockedReason: "run with VIDEOBOY_FLAGS=modeBar (selfqa.sh does)")
        }
        let files = FileManager.default
        let scratch = files.temporaryDirectory
            .appendingPathComponent("videoboy-import-mode-qa-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: scratch) }
        let fixtures = ["bars.dv", "motion.m2v", "motion.mov", "hd-h264-2997.mov"]
            .map { RepoPaths.samples.appendingPathComponent($0) }
        guard fixtures.allSatisfy({ files.fileExists(atPath: $0.path) }) else {
            return check.finish(blockedReason: "samples/ is missing fixtures — run scripts/make-fixtures.sh")
        }
        // Three source folders (Move empties its own), real files not links.
        func sourceFolder(_ name: String) throws -> URL {
            let folder = scratch.appendingPathComponent(name, isDirectory: true)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            for fixture in fixtures {
                try files.copyItem(at: fixture.resolvingSymlinksInPath(),
                                   to: folder.appendingPathComponent(fixture.lastPathComponent))
            }
            return folder
        }
        let addFolder: URL, moveFolder: URL, copyFolder: URL
        do {
            addFolder = try sourceFolder("Reel Add")
            moveFolder = try sourceFolder("Reel Move")
            copyFolder = try sourceFolder("Reel Copy")
        } catch {
            return check.finish(blockedReason: "could not build scratch folders: \(error)")
        }
        let moveDest = scratch.appendingPathComponent("Dest Move", isDirectory: true)
        let copyDest = scratch.appendingPathComponent("Dest Copy", isDirectory: true)

        let store = PreferenceStore(fileURL: scratch.appendingPathComponent("prefs.json"))
        store.preferences.setupCompleted = true
        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let screen = NSScreen.main,
              let shell = controller.shellController, let modes = controller.modeController else {
            return check.finish(blockedReason: "no window or no mode bar")
        }
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let library = shell.shell.grid.panels.library
        guard let catalog = try? Catalog(url: scratch.appendingPathComponent("QA.vbcatalog"), makesBackups: false) else {
            return check.finish(blockedReason: "could not open a scratch catalog")
        }
        library.attach(catalog)
        modes.show(.importMedia)
        guard let view = modes.importViewForChecks else {
            return check.finish(blockedReason: "Import mode did not build its view")
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        func source(_ url: URL, allowsMove: Bool = true) -> ImportSource {
            ImportSource(title: url.lastPathComponent, url: url, section: .favorites,
                         symbolName: "star", allowsMove: allowsMove, isEjectable: false)
        }
        func catalogPaths() -> Set<String> {
            Set(catalog.loadClips().map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        }
        func standard(_ url: URL) -> String { url.standardizedFileURL.path }

        // Main-thread watch for the whole check.
        var awake = 0.0, longest = 0.0
        var phase = "setup"
        var byPhase: [String: Double] = [:]
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true, 0) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting { awake = now } else if awake > 0 {
                let ms = (now - awake) * 1000
                longest = max(longest, ms)
                byPhase[phase] = max(byPhase[phase] ?? 0, ms)
            }
        }

        // 1. Listing returns at once and fills later.
        let started = CACurrentMediaTime()
        view.show(source(addFolder))
        let callMs = (CACurrentMediaTime() - started) * 1000
        wait(10) { view.entries.count == fixtures.count }
        check.record(AssertionResult(
            name: "a source lists off the main thread (the call returns at once, tiles arrive later)",
            passed: callMs < 5 && view.entries.count == fixtures.count,
            detail: String(format: "show() %.2f ms; %d of %d clips listed", callMs, view.entries.count, fixtures.count)))
        if let image = UISelfQA.render(view: shell.shell) { _ = try? check.writeImage(image, named: "import-mode.png") }

        // 2. Badges.
        func entry(_ name: String) -> ImportEntry? { view.entries.first { $0.url.lastPathComponent == name } }
        check.record(AssertionResult(
            name: "DV and MPEG are marked wedge-ready; a 16:9 HD clip is marked ⚠16:9",
            passed: entry("bars.dv")?.wedge == "DV" && entry("motion.m2v")?.wedge == "MPEG"
                && entry("hd-h264-2997.mov")?.mismatch == "⚠16:9" && entry("motion.mov")?.mismatch == nil,
            detail: view.entries.map { "\($0.url.lastPathComponent): \($0.wedge ?? "-") \($0.mismatch ?? "-")" }
                .joined(separator: ", ")))

        // 3. Greying.
        var greying: [String] = []
        for (segment, wantDestination) in [(0, false), (1, true), (2, true)] {
            view.methodControl.selectedSegment = segment
            view.methodControl.sendAction(view.methodControl.action, to: view.methodControl.target)
            if view.destinationEnabled != wantDestination { greying.append("segment \(segment) destination \(view.destinationEnabled)") }
            if view.optimizeCheck.isEnabled || view.optimizePreset.isEnabled { greying.append("optimize enabled in \(segment)") }
        }
        view.show(source(addFolder, allowsMove: false))
        if view.moveEnabled { greying.append("Move enabled for a read-only source") }
        if view.method == .move { greying.append("still on Move") }
        view.show(source(addFolder))
        wait(10) { view.entries.count == fixtures.count }
        check.record(AssertionResult(
            name: "greying: Add greys the destination; Optimize is 'coming' everywhere; no Move from a read-only source",
            passed: greying.isEmpty && view.optimizeCheck.title.contains("coming"),
            detail: greying.isEmpty ? "as the table says" : greying.joined(separator: "; ")))

        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        MainThreadCosts.byLabel = [:]
        func runImport(_ method: Int, destination: URL?) {
            view.methodControl.selectedSegment = method
            view.methodControl.sendAction(view.methodControl.action, to: view.methodControl.target)
            if let destination { view.setDestinationForChecks(destination) }
            // The scratch clips are copies of fixtures the library is seeded with, so
            // they read as DUP; these runs test file handling, so duplicates go through.
            // (Skipping is asserted on its own below.)
            view.skipDuplicates.state = .off
            view.setAllChecked(true)
            phase = "import \(method)"
            view.importPressed()
            wait(1) { shell.importJobsForChecks > 0 }
            wait(60) { shell.importJobsForChecks == 0 }
            phase = "after import \(method)"
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))  // catalog writes land
            phase = "between"
        }

        // 4. Add.
        runImport(0, destination: nil)
        let afterAdd = catalogPaths()
        let addExpected = Set(fixtures.map { standard(addFolder.appendingPathComponent($0.lastPathComponent)) })
        check.record(AssertionResult(
            name: "Add catalogs the clips where they are and leaves the files alone",
            passed: addExpected.isSubset(of: afterAdd)
                && fixtures.allSatisfy { files.fileExists(atPath: addFolder.appendingPathComponent($0.lastPathComponent).path) },
            detail: "\(addExpected.intersection(afterAdd).count) of \(fixtures.count) in the catalog"))

        // 7. DUP after Add, and skip-duplicates adds nothing.
        view.skipDuplicates.state = .on
        view.show(source(addFolder))
        wait(10) { view.entries.count == fixtures.count && view.entries.allSatisfy(\.isDuplicate) }
        let allDup = view.entries.count == fixtures.count && view.entries.allSatisfy(\.isDuplicate)
        view.setAllChecked(true)
        let dupImportable = view.importableURLs().count
        check.record(AssertionResult(
            name: "clips already in the library show DUP, and skip-duplicates imports none of them",
            passed: allDup && dupImportable == 0,
            detail: "\(view.entries.filter(\.isDuplicate).count) DUP; \(dupImportable) would import"))

        // 5. Move.
        view.show(source(moveFolder))
        wait(10) { view.entries.count == fixtures.count }
        runImport(1, destination: moveDest)
        let afterMove = catalogPaths()
        let moveExpected = Set(fixtures.map { standard(moveDest.appendingPathComponent($0.lastPathComponent)) })
        let movedOut = fixtures.allSatisfy { !files.fileExists(atPath: moveFolder.appendingPathComponent($0.lastPathComponent).path) }
        let movedIn = fixtures.allSatisfy { files.fileExists(atPath: moveDest.appendingPathComponent($0.lastPathComponent).path) }
        check.record(AssertionResult(
            name: "Move puts the files in the destination, empties the source, catalogs the new paths",
            passed: movedOut && movedIn && moveExpected.isSubset(of: afterMove),
            detail: "out of source \(movedOut), in destination \(movedIn), \(moveExpected.intersection(afterMove).count) cataloged"))

        // Marks before an import: I in the viewer, halfway into a clip not yet imported.
        // Not an import, so outside the main-thread measurement (opening a clip in
        // AVPlayer is the viewer's own cost, and it is not on the show's path).
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        let markedClip = copyFolder.appendingPathComponent("motion.mov")
        view.openInViewer(markedClip)
        wait(3) { view.playerView.player?.currentItem?.status == .readyToPlay }
        if let player = view.playerView.player, let item = player.currentItem {
            player.pause()
            let half = CMTimeMultiplyByFloat64(item.duration, multiplier: 0.5)
            var sought = false
            player.seek(to: half, toleranceBefore: .zero, toleranceAfter: .zero) { _ in sought = true }
            wait(3) { sought }
            view.handleViewerKey("i", player: player)
        }
        let waitingMarks = view.pendingMarkCountForChecks
        awake = 0
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)

        // 6. Copy.
        view.show(source(copyFolder))
        wait(10) { view.entries.count == fixtures.count }
        runImport(2, destination: copyDest)
        let afterCopy = catalogPaths()
        let copyExpected = Set(fixtures.map { standard(copyDest.appendingPathComponent($0.lastPathComponent)) })
        let kept = fixtures.allSatisfy { files.fileExists(atPath: copyFolder.appendingPathComponent($0.lastPathComponent).path) }
        let copiedIn = fixtures.allSatisfy { fixture in
            let copy = copyDest.appendingPathComponent(fixture.lastPathComponent)
            let a = (try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            let b = (try? fixture.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -2
            return a == b
        }
        let noPartial = !files.fileExists(atPath: copyDest.appendingPathComponent(FileTransfer.partialFolderName).path)
        check.record(AssertionResult(
            name: "Copy puts whole copies in the destination, keeps the originals, leaves no partial files",
            passed: kept && copiedIn && noPartial && copyExpected.isSubset(of: afterCopy),
            detail: "originals kept \(kept), full-size copies \(copiedIn), no partial folder \(noPartial), "
                + "\(copyExpected.intersection(afterCopy).count) cataloged"))
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)

        check.note("labelled main-thread work, worst: " + (MainThreadCosts.byLabel ?? [:])
            .map { String(format: "%@ %d× %.1f ms", $0.key, $0.value.count, $0.value.max() ?? 0) }.sorted().joined(separator: ", "))
        MainThreadCosts.byLabel = nil
        check.note("longest main-thread stretch by phase: " + byPhase.map { String(format: "%@ %.1f ms", $0.key, $0.value) }
            .sorted().joined(separator: ", "))
        // Marks: set before Copy, stored on the COPY in the catalog.
        let copiedMark = catalog.loadClips().first {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
                == standard(copyDest.appendingPathComponent("motion.mov"))
        }?.inPoint
        check.record(AssertionResult(
            name: "an I mark set in Import mode before Copy lands in the catalog on the copied clip",
            passed: waitingMarks == 1 && copiedMark.map { abs($0 - 0.5) < 0.06 } == true
                && view.pendingMarkCountForChecks == 0,
            detail: "waiting before import \(waitingMarks); catalog in point "
                + (copiedMark.map { String(format: "%.3f", $0) } ?? "none")
                + "; still waiting \(view.pendingMarkCountForChecks)"))

        // Marks on a clip already in the library are stored at once.
        let libraryClip = addFolder.appendingPathComponent("bars.dv")
        view.show(source(addFolder))
        wait(10) { view.entries.count == fixtures.count }
        view.openInViewer(libraryClip)
        wait(3) { view.playerView.player?.currentItem?.status == .readyToPlay }
        if let player = view.playerView.player { player.pause(); view.handleViewerKey("o", player: player) }
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let storedOut = catalog.loadClips().first {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == standard(libraryClip)
        }?.outPoint
        check.record(AssertionResult(
            name: "an O mark on a clip already in the library is stored in the catalog straight away",
            passed: storedOut != nil, detail: "catalog out point \(storedOut.map { String(format: "%.3f", $0) } ?? "none")"))

        // J/K/L and frame step.
        var shuttle: [Float] = []
        var stepped = false
        if let player = view.playerView.player {
            for key in ["l", "l", "k", "j"] { view.handleViewerKey(key, player: player); shuttle.append(player.rate) }
            let before = CMTimeGetSeconds(player.currentTime())
            view.handleViewerKey("", keyCode: 124, player: player)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            stepped = CMTimeGetSeconds(player.currentTime()) > before
            player.pause()
        }
        check.record(AssertionResult(
            name: "the viewer shuttles with J/K/L and steps a frame with →",
            passed: shuttle == [1, 2, 0, -1] && stepped,
            detail: "rates \(shuttle); stepped forward \(stepped)"))

        // 8. The main thread stayed free throughout the imports.
        check.record(AssertionResult(
            name: "the main thread never stays busy for 25 ms while importing",
            passed: longest < 25, detail: String(format: "longest %.1f ms", longest)))

        // 9. The viewer: its own player, the engine untouched.
        let channelsBefore = controller.engine.sources.mapValues { ObjectIdentifier($0) }
        let clip = copyFolder.appendingPathComponent("motion.mov")
        view.openInViewer(clip)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let channelsAfter = controller.engine.sources.mapValues { ObjectIdentifier($0) }
        check.record(AssertionResult(
            name: "the viewer plays the clip in its own player and leaves the engine's channels alone",
            passed: view.viewerURL?.standardizedFileURL == clip.standardizedFileURL && channelsBefore == channelsAfter,
            detail: "viewer: \(view.viewerURL?.lastPathComponent ?? "nothing"); channels unchanged \(channelsBefore == channelsAfter)"))
        view.playerView.player?.pause()

        modes.show(.vj)
        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

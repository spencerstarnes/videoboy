//
//  BinsSelfQA.swift — `Videoboy --selfqa bins`: a folder tree survives an import.
//
//  Purpose : Owner report 2026-09-28: importing folders of clips "removes the folder
//            hierarchy", and "Include subfolders" did not keep it. Proves the fix end
//            to end in the running app: Import mode's Copy rebuilds the tree on disk
//            and as bins inside bins; a folder dropped on the library keeps its tree,
//            and two folders of the same name no longer merge; the library opens a
//            bin inside a bin, the path bar's real Back button (reached by hit-testing)
//            goes up ONE level; rename and delete carry the bins inside; the column
//            view shows the open bin's own level. Plays nothing: no viewer, no sound.
//  Inputs  : samples/motion.mov and motion.m2v (no audio tracks), copied into a
//            scratch tree; a scratch catalog and preferences. Never the person's own.
//            Needs VIDEOBOY_FLAGS=modeBar (scripts/selfqa.sh sets it).
//  Outputs : selfqa/out/perf/bins/result.txt and a PNG of a nested bin.
//  Connects: ImportModeView, ShellController.importFiles, ImportJob, ImportScan,
//            FileTransfer, BinPath, LibraryModel, LibraryPanelBody, LibraryPathBar,
//            LibraryColumnView, Catalog.
//

import AppKit
import VideoboyCore

enum BinsSelfQA {

    @discardableResult
    private static func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return done()
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/bins")
        guard FeatureFlag.modeBar.isOn else {
            return check.finish(blockedReason: "run with VIDEOBOY_FLAGS=modeBar (selfqa.sh does)")
        }
        let files = FileManager.default
        let scratch = files.temporaryDirectory
            .appendingPathComponent("videoboy-bins-qa-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: scratch) }
        let movie = RepoPaths.samples.appendingPathComponent("motion.mov")
        let mpeg = RepoPaths.samples.appendingPathComponent("motion.m2v")
        guard files.fileExists(atPath: movie.path), files.fileExists(atPath: mpeg.path) else {
            return check.finish(blockedReason: "samples/ is missing motion.mov or motion.m2v — run scripts/make-fixtures.sh")
        }

        // The tree: two files called b.mov in different folders, and a second "Day 1"
        // under another folder — the two ways a flattened import went wrong.
        let shoot = scratch.appendingPathComponent("Shoot", isDirectory: true)
        let other = scratch.appendingPathComponent("Other", isDirectory: true)
        let layout: [(String, URL)] = [
            ("Shoot/a.mov", movie), ("Shoot/Day 1/b.mov", movie), ("Shoot/Day 2/b.mov", movie),
            ("Shoot/Day 2/Night/c.m2v", mpeg), ("Other/Day 1/d.mov", movie)
        ]
        do {
            for (path, fixture) in layout {
                let url = scratch.appendingPathComponent(path)
                try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try files.copyItem(at: fixture.resolvingSymlinksInPath(), to: url)
            }
        } catch {
            return check.finish(blockedReason: "could not build the scratch tree: \(error)")
        }
        let destination = scratch.appendingPathComponent("Copied", isDirectory: true)

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
        func bins(named name: String) -> [String] {
            library.items.filter { $0.name == name }.compactMap(\.bin).sorted()
        }
        func runningJobsFinish() {
            wait(1) { shell.importJobsForChecks > 0 }
            wait(60) { shell.importJobsForChecks == 0 }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))   // catalog writes land
        }

        // 1. Import mode: Copy, with "Include subfolders" (on by default), into the
        //    bin named after the source folder (the default).
        modes.show(.importMedia)
        guard let view = modes.importViewForChecks else {
            return check.finish(blockedReason: "Import mode did not build its view")
        }
        view.show(ImportSource(title: "Shoot", url: shoot, section: .favorites, symbolName: "star",
                               allowsMove: true, isEjectable: false))
        wait(10) { view.entries.count == 4 }
        view.methodControl.selectedSegment = 2
        view.methodControl.sendAction(view.methodControl.action, to: view.methodControl.target)
        view.optimizeCheck.state = .off
        view.setDestinationForChecks(destination)
        view.skipDuplicates.state = .off
        view.setAllChecked(true)
        view.importPressed()
        runningJobsFinish()

        let onDisk = ["a.mov", "Day 1/b.mov", "Day 2/b.mov", "Day 2/Night/c.m2v"]
        let missing = onDisk.filter { !files.fileExists(atPath: destination.appendingPathComponent($0).path) }
        let stray = ["b 2.mov"].filter { files.fileExists(atPath: destination.appendingPathComponent($0).path) }
        check.record(AssertionResult(
            name: "Copy with subfolders rebuilds the folder tree under the destination",
            passed: missing.isEmpty && stray.isEmpty,
            detail: missing.isEmpty && stray.isEmpty ? onDisk.joined(separator: ", ")
                : "missing \(missing), flattened \(stray)"))
        check.record(AssertionResult(
            name: "…and files the clips into the same tree of bins",
            passed: bins(named: "a.mov") == ["Shoot"]
                && bins(named: "b.mov") == ["Shoot/Day 1", "Shoot/Day 2"]
                && bins(named: "c.m2v") == ["Shoot/Day 2/Night"],
            detail: "a \(bins(named: "a.mov")), b \(bins(named: "b.mov")), c \(bins(named: "c.m2v"))"))
        let stored = Set(catalog.loadClips().compactMap(\.bin))
        check.record(AssertionResult(
            name: "the nested bins are saved in the catalog",
            passed: stored.isSuperset(of: ["Shoot", "Shoot/Day 1", "Shoot/Day 2", "Shoot/Day 2/Night"]),
            detail: stored.sorted().joined(separator: ", ")))

        // 2. A folder dropped on the library (VJ mode's path).
        modes.show(.vj)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        shell.importFiles([other])
        runningJobsFinish()
        check.record(AssertionResult(
            name: "a dropped folder keeps its tree, and two folders called Day 1 stay two bins",
            passed: bins(named: "d.mov") == ["Other/Day 1"]
                && library.binNames.contains("Shoot/Day 1") && library.binNames.contains("Other/Day 1"),
            detail: "d \(bins(named: "d.mov")); bins \(library.binNames)"))

        // 3. The library panel: in, in again, and Back — the real button, by hit-test.
        let panel = shell.shell.grid.panels.libraryOneBody
        panel.setViewStyleForChecks(.icon)
        panel.browser.openBin = nil
        panel.reloadNow()
        let top = panel.browser.currentEntries().compactMap(\.binName)
        panel.libraryOpen(.bin("Shoot"))
        let inShoot = panel.browser.currentEntries()
        panel.libraryOpen(.bin("Shoot/Day 2"))
        panel.reloadNow()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let inDay2 = panel.browser.currentEntries()
        check.record(AssertionResult(
            name: "the top level shows only top-level bins; each bin shows its own bins, then its clips",
            passed: Set(top) == ["Shoot", "Other"]
                && inShoot.compactMap(\.binName) == ["Shoot/Day 1", "Shoot/Day 2"]
                && inShoot.compactMap(\.item?.name) == ["a.mov"]
                && inDay2.compactMap(\.binName) == ["Shoot/Day 2/Night"]
                && inDay2.compactMap(\.item?.name) == ["b.mov"],
            detail: "top \(top); Shoot \(inShoot.map(\.id.count).count) entries; "
                + "Day 2 \(inDay2.compactMap(\.binName)) + \(inDay2.compactMap(\.item?.name))"))
        if let image = UISelfQA.render(view: shell.shell) { _ = try? check.writeImage(image, named: "nested-bin.png") }

        let back = panel.pathBar.backButtonForChecks
        let backTitle = back.title
        var reached = false
        if let content = window.contentView, !panel.pathBar.isHidden {
            let centre = back.convert(NSPoint(x: back.bounds.midX, y: back.bounds.midY), to: nil)
            let hit = content.hitTest(content.convert(centre, from: nil))
            reached = hit === back || hit?.isDescendant(of: back) == true
            if reached { back.performClick(nil) }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check.record(AssertionResult(
            name: "Back (reached by hit-test) is named for the bin above, and goes up ONE level",
            passed: reached && backTitle == "Shoot" && panel.browser.openBin == "Shoot",
            detail: "hit \(reached), title '\(backTitle)', now in \(panel.browser.openBin ?? "the top level")"))

        // 4. Rename and delete carry what is inside.
        panel.libraryRenameBin(from: "Shoot/Day 2", to: "Day Two")
        let afterRename = (bins(named: "c.m2v"), library.binNames.contains("Shoot/Day 2"))
        library.deleteBin("Shoot/Day Two")
        let afterDelete = (bins(named: "c.m2v"), bins(named: "b.mov"))
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let storedC = catalog.loadClips().first { $0.name == "c.m2v" }?.bin
        check.record(AssertionResult(
            name: "renaming a bin carries the bins inside it; deleting one lifts its contents up a level",
            passed: afterRename.0 == ["Shoot/Day Two/Night"] && !afterRename.1
                && afterDelete.0 == ["Shoot/Night"] && afterDelete.1 == ["Shoot", "Shoot/Day 1"]
                && storedC == "Shoot/Night",
            detail: "renamed: c \(afterRename.0); deleted: c \(afterDelete.0), b \(afterDelete.1); catalog c \(storedC ?? "nil")"))

        // 5. The column view shows the open bin's level on the left.
        panel.browser.openBin = "Shoot/Day 1"
        panel.setViewStyleForChecks(.column)
        panel.reloadNow()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let left = panel.columnView?.rootEntries.compactMap(\.binName) ?? []
        let right = panel.columnView?.binEntries.compactMap(\.item?.name) ?? []
        check.record(AssertionResult(
            name: "column view: left is the level the open bin is in, right is inside it",
            passed: left.contains("Shoot/Day 1") && left.contains("Shoot/Night") && right == ["b.mov"],
            detail: "left \(left), right \(right)"))
        panel.setViewStyleForChecks(.icon)

        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

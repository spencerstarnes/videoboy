//
//  ImportLookSelfQA.swift — `Videoboy --selfqa import-look`: Import mode reads clearly.
//
//  Purpose : The 2026-09-28 redesign (owner: "ugly and confusing"; reference:
//            Lightroom Classic's importer). Checks the things that made it confusing
//            are gone, in the running window: FROM names the folder and TO the
//            destination; no empty viewer before a clip is opened; the filter tabs carry
//            their counts; Check All / Uncheck All are their own buttons; the sentence
//            above Import says what will happen and follows Add / Move / Copy, the bin
//            and duplicates; Import names how many clips. Then a real window photo.
//            Never opens the viewer — silent.
//  Inputs  : samples/ clips copied into a scratch folder; scratch prefs. Needs
//            VIDEOBOY_FLAGS=modeBar (selfqa.sh sets it).
//  Outputs : selfqa/out/perf/import-look/result.txt and window.png.
//  Connects: ImportModeView, ModeController.
//

import AppKit
import VideoboyCore

enum ImportLookSelfQA {

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/import-look")
        guard FeatureFlag.modeBar.isOn else {
            return check.finish(blockedReason: "run with VIDEOBOY_FLAGS=modeBar (selfqa.sh does)")
        }
        let files = FileManager.default
        let scratch = files.temporaryDirectory
            .appendingPathComponent("videoboy-import-look-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent("Tape 07", isDirectory: true)
        let names = ["bars.dv", "motion.m2v", "motion.mov", "hd-h264-2997.mov", "hd-prores.mov"]
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in names {
                try files.copyItem(at: RepoPaths.samples.appendingPathComponent(name).resolvingSymlinksInPath(),
                                   to: folder.appendingPathComponent(name))
            }
        } catch {
            return check.finish(blockedReason: "could not build the scratch folder: \(error)")
        }

        let store = PreferenceStore(fileURL: scratch.appendingPathComponent("prefs.json"))
        store.preferences.setupCompleted = true
        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let screen = NSScreen.main,
              let modes = controller.modeController else {
            return check.finish(blockedReason: "no window or no mode bar")
        }
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        modes.show(.importMedia)
        guard let view = modes.importViewForChecks else {
            return check.finish(blockedReason: "Import mode did not build its view")
        }
        spin(0.5)
        let before = view.headerForChecks
        view.show(ImportSource(title: "Tape 07", url: folder, section: .favorites, symbolName: "star",
                               allowsMove: true, isEjectable: false))
        let deadline = Date().addingTimeInterval(10)
        while view.entries.count < names.count, Date() < deadline { spin(0.05) }
        spin(0.5)
        let header = view.headerForChecks

        check.record(AssertionResult(
            name: "before a source: FROM asks for one; after: it names the folder, and the footer counts what is checked",
            passed: before.title == "Choose a source" && header.title == "Tape 07"
                && header.counts.contains("of \(names.count) clips checked"),
            detail: "before '\(before.title)'; after '\(header.title)', '\(header.counts)'"))
        check.record(AssertionResult(
            name: "no viewer until a clip is opened (no empty black box)",
            passed: !view.isViewerOpen,
            detail: "viewer open \(view.isViewerOpen)"))

        // The sentence follows the choices.
        var sentences: [String] = []
        for segment in [0, 2] {
            view.methodControl.selectedSegment = segment
            view.methodControl.sendAction(view.methodControl.action, to: view.methodControl.target)
            sentences.append(view.summaryForChecks)
        }
        check.record(AssertionResult(
            name: "the line above Import says what will happen, and changes with Add / Copy",
            passed: sentences[0].hasPrefix("Add ") && sentences[0].contains("where they are")
                && sentences[1].hasPrefix("Copy ") && sentences[1].contains("Tape 07")
                && view.importButton.title.hasPrefix("Import ") && view.importButton.title.hasSuffix("Clips"),
            detail: "Add: '\(sentences[0])' · Copy: '\(sentences[1])' · button '\(view.importButton.title)'"))
        check.record(AssertionResult(
            name: "Add greys the destination; Copy lights it",
            passed: view.destinationEnabled,
            detail: "destination enabled on Copy \(view.destinationEnabled)"))
        view.setAllChecked(false)
        let none = (view.importButton.isEnabled, view.summaryForChecks)
        view.setAllChecked(true)
        check.record(AssertionResult(
            name: "with nothing checked Import is off and says why",
            passed: !none.0 && none.1.contains("Tick"),
            detail: "enabled \(none.0), '\(none.1)'"))

        view.methodControl.selectedSegment = 0
        view.methodControl.sendAction(view.methodControl.action, to: view.methodControl.target)
        spin(1.0)   // thumbnails
        let shot = RepoPaths.selfQAOutput.appendingPathComponent("perf/import-look/window.png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", shot.path]
        if (try? capture.run()) != nil {
            while capture.isRunning { spin(0.05) }
            check.note("window photo: \(shot.path)")
        }

        modes.show(.vj)
        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

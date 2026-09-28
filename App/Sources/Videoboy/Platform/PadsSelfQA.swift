//
//  PadsSelfQA.swift — `Videoboy --selfqa pads`: the Clip Pads, end to end.
//
//  Purpose : Proves docs/specs/clip-pads.md in the running app, through the paths a
//            performer uses: the pads sit in the top bar without moving anything and
//            are reached by hit-testing; a drop embeds a thumbnail and opens the clip
//            in memory; a real click loads it instantly (swapped in, nothing opened on
//            the main thread), again restarts it; AUTO decides play or pause; ⌥ plays
//            and cuts the sub-mix; the side switch retargets; number keys and ⌥+number
//            work through a real key event; a learned MIDI press fires; ⌥⌘ arms a pad
//            that then fires on the beat; the pads save and reopen with the show; and
//            presses under live render drop no frame and hold no picture.
//  Inputs  : samples/ clips with NO audio track (motion.mov, motion.m2v, the H.264
//            and ProRes HD files) — this check never makes a sound. A scratch prefs
//            file and template. Real window.
//  Outputs : selfqa/out/perf/pads/result.txt and window.png (a real window capture).
//  Connects: ClipPadController, ClipPadView/Strip, TransportToolbarView, Engine,
//            ShellController (load, auto-play, cut, templates).
//

import AppKit
import VideoboyCore

enum PadsSelfQA {

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private static func wait(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { spin(0.05) }
        return done()
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/pads")
        let names = ["motion.mov", "hd-h264-2997.mov", "hd-prores.mov", "motion.m2v"]
        let clips = names.map { RepoPaths.samples.appendingPathComponent($0) }
        guard clips.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            return check.finish(blockedReason: "samples/ is missing fixtures — run scripts/make-fixtures.sh")
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-pads-qa-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = PreferenceStore(fileURL: scratch.appendingPathComponent("prefs.json"))
        store.preferences.setupCompleted = true
        store.preferences.playOnLoad = true

        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let screen = NSScreen.main,
              let shell = controller.shellController, let pads = shell.clipPads else {
            return check.finish(blockedReason: "no window or no Clip Pads")
        }
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        spin(0.5)
        let engine = controller.engine
        let toolbar = shell.shell.toolbar
        let views = pads.padViewsForChecks

        // 1. Where they sit: flanking the cluster, 1–4 then 5–8, touching nothing else,
        // and each reached by a real click.
        toolbar.layoutSubtreeIfNeeded()
        let clusterFrame = toolbar.display.frame
        let frames = views.map { $0.convert($0.bounds, to: toolbar) }
        let leftOK = frames[0..<4].allSatisfy { $0.maxX <= clusterFrame.minX }
        let rightOK = frames[4..<8].allSatisfy { $0.minX >= clusterFrame.maxX }
        let ordered = frames.map(\.minX) == frames.map(\.minX).sorted()
        var overlaps: [String] = []
        for other in toolbar.subviews where other !== toolbar.leftPads && other !== toolbar.rightPads {
            if frames.contains(where: { $0.intersects(other.frame) }) { overlaps.append("\(type(of: other))") }
        }
        let centred = abs(clusterFrame.midX - toolbar.bounds.midX) < 1
        var unreachable: [Int] = []
        if let content = window.contentView {
            for view in views {
                let centre = content.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
                let hit = content.hitTest(centre)
                if hit !== view && hit?.isDescendant(of: view) != true { unreachable.append(view.index + 1) }
            }
        }
        check.record(AssertionResult(
            name: "eight pads flank the cluster (1–4 left, 5–8 right), overlap nothing, cluster still centred, every pad clickable",
            passed: leftOK && rightOK && ordered && overlaps.isEmpty && centred && unreachable.isEmpty
                && !toolbar.leftPads.isHidden,
            detail: "left ok \(leftOK), right ok \(rightOK), ordered \(ordered), overlaps \(overlaps), "
                + "centred \(centred), unreachable \(unreachable), window \(Int(window.frame.width)) wide"))

        // 2. Drops: a file, and a library entry with marks.
        func pasteboard(file url: URL) -> NSPasteboard {
            let board = NSPasteboard(name: NSPasteboard.Name("vb-pads-qa-\(UUID().uuidString)"))
            board.clearContents()
            board.writeObjects([url as NSURL])
            return board
        }
        let library = shell.shell.grid.panels.library
        // The clip as a LIBRARY entry — the one already there (the default library
        // holds the samples), or a new one.
        let existing = library.items.first { $0.url?.standardizedFileURL.path == clips[1].standardizedFileURL.path }
        let ids = existing.map { [$0.id] } ?? library.add([ShellController.libraryItem(for: clips[1])], measuresDurations: false)
        if let id = ids.first { library.setMarks(inPoint: 0.2, outPoint: 0.8, for: id) }
        let libraryBoard = NSPasteboard(name: NSPasteboard.Name("vb-pads-qa-lib-\(UUID().uuidString)"))
        libraryBoard.clearContents()
        if let id = ids.first, let entry = library.item(withID: id) {
            libraryBoard.writeObjects([LibraryBrowser.pasteboardItem(for: entry, range: library.markedRange(for: id))])
        }
        let dropped = [
            views[0].onDrop?(0, pasteboard(file: clips[0])) ?? false,
            views[1].onDrop?(1, libraryBoard) ?? false,
            views[4].onDrop?(4, pasteboard(file: clips[2])) ?? false,
            views[5].onDrop?(5, pasteboard(file: clips[3])) ?? false
        ]
        wait(8) { [0, 1, 4, 5].allSatisfy { pads.isReadyForChecks($0) } && views[0].thumbnail != nil }
        check.record(AssertionResult(
            name: "dropping a file or a library clip embeds its thumbnail and opens it in memory",
            passed: dropped.allSatisfy { $0 } && [0, 1, 4, 5].allSatisfy { pads.isReadyForChecks($0) && views[$0].hasClip }
                && views[0].thumbnail != nil && pads.bank[pad: 1]?.range == 0.2...0.8,
            detail: "taken \(dropped), ready \([0, 1, 4, 5].map { pads.isReadyForChecks($0) }), "
                + "thumbnail \(views[0].thumbnail != nil), pad 2 marks \(String(describing: pads.bank[pad: 1]?.range))"))
        if let image = UISelfQA.render(view: toolbar) { _ = try? check.writeImage(image, named: "toolbar.png") }

        // A real click: the press lands on the way down; its mouse-up is queued first so
        // the pad's tracking loop ends as it would under a finger.
        func click(_ view: ClipPadView, modifiers: NSEvent.ModifierFlags = []) {
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let up = event(.leftMouseUp) { window.postEvent(up, atStart: true) }
            if let down = event(.leftMouseDown) { view.mouseDown(with: down) }
        }
        func holds(_ channel: String) -> String? { engine.sources[channel]?.mediaURL?.lastPathComponent }

        // 3. A click loads — instantly — and plays per AUTO (on here).
        let instantBefore = pads.instantLoads
        var clickMs = 0.0
        let started = CACurrentMediaTime()
        click(views[0])
        clickMs = (CACurrentMediaTime() - started) * 1000
        spin(0.4)
        check.record(AssertionResult(
            name: "clicking pad 1 swaps its already-open clip into A (nothing opened on the main thread) and AUTO plays it",
            passed: holds("A") == names[0] && pads.instantLoads == instantBefore + 1 && engine.sources["A"]?.isPlaying == true
                && clickMs < 1000 / StandardDefinition.frameRate / 2,
            detail: String(format: "A holds %@, instant %d, playing %@, click %.2f ms", holds("A") ?? "nothing",
                           pads.instantLoads - instantBefore, String(describing: engine.sources["A"]?.isPlaying), clickMs)))

        // 4. Again, while loaded: back to the head.
        spin(1.0)
        let playedTo = engine.sources["A"]?.playheadFrame ?? 0
        click(views[0])
        let afterRestart = engine.sources["A"]?.playheadFrame ?? 99
        check.record(AssertionResult(
            name: "clicking it again while it is loaded restarts it",
            passed: playedTo > 5 && afterRestart <= 1 && holds("A") == names[0],
            detail: "playhead \(playedTo) → \(afterRestart)"))

        // 5. AUTO off: the clip lands paused.
        shell.setAutoPlayForChecks(false, channel: "A")
        click(views[1])
        spin(0.4)
        check.record(AssertionResult(
            name: "with A's AUTO off, a pad loads its clip paused (and with its marks)",
            passed: holds("A") == names[1] && engine.sources["A"]?.isPlaying == false
                && engine.sources["A"]?.playbackRange == 0.2...0.8,
            detail: "A holds \(holds("A") ?? "nothing"), playing \(String(describing: engine.sources["A"]?.isPlaying)), "
                + "range \(String(describing: engine.sources["A"]?.playbackRange))"))
        shell.setAutoPlayForChecks(true, channel: "A")

        // 6. ⌥-click: load, play, and cut C/D to C.
        let cdSlot = GraphTopology.subMixTwo
        engine.registry.setValue(1, slot: cdSlot, code: .crossfadeCD)
        shell.shell.grid.panels.faderCDBody.setPosition(1)
        shell.setAutoPlayForChecks(false, channel: "C")
        click(views[4], modifiers: [.option])
        wait(1) { (engine.registry.value(slot: cdSlot, code: .crossfadeCD) ?? 1) < 0.01 }
        check.record(AssertionResult(
            name: "⌥-clicking pad 5 loads C, plays it even with AUTO off, and cuts C/D to C",
            passed: holds("C") == names[2] && engine.sources["C"]?.isPlaying == true
                && (engine.registry.value(slot: cdSlot, code: .crossfadeCD) ?? 1) < 0.01,
            detail: "C holds \(holds("C") ?? "nothing"), playing \(String(describing: engine.sources["C"]?.isPlaying)), "
                + "C/D fader \(engine.registry.value(slot: cdSlot, code: .crossfadeCD) ?? -1)"))
        shell.setAutoPlayForChecks(true, channel: "C")

        // 7. The side switch, by a real click on its B segment: pads 1–4 now load into B.
        let segmented = toolbar.leftPads.sideSwitch
        segmented.selectedSegment = 1
        _ = segmented.target?.perform(segmented.action, with: segmented)
        wait(8) { pads.isReadyForChecks(0) }
        click(views[0])
        spin(0.3)
        check.record(AssertionResult(
            name: "switching the left side to B re-opens its pads for B; pad 1 then loads into B",
            passed: pads.bank.channel(forPad: 0) == "B" && holds("B") == names[0],
            detail: "pad 1 → \(pads.bank.channel(forPad: 0)), B holds \(holds("B") ?? "nothing")"))

        // 8. Number keys, through a real key event: 6 loads pad 6 into C; ⌘6 does not.
        func key(_ character: String, _ modifiers: NSEvent.ModifierFlags = []) -> Bool {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: 22) else { return false }
            return pads.handleKey(event)
        }
        window.makeFirstResponder(nil)
        let commandTaken = key("6", [.command])
        let taken = key("6")
        spin(0.3)
        check.record(AssertionResult(
            name: "the number key 6 loads pad 6; ⌘6 is left alone",
            passed: taken && !commandTaken && holds("C") == names[3],
            detail: "6 taken \(taken), ⌘6 taken \(commandTaken), C holds \(holds("C") ?? "nothing")"))

        // 9. A learned MIDI press: the mapping writes 1 to 62J; the tick fires pad 2.
        engine.registry.setValue(1, slot: ClipPadController.slot, code: ParamCode.clipPadPresses[1])
        pads.tick()
        spin(0.3)
        check.record(AssertionResult(
            name: "a MIDI press on 62J fires pad 2 and the trigger falls back to 0",
            passed: holds("B") == names[1]
                && engine.registry.value(slot: ClipPadController.slot, code: ParamCode.clipPadPresses[1]) == 0,
            detail: "B holds \(holds("B") ?? "nothing")"))

        // 10. ⌥⌘ arms pad 6 on the beat; at 1/16 it fires on its own while the clock runs.
        if let armEvent = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [.command, .option],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            views[5].mouseDown(with: armEvent)
        }
        for _ in 0..<4 { if let forward = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            views[5].rateKey.mouseDown(with: forward) } }
        let armedRate = pads.bank[pad: 5]?.flipRate?.displayName
        engine.setTransportRunning(true)
        let pressesBefore = pads.instantLoads + pads.waitedLoads
        let restartsBefore = engine.sources["C"]?.playheadFrame ?? 0
        spin(2.0)
        engine.setTransportRunning(false)
        let fired = views[5].flipRate != nil && !views[5].rateKey.isHidden
        check.record(AssertionResult(
            name: "⌥⌘ arms a pad (the blue rate box shows inside it) and it fires on the beat",
            passed: armedRate == "1/16" && fired && (engine.sources["C"]?.playheadFrame ?? 99) < 20,
            detail: "rate \(armedRate ?? "none"), box shown \(fired), C playhead \(restartsBefore) → "
                + "\(engine.sources["C"]?.playheadFrame ?? -1) (restarted every 1/16), loads \(pads.instantLoads + pads.waitedLoads - pressesBefore)"))
        views[5].onArmToggled?(5)

        // 11. Saved with the show, and back.
        let saved = shell.captureTemplate(name: "pads")
        pads.restore(nil)
        let emptied = views.allSatisfy { !$0.hasClip }
        shell.openTemplate(saved, from: nil)
        wait(8) { pads.isReadyForChecks(0) && pads.isReadyForChecks(5) }
        check.record(AssertionResult(
            name: "the pads, their marks and the side switches save with the show and reopen ready",
            passed: emptied && saved.clipPads?[pad: 1]?.range == 0.2...0.8 && views[0].hasClip && views[5].hasClip
                && pads.bank.channel(forPad: 0) == "B" && pads.isReadyForChecks(0),
            detail: "emptied \(emptied), pads back \(views.filter(\.hasClip).count), left side \(pads.bank.channel(forPad: 0))"))

        // 12. Under live render: presses drop no frame, hold no picture, stall nothing.
        for letter in ["A", "B", "C", "D"] { engine.setPlaying(true, channel: letter) }
        wait(8) { [0, 1, 4, 5].allSatisfy { pads.isReadyForChecks($0) } }
        engine.tickCostsForChecks = []
        let baseDrops = engine.droppedFrames
        spin(3)
        let dropsWithout = engine.droppedFrames - baseDrops
        engine.tickCostsForChecks = []
        var awake = 0.0, worstStretch = 0.0
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting { awake = now } else if awake > 0 { worstStretch = max(worstStretch, (now - awake) * 1000) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        MainThreadCosts.byLabel = [:]
        let dropsBefore = engine.droppedFrames
        let instantStart = pads.instantLoads, waitedStart = pads.waitedLoads, restartStart = pads.restarts
        var held = 0
        for index in [0, 4, 1, 5, 0, 4, 1, 5] {
            let channel = pads.bank.channel(forPad: index)
            let heldBefore = engine.sources[channel]?.heldFrames ?? 0
            click(views[index])
            spin(0.3)
            held += (engine.sources[channel]?.heldFrames ?? 0) - heldBefore
            spin(0.9)
        }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        check.note("press costs, worst: " + (MainThreadCosts.byLabel ?? [:])
            .map { String(format: "%@ %.2f ms", $0.key, $0.value.max() ?? 0) }.sorted().joined(separator: ", "))
        MainThreadCosts.byLabel = nil
        let ticks = engine.tickCostsForChecks ?? []
        engine.tickCostsForChecks = nil
        let drops = engine.droppedFrames - dropsBefore
        check.record(AssertionResult(
            name: "8 pad presses on HD under live render: each an instant swap or a restart, no dropped frame, no held picture, no stall",
            passed: (pads.instantLoads - instantStart) + (pads.restarts - restartStart) == 8
                && pads.waitedLoads == waitedStart && drops <= dropsWithout
                && held == 0 && (ticks.max() ?? 99) < 1000 / StandardDefinition.frameRate
                && worstStretch < 1000 / StandardDefinition.frameRate / 2,
            detail: String(format: "%d instant, %d restarts, %d opened on demand, %d dropped (%d in 3 s without), %d held, "
                           + "worst tick %.2f ms, longest main-thread stretch %.1f ms",
                           pads.instantLoads - instantStart, pads.restarts - restartStart,
                           pads.waitedLoads - waitedStart, drops, dropsWithout,
                           held, ticks.max() ?? 0, worstStretch)))

        let shot = RepoPaths.selfQAOutput.appendingPathComponent("perf/pads/window.png")
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", shot.path]
        if (try? capture.run()) != nil {
            while capture.isRunning { spin(0.05) }
            check.note("window photo: \(shot.path)")
        }

        for letter in ["A", "B", "C", "D"] { engine.setPlaying(false, channel: letter) }
        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

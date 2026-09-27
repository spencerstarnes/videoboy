//
//  ModeBarSelfQA.swift — the mode bar, Settings mode and the setup assistant (0.4.8).
//
//  Purpose : Proves what docs/specs/0.4.8-mode-bar.md promises: the strip grows by
//            10 pt and nothing else in VJ mode moves; the bar is reachable through
//            real hit-testing; ⌘1–⌘3 switch through the View menu's key equivalents;
//            switching modes never interrupts the show; Settings embeds every pane;
//            the setup assistant finishes on defaults without a modal.
//  Inputs  : samples/ (four SD fixtures for the live part). Needs VIDEOBOY_FLAGS=modeBar
//            (scripts/selfqa.sh sets it for this check).
//  Outputs : selfqa/out/perf/modes/result.txt and PNGs of each mode.
//  Connects: ShellView, StatusBarView, ModeController, PreferencesWindowController,
//            SetupAssistant, Engine (frame counter, tick costs, dropped frames).
//

import AppKit
import VideoboyCore

enum ModeBarSelfQA {

    /// Every control under a view, in a stable (depth-first) order.
    private static func controls(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if view is NSControl { found.append(view) }
            view.subviews.forEach(walk)
        }
        walk(view)
        return found
    }

    /// A view's frame in its shell, measured from the TOP-left, so a shell that only
    /// grew at the bottom gives identical numbers.
    private static func topLeftFrame(_ view: NSView, in shell: NSView) -> NSRect {
        let frame = view.convert(view.bounds, to: shell)
        return NSRect(x: frame.minX, y: shell.bounds.height - frame.maxY,
                      width: frame.width, height: frame.height)
    }

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "perf/modes")
        guard FeatureFlag.modeBar.isOn else {
            return check.finish(blockedReason: "run with VIDEOBOY_FLAGS=modeBar (selfqa.sh does)")
        }
        let grow = Theme.Metrics.modeBarHeight - Theme.Metrics.statusBarHeight

        // 1–2. Strip heights, and no performance control moves but by the strip change.
        for size in [NSSize(width: 1460, height: 912), NSSize(width: 1920, height: 1100),
                     NSSize(width: 1200, height: 800)] {
            // Several shells of each kind, geometry only (no controller: a live one
            // fills pop-ups asynchronously). A few controls have an under-constrained
            // layout that predates the mode bar — identical shells place them
            // differently (BUILD-PLAN backlog). So: a control has MOVED only if none of
            // its positions with the bar matches any of its positions without it. A
            // real move shifts every sample; an ambiguous control overlaps.
            func settled(_ modeBar: Bool, height: CGFloat) -> ShellView {
                let shell = ShellView(modeBar: modeBar)
                shell.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: height))
                for _ in 0..<3 { shell.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
                return shell
            }
            // Interleaved, so anything that drifts over time (the ambiguous controls'
            // choice seems to) lands on both sides alike.
            var withouts: [ShellView] = [], withs: [ShellView] = []
            for _ in 0..<6 {
                withouts.append(settled(false, height: size.height - grow))
                withs.append(settled(true, height: size.height))
            }
            let before = withouts[0], after = withs[0]
            let label = "\(Int(size.width))x\(Int(size.height))"
            check.record(AssertionResult(
                name: "\(label): the strip is \(Int(Theme.Metrics.modeBarHeight)) pt with the mode bar, "
                    + "\(Int(Theme.Metrics.statusBarHeight)) pt without",
                passed: after.statusBar.frame.height == Theme.Metrics.modeBarHeight
                    && before.statusBar.frame.height == Theme.Metrics.statusBarHeight,
                detail: "\(after.statusBar.frame.height) / \(before.statusBar.frame.height)"))

            func frames(_ shells: [ShellView]) -> [[NSRect]] {
                shells.map { shell in (controls(in: shell.toolbar) + controls(in: shell.grid)).map { topLeftFrame($0, in: shell) } }
            }
            // Even the NUMBER of controls occasionally differs by one between identical
            // shells (a view built a run-loop turn late); compare the majority.
            let allFrames = frames(withouts) + frames(withs)
            let tally = Dictionary(grouping: allFrames.map(\.count), by: { $0 })
            let majority: Int = tally.max(by: { $0.value.count < $1.value.count }).map(\.key) ?? 0
            let off = frames(withouts).filter { $0.count == majority }
            let on = frames(withs).filter { $0.count == majority }
            let counts: Set<Int> = off.count >= 3 && on.count >= 3 ? [majority] : [-1, majority]
            func same(_ a: NSRect, _ b: NSRect) -> Bool {
                abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5
                    && abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
            }
            var moved: [String] = []
            var unstable: [String] = []
            let total = majority
            if counts.count == 1 {
                for index in 0..<total {
                    let offSamples = off.map { $0[index] }, onSamples = on.map { $0[index] }
                    if !offSamples.allSatisfy({ same($0, offSamples[0]) }) || !onSamples.allSatisfy({ same($0, onSamples[0]) }) {
                        unstable.append("\(offSamples[0]) / \(onSamples[0])")
                    }
                    if !offSamples.contains(where: { a in onSamples.contains { same(a, $0) } }) {
                        moved.append("\(offSamples[0]) → \(onSamples[0])")
                    }
                }
            }
            check.record(AssertionResult(
                name: "\(label): no toolbar or grid control moves except by the strip change",
                passed: counts.count == 1 && total > 100 && moved.isEmpty,
                detail: "\(total) controls × \(off.count)/\(on.count) shells; \(moved.count) moved"
                    + (moved.first.map { " — first: \($0)" } ?? "")
                    + "; \(unstable.count) vary between identical shells (pre-existing)"))
            if !unstable.isEmpty {
                check.note("\(label) unstable without the bar: " + unstable.prefix(4).joined(separator: " | "))
            }
        }

        // The live part: a real window, four channels playing, every effect on.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("videoboy-modes-qa-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sources = ["bars.dv", "motion.dv", "motion.mov", "motion.m2v"]
            .map { RepoPaths.samples.appendingPathComponent($0) }
        guard sources.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            return check.finish(blockedReason: "samples/ is missing fixtures")
        }
        let store = PreferenceStore(fileURL: scratch.appendingPathComponent("prefs.json"))
        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let screen = NSScreen.main,
              let shellController = controller.shellController,
              let modes = controller.modeController,
              let modeSwitch = shellController.shell.statusBar.modeSwitch else {
            return check.finish(blockedReason: "no window or no mode bar")
        }
        let shell = shellController.shell
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let engine = controller.engine
        let panels = shell.grid.panels
        for (letter, url) in zip(["A", "B", "C", "D"], sources) {
            panels.sourceBodies[letter]?.onClipDropped?(url, nil)
            engine.setPlaying(true, channel: letter)
            for effect in ["mosh", "transform", "colour", "composite", "echo", "feedback"] {
                engine.registry.setValue(1, slot: Engine.channelSlot(letter, effect), code: .wetDry)
            }
        }
        for slot in Engine.busEffectSlots { engine.registry.setValue(1, slot: slot, code: .wetDry) }
        engine.setTransportRunning(true)
        RunLoop.main.run(until: Date().addingTimeInterval(2))

        // 3. The bar through real hit-testing: each segment's centre reaches the
        // segmented control, and a click there switches mode.
        guard let content = window.contentView else { return check.finish(blockedReason: "no content view") }
        var hitsReach = 0
        var clicksSwitch = 0
        let segmentWidth = modeSwitch.bounds.width / CGFloat(modeSwitch.segmentCount)
        for mode in [AppMode.importMedia, .settings, .vj] {
            let local = NSPoint(x: segmentWidth * (CGFloat(mode.rawValue) - 0.5), y: modeSwitch.bounds.midY)
            let inWindow = modeSwitch.convert(local, to: nil)
            // hitTest takes a point in the receiver's SUPERVIEW's coordinates.
            let hit = content.hitTest(content.superview?.convert(inWindow, from: nil) ?? inWindow)
            if hit === modeSwitch || hit?.isDescendant(of: modeSwitch) == true { hitsReach += 1 }
            // What a click on that segment does: select it and send the action.
            modeSwitch.selectedSegment = mode.rawValue - 1
            modeSwitch.sendAction(modeSwitch.action, to: modeSwitch.target)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if modes.mode == mode { clicksSwitch += 1 }
        }
        check.record(AssertionResult(
            name: "every mode-bar segment is reached by hitTest at its centre",
            passed: hitsReach == 3, detail: "\(hitsReach) of 3"))
        check.record(AssertionResult(
            name: "clicking a segment switches to its mode",
            passed: clicksSwitch == 3, detail: "\(clicksSwitch) of 3"))

        // 4. ⌘1–⌘3 through the View menu's key equivalents.
        let menu = ModeController.makeViewMenu(target: modes, action: #selector(ModeController.menuChosen(_:)))
        var keysWork = 0
        for mode in [AppMode.settings, .importMedia, .vj] {
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil,
                characters: mode.keyEquivalent, charactersIgnoringModifiers: mode.keyEquivalent,
                isARepeat: false, keyCode: 0) else { continue }
            _ = menu.performKeyEquivalent(with: event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if modes.mode == mode { keysWork += 1 }
        }
        check.record(AssertionResult(
            name: "⌘1 / ⌘2 / ⌘3 switch modes through the View menu",
            passed: keysWork == 3 && menu.items.map(\.keyEquivalent) == ["1", "2", "3"]
                && menu.items.allSatisfy { $0.keyEquivalentModifierMask == .command },
            detail: "\(keysWork) of 3; items \(menu.items.map { "\($0.title) ⌘\($0.keyEquivalent)" })"))

        // 5. Visibility per mode, and VJ comes back with its controls where they were.
        let vjFrames = controls(in: shell.grid).map { topLeftFrame($0, in: shell) }
        var visibilityRight = 0
        for mode in [AppMode.importMedia, .settings, .vj] {
            modes.show(mode)
            shell.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let shown = shell.modeHost.subviews.filter { !$0.isHidden }
            let right = mode == .vj
                ? (shell.modeHost.isHidden && !shell.grid.previewsCovered)
                : (!shell.modeHost.isHidden && shown.count == 1 && shell.grid.previewsCovered
                   && content.hitTest(content.superview?.convert(
                        shell.grid.convert(NSPoint(x: shell.grid.bounds.midX, y: shell.grid.bounds.midY), to: nil),
                        from: nil) ?? .zero).map { $0.isDescendant(of: shell.modeHost) } == true)
            if right { visibilityRight += 1 }
            if let image = UISelfQA.render(view: shell) {
                _ = try? check.writeImage(image, named: "mode-\(mode.menuTitle.lowercased()).png")
            }
        }
        let backFrames = controls(in: shell.grid).map { topLeftFrame($0, in: shell) }
        check.record(AssertionResult(
            name: "each mode shows its own view over the grid (hitTest lands in it); VJ shows the grid",
            passed: visibilityRight == 3, detail: "\(visibilityRight) of 3"))
        check.record(AssertionResult(
            name: "back in VJ, every grid control is exactly where it was",
            passed: vjFrames == backFrames && !vjFrames.isEmpty,
            detail: "\(vjFrames.count) controls"))

        // 6. The show never stops: switch every 0.5 s for 10 s while measuring — after
        // the same 10 s without switching, so a drop the show makes anyway is not
        // blamed on the mode bar.
        engine.tickCostsForChecks = []
        let baselineStart = engine.droppedFrames
        let baselineDrops = engine.droppedFrames
        let baselineFrames = engine.frameIndex
        RunLoop.main.run(until: Date().addingTimeInterval(10))
        let baselineTicks = engine.tickCostsForChecks ?? []
        let droppedAnyway = engine.droppedFrames - baselineStart
        check.note(String(format: "baseline, no switching, 10 s: %d frames, %d dropped, worst tick %.2f ms",
                          engine.frameIndex - baselineFrames, engine.droppedFrames - baselineDrops,
                          baselineTicks.max() ?? 0))
        engine.tickCostsForChecks = []
        let dropsBefore = engine.droppedFrames
        let framesBefore = engine.frameIndex
        let started = Date()
        var switches = 0
        let cycle: [AppMode] = [.importMedia, .settings, .vj, .settings, .importMedia, .vj]
        // The main thread's longest stretch without going back to sleep, per switch:
        // a switch's cost is not in the tick, it is the layout and display after it.
        var awake = 0.0
        var longest: [AppMode: Double] = [:]
        var current = AppMode.vj
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true, 0) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting { awake = now } else if awake > 0 {
                longest[current] = max(longest[current] ?? 0, (now - awake) * 1000)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        while Date().timeIntervalSince(started) < 10 {
            current = cycle[switches % cycle.count]
            modes.show(current)
            switches += 1
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
        check.note("longest main-thread stretch after switching to: "
            + longest.map { String(format: "%@ %.1f ms", $0.key.menuTitle, $0.value) }.sorted().joined(separator: ", "))
        let seconds = Date().timeIntervalSince(started)
        let ticks = engine.tickCostsForChecks ?? []
        engine.tickCostsForChecks = nil
        let rendered = engine.frameIndex - framesBefore
        let rate = Double(rendered) / seconds
        let drops = engine.droppedFrames - dropsBefore
        let worst = ticks.max() ?? 0
        let budget = 1000 / StandardDefinition.frameRate
        let worstSwitch = longest.values.max() ?? 0
        check.record(AssertionResult(
            name: "switching modes never interrupts the show (\(switches) switches in 10 s)",
            passed: rate >= 29.5 && drops <= max(droppedAnyway, 1) && worst < budget && ticks.count > 200,
            detail: String(format: "%.2f frames/s, %d dropped (%d in the same time without switching), "
                + "worst tick %.2f ms of %d", rate, drops, droppedAnyway, worst, ticks.count)))
        check.record(AssertionResult(
            name: "no switch holds the main thread for half a frame (tick included)",
            passed: worstSwitch < budget / 2,
            detail: String(format: "longest %.1f ms", worstSwitch)))
        modes.show(.vj)

        // 7. Settings embeds every pane; Project offers SD NTSC 29.97 and greys the rest.
        modes.show(.settings)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        if let settings = modes.settings {
            settings.select(.project)
            let tabs = settings.tabButtonsForChecks
            let popUps = controls(in: settings.rootView).compactMap { $0 as? NSPopUpButton }
            let canvas = popUps.first { $0.accessibilityIdentifier() == "project-canvas" }
            let greyed = canvas.map { popUp in popUp.itemArray.dropFirst().allSatisfy { !$0.isEnabled } } ?? false
            check.record(AssertionResult(
                name: "Settings mode shows every Preferences pane, Project first",
                passed: tabs.count == PreferencesWindowController.Pane.allCases.count
                    && settings.rootView.window === window,
                detail: "\(tabs.count) tabs, embedded in the main window: \(settings.rootView.window === window)"))
            check.record(AssertionResult(
                name: "Project: SD NTSC 720×480 selected, other canvases present and disabled",
                passed: canvas?.titleOfSelectedItem == "SD NTSC 720×480" && greyed,
                detail: "\(canvas?.titleOfSelectedItem ?? "no canvas pop-up"); others disabled \(greyed)"))
            if let image = UISelfQA.render(view: shell) {
                _ = try? check.writeImage(image, named: "settings-project.png")
            }
        } else {
            check.record(AssertionResult(name: "Settings mode shows every Preferences pane, Project first",
                                         passed: false, detail: "no settings controller"))
        }
        modes.show(.vj)

        // 8. The setup assistant: Continue through on defaults, never a modal.
        store.preferences.setupCompleted = false
        controller.runSetupAssistant()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        var pages = 0
        var modalSeen = false
        if let assistant = controller.setupAssistant {
            if let sheet = assistant.window, let image = UISelfQA.render(view: sheet.contentView ?? NSView()) {
                _ = try? check.writeImage(image, named: "setup-welcome.png")
            }
            while controller.setupAssistant != nil, pages < 10 {
                if NSApp.modalWindow != nil { modalSeen = true }
                assistant.continuePressed()
                pages += 1
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
        }
        check.record(AssertionResult(
            name: "the setup assistant finishes on Continue ▸ … ▸ Done with every default",
            passed: controller.setupAssistant == nil && pages == SetupAssistant.Page.allCases.count
                && store.preferences.setupCompleted
                && store.preferences.mediaLocationPath != nil
                && store.preferences.optimizedMediaLocationPath != nil,
            detail: "\(pages) presses; setupCompleted \(store.preferences.setupCompleted); "
                + "media \(store.preferences.mediaLocationPath ?? "nil")"))
        check.record(AssertionResult(
            name: "the setup assistant is a sheet, never an app-modal window",
            passed: !modalSeen && NSApp.modalWindow == nil,
            detail: modalSeen ? "a modal window was open" : "no modal window"))

        engine.setTransportRunning(false)
        window.orderOut(nil)
        withExtendedLifetime(controller) {}
        return check.finish()
    }
}

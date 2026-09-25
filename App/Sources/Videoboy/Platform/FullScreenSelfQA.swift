//
//  FullScreenSelfQA.swift — the real window at full-screen size, photographed.
//
//  Purpose : The offscreen layout check renders an empty shell at three sizes and
//            cannot see Metal content, layers drawn over the pictures, or a panel
//            with media in it. The human performs full screen on a 1920x1080
//            display, so this opens the actual main window at the main screen's
//            full visible size, loads all four channels, and walks the states a
//            performer puts it in — every scope key on every composite, a hovered
//            source, the Generators tab — photographing the window at each.
//  Inputs  : samples/ (bars.dv, motion.dv, motion.m2v, motion.mov).
//  Outputs : selfqa/out/ui/fullscreen/{*.png,result.txt}.
//  Connects: MainWindowController, ShellController, PreviewPanelBody, SourcePanelBody,
//            LibraryPanelBody, GeneratorThumbnails.
//  Extend  : add a state to `run()`: put the window in it, `settle`, `capture`, and
//            assert on the geometry that state is about.
//
//  The photographs are taken with /usr/sbin/screencapture on this window alone. Run
//  from a terminal (scripts/selfqa.sh), the terminal is the process macOS asks about
//  Screen Recording, not this app — so it works on an ad-hoc-signed build.
//

import AppKit
import VideoboyCore

enum FullScreenSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "ui/fullscreen")
        let store = PreferenceStore(
            fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("videoboy-fullscreen-prefs-\(UUID().uuidString).json"))
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        let controller = MainWindowController(preferences: store)
        guard let window = controller.window, let screen = NSScreen.main,
              let shellController = controller.shellController else {
            return check.finish(blockedReason: "no window or screen to run on")
        }
        window.setFrame(screen.visibleFrame, display: true)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        let engine = controller.engine
        let shell = shellController.shell
        let panels = shell.grid.panels

        // ── The Generators tab ────────────────────────────────────────────────
        let browserBody = panels.assetBrowserBody
        if let tabs = Self.segmented(in: browserBody),
           let index = AssetTab.allCases.firstIndex(of: .generators) {
            tabs.selectedSegment = index
            tabs.sendAction(tabs.action, to: tabs.target)
            // Opened straight after launch, while the ISF generators are still
            // compiling, so their pictures arrive into tiles already on screen —
            // the case that used to leave them blank.
            settle(6)
            capture(window, "generators-tab", check)
            let items = browserBody.browser.fixedItems ?? []
            let missing = items.filter { $0.thumbnail == nil }.map(\.name)
            check.record(AssertionResult(
                name: "every generator has a thumbnail",
                passed: !items.isEmpty && missing.isEmpty,
                detail: "\(items.count) generators; without a picture: "
                    + (missing.isEmpty ? "none" : missing.joined(separator: ", "))))
            let black = items.filter { item in
                guard let image = item.thumbnail,
                      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
                return Self.isBlack(cg)
            }.map(\.name)
            check.note("generators whose thumbnail is black at every moment tried: \(black.count)"
                + (black.isEmpty ? "" : " — " + black.joined(separator: ", ")))
            let tiles = HoverScrubView.all(in: browserBody)
                .filter { !$0.isHiddenOrHasHiddenAncestor && $0.item != nil }
            let blank = tiles.filter { $0.item?.thumbnail != nil && !$0.hasDecodedFrame }
            check.record(AssertionResult(
                name: "every generator tile on screen shows its picture",
                passed: !tiles.isEmpty && blank.isEmpty,
                detail: "\(tiles.count) tiles; blank: "
                    + (blank.isEmpty ? "none" : blank.compactMap { $0.item?.name }.joined(separator: ", "))))
        }

        check.note("window \(Int(window.frame.width))x\(Int(window.frame.height)) on "
            + "\(screen.localizedName) at \(screen.backingScaleFactor)x")

        let clips = ["A": "bars.dv", "B": "motion.dv", "C": "motion.m2v", "D": "motion.mov"]
        for (letter, name) in clips.sorted(by: { $0.key < $1.key }) {
            let url = RepoPaths.samples.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path),
               engine.load(url: url, intoChannel: letter) {
                engine.setPlaying(true, channel: letter)
            }
        }
        engine.setTransportRunning(true)
        settle(2)
        capture(window, "base", check)

        // ── Every scope key on every composite ─────────────────────────────────
        //
        // Each key is pressed through its own action, the scope is given time to
        // refresh, and the scope and data layers must sit inside the preview they
        // are drawn on — at every fill mode, since the fill mode is what moves the
        // picture they are placed against.
        let composites: [(String, PreviewPanelBody)] = [
            ("submix1", panels.subMixOneBody), ("program", panels.programBody),
            ("submix2", panels.subMixTwoBody)
        ]
        // The keys in the order they sit on the bar. From a clean start (OVER lit,
        // nothing else) each press has one expected picture opacity behind the
        // scope: one instrument sits in its own corner box and leaves the picture
        // alone; two or more fill the frame over a held-back picture; OVER off puts
        // them over black.
        let expectedOpacity: [String: Float] = ["WFM": 1, "VEC": 0.35, "OVER": 0]
        for fill in PreviewFill.allCases {
            shellController.setPreviewFill(fill)
            for (name, body) in composites {
                for key in VBOptionButton.all(in: body) where key.isEnabled {
                    let label = key.title.replacingOccurrences(of: "\n", with: " ")
                    // DATA BURN changes the programme, not the monitor; it is covered
                    // by the data-burn checks in `selfqa ui`.
                    guard label != "DATA BURN" else { continue }
                    key.sendAction(key.action, to: key.target)
                    settle(0.4)
                    let preview = body.preview
                    let bounds = preview.bounds.insetBy(dx: -0.5, dy: -0.5)
                    let scope = preview.scopeFrameForChecks
                    let data = preview.dataFrameForChecks
                    let inside = (scope.map { bounds.contains($0) } ?? true)
                        && (data.map { bounds.contains($0) } ?? true)
                    check.record(AssertionResult(
                        name: "\(fill.displayName): \(name) \(label) draws inside its preview",
                        passed: inside && scope != nil,
                        detail: "preview \(Self.describe(preview.bounds)), scope "
                            + (scope.map(Self.describe) ?? "hidden") + ", data "
                            + (data.map(Self.describe) ?? "hidden")))
                    guard fill == .fit else { continue }
                    capture(window, "scope-\(name)-\(label.lowercased())", check)
                    if label == "FILE" || label == "TC" {
                        check.record(AssertionResult(
                            name: "\(name) \(label) puts its text on the monitor",
                            passed: data != nil,
                            detail: data.map { "text block at \(Self.describe($0))" } ?? "nothing drawn"))
                    }
                    if let expected = expectedOpacity[label] {
                        let opacity = preview.pictureOpacityForChecks
                        check.record(AssertionResult(
                            name: "\(name) after \(label): picture behind the scope at \(expected)",
                            passed: abs(opacity - expected) < 0.01,
                            detail: "picture opacity \(opacity)"))
                    }
                }
                // Everything back off, so the next composite starts clean. Backwards:
                // OVER and L3 grey out once the last instrument is off, and a greyed
                // key cannot be pressed back off. OVER ends lit, as it starts.
                for key in VBOptionButton.all(in: body).reversed() where key.isEnabled
                    && key.isOn != (key.title == "OVER") {
                    key.sendAction(key.action, to: key.target)
                }
                settle(0.2)
            }
        }
        shellController.setPreviewFill(.fit)

        // ── What FILE / TC cost the tick ──────────────────────────────────────
        //
        // TC redraws its text every frame. On all three monitors at once, the worst
        // tick must stay well inside the 33.4 ms budget. Measured against the same
        // window with them off, so the cost is theirs and not the harness's.
        func measureTicks() -> (count: Int, mean: Double, worst: Double) {
            engine.tickCostsForChecks = []
            settle(4)
            let ticks = engine.tickCostsForChecks ?? []
            engine.tickCostsForChecks = nil
            let mean = ticks.isEmpty ? 0 : ticks.reduce(0, +) / Double(ticks.count)
            return (ticks.count, mean, ticks.max() ?? 0)
        }
        settle(0.5)
        let baseline = measureTicks()
        check.note(String(format: "ticks with FILE/TC off: %d, mean %.1f ms, worst %.1f ms",
                          baseline.count, baseline.mean, baseline.worst))
        for (_, body) in composites {
            for key in VBOptionButton.all(in: body) where ["FILE", "TC"].contains(key.title) {
                key.sendAction(key.action, to: key.target)
            }
        }
        settle(0.5)
        let loaded = measureTicks()
        check.record(AssertionResult(
            name: "FILE + TC on all three monitors keeps the worst tick under 25 ms",
            passed: loaded.count > 0 && loaded.worst < 25,
            detail: String(format: "%d ticks, mean %.1f ms (%.1f off), worst %.1f ms (%.1f off)",
                           loaded.count, loaded.mean, baseline.mean, loaded.worst, baseline.worst)))
        capture(window, "file-tc-all-monitors", check)
        for (_, body) in composites {
            for key in VBOptionButton.all(in: body) where key.isOn && ["FILE", "TC"].contains(key.title) {
                key.sendAction(key.action, to: key.target)
            }
        }

        // ── A hovered source: its transport ───────────────────────────────────
        for letter in ["A", "B", "C", "D"] {
            guard let body = panels.sourceBodies[letter] else { continue }
            hover(body, in: window, entering: true)
            settle(0.3)
            capture(window, "source-\(letter.lowercased())-hover", check)
            // Every control on the hovered picture must be whole inside it and clear
            // of every other — compared by what is DRAWN (alignment rects), not by
            // frames, which include a push button's invisible bezel margin.
            let controls = Self.controls(in: body).filter { !$0.isHiddenOrHasHiddenAncestor }
            let frames = controls.map { $0.convert($0.alignmentRect(forFrame: $0.bounds), to: body) }
            let area = body.preview.frame.insetBy(dx: -0.5, dy: -0.5)
            var problems: [String] = []
            for (index, frame) in frames.enumerated() {
                let name = Self.name(of: controls[index])
                if !area.contains(frame) { problems.append("\(name) outside the picture \(Self.describe(frame))") }
                for other in frames.indices where other > index
                    && frame.insetBy(dx: 0.5, dy: 0.5).intersects(frames[other]) {
                    problems.append("\(name) overlaps \(Self.name(of: controls[other]))")
                }
            }
            check.record(AssertionResult(
                name: "source \(letter): every control shows whole and unobstructed",
                passed: problems.isEmpty,
                detail: problems.isEmpty
                    ? "\(controls.count) controls in \(Self.describe(body.bounds))"
                    : problems.joined(separator: "; ")))
            hover(body, in: window, entering: false)
        }

        // ── The fill key, in each source's title bar ──────────────────────────
        //
        // Reached by a real hit-test at every one of its four titles, so the widest
        // (STRETCH, CENTRE) is proven to fit the header and to be the thing a click
        // lands on — not the header's collapse button underneath.
        for letter in ["A", "B", "C", "D"] {
            guard let body = panels.sourceBodies[letter], let content = window.contentView else { continue }
            let key = body.fillKey
            var titles: [String] = []
            var misses: [String] = []
            for _ in PreviewFill.allCases {
                shell.layoutSubtreeIfNeeded()
                let centre = key.convert(NSPoint(x: key.bounds.midX, y: key.bounds.midY), to: nil)
                let hit = content.hitTest(content.convert(centre, from: nil))
                let whole = key.frame.width >= key.intrinsicContentSize.width - 0.5
                    && (key.superview.map { $0.bounds.contains(key.frame) } ?? false)
                if hit !== key || !whole {
                    misses.append("\(key.title): hit \(hit.map { String(describing: type(of: $0)) } ?? "nothing"), "
                        + "\(Self.describe(key.frame))")
                }
                titles.append(key.title)
                key.sendAction(key.action, to: key.target)
            }
            check.record(AssertionResult(
                name: "source \(letter): the fill key is whole and clickable in the title bar at every mode",
                passed: misses.isEmpty && Set(titles).count == PreviewFill.allCases.count,
                detail: misses.isEmpty ? titles.joined(separator: " → ") : misses.joined(separator: "; ")))
        }
        capture(window, "fill-keys-in-headers", check)

        // ── Every asset-browser tab, and the list and column views ─────────────
        if let tabs = Self.segmented(in: browserBody) {
            for (index, tab) in AssetTab.allCases.enumerated() {
                tabs.selectedSegment = index
                tabs.sendAction(tabs.action, to: tabs.target)
                settle(0.4)
                capture(window, "browser-\(tab.rawValue)", check)
            }
            if let clips = AssetTab.allCases.firstIndex(of: .clips) {
                tabs.selectedSegment = clips
                tabs.sendAction(tabs.action, to: tabs.target)
            }
        }
        if let styles = Self.first(VBSlideToggle.self, in: browserBody) {
            for (index, style) in LibraryViewStyle.allCases.enumerated().reversed() {
                styles.selectedIndex = index
                styles.sendAction(styles.action, to: styles.target)
                settle(0.4)
                capture(window, "browser-view-\(style)", check)
            }
        }

        // ── Diagonal Blur, live, on the A/B chain ─────────────────────────────
        //
        // The Vidvox file that drew full-frame noise: its accumulator was an
        // uninitialised local. A flat test pattern blurred must stay clean.
        let chainPanel = panels.effectsOneBody
        if let addMenu = Self.all(NSPopUpButton.self, in: chainPanel)
            .first(where: { $0.identifier?.rawValue == "fx-add" }),
           addMenu.itemArray.contains(where: { $0.title == "Diagonal Blur" }) {
            addMenu.selectItem(withTitle: "Diagonal Blur")
            _ = addMenu.target?.perform(addMenu.action, with: addMenu)
            settle(3)
            let toggle = Self.all(NSSwitch.self, in: chainPanel)
                .first(where: { $0.identifier?.rawValue == "Diagonal Blur" })
            if let toggle {
                toggle.state = .on
                toggle.sendAction(toggle.action, to: toggle.target)
            }
            if let width = VBFader.all(in: chainPanel)
                .first(where: { $0.ownerCard == "Diagonal Blur" && $0.mappingCode?.rawValue == "x:width" }) {
                width.value = 0.15
                width.sendAction(width.action, to: width.target)
            }
            settle(1)
            capture(window, "diagonal-blur-on-ab", check)
            check.note("Diagonal Blur added to the A/B chain: switch \(toggle == nil ? "missing" : "on")")
        } else {
            check.note("Diagonal Blur is not in the Add menu here; skipped")
        }

        engine.setTransportRunning(false)
        window.orderOut(nil)
        return check.finish()
    }

    // MARK: - Helpers

    /// Lets the display link run.
    private static func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Photographs this window alone, shadow excluded.
    private static func capture(_ window: NSWindow, _ name: String, _ check: SelfQACheck) {
        window.displayIfNeeded()
        settle(0.1)
        let url = check.outputDirectory.appendingPathComponent("\(name).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Log.error(.selfqa, "screencapture failed for \(name): \(error)")
        }
    }

    /// Sends the hover the tracking area would.
    private static func hover(_ view: NSView, in window: NSWindow, entering: Bool) {
        let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let event = NSEvent.enterExitEvent(
            with: entering ? .mouseEntered : .mouseExited, location: centre,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil) else { return }
        if entering { view.mouseEntered(with: event) } else { view.mouseExited(with: event) }
    }

    /// Every clickable control under `view`, not descending into controls.
    private static func controls(in view: NSView) -> [NSView] {
        if view is NSControl || view is VBOptionButton || view is VBStepButton { return [view] }
        return view.subviews.flatMap { controls(in: $0) }
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    private static func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        all(type, in: view).first
    }

    private static func segmented(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for sub in view.subviews { if let found = segmented(in: sub) { return found } }
        return nil
    }

    private static func name(of view: NSView) -> String {
        if let key = view as? VBOptionButton { return key.title.replacingOccurrences(of: "\n", with: " ") }
        if let popUp = view as? NSPopUpButton { return "popup '\(popUp.titleOfSelectedItem ?? "")'" }
        if let button = view as? NSButton {
            return button.title.isEmpty ? "button '\(button.toolTip ?? "")'" : button.title
        }
        return String(describing: type(of: view))
    }

    /// True when a picture's mean brightness is under 6 of 255.
    private static func isBlack(_ image: CGImage) -> Bool {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        var total = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])
        }
        return Double(total) / Double(width * height * 3) < 6
    }

    private static func describe(_ rect: CGRect) -> String {
        "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
    }
}

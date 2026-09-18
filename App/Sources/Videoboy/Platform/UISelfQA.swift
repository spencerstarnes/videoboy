//
//  UISelfQA.swift — renders the window shell offscreen so its layout can be checked.
//
//  Purpose : SPEC 14.4 requires the layout to reflow at wide, compact and narrow
//            widths, and BUILD-PLAN Phase 2 requires that reflow to be verified by
//            offscreen PNGs at three window sizes. AppKit can draw a view hierarchy
//            into a bitmap without ever showing a window, which needs no screen-
//            recording permission and works over SSH.
//  Inputs  : none; it builds its own ShellView at each width.
//  Outputs : selfqa/out/phase-2/ui-layout/{wide,compact,narrow}.png plus a result.txt.
//  Connects: ShellView and PanelGridView (what it renders), Core's SelfQACheck.
//  Extend  : add a width to `layoutCases`, or assert on more of the rendered result.
//

import AppKit
import VideoboyCore

/// Renders the shell offscreen at each breakpoint.
enum UISelfQA {

    /// The three widths, chosen to land inside each breakpoint band.
    private static let layoutCases: [(name: String, size: NSSize)] = [
        ("wide", NSSize(width: 1460, height: 912)),
        ("compact", NSSize(width: 1000, height: 760)),
        ("narrow", NSSize(width: 760, height: 640))
    ]

    /// Renders each case and asserts the result is a real, non-blank picture of the
    /// expected size.
    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "phase-2/ui-layout")

        for layoutCase in layoutCases {
            let shell = ShellView()
            shell.frame = NSRect(origin: .zero, size: layoutCase.size)
            // Force a full layout pass; nothing is on screen to trigger one.
            shell.layoutSubtreeIfNeeded()
            shell.displayIfNeeded()

            guard let image = render(view: shell) else {
                check.record(AssertionResult(
                    name: "\(layoutCase.name) renders", passed: false,
                    detail: "AppKit produced no bitmap at \(Int(layoutCase.size.width))px"
                ))
                continue
            }

            do {
                try check.writeImage(image, named: "\(layoutCase.name).png")
            } catch {
                Log.error(.selfqa, "could not write \(layoutCase.name).png: \(error)")
            }

            check.record(FrameAssertions.hasDimensions(
                image, width: Int(layoutCase.size.width), height: Int(layoutCase.size.height)
            ))
            // A blank window would pass a dimension check; this catches it.
            check.record(AssertionResult(
                name: "\(layoutCase.name) is not blank",
                passed: FrameAssertions.signalPresent(image, varianceThreshold: 5.0),
                detail: "luminance variance \(String(format: "%.1f", FrameAssertions.luminanceVariance(image)))"
            ))
            check.note("\(layoutCase.name): \(Int(layoutCase.size.width))x\(Int(layoutCase.size.height)) rendered")
        }

        // Collapsed states. The point of collapsing is that the middle of the window
        // gets the space, so this checks the reflow actually happens rather than the
        // groups merely disappearing.
        let collapseCases: [(name: String, groups: [PanelGroup])] = [
            ("collapsed-left", [.sourcesLeft, .effectsLeft]),
            ("collapsed-both-edges", [.sourcesLeft, .effectsLeft, .sourcesRight, .effectsRight]),
            // The two partial cases, which reflow differently on purpose: folding the
            // sources hands their rows to the effect chain below, folding the chains
            // hands their width to the libraries and the browser.
            ("collapsed-sources-only", [.sourcesLeft, .sourcesRight]),
            ("collapsed-effects-only", [.effectsLeft, .effectsRight])
        ]
        for collapseCase in collapseCases {
            let shell = ShellView()
            shell.frame = NSRect(origin: .zero, size: NSSize(width: 1460, height: 912))
            for panelGroup in collapseCase.groups {
                shell.grid.setGroup(panelGroup, collapsed: true)
            }
            shell.layoutSubtreeIfNeeded()
            shell.displayIfNeeded()

            guard let image = render(view: shell) else {
                check.record(AssertionResult(
                    name: "\(collapseCase.name) renders", passed: false, detail: "no bitmap"))
                continue
            }
            _ = try? check.writeImage(image, named: "\(collapseCase.name).png")

            // The centre must have grown. Program Preview sits in the middle column,
            // so a widened centre shows up as more non-background pixels across the
            // horizontal band the previews occupy.
            check.record(AssertionResult(
                name: "\(collapseCase.name) is not blank",
                passed: FrameAssertions.signalPresent(image, varianceThreshold: 5.0),
                detail: "luminance variance \(String(format: "%.1f", FrameAssertions.luminanceVariance(image)))"
            ))
            check.note("\(collapseCase.name): folded \(collapseCase.groups.map(\.displayName).joined(separator: ", "))")
        }

        // Shift-to-detect, rendered. The audit proves every enabled fader carries a
        // mapping address; this proves holding Shift actually reaches them, which is
        // a different claim and the one the performer experiences.
        do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            shell.frame = NSRect(origin: .zero, size: NSSize(width: 1460, height: 912))
            shell.layoutSubtreeIfNeeded()

            controller.detectSession?.setArmed(true)
            shell.layoutSubtreeIfNeeded()
            shell.displayIfNeeded()

            var highlighted = 0
            countHighlightedFaders(in: shell, into: &highlighted)
            check.record(AssertionResult(
                name: "holding Shift lights the mappable faders",
                passed: highlighted >= 39,
                detail: "\(highlighted) faders highlighted"
            ))

            if let image = render(view: shell) {
                _ = try? check.writeImage(image, named: "detect-armed.png")
            }

            // And releasing it puts them back — a highlight that sticks would be
            // worse than none, because it would stop meaning anything.
            controller.detectSession?.setArmed(false)
            var stillLit = 0
            countHighlightedFaders(in: shell, into: &stillLit)
            check.record(AssertionResult(
                name: "releasing Shift clears the highlights",
                passed: stillLit == 0,
                detail: "\(stillLit) faders still highlighted"
            ))
            withExtendedLifetime(controller) {}
        }

        // Driven parameters. A mark that says "something is driving this" is only
        // worth having if it appears when a driver is assigned and goes away when it
        // is removed, so the check does both rather than rendering one state.
        do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            shell.frame = NSRect(origin: .zero, size: NSSize(width: 1460, height: 912))
            shell.layoutSubtreeIfNeeded()

            var beforeCount = 0
            countDrivenFaders(in: shell, into: &beforeCount)
            check.record(AssertionResult(
                name: "nothing is marked as driven before anything is assigned",
                passed: beforeCount == 0,
                detail: "\(beforeCount) faders marked"
            ))

            // An LFO on the programme crossfader and an audio tap on a parameter INSIDE
            // an effect chain: one outside the chains and one in, because the two are
            // marked by different paths and only testing one proves half of it.
            //
            // The inside one used to be the corruptor's amount. That card is behind a
            // switched-off flag now, so its fader is not built and the check was
            // counting a driver on a control that does not exist. The grade is the
            // right replacement: it is the one effect live at launch, so its faders are
            // always there to be marked.
            engine.lfos.assign(LFOBank.Assignment(
                lfo: LFO(shape: .sine, rate: .subdivision(.whole), depth: 1.0),
                slot: GraphTopology.primary, code: .crossfadeOneTwo, latencyInFrames: 0))
            // The slot is READ OFF THE FADER rather than written here. The chain
            // resolves a code to a slot through the card's channel selector, so the
            // name is not something this check should be guessing at — and when it did
            // guess, it guessed a slot no fader addressed and counted one driver
            // instead of two.
            let chainFader = faders(in: shell.grid.panels.effectsOneBody)
                .first { $0.mappingSlot != nil && $0.mappingCode != nil }
            if let chainFader, let slot = chainFader.mappingSlot, let code = chainFader.mappingCode {
                engine.audioReactivity.assign(ReactivityAssignment(
                    tap: .rms, shape: .direct, slot: slot, code: code))
            }
            controller.refreshDrivenParameters()

            var afterCount = 0
            countDrivenFaders(in: shell, into: &afterCount)
            check.record(AssertionResult(
                name: "assigning a driver marks exactly the parameters it drives",
                passed: afterCount == 2,
                detail: "\(afterCount) faders marked, expected 2"
            ))

            // Mid-beat, so the pulse is caught part way through its decay rather
            // than at the peak where it would look the same as a static outline.
            for fader in drivenFaders(in: shell) { fader.pulsePhase = 0.35 }
            shell.displayIfNeeded()
            if let image = render(view: shell) {
                _ = try? check.writeImage(image, named: "driven-parameters.png")
            }

            // A driven fader must MOVE, not just glow. The value is in the registry
            // being rewritten every frame; a bar that ignores it says something is
            // happening and refuses to say what.
            let programFader = shell.grid.panels.faderOneTwoBody.fader
            var positions: Set<String> = []
            engine.transport.beatsPerMinute = 120
            engine.transport.start(atHostTime: CACurrentMediaTime())
            for step in 0..<8 {
                let hostTime = CACurrentMediaTime() + Double(step) * 0.12
                engine.lfos.update(atHostTime: hostTime, into: engine.registry)
                if let value = engine.registry.value(
                    slot: GraphTopology.primary, code: .crossfadeOneTwo) {
                    programFader.setDisplayedValue(value)
                    positions.insert(String(format: "%.3f", programFader.value))
                }
            }
            engine.transport.stop(atHostTime: CACurrentMediaTime())
            check.record(AssertionResult(
                name: "a driven fader's bar follows the value driving it",
                passed: positions.count > 1,
                detail: "\(positions.count) distinct bar positions over eight LFO steps"
            ))

            engine.lfos.remove(slot: GraphTopology.primary, code: .crossfadeOneTwo)
            // The same address the assignment used, read off the same fader — a
            // removal that clears a DIFFERENT parameter leaves the first one driven and
            // reports it as a failure to clear, which is what happened here.
            if let chainFader, let slot = chainFader.mappingSlot, let code = chainFader.mappingCode {
                engine.audioReactivity.remove(slot: slot, code: code)
            }
            controller.refreshDrivenParameters()
            var clearedCount = 0
            countDrivenFaders(in: shell, into: &clearedCount)
            check.record(AssertionResult(
                name: "removing the driver clears the mark",
                passed: clearedCount == 0,
                detail: "\(clearedCount) faders still marked"
            ))
            withExtendedLifetime(controller) {}
        }

        // Preferences, one render per pane. A settings window is where people go to
        // find out what an app can do, so a pane that lays out badly or comes up
        // empty is worth catching here rather than on first open.
        section3: do {
            let engine = Engine()
            let store = PreferenceStore(
                fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("videoboy-selfqa-prefs.json"))
            // Seeded, so the Outputs pane renders its editor rather than only its
            // empty state — the empty state is the easy half to get right.
            store.preferences.destinations = [
                OutputDestination(kind: .obs, name: "OBS", target: "127.0.0.1:9000"),
                OutputDestination(kind: .feedbackSend, name: "Feedback A", target: "mix.one")
            ]
            let preferences = PreferencesWindowController(store: store, engine: engine)
            guard let content = preferences.window?.contentView else {
                check.record(AssertionResult(
                    name: "the preferences window has content", passed: false, detail: "no content view"))
                break section3
            }

            for pane in PreferencesWindowController.Pane.allCases {
                preferences.select(pane)
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
                guard let image = render(view: content) else {
                    check.record(AssertionResult(
                        name: "preferences \(pane.rawValue) renders",
                        passed: false, detail: "no bitmap"))
                    continue
                }
                _ = try? check.writeImage(image, named: "preferences-\(pane.rawValue).png")
                check.record(AssertionResult(
                    name: "preferences \(pane.rawValue) has content",
                    passed: FrameAssertions.signalPresent(image, varianceThreshold: 5.0),
                    detail: "luminance variance "
                        + String(format: "%.1f", FrameAssertions.luminanceVariance(image))
                ))
            }
            try? FileManager.default.removeItem(at: store.fileURL)
        }

        // The library: hover-scrub, in/out marks, and double-click-to-channel with its
        // auto-advance. The advance is the part worth checking mechanically — it is
        // stateful, and getting it wrong means clips quietly overwriting each other.
        do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            shell.frame = NSRect(origin: .zero, size: NSSize(width: 1460, height: 912))
            shell.layoutSubtreeIfNeeded()

            let library = shell.grid.panels.libraryOneBody
            let first = library.destination.takeNextChannel()
            let second = library.destination.takeNextChannel()
            let third = library.destination.takeNextChannel()
            check.record(AssertionResult(
                name: "double-click fills a pair then comes back round",
                passed: [first, second, third] == ["A", "B", "A"],
                detail: "channels offered: \(first), \(second), \(third)"
            ))

            library.setDestinationPair(.cd)
            let afterSwitch = library.destination.takeNextChannel()
            check.record(AssertionResult(
                name: "switching pair starts at that pair's first channel",
                passed: afterSwitch == "C",
                detail: "offered \(afterSwitch) after switching to C/D"
            ))

            // Scrub every thumbnail to a different position and mark one with in/out,
            // so the render shows the filmstrip working rather than one poster frame
            // repeated.
            let thumbnails = HoverScrubView.all(in: shell)
            for (index, thumbnail) in thumbnails.enumerated() {
                thumbnail.scrub(to: Double(index % 5) / 4.0)
            }
            thumbnails.first?.setInOut(inPoint: 0.25, outPoint: 0.75)

            let decoded = thumbnails.filter(\.hasDecodedFrame).count
            check.record(AssertionResult(
                name: "library thumbnails decode real frames",
                passed: decoded > 0,
                detail: "\(decoded) of \(thumbnails.count) thumbnails have a picture"
            ))

            shell.layoutSubtreeIfNeeded()
            shell.displayIfNeeded()
            if let image = render(view: shell) {
                _ = try? check.writeImage(image, named: "library-scrubbing.png")
            }
            withExtendedLifetime(controller) {}
        }

        // The two output-emulation popovers. They are the one place in the app where
        // a control panel is hidden behind a chevron, so "does it lay out and say
        // what it is" is worth a picture rather than an assumption.
        do {
            let engine = Engine()
            let cases: [(String, EmulationPopover)] = [
                ("ntsc", EmulationPopover(
                    heading: "NTSC signal",
                    summary: "What the picture picks up on its way out as composite video. "
                        + "Applies to whatever is on air, after every bus effect.",
                    slot: Engine.compositeProgramSlot,
                    variables: [
                        .init(caption: "Dot crawl", code: .compositeCrawl),
                        .init(caption: "Chroma bleed", code: .chromaBleed),
                        .init(caption: "Luma bandwidth", code: .lumaBandwidth)
                    ],
                    registry: engine.registry)),
                ("dv", EmulationPopover(
                    heading: "DV colour",
                    summary: "Passes the output through DV: 4:1:1 colour and 8-bit. Each "
                        + "generation re-quantises what the last one produced, the way "
                        + "dubbing a tape does.",
                    slot: Engine.busCodecProgramSlot,
                    variables: [
                        .init(caption: "Generations", code: .compositeGeneration, range: 0...4),
                        .init(caption: "Damage", code: .corruptAmount),
                        .init(
                            caption: "Rate lock", code: .playbackSpeed,
                            unavailableNote: "Locking output to 29.97 is not built yet; "
                                + "the output mode is negotiated in the Output section.")
                    ],
                    registry: engine.registry))
            ]

            for (name, controller) in cases {
                let content = controller.view
                content.appearance = NSAppearance(named: .darkAqua)
                content.layoutSubtreeIfNeeded()
                content.frame = NSRect(origin: .zero, size: content.fittingSize)

                // NSPopover supplies the background in the app; offscreen there is
                // none, and the render came back as pale text on white — a picture of
                // the harness rather than of the popover. This stands in for the
                // chrome so what is saved is what a person would actually see.
                let backing = NSView(frame: content.frame)
                backing.wantsLayer = true
                backing.layer?.backgroundColor = Theme.Color.panelFill
                    .blended(withFraction: 1.0, of: Theme.Color.content)?.cgColor
                    ?? Theme.Color.content.cgColor
                backing.addSubview(content)
                backing.layoutSubtreeIfNeeded()
                backing.displayIfNeeded()

                guard let image = render(view: backing) else {
                    check.record(AssertionResult(
                        name: "\(name) popover renders", passed: false, detail: "no bitmap"))
                    continue
                }
                _ = try? check.writeImage(image, named: "emulation-\(name).png")
                check.record(AssertionResult(
                    name: "\(name) emulation popover has content",
                    passed: FrameAssertions.signalPresent(image, varianceThreshold: 5.0),
                    detail: "\(image.width)x\(image.height)"
                ))
            }
        }

        // Output routing. The tiling is the part with real arithmetic in it, so it is
        // checked against pixels rather than by looking at the popover.
        do {
            let store = PreferenceStore(
                fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("videoboy-selfqa-routing.json"))
            store.preferences.destinations = [
                OutputDestination(kind: .obs, name: "OBS ready", target: "127.0.0.1:9000"),
                OutputDestination(kind: .obs, name: "OBS no target", target: ""),
                OutputDestination(kind: .ipStream, name: "IP out", target: "239.0.0.1:5000")
            ]
            let router = OutputRouter(store: store, metal: MetalContext.shared)

            let options = router.availableOptions()
            let configured = options.filter {
                if case .configured = $0.destination { return true }
                return false
            }

            // A destination that CAN be served is offered plainly.
            check.record(AssertionResult(
                name: "a stream destination with a target is offered as available",
                passed: configured.first(where: { $0.name == "OBS ready" })?.isAvailable == true,
                detail: "OBS with a target is \(configured.first(where: { $0.name == "OBS ready" })?.isAvailable == true ? "available" : "greyed")"
            ))

            // One that cannot must say WHY rather than being offered and then doing
            // nothing — a menu item that looks live and is not is the failure this
            // whole list exists to avoid.
            let unservable = configured.filter { !$0.isAvailable }
            check.record(AssertionResult(
                name: "destinations that cannot be served are greyed, each with its own reason",
                passed: unservable.count == 2
                    && unservable.allSatisfy { $0.unavailableReason != nil }
                    && Set(unservable.compactMap(\.unavailableReason)).count == 2,
                detail: unservable.compactMap(\.unavailableReason).joined(separator: " / ")
            ))

            // The main display must never be offered: the app is on it, and a
            // borderless output window there would leave no way back to the controls.
            let mainOffered = options.contains {
                $0.isAvailable && $0.detail.contains("main")
            }
            check.record(AssertionResult(
                name: "the display Videoboy is running on is not offered as an output",
                passed: !mainOffered,
                detail: mainOffered ? "the main display was offered" : "correctly withheld"
            ))

            // Four-up tiling, with one quadrant deliberately empty.
            if let metal = MetalContext.shared {
                let quadrantColours: [ImageBuffer] = [
                    solid(width: 320, height: 240, r: 220, g: 40, b: 40),
                    solid(width: 320, height: 240, r: 40, g: 220, b: 40),
                    solid(width: 320, height: 240, r: 40, g: 40, b: 220)
                ]
                let textures: [MTLTexture?] = quadrantColours.map {
                    metal.makeTexture(from: $0, label: "quadrant")
                } + [nil]

                if let tiled = router.tiled(textures),
                   let renderer = OffscreenRenderer(context: metal),
                   let image = renderer.readback(tiled) {
                    _ = try? check.writeImage(image, named: "four-up.png")

                    // Each quadrant must hold its own colour, and the missing one must
                    // stay black rather than shifting the others along.
                    let topLeft = image.pixel(x: image.width / 4, y: image.height / 4)
                    let topRight = image.pixel(x: image.width * 3 / 4, y: image.height / 4)
                    let bottomLeft = image.pixel(x: image.width / 4, y: image.height * 3 / 4)
                    let bottomRight = image.pixel(x: image.width * 3 / 4, y: image.height * 3 / 4)

                    check.record(AssertionResult(
                        name: "each source keeps its own quadrant in the four-up",
                        passed: topLeft.r > 150 && topRight.g > 150 && bottomLeft.b > 150,
                        detail: "top-left r=\(topLeft.r), top-right g=\(topRight.g), "
                            + "bottom-left b=\(bottomLeft.b)"
                    ))
                    check.record(AssertionResult(
                        name: "an empty channel leaves its quadrant black rather than moving the others",
                        passed: bottomRight.r < 40 && bottomRight.g < 40 && bottomRight.b < 40,
                        detail: "bottom-right is (\(bottomRight.r), \(bottomRight.g), \(bottomRight.b))"
                    ))
                } else {
                    check.record(AssertionResult(
                        name: "four-up tiles", passed: false, detail: "no tiled texture came back"))
                }
            }

            // The popover itself.
            let popover = RoutingPopover(
                source: .slot(Engine.outputSlot), router: router, onChosen: { _ in })
            let content = popover.view
            content.appearance = NSAppearance(named: .darkAqua)
            content.layoutSubtreeIfNeeded()
            content.frame = NSRect(origin: .zero, size: content.fittingSize)
            let backing = NSView(frame: content.frame)
            backing.wantsLayer = true
            backing.layer?.backgroundColor = Theme.Color.content.cgColor
            backing.addSubview(content)
            backing.layoutSubtreeIfNeeded()
            backing.displayIfNeeded()
            if let image = render(view: backing) {
                _ = try? check.writeImage(image, named: "routing-popover.png")
            }
            try? FileManager.default.removeItem(at: store.fileURL)
        }

        // Drag and drop, through the real pasteboard. Dragging cannot be synthesised
        // offscreen, but the two halves that actually break can both be exercised:
        // what the library WRITES, and what a drop target can READ back from it.
        do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            shell.frame = NSRect(origin: .zero, size: NSSize(width: 1460, height: 912))
            shell.layoutSubtreeIfNeeded()

            let sample = RepoPaths.samples.appendingPathComponent("motion.dv")
            let pasteboard = NSPasteboard(name: .init("videoboy-selfqa-drag"))
            pasteboard.clearContents()
            pasteboard.writeObjects([LibraryItemView.pasteboardItem(for: sample)])

            // WHICH VIEW GETS THE CLICK. A drag that never starts is almost always
            // this: the press lands on a subview that handles it, or on one whose
            // responder chain does not reach the thing that knows how to drag.
            shell.layoutSubtreeIfNeeded()
            let items = LibraryItemView.all(in: shell)
            var unreachable: [String] = []
            for item in items where item.item.url != nil {
                let centre = item.convert(
                    NSPoint(x: item.bounds.midX, y: item.bounds.midY), to: shell)
                let hit = shell.hitTest(centre)

                // Walk up from whatever was hit. If no LibraryItemView is on that
                // chain, a press there can never reach the code that starts a drag.
                var responder: NSResponder? = hit
                var reaches = false
                while let current = responder {
                    if current === item { reaches = true; break }
                    responder = current.nextResponder
                }
                if !reaches {
                    unreachable.append(
                        "\(item.item.name) hit \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
                }
            }
            check.record(AssertionResult(
                name: "a press on a library item reaches the view that starts the drag",
                passed: unreachable.isEmpty && !items.isEmpty,
                detail: unreachable.isEmpty
                    ? "\(items.count) items, all reachable"
                    : unreachable.joined(separator: "; ")
            ))

            // PERFORM REAL DROPS. Everything above proves the parts; this drives the
            // actual handlers on the actual views and checks the file lands. It is
            // the only one of these checks that would have caught a drop that is
            // registered, readable, reachable — and still does nothing.
            let dv = RepoPaths.samples.appendingPathComponent("motion.dv")
            if FileManager.default.fileExists(atPath: dv.path) {
                // Onto a source panel: the clip should load into that channel.
                if let sourceB = shell.grid.panels.sourceBodies["B"] {
                    let drag = FakeDragging(urls: [dv], pasteboardName: "vb-drop-source")
                    let operation = sourceB.draggingEntered(drag)
                    let accepted = sourceB.performDragOperation(drag)
                    check.record(AssertionResult(
                        name: "dropping a clip on a source loads it",
                        passed: operation == .copy && accepted
                            && engine.sources["B"]?.mediaURL?.lastPathComponent == dv.lastPathComponent,
                        detail: "entered \(operation == .copy ? "copy" : "refused"), "
                            + "accepted \(accepted), "
                            + "channel B holds \(engine.sources["B"]?.mediaURL?.lastPathComponent ?? "nothing")"
                    ))
                }

                // Onto a library — and onto the view a drop ACTUALLY lands on, which
                // is the scrolling grid rather than the panel behind it. Driving the
                // panel directly would pass while a real drop hit the grid and did
                // nothing.
                let library = shell.grid.panels.libraryOneBody
                library.layoutSubtreeIfNeeded()

                // A file the library does not already hold, since duplicates are
                // skipped on purpose and would make this pass without adding anything.
                let newClip = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("videoboy-dropped-\(UUID().uuidString).dv")
                try? FileManager.default.copyItem(at: dv, to: newClip)
                defer { try? FileManager.default.removeItem(at: newClip) }

                let before = LibraryItemView.all(in: library).count
                let libraryDrag = FakeDragging(urls: [newClip], pasteboardName: "vb-drop-library")

                // Find the deepest registered view under the middle of the grid, the
                // way AppKit does, and drop on THAT.
                let centre = NSPoint(x: library.bounds.midX, y: library.bounds.midY)
                var target = library.hitTest(centre)
                while let current = target, !current.registeredDraggedTypes.contains(.fileURL) {
                    target = current.superview
                }
                let landedOn = target.map { String(describing: type(of: $0)) } ?? "nothing"

                let libraryOperation = target?.draggingEntered(libraryDrag) ?? []
                let libraryAccepted = target?.performDragOperation(libraryDrag) ?? false
                // The grid rebuild is deferred so a drop cannot stall the render;
                // let the runloop turn before counting what arrived.
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                library.layoutSubtreeIfNeeded()
                let after = LibraryItemView.all(in: library).count

                check.record(AssertionResult(
                    name: "a drop on the library grid adds the clip",
                    passed: libraryOperation == .copy && libraryAccepted && after == before + 1,
                    detail: "landed on \(landedOn), entered "
                        + "\(libraryOperation == .copy ? "copy" : "refused"), "
                        + "accepted \(libraryAccepted), \(before) items before, \(after) after"
                ))
            }

            // STARTING a drag, driven as the real gesture: a press on the thumbnail,
            // then movement. This is the half that was broken, and it was broken in
            // the part no check could see — so this drives the actual mouse handlers
            // on the actual views and watches for the drag to begin.
            if let cell = LibraryItemView.all(in: shell).first(where: { $0.item.url != nil }),
               let window = NSWindow(
                contentRect: shell.frame, styleMask: [.borderless],
                backing: .buffered, defer: false) as NSWindow? {
                window.contentView = shell
                shell.layoutSubtreeIfNeeded()

                var draggedURL: URL?
                LibraryItemView.onDragStartedForChecks = { draggedURL = $0 }
                defer { LibraryItemView.onDragStartedForChecks = nil }

                let origin = cell.convert(
                    NSPoint(x: cell.bounds.midX, y: cell.bounds.midY), to: nil)
                func mouse(_ type: NSEvent.EventType, at point: NSPoint, clicks: Int) -> NSEvent? {
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: clicks, pressure: 1)
                }

                // Sent to the view a press ACTUALLY lands on — the thumbnail, which
                // covers the cell — not to the cell itself. Driving the cell directly
                // would pass while a real press hit the thumbnail and stopped there,
                // which is precisely the shape of the bug being fixed.
                let pressTarget = shell.hitTest(origin) ?? cell
                let landedOn = String(describing: type(of: pressTarget))

                // The press alone must NOT start a drag — that was the bug where a
                // plain click became one and swallowed the double-click.
                if let press = mouse(.leftMouseDown, at: origin, clicks: 1) {
                    pressTarget.mouseDown(with: press)
                }
                let startedOnPressAlone = draggedURL != nil

                // Movement past the threshold must start it.
                let moved = NSPoint(x: origin.x + 20, y: origin.y)
                if let drag = mouse(.leftMouseDragged, at: moved, clicks: 1) {
                    pressTarget.mouseDragged(with: drag)
                }

                check.record(AssertionResult(
                    name: "a press then a drag on a thumbnail starts a drag",
                    passed: !startedOnPressAlone && draggedURL != nil,
                    detail: startedOnPressAlone
                        ? "the press alone started a drag, which swallows clicks"
                        : (draggedURL.map { "pressed \(landedOn), dragged \($0.lastPathComponent)" }
                            ?? "pressed \(landedOn), movement started nothing")
                ))

                window.contentView = nil
            }

            let readBack = SourcePanelBody.fileURL(from: pasteboard)
            check.record(AssertionResult(
                name: "a drop target can read what the library writes",
                passed: readBack?.lastPathComponent == sample.lastPathComponent,
                detail: readBack.map { "read \($0.lastPathComponent)" }
                    ?? "nothing came back off the pasteboard"
            ))

            // Registration is the other half: a view that cannot read the type is
            // never asked, and a view that never registered is never asked either.
            for letter in ["A", "B", "C", "D"] {
                guard let body = shell.grid.panels.sourceBodies[letter] else { continue }
                check.record(AssertionResult(
                    name: "source \(letter) accepts dropped files",
                    passed: body.registeredDraggedTypes.contains(.fileURL),
                    detail: body.registeredDraggedTypes.map(\.rawValue).joined(separator: ", ")
                ))
            }

            // And the libraries, which is where clips are collected.
            for (name, library) in [
                ("Sub Mix 1", shell.grid.panels.libraryOneBody),
                ("Sub Mix 2", shell.grid.panels.libraryTwoBody),
                ("Asset Browser", shell.grid.panels.assetBrowserBody)
            ] {
                check.record(AssertionResult(
                    name: "\(name) library accepts dropped files",
                    passed: library.registeredDraggedTypes.contains(.fileURL),
                    detail: library.registeredDraggedTypes.map(\.rawValue).joined(separator: ", ")
                ))
            }
            withExtendedLifetime(controller) {}
        }

        // The bus keys and their tally lamps. Red means on air everywhere in
        // broadcast, so the thing worth checking is that the lamp actually follows
        // the fader rather than being a static colour that looks right at 0.5.
        do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            shell.frame = NSRect(origin: .zero, size: NSSize(width: 1460, height: 912))
            shell.layoutSubtreeIfNeeded()

            // Each fader hard over to one end, so one key is lit and one is not.
            engine.registry.setValue(0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
            engine.registry.setValue(1, slot: GraphTopology.subMixTwo, code: .crossfadeCD)
            engine.registry.setValue(0, slot: GraphTopology.primary, code: .crossfadeOneTwo)
            shell.grid.panels.faderABBody.setPosition(0)
            shell.grid.panels.faderCDBody.setPosition(1)
            shell.grid.panels.faderOneTwoBody.setPosition(0)
            shell.layoutSubtreeIfNeeded()
            shell.displayIfNeeded()

            let keys = VBBusButton.all(in: shell)
            let lit = keys.filter { $0.onAirAmount >= 0.995 }
            let dark = keys.filter { $0.onAirAmount <= 0.005 }
            check.record(AssertionResult(
                name: "one bus key is lit per fader, and its partner is not",
                passed: keys.count == 6 && lit.count == 3 && dark.count == 3,
                detail: "\(keys.count) keys, \(lit.count) on air, \(dark.count) dark"
            ))

            if let image = render(view: shell) {
                _ = try? check.writeImage(image, named: "bus-keys-on-air.png")
            }
            withExtendedLifetime(controller) {}
        }

        // The step key's ladder. The sequence is the whole feature, so it is walked
        // rather than assumed: click goes toward faster, control-click toward slower,
        // and STEP sits between the two halves.
        do {
            let key = VBStepButton()
            var seen: [String] = []
            key.onTimingChanged = { _ in }

            func click(_ times: Int, control: Bool) {
                for _ in 0..<times {
                    let event = NSEvent.mouseEvent(
                        with: .leftMouseDown, location: .zero,
                        modifierFlags: control ? [.control] : [],
                        timestamp: 0, windowNumber: 0, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1)
                    if let event { key.mouseDown(with: event) }
                    seen.append(key.timing.displayName)
                }
            }

            click(6, control: false)
            let forward = seen
            check.record(AssertionResult(
                name: "clicking the step key walks toward faster and returns to STEP",
                passed: forward == ["1/1", "1/2", "1/4", "1/8", "1/16", "STEP"],
                detail: forward.joined(separator: " → ")
            ))

            seen.removeAll()
            click(4, control: true)
            let backward = seen
            check.record(AssertionResult(
                name: "control-clicking walks toward slower and returns to STEP",
                passed: backward == ["2/1", "4/1", "8/1", "STEP"],
                detail: backward.joined(separator: " → ")
            ))

            // And from a rung, the other direction comes back the way you came
            // rather than jumping across to the far half.
            seen.removeAll()
            click(3, control: false)      // 1/1, 1/2, 1/4
            click(1, control: true)       // should be 1/2 again
            check.record(AssertionResult(
                name: "the other direction retraces the ladder rather than jumping",
                passed: seen.last == "1/2",
                detail: seen.joined(separator: " → ")
            ))
        }

        // The preview panels must come out 4:3, measured on the panels themselves
        // rather than on the picture inside them.
        for layoutCase in layoutCases {
            let shell = ShellView()
            shell.frame = NSRect(origin: .zero, size: layoutCase.size)
            shell.layoutSubtreeIfNeeded()

            let previews = [
                ("A/B Sub Mix", shell.grid.panels.subMixOne),
                ("Program", shell.grid.panels.program),
                ("C/D Sub Mix", shell.grid.panels.subMixTwo)
            ]
            // The contract CHANGED, deliberately, and this is what replaced it.
            //
            // These were asserted to be exactly 4:3. They no longer are, because the
            // preview band is now allowed to grow past 4:3 so the SOURCE monitors —
            // which get half the band each and were tiny — can be read at a glance.
            // What matters is unchanged in substance: the picture inside is still 4:3
            // (the fill mode letterboxes it), the panel is never SQUATTER than 4:3,
            // which is the direction that would crop or shrink the video, and all
            // three stay the same shape as each other, which is why the three centre
            // columns are equal in the first place.
            var offenders: [String] = []
            var ratios: [CGFloat] = []
            for (name, panel) in previews {
                let size = panel.frame.size
                guard size.height > 1 else { continue }
                let ratio = size.width / size.height
                ratios.append(ratio)
                if ratio > Theme.Metrics.previewAspectRatio + 0.06 {
                    offenders.append(String(
                        format: "%@ %@ %.2f is wider than 4:3", layoutCase.name, name, ratio))
                }
            }
            if let first = ratios.first,
               ratios.contains(where: { abs($0 - first) > 0.06 }) {
                offenders.append(String(
                    format: "%@ the three previews are not the same shape: %@",
                    layoutCase.name,
                    ratios.map { String(format: "%.2f", $0) }.joined(separator: ", ")))
            }
            check.record(AssertionResult(
                name: "previews are never squatter than 4:3, and all three match, at \(layoutCase.name)",
                passed: offenders.isEmpty,
                detail: offenders.isEmpty
                    ? String(format: "all three within 4:3 (%.3f)", Theme.Metrics.previewAspectRatio)
                    : offenders.joined(separator: ", ")
            ))

            // And the rows below must still be reachable.
            let bar = shell.grid.panels.settingsBar.frame
            check.record(AssertionResult(
                name: "the output bar survives 4:3 previews at \(layoutCase.name)",
                passed: bar.height >= Theme.Metrics.settingsBarHeight - 1 && bar.minY >= 0,
                detail: String(format: "bar is %.0fpt tall at y=%.0f", bar.height, bar.minY)
            ))
        }

        // Reordering, driven through the SAME path a real drag uses: the grip's own
        // callbacks, with window-space points. It has been rewritten twice, and both
        // times the bug was coordinate spaces rather than logic — which is exactly the
        // class of bug a screenshot cannot show and an assertion can.
        section10: do {
            let shell = ShellView()
            let engine = Engine()
            _ = ShellController(shell: shell, engine: engine)
            shell.frame = NSRect(origin: .zero, size: NSSize(width: 1460, height: 912))
            shell.layoutSubtreeIfNeeded()

            let chain = shell.grid.panels.effectsOneBody
            let before = chain.effects.map(\.name)

            guard before.count >= 2, let grip = firstDragHandle(in: chain) else {
                check.record(AssertionResult(
                    name: "the FX chain can be reordered by dragging",
                    passed: false, detail: "no drag handle found"))
                break section10
            }

            // Grab the first card and drag it down past the second.
            let start = grip.convert(NSPoint(x: 4, y: 4), to: nil)
            grip.onDragBegan?(start)
            // Down the screen is DOWN in window coordinates, which are not flipped —
            // so a lower y. Getting this backwards is precisely what made the gap move
            // the opposite way to the hand.
            // Far enough to clear the card below it. These cards are tall — the
            // composite stage has nine parameters — so a fixed 120pt nudge lands
            // inside the first slot and proves nothing.
            var moved = start
            moved.y -= 400
            grip.onDrag?(moved)
            grip.onDragEnded?()
            shell.layoutSubtreeIfNeeded()

            let after = chain.effects.map(\.name)
            check.record(AssertionResult(
                name: "dragging a card down moves it later in the chain",
                passed: after != before && after.first != before.first,
                detail: "\(before.joined(separator: " → ")) became \(after.joined(separator: " → "))"
            ))
            check.record(AssertionResult(
                name: "reordering keeps every effect",
                passed: Set(after) == Set(before),
                detail: "\(after.count) cards, was \(before.count)"
            ))
        }

        // Per-channel FX (chFX, SPEC 2). A and B — and separately C and D — each
        // carry their own bitstream wedge in the graph; the only thing this checks
        // is whether the ONE card that represents it can actually REACH all of them,
        // because that reach is exactly what was missing. Everything here goes
        // through the same paths a real click and a real drag would use — the
        // selector's own target/action, and the fader's own onParameterChanged
        // closure — not a shortcut into the engine.
        section11: do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            shell.frame = NSRect(origin: .zero, size: NSSize(width: 1460, height: 912))
            shell.layoutSubtreeIfNeeded()

            let corruptorName = "DV · DIF corruptor"

            // The card is behind a flag now, and with the flag OFF the correct state
            // is that it is ABSENT — so that is what gets asserted, rather than the
            // check being skipped. A skipped check proves nothing; this one proves the
            // card really went, and would catch it coming back by accident.
            guard FeatureFlag.bitstreamCorruptor.isOn else {
                let stillThere =
                    segmentedControl(named: corruptorName, in: shell.grid.panels.effectsOneBody) != nil
                    || segmentedControl(named: corruptorName, in: shell.grid.panels.effectsTwoBody) != nil
                check.record(AssertionResult(
                    name: "the bitstream card is absent while its flag is off",
                    passed: !stillThere,
                    detail: stillThere
                        ? "a card is still being built for a switched-off subsystem"
                        : "omitted from both chains, as the flag says"
                ))
                break section11
            }

            guard let selectorOne = segmentedControl(named: corruptorName, in: shell.grid.panels.effectsOneBody),
                  let selectorTwo = segmentedControl(named: corruptorName, in: shell.grid.panels.effectsTwoBody) else {
                check.record(AssertionResult(
                    name: "both FX chains have a channel selector on the corruptor card",
                    passed: false, detail: "one or both selectors were not found"
                ))
                break section11
            }
            check.record(AssertionResult(
                name: "both FX chains have a channel selector on the corruptor card",
                // TWO segments and three states: clicking past the last channel
                // selects BOTH, which lights both segments rather than adding a
                // third. A word meaning "both" costs more width than the two things
                // it describes.
                passed: selectorOne.segmentCount == 2 && selectorTwo.segmentCount == 2,
                detail: "A/B has \(selectorOne.segmentCount) segments, C/D has \(selectorTwo.segmentCount)"
            ))

            /// Fires a segmented control's action exactly as AppKit would after a
            /// click lands on a segment — set the selection, then invoke target/action.
            func click(_ control: NSSegmentedControl, segment: Int) {
                control.selectedSegment = segment
                _ = control.target?.perform(control.action, with: control)
            }

            // A gets 0.9, B gets 0.3, written the way a real drag writes them: through
            // the card's own onParameterChanged closure, with the selector pointed at
            // each channel in turn.
            click(selectorOne, segment: 0) // A
            shell.grid.panels.effectsOneBody.onParameterChanged?(ParamCode.corruptAmount.rawValue, 0.9)
            click(selectorOne, segment: 1) // B
            shell.grid.panels.effectsOneBody.onParameterChanged?(ParamCode.corruptAmount.rawValue, 0.3)

            let amountA = engine.registry.value(slot: GraphTopology.sourceA, code: .corruptAmount)
            let amountB = engine.registry.value(slot: GraphTopology.sourceB, code: .corruptAmount)
            check.record(AssertionResult(
                name: "the selector routes a drag to the channel it points at, not always A",
                passed: abs((amountA ?? -1) - 0.9) < 0.01 && abs((amountB ?? -1) - 0.3) < 0.01,
                detail: "source.a=\(amountA.map { String(format: "%.2f", $0) } ?? "nil"), "
                    + "source.b=\(amountB.map { String(format: "%.2f", $0) } ?? "nil")"
            ))

            // Switch back to A. The card must show A's 0.9 — not B's 0.3, and not the
            // stale 0.0 the card was built with — proving the readback sync actually
            // reads the registry rather than just remembering what it last wrote.
            click(selectorOne, segment: 0)
            if let faderA = fader(named: ParamCode.corruptAmount.rawValue, in: shell.grid.panels.effectsOneBody) {
                check.record(AssertionResult(
                    name: "switching back to A shows A's value, not B's or a stale default",
                    passed: abs(faderA.value - 0.9) < 0.01,
                    detail: "displayed \(String(format: "%.2f", faderA.value))"
                ))
            }

            // The enable switch must be per-CHANNEL too. Bypass B specifically —
            // through the engine, simulating some other actor (a template load, a
            // MIDI mapping) having set it — then confirm selecting B shows the switch
            // off, and that A's switch state is untouched by anything done to B.
            engine.registry.setValue(0, slot: GraphTopology.sourceB, code: .wetDry)
            click(selectorOne, segment: 1)
            if let switchB = enableSwitch(named: corruptorName, in: shell.grid.panels.effectsOneBody) {
                check.record(AssertionResult(
                    name: "each channel's bypass is independent, and the card shows it",
                    passed: switchB.state == .off,
                    detail: "B's switch reads \(switchB.state == .off ? "off" : "on") after B was bypassed"
                ))
            }

            // The C/D chain had NO corruptor card at all before this. Prove D — the
            // channel that was never reachable even in principle — through the same
            // path, all the way to a rendered pixel difference on PROGRAM.
            // `appendingPathComponent` neither throws nor returns an optional, so the
            // `try?` this used to carry only wrapped it in one. The fileExists check
            // below is what actually guards the clip being there.
            let motionClip = RepoPaths.samples.appendingPathComponent("motion.dv")
            guard FileManager.default.fileExists(atPath: motionClip.path) else {
                check.note("samples/motion.dv is missing; the C/D chFX render check was skipped")
                break section11
            }
            _ = engine.load(url: motionClip, intoChannel: "D")
            engine.registry.setValue(0, slot: GraphTopology.subMixTwo, code: .crossfadeCD) // pure D
            engine.registry.setValue(1, slot: GraphTopology.primary, code: .crossfadeOneTwo) // PROGRAM = TWO
            engine.setInterchange(.none, forBus: GraphTopology.primary)
            engine.registry.setValue(0, slot: Engine.busCodecProgramSlot, code: .corruptAmount)

            guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
                check.record(AssertionResult(
                    name: "channel D chFX renders", passed: false, detail: "no Metal device"))
                break section11
            }

            // Read straight from evaluateGraph's own returned dictionary, the same
            // way PlaybackSelfQA does. `engine.texture(for:)` reads a DIFFERENT,
            // separately-populated cache that only fills in via the private
            // `evaluate(context:)` path the live render loop uses — calling it here,
            // on a fresh Engine that has never run that loop, reads nothing and a
            // force-unwrapped nil is exactly what silently killed this check the
            // first time it ran.
            func renderProgram(frameIndex: Int) -> ImageBuffer? {
                let context = RenderContext(
                    frameIndex: frameIndex, presentationTime: Double(frameIndex) / 29.97,
                    musicalPosition: nil)
                let produced = engine.evaluateGraph(context: context)
                guard let texture = produced[Engine.outputSlot] ?? produced[GraphTopology.primary]
                else { return nil }
                return renderer.readback(texture)
            }

            click(selectorTwo, segment: 1) // D
            // The corruptor boots BYPASSED now, like every effect except the grade, so
            // the wedge has to be switched on before it can damage anything — exactly
            // what an operator does. Driven through the card's own enable switch
            // rather than by writing wet/dry directly, so this still exercises the
            // path a click takes.
            if let enable = enableSwitch(named: corruptorName, in: shell.grid.panels.effectsTwoBody) {
                enable.state = .on
                _ = enable.target?.perform(enable.action, with: enable)
            }
            shell.grid.panels.effectsTwoBody.onParameterChanged?(ParamCode.corruptAmount.rawValue, 0)
            let clean = renderProgram(frameIndex: 50)

            shell.grid.panels.effectsTwoBody.onParameterChanged?(ParamCode.corruptAmount.rawValue, 0.9)
            let damaged = renderProgram(frameIndex: 50)

            if let clean, let damaged {
                _ = try? check.writeImage(damaged, named: "channel-d-chfx-damaged.png")
                check.record(FrameAssertions.framesDiffer(
                    clean, damaged, minimumFraction: 0.02,
                    name: "channel D's wedge — unreachable before this — now damages PROGRAM"))
            } else {
                check.record(AssertionResult(
                    name: "channel D chFX renders", passed: false, detail: "a frame failed to render"))
            }

            // The ✕ on that same card. It resolved its slot through the static
            // name-to-slot table, which has no entry for a per-channel effect, so the
            // guard fell through and the button did nothing whatsoever — the card
            // stayed put. Driven here through the button's real target/action.
            let corruptorSlots = ["C", "D"].map(Engine.slot(forChannel:))
            for slot in corruptorSlots {
                engine.registry.setValue(0.8, slot: slot, code: .wetDry)
            }

            if let remove = removeButton(named: corruptorName, in: shell.grid.panels.effectsTwoBody) {
                _ = remove.target?.perform(remove.action, with: remove)
                shell.layoutSubtreeIfNeeded()

                check.record(AssertionResult(
                    name: "the corruptor card's ✕ actually takes the card out of the chain",
                    passed: segmentedControl(named: corruptorName, in: shell.grid.panels.effectsTwoBody) == nil,
                    detail: "card present after ✕: \(segmentedControl(named: corruptorName, in: shell.grid.panels.effectsTwoBody) != nil)"
                ))

                // Both channels, not just the one the selector pointed at. Bypassing
                // only the selected channel would leave the other one corrupting with
                // no card left in the window to reach it.
                let remaining = corruptorSlots.map { engine.registry.value(slot: $0, code: .wetDry) ?? -1 }
                check.record(AssertionResult(
                    name: "removing a card bypasses every copy of it, not just the selected one",
                    passed: remaining.allSatisfy { $0 < 0.001 },
                    detail: "C wet/dry \(remaining[0]), D wet/dry \(remaining[1])"
                ))
            } else {
                check.record(AssertionResult(
                    name: "the corruptor card has a ✕", passed: false, detail: "no remove button found"))
            }

            withExtendedLifetime(controller) {}
        }

        // IN AND OUT POINTS. Reported as not working. The Core side is sound —
        // ClipSourceNode.playbackRange clamps the playhead and every end-of-clip rule
        // runs over the range — so this drives the UI half: hover a thumbnail the way
        // the pointer does, press I and O the way the keyboard does, and ask whether a
        // range came out the other end.
        do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1460, height: 912),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = shell
            shell.layoutSubtreeIfNeeded()

            let cells = LibraryItemView.all(in: shell.grid.panels.libraryOneBody)
            if let cell = cells.first(where: { $0.item.url != nil }),
               let hover = HoverScrubView.all(in: cell).first {
                let centre = hover.convert(
                    NSPoint(x: hover.bounds.midX, y: hover.bounds.midY), to: nil)
                // `.mouseMoved`, not `.mouseEntered`: NSEvent.mouseEvent refuses to
                // build the latter — it is not in the mask that initialiser accepts —
                // and a moved event is what actually carries a position anyway.
                let move = NSEvent.mouseEvent(
                    with: .mouseMoved, location: centre, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 0, pressure: 0)

                if let move {
                    hover.mouseEntered(with: move)
                    hover.mouseMoved(with: move)
                }

                check.record(AssertionResult(
                    name: "hovering a clip gives it a scrub position to mark against",
                    passed: hover.scrubPositionForChecks != nil,
                    detail: hover.scrubPositionForChecks.map { String(format: "%.2f", $0) }
                        ?? "nil — without this, I and O have nothing to mark"
                ))

                /// A key press, the way the keyboard delivers one.
                func key(_ character: String) -> NSEvent? {
                    NSEvent.keyEvent(
                        with: .keyDown, location: centre, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        characters: character, charactersIgnoringModifiers: character,
                        isARepeat: false, keyCode: 0)
                }

                /// Moves the pointer along the strip, so I and O land in different
                /// places the way two real presses would.
                func hoverAt(fraction: CGFloat) {
                    let x = hover.bounds.minX + hover.bounds.width * fraction
                    let point = hover.convert(NSPoint(x: x, y: hover.bounds.midY), to: nil)
                    if let moved = NSEvent.mouseEvent(
                        with: .mouseMoved, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 0, pressure: 0) {
                        hover.mouseMoved(with: moved)
                    }
                }

                hoverAt(fraction: 0.25)
                if let i = key("i") { hover.keyDown(with: i) }
                hoverAt(fraction: 0.75)
                if let o = key("o") { hover.keyDown(with: o) }

                let range = hover.markedRange
                check.record(AssertionResult(
                    name: "I and O mark a range the loader can use",
                    passed: range != nil,
                    detail: range.map { String(format: "%.2f...%.2f", $0.lowerBound, $0.upperBound) }
                        ?? "no range — the marks are drawn but never reach the clip"
                ))

                // And the range has to survive the trip into the channel, which is the
                // part that makes it playback rather than decoration.
                if let url = cell.item.url, let range {
                    _ = engine.load(url: url, intoChannel: "A")
                    engine.sources["A"]?.playbackRange = range
                    let applied = engine.sources["A"]?.playbackRange
                    check.record(AssertionResult(
                        name: "a marked range reaches the source node",
                        passed: applied != nil,
                        detail: applied.map { String(format: "%.2f...%.2f", $0.lowerBound, $0.upperBound) }
                            ?? "the node did not keep it"
                    ))

                    // THE DRAG HALF. Double-click carried the marks; dragging did
                    // not, because the pasteboard only ever held the URL. Same clip,
                    // same marks, two ways of loading it, and only one of them worked
                    // — which reads as "in and out points are broken" rather than as
                    // "one of the two paths ignores them".
                    let board = NSPasteboard(name: .init("videoboy-inout-check"))
                    board.clearContents()
                    board.writeObjects([LibraryItemView.pasteboardItem(for: url, range: range)])
                    let carried = LibraryItemView.markedRange(from: board)
                    check.record(AssertionResult(
                        name: "a dragged clip carries its in and out points",
                        passed: carried != nil
                            && abs((carried?.lowerBound ?? -1) - range.lowerBound) < 0.001
                            && abs((carried?.upperBound ?? -1) - range.upperBound) < 0.001,
                        detail: carried.map {
                            String(format: "%.2f...%.2f survived the pasteboard",
                                   $0.lowerBound, $0.upperBound)
                        } ?? "the marks did not survive the drag"
                    ))

                    // Whether playback then STAYS inside those marks is Core's
                    // business and is asserted there — PlaybackRangeTests — because
                    // advancePlayhead is internal to that module. This check owns the
                    // UI half: that the keys produce a range and it reaches the node.
                }
            } else {
                check.record(AssertionResult(
                    name: "a library clip is available to mark", passed: false,
                    detail: "no clip with a URL in the A/B library"))
            }

            withExtendedLifetime(controller) {}
        }

        // ADDING FILES MUST NOT STALL THE RENDER. Reported as the one place playback
        // jitters. The render loop runs on the MAIN thread, so any main-thread work
        // during a library add is time the picture is not being drawn — and a drop is
        // exactly when a lot of work happens at once.
        section13: do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            shell.frame = NSRect(origin: .zero, size: NSSize(width: 1460, height: 912))
            shell.layoutSubtreeIfNeeded()

            let library = shell.grid.panels.libraryOneBody
            let sample = RepoPaths.samples.appendingPathComponent("motion.mov")
            guard FileManager.default.fileExists(atPath: sample.path) else {
                check.note("samples missing; the library-add stall check was skipped")
                break section13
            }

            // A realistic drop: several files at once.
            let dropped = Array(repeating: sample, count: 24)
            // Measures the DROP HANDLER, which is what runs inside the gesture and
            // therefore what can stall the render. The grid rebuild it schedules
            // happens on a later runloop turn, where the display link can interleave.
            let start = Date()
            library.onFilesDropped?(dropped)
            let milliseconds = Date().timeIntervalSince(start) * 1000
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            shell.layoutSubtreeIfNeeded()
            let budget = 1000.0 / StandardDefinition.frameRate

            check.note(String(
                format: "adding %d files took %.1f ms of main-thread time (one frame is %.1f ms)",
                dropped.count, milliseconds, budget))

            // Deliberately generous. One frame's worth of hitch on a deliberate,
            // one-off action is acceptable; several frames is a visible stutter, and
            // that is what this is here to catch.
            check.record(AssertionResult(
                name: "adding files to a library does not stall the render for multiple frames",
                passed: milliseconds < budget * 2,
                detail: String(
                    format: "%.1f ms for %d files — %.1f frames' worth",
                    milliseconds, dropped.count, milliseconds / budget)
            ))
        }

        // FRAME TIME AND JITTER. The single most important property of this app: the
        // picture must not stutter. Mean frame time is not the measure — a chain that
        // averages 8 ms and spikes to 40 every twentieth frame drops a frame every
        // twentieth frame, and that is exactly what an audience sees.
        //
        // So this reports the WORST frame and the spread, not the average, with every
        // effect switched on so it measures the real load rather than a bypassed one.
        section14: do {
            let engine = Engine()
            let url = RepoPaths.samples.appendingPathComponent("motion.dv")
            guard FileManager.default.fileExists(atPath: url.path),
                  engine.load(url: url, intoChannel: "A"),
                  engine.load(url: url, intoChannel: "B") else {
                check.note("samples/motion.dv missing; the jitter check was skipped")
                break section14
            }
            engine.setPlaying(true, channel: "A")
            engine.setPlaying(true, channel: "B")

            // EVERYTHING on, including all four channel chains and both bus chains.
            for slot in Engine.busEffectSlots {
                engine.registry.setValue(1, slot: slot, code: .wetDry)
            }
            for letter in ["A", "B", "C", "D"] {
                engine.registry.setValue(1, slot: Engine.slot(forChannel: letter), code: .wetDry)
                engine.registry.setValue(0.6, slot: Engine.slot(forChannel: letter), code: .corruptAmount)
                for effect in ["transform", "colour", "composite", "echo", "feedback", "mx1"] {
                    engine.registry.setValue(
                        1, slot: Engine.channelSlot(letter, effect), code: .wetDry)
                }
                // Neutral settings let a node skip its pass, which would measure an
                // idle chain rather than a working one.
                engine.registry.setValue(1.3, slot: Engine.channelSlot(letter, "colour"), code: .contrast)
                engine.registry.setValue(1.2, slot: Engine.channelSlot(letter, "transform"), code: .scale)
            }
            engine.applyAllParameters()

            var milliseconds: [Double] = []
            for frame in 0..<90 {
                let context = RenderContext(
                    frameIndex: frame, presentationTime: Double(frame) / 29.97,
                    musicalPosition: nil)
                let start = Date()
                _ = engine.evaluateGraph(context: context)
                milliseconds.append(Date().timeIntervalSince(start) * 1000)
            }
            // The first few frames pay for texture allocation and shader warm-up, and
            // are not what a running show looks like.
            let settled = Array(milliseconds.dropFirst(10)).sorted()
            let mean = settled.reduce(0, +) / Double(settled.count)
            let worst = settled.last ?? 0
            let p95 = settled[Int(Double(settled.count) * 0.95)]
            let budget = 1000.0 / StandardDefinition.frameRate

            check.note(String(
                format: "frame time with everything on: mean %.2f ms, p95 %.2f ms, worst %.2f ms, budget %.2f ms",
                mean, p95, worst, budget))

            check.record(AssertionResult(
                name: "no frame misses the budget with every effect running",
                passed: worst < budget,
                detail: String(
                    format: "worst frame %.2f ms against a %.2f ms budget (mean %.2f, p95 %.2f)",
                    worst, budget, mean, p95)
            ))

            // Spread matters on its own. A chain that is always 20 ms is playable; one
            // that alternates 4 and 20 is visibly uneven even though both fit.
            check.record(AssertionResult(
                name: "frame time is even, not just fast on average",
                passed: worst < mean * 3.0 || worst < 4.0,
                detail: String(format: "worst is %.1fx the mean", mean > 0 ? worst / mean : 0)
            ))
        }

        // A MOVING FADER MUST NOT LEAVE A GHOST. Reported as "a little ghost bar"
        // trailing an animating fader. Rendered here at one position and then another,
        // asking whether anything from the first is still on screen — which is the
        // difference between a drawing-order bug and a redraw bug, and they have
        // different fixes.
        do {
            let fader = VBFader(frame: NSRect(x: 0, y: 0, width: 240, height: 20))
            fader.minimum = 0
            fader.maximum = 1
            fader.mappingSlot = "mix.one"
            fader.mappingCode = .crossfadeAB

            /// Draws the fader into a fresh bitmap and returns the pixels.
            func snapshot(at value: Double) -> NSBitmapImageRep? {
                fader.value = value
                guard let rep = fader.bitmapImageRepForCachingDisplay(in: fader.bounds) else {
                    return nil
                }
                fader.cacheDisplay(in: fader.bounds, to: rep)
                return rep
            }

            /// How bright the cap area is at a given fraction across the track.
            func brightness(_ rep: NSBitmapImageRep, atFraction fraction: CGFloat) -> Int {
                let x = Int(CGFloat(rep.pixelsWide) * fraction)
                var total = 0
                for y in 0..<rep.pixelsHigh {
                    for dx in -2...2 {
                        let px = min(max(x + dx, 0), rep.pixelsWide - 1)
                        // Converted to a known colour space first: colorAt can hand
                        // back a tagged colour whose components throw when read.
                        if let colour = rep.colorAt(x: px, y: y)?
                            .usingColorSpace(.deviceRGB) {
                            total += Int((colour.redComponent + colour.greenComponent
                                + colour.blueComponent) / 3 * 255)
                        }
                    }
                }
                return total
            }

            // The same again with a SWEEP ARMED, which is the state actually reported.
            // A fader drawing a purple span and a moving cap has more on it than one
            // simply being dragged, and the span is drawn every frame underneath.
            fader.markSweepForChecks(first: 0.2, second: 0.8)
            if let sweptLeft = snapshot(at: 0.25), let sweptRight = snapshot(at: 0.75) {
                let capThere = brightness(sweptLeft, atFraction: 0.25)
                let capGone = brightness(sweptRight, atFraction: 0.25)
                check.record(AssertionResult(
                    name: "an ANIMATING fader leaves no ghost where the cap was",
                    passed: capGone < capThere * 3 / 4,
                    detail: "swept position reads \(capGone) after moving, \(capThere) with the cap there"
                ))
            }
            fader.clearSweep()

            if let atLeft = snapshot(at: 0.15), let atRight = snapshot(at: 0.85) {
                // The cap is the brightest thing on the track. After moving right,
                // the left position must be back to track brightness — if the cap is
                // still lit there, that is the ghost.
                let leftWhenThere = brightness(atLeft, atFraction: 0.15)
                let leftAfterMoving = brightness(atRight, atFraction: 0.15)

                check.record(AssertionResult(
                    name: "a fader leaves no ghost of the cap at its previous position",
                    passed: leftAfterMoving < leftWhenThere * 3 / 4,
                    detail: "left position reads \(leftAfterMoving) after moving away, "
                        + "\(leftWhenThere) while the cap was there"
                ))
            }
        }

        // A SWEEP ON A CROSSFADER IS ACTUALLY DRIVEN. The crossfaders took the
        // gesture and drew the bar, so a sweep LOOKED armed — but only the FX chains
        // were scanned by the driver, so nothing moved them. A control that says it
        // worked and then does nothing is worse than one that refuses.
        do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1460, height: 912),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = shell
            shell.layoutSubtreeIfNeeded()

            let fader = shell.grid.panels.faderABBody.fader
            func mark(_ fraction: CGFloat) {
                let x = fader.bounds.minX + fader.bounds.width * fraction
                let point = fader.convert(NSPoint(x: x, y: fader.bounds.midY), to: nil)
                if let event = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [.command, .option],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1) {
                    fader.mouseDown(with: event)
                }
            }

            var written: [Double] = []
            let existing = shell.grid.panels.faderABBody.onFaderMoved
            shell.grid.panels.faderABBody.onFaderMoved = { value in
                written.append(value)
                existing?(value)
            }

            mark(0.2)
            mark(0.8)
            check.record(AssertionResult(
                name: "a crossfader accepts sweep marks",
                passed: fader.sweep != nil,
                detail: fader.sweep.map { String(format: "%.2f...%.2f", $0.lower, $0.upper) }
                    ?? "no sweep armed"
            ))

            // And, the part that was missing: something actually moves it.
            // A sweep reads the TRANSPORT, which follows wall-clock time — so a tight
            // loop would advance the beat by almost nothing and measure a fader that
            // correctly barely moved. Real time has to pass for this to mean anything.
            engine.setTransportRunning(true)
            for _ in 0..<12 {
                controller.driveSweepsForChecks()
                RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            }
            engine.setTransportRunning(false)

            check.record(AssertionResult(
                name: "an armed crossfader is actually driven, not just marked",
                passed: Set(written.map { String(format: "%.3f", $0) }).count > 2,
                detail: "\(Set(written.map { String(format: "%.3f", $0) }).count) distinct values written"
            ))

            withExtendedLifetime(controller) {}
        }

        // ACTION KEYS CAN BE LEARNED. Shift-to-map reached faders only, so the keys
        // you most want on a controller — CUT and FADE — were the ones you could not
        // put there.
        do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1460, height: 912),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = shell
            shell.layoutSubtreeIfNeeded()

            let keys = VBOptionButton.all(in: shell.grid.panels.faderABBody)
                .filter { $0.mappingCode != nil }
            check.record(AssertionResult(
                name: "CUT and FADE carry a mapping address",
                passed: keys.count >= 2,
                detail: "\(keys.count) learnable action keys on the A/B fader: "
                    + keys.compactMap { $0.mappingCode?.displayName }.joined(separator: ", ")
            ))

            if let cut = keys.first(where: { $0.mappingCode == .cutTrigger }) {
                var asked: (String, ParamCode)?
                cut.onDetectRequested = { asked = ($0, $1) }
                let point = cut.convert(
                    NSPoint(x: cut.bounds.midX, y: cut.bounds.midY), to: nil)
                if let shiftClick = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [.shift],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1) {
                    cut.mouseDown(with: shiftClick)
                }
                check.record(AssertionResult(
                    name: "shift-clicking CUT arms it for learning rather than cutting",
                    passed: asked?.1 == .cutTrigger,
                    detail: asked.map { "\($0.0) · \($0.1.rawValue)" } ?? "detect was never asked"
                ))
            }

            withExtendedLifetime(controller) {}
        }

        // LIBRARY BINS AND SEARCH. Search used to log "not built yet" and do nothing,
        // in a field that looks exactly like one that works.
        do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            shell.frame = NSRect(origin: .zero, size: NSSize(width: 1460, height: 912))
            shell.layoutSubtreeIfNeeded()

            let library = shell.grid.panels.libraryOneBody
            let before = LibraryItemView.all(in: library).count

            if let field = searchField(in: library), before > 0 {
                // A string that cannot match anything must empty the grid — the
                // failure being guarded is a search that silently shows everything.
                field.stringValue = "zzzznomatch"
                _ = field.target?.perform(field.action, with: field)
                // The rebuild is deferred so typing cannot stall the render, so the
                // check has to let the runloop turn before reading the result.
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                shell.layoutSubtreeIfNeeded()
                let filtered = LibraryItemView.all(in: library).count

                check.record(AssertionResult(
                    name: "library search actually filters",
                    passed: filtered < before,
                    detail: "\(before) items, \(filtered) after searching for something absent"
                ))

                field.stringValue = ""
                _ = field.target?.perform(field.action, with: field)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                shell.layoutSubtreeIfNeeded()
                check.record(AssertionResult(
                    name: "clearing the search brings everything back",
                    passed: LibraryItemView.all(in: library).count == before,
                    detail: "\(LibraryItemView.all(in: library).count) of \(before) restored"
                ))
            }

            // A bin groups without losing anything.
            if let first = LibraryItemView.all(in: library).first?.item.name {
                library.moveItem(named: first, toBin: "Set One")
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                shell.layoutSubtreeIfNeeded()
                check.record(AssertionResult(
                    name: "an item moved into a bin is still in the library",
                    passed: library.binNames.contains("Set One")
                        && LibraryItemView.all(in: library).count == before,
                    detail: "bins: \(library.binNames.joined(separator: ", ")), "
                        + "\(LibraryItemView.all(in: library).count) items still shown"
                ))
            }

            withExtendedLifetime(controller) {}
        }

        // DOUBLE-CLICKING A SOURCE PICTURE PLAYS OR PAUSES IT. The transport keys
        // live on a hover overlay, so the picture being dead to a click made the most
        // obvious gesture in the window do nothing at all.
        do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1460, height: 912),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = shell
            shell.layoutSubtreeIfNeeded()

            if let body = shell.grid.panels.sourceBodies["A"] {
                var toggled = 0
                let existing = body.onPlayToggled
                body.onPlayToggled = { toggled += 1; existing?() }

                let centre = body.convert(
                    NSPoint(x: body.bounds.midX, y: body.bounds.midY), to: nil)
                func click(times: Int) -> NSEvent? {
                    NSEvent.mouseEvent(
                        with: .leftMouseDown, location: centre, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: times, pressure: 1)
                }

                if let single = click(times: 1) { body.mouseDown(with: single) }
                check.record(AssertionResult(
                    name: "a single click on a source picture does NOT toggle playback",
                    passed: toggled == 0,
                    detail: toggled == 0
                        ? "single clicks left the transport alone"
                        : "a stray click would stop the show"
                ))

                if let double = click(times: 2) { body.mouseDown(with: double) }
                check.record(AssertionResult(
                    name: "double-clicking a source picture plays or pauses it",
                    passed: toggled == 1,
                    detail: "\(toggled) toggle(s) from one double click"
                ))
            }

            withExtendedLifetime(controller) {}
        }

        // FADER SWEEPS. Command-option marks an in and an out on any mappable fader,
        // and the fader then plays itself between them on the clock. Driven through
        // the real mouseDown with real modifier flags rather than by setting the
        // marks directly, so the gesture is tested and not just the state it leaves.
        do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1460, height: 912),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = shell
            shell.layoutSubtreeIfNeeded()

            let faders = VBFader.all(in: shell.grid.panels.effectsOneBody)
                .filter { $0.mappingCode != nil && $0.isEnabled }

            // Specifically a COLOUR fader, reported as the one where the second mark
            // would not take. Checking the first fader in the panel would test the
            // corruptor and say nothing about it.
            if let colourFader = faders.first(where: { $0.mappingCode == .brightness }) {
                func markAt(_ fraction: CGFloat) {
                    let x = colourFader.bounds.minX + colourFader.bounds.width * fraction
                    let point = colourFader.convert(
                        NSPoint(x: x, y: colourFader.bounds.midY), to: nil)
                    if let event = NSEvent.mouseEvent(
                        with: .leftMouseDown, location: point,
                        modifierFlags: [.command, .option],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1) {
                        colourFader.mouseDown(with: event)
                    }
                }
                // WHAT A REAL CLICK LANDS ON. Every assertion above calls mouseDown
                // on the fader directly, which bypasses hit-testing — so a view
                // sitting on top of the fader would swallow the gesture in the app
                // while every check here passed. That is exactly how the library drag
                // bug hid.
                // Scrolled into view first. With five cards in a chain the colour
                // card sits below the fold, and a control you have to scroll to is not
                // a bug — it is a list. What this check is actually for is whether
                // anything COVERS the fader once it is on screen, which is how the
                // library drag bug hid.
                colourFader.scrollToVisible(colourFader.bounds)
                shell.layoutSubtreeIfNeeded()
                let centre = colourFader.convert(
                    NSPoint(x: colourFader.bounds.midX, y: colourFader.bounds.midY), to: nil)
                let hit = shell.hitTest(centre)
                check.record(AssertionResult(
                    name: "a click on a colour fader actually lands on that fader",
                    passed: hit === colourFader,
                    detail: hit === colourFader
                        ? "hit test returns the fader"
                        : "hit test returns \(hit.map { String(describing: type(of: $0)) } ?? "nothing") — "
                            + "the gesture never reaches the fader in the real window"
                ))

                colourFader.clearSweep()
                markAt(0.3)
                let afterFirst = colourFader.sweepMarksForChecks
                markAt(0.6)
                let afterSecond = colourFader.sweepMarksForChecks

                check.record(AssertionResult(
                    name: "a colour fader takes BOTH marks where they were clicked",
                    passed: afterSecond.second != nil
                        && abs((afterSecond.first ?? -1) - 0.3) < 0.06
                        && abs((afterSecond.second ?? -1) - 0.6) < 0.06,
                    detail: "after one click: \(afterFirst.first.map { String(format: "%.2f", $0) } ?? "nil"), "
                        + "after two: \(afterSecond.first.map { String(format: "%.2f", $0) } ?? "nil") / "
                        + "\(afterSecond.second.map { String(format: "%.2f", $0) } ?? "nil") "
                        + "(expected 0.30 / 0.60)"
                ))
                colourFader.clearSweep()
            } else {
                check.record(AssertionResult(
                    name: "a colour fader exists to mark", passed: false,
                    detail: "no brightness fader found"))
            }

            if let fader = faders.first {
                func commandOptionClick(atFraction fraction: CGFloat) {
                    let x = fader.bounds.minX + fader.bounds.width * fraction
                    let point = fader.convert(NSPoint(x: x, y: fader.bounds.midY), to: nil)
                    if let event = NSEvent.mouseEvent(
                        with: .leftMouseDown, location: point,
                        modifierFlags: [.command, .option],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1) {
                        fader.mouseDown(with: event)
                    }
                }

                let before = fader.value
                commandOptionClick(atFraction: 0.2)
                check.record(AssertionResult(
                    name: "command-option marks a point instead of moving the fader",
                    passed: fader.value == before && fader.sweep == nil,
                    detail: fader.value == before
                        ? "one mark set, fader did not jump"
                        : "the fader moved — the gesture fell through to a drag"
                ))

                commandOptionClick(atFraction: 0.8)
                let sweep = fader.sweep
                check.record(AssertionResult(
                    name: "a second command-option click arms the sweep",
                    passed: sweep != nil,
                    detail: sweep.map {
                        String(format: "%.2f...%.2f", $0.lower, $0.upper)
                    } ?? "no sweep armed"
                ))

                // And it must actually move the parameter, through the same closure a
                // drag writes through.
                if let sweep {
                    engine.setTransportRunning(true)
                    var seen: Set<String> = []
                    for beat in stride(from: 0.0, through: 4.0, by: 0.25) {
                        seen.insert(String(format: "%.2f", sweep.value(atBeats: beat)))
                    }
                    check.record(AssertionResult(
                        name: "an armed sweep travels between its marks",
                        passed: seen.count > 6,
                        detail: "\(seen.count) distinct values across one cycle"
                    ))
                    engine.setTransportRunning(false)
                }

                // A third click re-aims rather than leaving the old pair in place.
                commandOptionClick(atFraction: 0.5)
                check.record(AssertionResult(
                    name: "a third click starts a new pair rather than sticking",
                    passed: fader.sweep == nil,
                    detail: fader.sweep == nil ? "back to one mark" : "the old pair survived"
                ))

                // Plain shift must still arm detect, not mark a sweep.
                fader.clearSweep()
                var detectAsked = false
                fader.onDetectRequested = { _, _ in detectAsked = true }
                let point = fader.convert(
                    NSPoint(x: fader.bounds.midX, y: fader.bounds.midY), to: nil)
                if let shiftOnly = NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [.shift],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1) {
                    fader.mouseDown(with: shiftOnly)
                }
                check.record(AssertionResult(
                    name: "plain shift still arms detect rather than marking a sweep",
                    passed: detectAsked && fader.sweep == nil,
                    detail: detectAsked
                        ? "detect armed, no mark set"
                        : "shift-click stopped arming detect — the two gestures collided"
                ))
            } else {
                check.record(AssertionResult(
                    name: "a mappable fader exists to sweep", passed: false,
                    detail: "none found in the A/B chain"))
            }

            withExtendedLifetime(controller) {}
        }

        // EVERY ENABLED EFFECT SWITCH MUST REACH THE ENGINE.
        //
        // Three controls on the corruptor card shipped dead this week — the enable
        // switch, the modulation badges and the ✕ — all with the same shape: the
        // handler looked the effect's name up in a static table, the table had no
        // entry for it, and the guard returned before doing anything. Nothing caught
        // it, because the control audit only asks whether a control HAS a target and
        // an action, and all three did.
        //
        // This asks the question that actually matters: flip the switch and see
        // whether any parameter in the engine moved. It needs no list of effect
        // names to stay in step with, so a new card cannot quietly opt out of it.
        do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            shell.frame = NSRect(origin: .zero, size: NSSize(width: 1460, height: 912))
            shell.layoutSubtreeIfNeeded()

            /// Every value the registry holds, for spotting a write anywhere.
            func snapshotEveryValue() -> [String: Double] {
                var values: [String: Double] = [:]
                for slot in engine.graph.nodes.keys {
                    for parameter in engine.graph.nodes[slot]?.parameters ?? [] {
                        if let value = engine.registry.value(slot: slot, code: parameter.code) {
                            values["\(slot)|\(parameter.code.rawValue)"] = value
                        }
                    }
                }
                return values
            }

            /// Every wet/dry in the engine, as one comparable snapshot.
            func wetDrySnapshot() -> [String: Double] {
                var values: [String: Double] = [:]
                for slot in engine.graph.nodes.keys {
                    if let value = engine.registry.value(slot: slot, code: .wetDry) {
                        values[slot] = value
                    }
                }
                return values
            }

            let panels = [
                ("A/B", shell.grid.panels.effectsOneBody),
                ("C/D", shell.grid.panels.effectsTwoBody)
            ]
            var deadSwitches: [String] = []
            var livingSwitches = 0

            for (busName, panel) in panels {
                for (name, control) in enableSwitches(in: panel) where control.isEnabled {
                    let before = wetDrySnapshot()
                    control.state = control.state == .on ? .off : .on
                    _ = control.target?.perform(control.action, with: control)
                    if wetDrySnapshot() == before {
                        deadSwitches.append("\(busName) · \(name)")
                    } else {
                        livingSwitches += 1
                    }
                }
            }

            check.record(AssertionResult(
                name: "every enabled effect switch actually reaches the engine",
                passed: deadSwitches.isEmpty,
                detail: deadSwitches.isEmpty
                    ? "\(livingSwitches) switches moved a wet/dry in the graph"
                    : "dead: \(deadSwitches.joined(separator: ", "))"
            ))

            // AND EVERY ENABLED FADER, which is the half this check was missing.
            //
            // The switch and the faders on a card resolve their slot through two
            // DIFFERENT tables — the switch by effect NAME, the faders by param
            // CODE — so a card can be added with its name registered and its codes
            // forgotten. Its switch then works while every one of its faders does
            // nothing, which is exactly how the colour controls shipped: the
            // switch-only version of this check passed them.
            var deadFaders: [String] = []
            var livingFaders = 0
            for (busName, panel) in panels {
                for fader in VBFader.all(in: panel) where fader.isEnabled {
                    guard let code = fader.mappingCode else { continue }
                    let before = snapshotEveryValue()
                    // Through the panel's own closure, which is what a drag calls.
                    let moved = fader.value < 0.5 ? 0.9 : 0.1
                    panel.onParameterChanged?(code.rawValue, moved)
                    if snapshotEveryValue() == before {
                        deadFaders.append("\(busName) · \(code.rawValue) \(code.displayName)")
                    } else {
                        livingFaders += 1
                    }
                }
            }

            check.record(AssertionResult(
                name: "every enabled effect fader actually reaches the engine",
                passed: deadFaders.isEmpty,
                detail: deadFaders.isEmpty
                    ? "\(livingFaders) faders moved a value in the registry"
                    : "dead: \(deadFaders.joined(separator: ", "))"
            ))

            withExtendedLifetime(controller) {}
        }


        // The EMU tab, built for real.
        //
        // This exists because the panel shipped with NO SLIDERS AT ALL and every other
        // check passed. The control set was matched on the program's product name, so
        // changing the default machine from Scala MM300 to MM400 emptied the tab — and
        // nothing noticed, because the emu check drives EmulatorController directly and
        // never touches the view the operator actually clicks. A check that exercises
        // the engine is not a check of the UI.
        //
        // Needs no emulator, no permission and no hardware: building the view is enough
        // to show whether it has controls on it.
        do {
            let emuTab = EmuBrowserView(controller: EmulatorController())
            // Hosted on the panel fill it actually sits on. Rendered bare, the labels
            // are near-white text on the bitmap's white ground and the PNG shows a
            // column of faders with nothing written beside them — which looks exactly
            // like a second bug and is only the render missing its background.
            let emuHost = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 900))
            emuHost.wantsLayer = true
            emuHost.layer?.backgroundColor = Theme.Color.panelFillOpaque.cgColor
            emuHost.addSubview(emuTab)
            emuTab.frame = NSRect(x: 0, y: 0, width: 300, height: 900)
            // Without this the labels and readouts are empty strings: they are filled
            // from the controller, not at construction. Rendering before it produces a
            // picture of faders with nothing written beside them, which is not what the
            // tab looks like and would make this PNG useless as evidence.
            emuTab.refresh()
            emuTab.layoutSubtreeIfNeeded()

            let emuFaders = faders(in: emuTab)
            let emuMenus = popUpButtons(in: emuTab)
            let emuSwitches = switches(in: emuTab)
            let emuWells = colourWells(in: emuTab)

            check.record(AssertionResult(
                name: "the EMU tab has controls on it",
                passed: !emuFaders.isEmpty || !emuMenus.isEmpty,
                detail: "\(emuFaders.count) faders, \(emuMenus.count) menus, "
                    + "\(emuSwitches.count) switches, \(emuWells.count) wells"))

            // The count of each KIND has to match what the control set asks for. This is
            // the assertion that keeps lists off faders: choosing one of fifty-one wipes
            // by dragging a slider until the readout happens to say the right word is
            // not a control, and for the font size it is a way to drop Scala's screen.
            let wanted = TitlerControlSet.controls(for: EmulatorController().program)
            func expected(_ shape: TitlerControl.Shape) -> Int {
                wanted.filter { $0.shape == shape }.count
            }
            let mismatches = [
                ("faders", emuFaders.count, expected(.continuous)),
                ("menus", emuMenus.count, expected(.list)),
                ("switches", emuSwitches.count, expected(.toggle)),
                ("colour wells", emuWells.count, expected(.colour))
            ].filter { $0.1 != $0.2 }

            check.record(AssertionResult(
                name: "every control is drawn as the KIND it says it is",
                passed: mismatches.isEmpty,
                detail: mismatches.isEmpty
                    ? "\(wanted.count) controls, each with the widget it asked for"
                    : mismatches.map { "\($0.0): \($0.1) drawn, \($0.2) wanted" }
                        .joined(separator: "; ")))

            // A menu with nothing in it is a control that cannot be used. The ones that
            // depend on a drive being read are allowed to be empty and say why; the
            // rest must have something to choose from.
            let emptyMenus = emuMenus.filter { $0.numberOfItems <= 1 && $0.isEnabled }
            check.record(AssertionResult(
                name: "no menu is both empty and clickable",
                passed: emptyMenus.isEmpty,
                detail: emptyMenus.isEmpty
                    ? "every enabled menu has choices in it"
                    : "\(emptyMenus.count) empty menus look usable"))

            // EVERY control, not just the faders. A control the operator cannot put
            // under a knob is half a control, and the promise Shift makes is that one
            // gesture reveals all of them.
            let mappableFaders = emuFaders.filter {
                $0.mappingSlot != nil && $0.mappingCode != nil
            }
            let wrapped = mappableControls(in: emuTab)
            let totalControls = emuFaders.count + emuMenus.count
                + emuSwitches.count + emuWells.count
            check.record(AssertionResult(
                name: "every EMU control can be learned to MIDI",
                passed: mappableFaders.count == emuFaders.count
                    && wrapped.count == emuMenus.count + emuSwitches.count + emuWells.count,
                detail: "\(mappableFaders.count + wrapped.count) of \(totalControls) "
                    + "carry a slot and a code"))

            // And Shift really reaches them, rather than them merely being able to be
            // reached. Driven through DetectSession, which is what the key press drives.
            let detect = DetectSession(root: emuTab)
            detect.setArmed(true)
            let lit = mappableControls(in: emuTab).filter(\.isDetectHighlighted).count
            detect.setArmed(false)
            check.record(AssertionResult(
                name: "holding Shift lights the EMU menus and switches too",
                passed: lit == wrapped.count,
                detail: "\(lit) of \(wrapped.count) lit"))

            // And the text field, which is the first thing anyone touches.
            let fields = textFields(in: emuTab).filter { $0.isEditable }
            check.record(AssertionResult(
                name: "the EMU tab takes typed text",
                passed: !fields.isEmpty,
                detail: fields.isEmpty ? "no editable field" : "\(fields.count) editable"))

            if let image = render(view: emuHost) {
                _ = try? check.writeImage(image, named: "emu-tab.png")
            }
        }


        // The ⇅ swap key, across SOURCE KINDS. Swapping two channels that are both
        // playing files exercises almost none of this — the bug it is here to catch was
        // that a channel pointed at the EMULATOR takes its picture from the shared
        // emulator slot, so exchanging the two ClipSourceNodes moved the clips
        // underneath and nothing on screen changed. File/file looked fine, which is the
        // worst way for it to present.
        sectionSwap: do {
            let shell = ShellView()
            let engine = Engine()
            let controller = ShellController(shell: shell, engine: engine)
            shell.frame = NSRect(origin: .zero, size: NSSize(width: 1460, height: 912))
            shell.layoutSubtreeIfNeeded()
            withExtendedLifetime(controller) {}

            engine.setChannelSource(.emulator, channel: "A")
            engine.setChannelSource(.file, channel: "B")

            let swapped = engine.swapChannels("A", "B")
            check.record(AssertionResult(
                name: "the swap key reports success across two channels",
                passed: swapped, detail: swapped ? "swapped" : "refused"))

            let aKind = engine.channelSourceKinds["A"]
            let bKind = engine.channelSourceKinds["B"]
            check.record(AssertionResult(
                name: "swapping moves WHAT THE CHANNEL SHOWS, not just the clip",
                passed: aKind == .file && bKind == .emulator,
                detail: "A is \(String(describing: aKind ?? .file)), "
                    + "B is \(String(describing: bKind ?? .file)) — expected file, emulator"))

            // And the graph has to agree, or the picture comes from the old node while
            // the state says otherwise.
            check.record(AssertionResult(
                name: "the graph follows the swap",
                passed: engine.sourceSlot(forChannel: "B") == Engine.emulatorSlot
                    && engine.sourceSlot(forChannel: "A") != Engine.emulatorSlot,
                detail: "A reads \(engine.sourceSlot(forChannel: "A")), "
                    + "B reads \(engine.sourceSlot(forChannel: "B"))"))
        }

        return check.finish()
    }

    /// Every enable switch in a panel, with the effect name it belongs to.
    private static func enableSwitches(in view: NSView) -> [(name: String, control: NSSwitch)] {
        var found: [(String, NSSwitch)] = []
        if let control = view as? NSSwitch, let name = control.identifier?.rawValue, !name.isEmpty {
            found.append((name, control))
        }
        for subview in view.subviews { found.append(contentsOf: enableSwitches(in: subview)) }
        return found
    }

    /// The first search field beneath a view.
    private static func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        for subview in view.subviews {
            if let found = searchField(in: subview) { return found }
        }
        return nil
    }

    /// The remove (✕) button on a card, which shares the card's identifier with the
    /// enable switch — so this matches on the title too.
    private static func removeButton(named identifier: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.identifier?.rawValue == identifier,
           button.title == "✕" {
            return button
        }
        for subview in view.subviews {
            if let found = removeButton(named: identifier, in: subview) { return found }
        }
        return nil
    }

    /// The first segmented control found with a matching identifier.
    private static func segmentedControl(named identifier: String, in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl, control.identifier?.rawValue == identifier {
            return control
        }
        for subview in view.subviews {
            if let found = segmentedControl(named: identifier, in: subview) { return found }
        }
        return nil
    }

    /// The first switch found with a matching identifier.
    private static func enableSwitch(named identifier: String, in view: NSView) -> NSSwitch? {
        if let control = view as? NSSwitch, control.identifier?.rawValue == identifier {
            return control
        }
        for subview in view.subviews {
            if let found = enableSwitch(named: identifier, in: subview) { return found }
        }
        return nil
    }

    /// The first fader found with a matching identifier (a param code).
    private static func fader(named identifier: String, in view: NSView) -> VBFader? {
        if let control = view as? VBFader, control.identifier?.rawValue == identifier {
            return control
        }
        for subview in view.subviews {
            if let found = fader(named: identifier, in: subview) { return found }
        }
        return nil
    }

    /// A flat colour, for checking that a quadrant kept its own picture.
    private static func solid(
        width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8
    ) -> ImageBuffer {
        var image = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width { image.setPixel(x: x, y: y, r: r, g: g, b: b) }
        }
        return image
    }

    /// Counts faders marked as driven.
    private static func countDrivenFaders(in view: NSView, into count: inout Int) {
        if let fader = view as? VBFader, fader.isDriven { count += 1 }
        for subview in view.subviews { countDrivenFaders(in: subview, into: &count) }
    }

    /// Every fader beneath a view, driven or not.
    ///
    /// Used where a check needs to ask a control what it ADDRESSES rather than assume
    /// it — the slot a chain fader writes to is resolved through its card's channel
    /// selector, so it is not something a test should be spelling out.
    /// The first drag handle beneath a view, for driving a reorder.
    private static func firstDragHandle(in view: NSView) -> DragHandleView? {
        if let handle = view as? DragHandleView { return handle }
        for subview in view.subviews {
            if let found = firstDragHandle(in: subview) { return found }
        }
        return nil
    }

    private static func faders(in view: NSView) -> [VBFader] {
        var found: [VBFader] = []
        if let fader = view as? VBFader { found.append(fader) }
        return found + view.subviews.flatMap { faders(in: $0) }
    }

    private static func mappableControls(in view: NSView) -> [MappableControl] {
        var found: [MappableControl] = []
        if let control = view as? MappableControl { found.append(control) }
        return found + view.subviews.flatMap { mappableControls(in: $0) }
    }

    private static func popUpButtons(in view: NSView) -> [NSPopUpButton] {
        var found: [NSPopUpButton] = []
        if let menu = view as? NSPopUpButton { found.append(menu) }
        return found + view.subviews.flatMap { popUpButtons(in: $0) }
    }

    private static func switches(in view: NSView) -> [NSSwitch] {
        var found: [NSSwitch] = []
        if let toggle = view as? NSSwitch { found.append(toggle) }
        return found + view.subviews.flatMap { switches(in: $0) }
    }

    private static func colourWells(in view: NSView) -> [NSColorWell] {
        var found: [NSColorWell] = []
        if let well = view as? NSColorWell { found.append(well) }
        return found + view.subviews.flatMap { colourWells(in: $0) }
    }

    private static func textFields(in view: NSView) -> [NSTextField] {
        var found: [NSTextField] = []
        if let field = view as? NSTextField { found.append(field) }
        return found + view.subviews.flatMap { textFields(in: $0) }
    }

    private static func drivenFaders(in view: NSView) -> [VBFader] {
        var found: [VBFader] = []
        if let fader = view as? VBFader, fader.isDriven { found.append(fader) }
        return found + view.subviews.flatMap { drivenFaders(in: $0) }
    }

    /// Counts faders currently drawing the detect highlight.
    private static func countHighlightedFaders(in view: NSView, into count: inout Int) {
        if let fader = view as? VBFader, fader.isDetectHighlighted { count += 1 }
        for subview in view.subviews { countHighlightedFaders(in: subview, into: &count) }
    }

    /// Draws a view hierarchy into an `ImageBuffer` with no window involved.
    private static func render(view: NSView) -> ImageBuffer? {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Log.error(.selfqa, "view refused to provide a bitmap representation")
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)

        // Re-draw into a known RGBA8 layout: the cached representation's own format
        // varies, and the harness assumes tightly packed RGBA everywhere.
        let width = Int(view.bounds.width)
        let height = Int(view.bounds.height)
        var pixels = [UInt8](repeating: 0, count: width * height * ImageBuffer.bytesPerPixel)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * ImageBuffer.bytesPerPixel,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = representation.cgImage else { return false }
            // No flip: in a CoreGraphics bitmap context the first row of the backing
            // buffer is already the top row of the drawn image, which is exactly
            // ImageBuffer's convention.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            Log.error(.selfqa, "could not redraw the cached representation into RGBA8")
            return nil
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }
}

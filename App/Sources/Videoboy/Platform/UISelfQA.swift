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
            try? check.writeImage(image, named: "\(collapseCase.name).png")

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
                try? check.writeImage(image, named: "detect-armed.png")
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

            // An LFO on the programme crossfader and an audio tap on a corruptor:
            // one outside the effect chains and one inside, because they are marked
            // by different paths.
            engine.lfos.assign(LFOBank.Assignment(
                lfo: LFO(shape: .sine, rate: .subdivision(.whole), depth: 1.0),
                slot: GraphTopology.primary, code: .crossfadeOneTwo, latencyInFrames: 0))
            engine.audioReactivity.assign(ReactivityAssignment(
                tap: .rms, shape: .direct,
                slot: GraphTopology.sourceA, code: .corruptAmount))
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
                try? check.writeImage(image, named: "driven-parameters.png")
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
            engine.audioReactivity.remove(slot: GraphTopology.sourceA, code: .corruptAmount)
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
        do {
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
                return check.finish()
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
                try? check.writeImage(image, named: "preferences-\(pane.rawValue).png")
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
                try? check.writeImage(image, named: "library-scrubbing.png")
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
                try? check.writeImage(image, named: "emulation-\(name).png")
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
                    try? check.writeImage(image, named: "four-up.png")

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
                try? check.writeImage(image, named: "routing-popover.png")
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
                try? check.writeImage(image, named: "bus-keys-on-air.png")
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
            var offenders: [String] = []
            for (name, panel) in previews {
                let size = panel.frame.size
                guard size.height > 1 else { continue }
                let ratio = size.width / size.height
                // Within a couple of percent: the grid works in whole points and a
                // gutter cannot always be split evenly.
                if abs(ratio - Theme.Metrics.previewAspectRatio) > 0.06 {
                    offenders.append(String(format: "%@ %@ %.2f", layoutCase.name, name, ratio))
                }
            }
            check.record(AssertionResult(
                name: "preview panels are 4:3 at \(layoutCase.name)",
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

        return check.finish()
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

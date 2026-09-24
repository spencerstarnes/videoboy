//
//  AVE5SelfQA.swift — the AVE-5 wipe transition: the manual's table, the live
//  picture, and the popover a hand actually uses.
//
//  Purpose : Core's tests hold the shader to its CPU twin on flat colours. This
//            renders the operating manual's WIPE PATTERNS table (p.5) — black for A,
//            white for B, as the manual draws it — so the two can be compared by eye;
//            runs real DV through the engine's mixer; then opens the block on a real
//            fader in a real window and presses its keys through hit-testing, learns
//            a key and the positioner the Shift way, and fires a learned MIDI key and
//            a pitch bend.
//  Inputs  : samples/motion.dv and samples/bars.dv.
//  Outputs : selfqa/out/phase-4/ave5/{*.png,result.txt}.
//  Connects: AVE5Wipe, CrossfadeNode, AVE5WipePanelController, VBTransitionButton,
//            ShellController, DetectSession, ParamRegistry.
//

import AppKit
import Metal
import VideoboyCore

enum AVE5SelfQA {

    /// The table's rows, in the manual's order: the five key columns are A|B, B|A,
    /// A/B, B/A, circle.
    static let manualRows: [AVE5Wipe.PatternKeys] = {
        let r = AVE5Wipe.PatternKeys.fromRight, l = AVE5Wipe.PatternKeys.fromLeft
        let b = AVE5Wipe.PatternKeys.fromBottom, t = AVE5Wipe.PatternKeys.fromTop
        let c = AVE5Wipe.PatternKeys.circle
        return [
            r, l, b, t,
            [r, b], [l, b], [r, t], [l, t],
            [r, l], [b, t],
            [r, b, t], [l, b, t], [r, l, t], [r, l, b],
            [r, l, b, t], c,
            [r, t, c], [l, t, c], [r, b, c], [l, b, c],
            [r, c], [l, c], [b, c], [t, c],
            [r, b, t, c], [l, b, t, c], [r, l, b, c], [r, l, t, c],
            [r, l, b, t, c], [r, l, c], [b, t, c]
        ]
    }()

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "phase-4/ave5")
        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            return check.finish(blockedReason: "no Metal device is available")
        }

        // Each section is a labelled block and skips with `break`, never `return`.

        // ── 1. The manual's table ────────────────────────────────────────────────
        section1: do {
            check.record(AssertionResult(
                name: "the table has the manual's 31 rows, each a different set of keys",
                passed: manualRows.count == 31 && Set(manualRows.map(\.rawValue)).count == 31,
                detail: "\(manualRows.count) rows, \(Set(manualRows.map(\.rawValue)).count) distinct"))
            let side = (width: 160, height: 120)
            guard let black = metal.makeTexture(
                    from: ImageBuffer(width: side.width, height: side.height, r: 0, g: 0, b: 0), label: "A"),
                  let white = metal.makeTexture(
                    from: ImageBuffer(width: side.width, height: side.height, r: 235, g: 235, b: 235), label: "B")
            else {
                check.record(AssertionResult(name: "table textures", passed: false, detail: "upload failed"))
                break section1
            }
            var rows: [[ImageBuffer]] = []
            for keys in manualRows {
                var row: [ImageBuffer] = []
                for multi in AVE5Wipe.Multi.allCases {
                    let node = CrossfadeNode(identifier: "selfqa.ave5", positionCode: .crossfadeAB, context: metal)
                    node.transition = .ave5
                    node.ave5 = AVE5Wipe(keys: keys, multi: multi)
                    node.position = 0.45
                    let context = RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil,
                                                width: side.width, height: side.height)
                    if let texture = node.render(inputs: [black, white], context: context),
                       let image = renderer.readback(texture) {
                        row.append(image)
                    }
                }
                rows.append(row)
            }
            // Two sheets, as the table is split over the page: rows 1–16 and 17–31.
            if let top = contactSheet(Array(rows.prefix(16))) {
                _ = try? check.writeImage(top, named: "table-rows-01-16.png")
            }
            if let bottom = contactSheet(Array(rows.dropFirst(16))) {
                _ = try? check.writeImage(bottom, named: "table-rows-17-31.png")
            }
            check.note("table-rows-*.png: the manual's WIPE PATTERNS table (p.5), row for row — "
                + "NON MULTI, ×4, ×16 — black A, white B, at 45% of the lever")
            check.record(AssertionResult(
                name: "every row of the table rendered in all three MULTI states",
                passed: rows.count == 31 && rows.allSatisfy { $0.count == 3 },
                detail: "\(rows.map(\.count).reduce(0, +)) of 93 frames"))

            // The edge modes and REVERSE, on one circle, for the eye.
            var edges: [ImageBuffer] = []
            for block in [AVE5Wipe(keys: .circle),
                          AVE5Wipe(keys: .circle, edge: .border, backColour: .red),
                          AVE5Wipe(keys: .circle, edge: .soft),
                          AVE5Wipe(keys: .circle, reverse: true),
                          AVE5Wipe(keys: [.allEdges, .circle], positionX: 0.25, positionY: 0.3)] {
                let node = CrossfadeNode(identifier: "selfqa.ave5", positionCode: .crossfadeAB, context: metal)
                node.transition = .ave5
                node.ave5 = block
                node.position = 0.35
                let context = RenderContext(frameIndex: 0, presentationTime: 0, musicalPosition: nil,
                                            width: 360, height: 270)
                guard let big = metal.makeTexture(from: ImageBuffer(width: 360, height: 270, r: 0, g: 0, b: 0), label: "A"),
                      let bigB = metal.makeTexture(from: ImageBuffer(width: 360, height: 270, r: 235, g: 235, b: 235), label: "B"),
                      let texture = node.render(inputs: [big, bigB], context: context),
                      let image = renderer.readback(texture) else { continue }
                edges.append(image)
            }
            if let sheet = contactSheet([edges]) {
                _ = try? check.writeImage(sheet, named: "edges-normal-border-soft-reverse-positioned.png")
            }
        }

        // ── 2. Real pictures, through the engine ─────────────────────────────────
        let samples = RepoPaths.samples
        let fileA = samples.appendingPathComponent("motion.dv")
        let fileB = samples.appendingPathComponent("bars.dv")
        let haveSamples = [fileA, fileB].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        if !haveSamples {
            check.note("motion.dv / bars.dv missing — sections 2 and 3 skipped (run scripts/make-fixtures.sh)")
        }
        section2: do {
            guard haveSamples, let engine = loadedEngine(fileA: fileA, fileB: fileB, check: check) else {
                break section2
            }
            let slot = GraphTopology.subMixOne
            engine.registry.setValue(Transition.ave5.normalisedPosition, slot: slot, code: .transition)
            var index = 0
            func frame(_ block: AVE5Wipe, _ position: Double) -> ImageBuffer? {
                for (code, value) in block.parameterValues {
                    engine.registry.setValue(value, slot: slot, code: code)
                }
                engine.registry.setValue(position, slot: slot, code: .crossfadeAB)
                index += 1
                return self.frame(from: engine, renderer: renderer, index: index)
            }
            let bOnly = frame(AVE5Wipe(), 1)
            let aOnly = frame(AVE5Wipe(), 0)
            let diamond = frame(AVE5Wipe(keys: [.allEdges, .circle], edge: .border, backColour: .yellow), 0.35)
            let circles = frame(AVE5Wipe(keys: .circle, multi: .x4), 0.3)
            for (name, image) in [("live-diamond-border.png", diamond), ("live-circle-x4.png", circles)] {
                if let image { _ = try? check.writeImage(image, named: name) }
            }
            if let bOnly, let aOnly, let diamond {
                let cx = diamond.width / 2, cy = diamond.height / 2
                let centreIsB = close(diamond.pixel(x: cx, y: cy), bOnly.pixel(x: cx, y: cy))
                let cornerIsA = close(diamond.pixel(x: 6, y: 6), aOnly.pixel(x: 6, y: 6))
                check.record(AssertionResult(
                    name: "live DV: the diamond has B inside and A in the corners",
                    passed: centreIsB && cornerIsA,
                    detail: "centre is B: \(centreIsB), corner is A: \(cornerIsA)"))
            }
            // Both ends are the pure sources, through the engine, for a busy state.
            let busy = AVE5Wipe(keys: [.fromLeft, .fromTop, .circle], multi: .x16, edge: .soft,
                                reverse: true, backColour: .magenta)
            if let bOnly, let aOnly, let end = frame(busy, 1), let start = frame(busy, 0) {
                check.record(AssertionResult(
                    name: "live DV: both ends are the pure sources under a busy AVE-5 state",
                    passed: FrameAssertions.differingPixelFraction(end, bOnly) < 0.001
                        && FrameAssertions.differingPixelFraction(start, aOnly) < 0.001,
                    detail: "hard right vs B: \(FrameAssertions.differingPixelFraction(end, bOnly)), "
                        + "hard left vs A: \(FrameAssertions.differingPixelFraction(start, aOnly))"))
            }
        }

        // ── 3. The popover, in a real window ─────────────────────────────────────
        section3: do {
            guard haveSamples, let engine = loadedEngine(fileA: fileA, fileB: fileB, check: check) else {
                break section3
            }
            let shell = ShellView()
            shell.appearance = NSAppearance(named: .darkAqua)
            let controller = ShellController(shell: shell, engine: engine)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1460, height: 912),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = shell
            window.orderFrontRegardless()
            shell.layoutSubtreeIfNeeded()
            let slot = GraphTopology.subMixOne
            let panelBody = shell.grid.panels.faderABBody
            guard let key = panelBody.transitionButton else {
                check.record(AssertionResult(name: "the A/B fader has a transition key", passed: false, detail: "nil"))
                break section3
            }

            // Where every control on all three fader panels sits before the block opens.
            let faderPanels = [panelBody, shell.grid.panels.faderCDBody, shell.grid.panels.faderOneTwoBody]
            let framesBefore = faderPanels.flatMap(controlFrames(in:))

            // Choose AVE-5 through the key's own menu item, as a click does.
            let menu = key.makeMenu()
            if let item = menu.items.firstIndex(where: { $0.title == Transition.ave5.displayName }) {
                menu.performActionForItem(at: item)
            }
            let stored = engine.registry.value(slot: slot, code: .transition).map(Transition.from(normalised:))
            check.record(AssertionResult(
                name: "choosing AVE-5 on the key arms it and opens the block",
                passed: stored == .ave5 && controller.ave5Panel?.slot == slot
                    && controller.ave5Popover?.isShown == true,
                detail: "registry \(stored?.displayName ?? "nil"), panel for \(controller.ave5Panel?.slot ?? "nil"), "
                    + "shown \(controller.ave5Popover?.isShown ?? false)"))
            guard let panel = controller.ave5Panel, let popoverWindow = panel.view.window else {
                check.record(AssertionResult(name: "the block has a window", passed: false, detail: "no popover window"))
                break section3
            }
            panel.view.layoutSubtreeIfNeeded()

            let framesAfter = faderPanels.flatMap(controlFrames(in:))
            check.record(AssertionResult(
                name: "opening the block moves no control on any fader panel",
                passed: framesBefore == framesAfter,
                detail: "\(framesBefore.count) control frames compared"))

            // Press keys the way a click lands: hit-test the key's centre in the
            // popover's own window, then press whatever the hit landed on.
            func click(_ which: AVE5Wipe.Key) -> Bool {
                guard let view = panel.keyViews[which], let content = popoverWindow.contentView else { return false }
                let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                guard let hit = content.hitTest(windowPointInSuperview(centre, of: content)) as? VBAVE5Key,
                      hit === view else { return false }
                hit.press()
                return true
            }
            var reached: [String] = []
            for which: AVE5Wipe.Key in [.fromLeft, .fromTop, .fromBottom, .circle] where !click(which) {
                reached.append(which.legend)
            }
            let afterKeys = controller.ave5State(slot: slot)
            check.record(AssertionResult(
                name: "clicking A|B's partners and the circle lights all five: a diamond",
                passed: reached.isEmpty && afterKeys.keys == [.allEdges, .circle] && afterKeys.shape == .diamond
                    && panel.keyViews.filter { $0.key.patternKey != nil }.allSatisfy { $0.value.isLit },
                detail: reached.isEmpty
                    ? "keys \(afterKeys.keys.rawValue), \(afterKeys.shape.displayName)"
                    : "hit-test missed: \(reached.joined(separator: ", "))"))

            _ = click(.multi)
            _ = click(.multi)
            _ = click(.wipe)
            let cycled = controller.ave5State(slot: slot)
            check.record(AssertionResult(
                name: "MULTI twice is ×16 and WIPE once is a border — lamps and legends follow",
                passed: cycled.multi == .x16 && cycled.edge == .border
                    && panel.keyViews[.multi]?.isLit == true
                    && panel.keyViews[.multi]?.legend == .word("×16")
                    && panel.keyViews[.wipe]?.legend == .word("BORDER"),
                detail: "multi \(cycled.multi.label), edge \(cycled.edge.label)"))
            check.record(AssertionResult(
                name: "the fader key's pictogram follows the block",
                passed: key.ave5 == cycled,
                detail: "key shows \(key.ave5.shape.displayName) \(key.ave5.multi.label)"))

            // The positioner: the pad writes both axes, and the picture follows.
            panel.positioner?.move(to: (0.25, 0.3))
            let positioned = controller.ave5State(slot: slot)
            check.record(AssertionResult(
                name: "the positioner pad writes X and Y",
                passed: abs(positioned.positionX - 0.25) < 1e-9 && abs(positioned.positionY - 0.3) < 1e-9
                    && abs((panel.xFader?.value ?? 0) - 0.25) < 1e-9,
                detail: "X \(positioned.positionX), Y \(positioned.positionY)"))

            // Shift: every key in the popover and both positioner faders light, and a
            // Shift-click asks to learn the right code with the right filter.
            var requests: [(String, ParamCode, MIDIInput.DetectFilter)] = []
            controller.detectSession?.onDetectRequested = { requests.append(($0, $1, $2)) }
            controller.detectSession?.setArmed(true)
            let wrappers = mappableControls(in: panel.view)
            let lit = wrappers.filter(\.isDetectHighlighted).count
            check.record(AssertionResult(
                name: "Shift lights all ten keys in the block, and both positioner faders",
                passed: wrappers.count == 10 && lit == 10
                    && panel.xFader?.isDetectHighlighted == true && panel.yFader?.isDetectHighlighted == true,
                detail: "\(lit) of \(wrappers.count) keys; X \(panel.xFader?.isDetectHighlighted ?? false), "
                    + "Y \(panel.yFader?.isDetectHighlighted ?? false)"))
            if let circleWrapper = wrappers.first(where: { $0.mappingCode == .ave5PressCircle }),
               let event = shiftClick(at: circleWrapper, in: popoverWindow),
               let content = popoverWindow.contentView {
                content.hitTest(windowPointInSuperview(event.locationInWindow, of: content))?
                    .mouseDown(with: event)
            }
            if let x = panel.xFader, let event = shiftClick(at: x, in: popoverWindow),
               let content = popoverWindow.contentView {
                content.hitTest(windowPointInSuperview(event.locationInWindow, of: content))?
                    .mouseDown(with: event)
            }
            controller.detectSession?.setArmed(false)
            let circleRequest = requests.first { $0.1 == .ave5PressCircle }
            let xRequest = requests.first { $0.1 == .ave5PositionX }
            check.record(AssertionResult(
                name: "Shift-click learns the circle key as a note and positioner X as anything",
                passed: circleRequest?.0 == slot && circleRequest.map { filterIsNotes($0.2) } == true
                    && xRequest?.0 == slot && xRequest.map { !filterIsNotes($0.2) } == true,
                detail: requests.map { "\($0.0)/\($0.1.rawValue)" }.joined(separator: ", ")))

            // A learned MIDI key: the 6xG code goes to 1, the next tick presses once
            // and puts it back to 0.
            let beforeMIDI = controller.ave5State(slot: slot).multi
            engine.registry.setValue(1, slot: slot, code: .ave5PressMulti)
            controller.fireActionTriggersForChecks()
            let afterMIDI = controller.ave5State(slot: slot).multi
            check.record(AssertionResult(
                name: "a learned MIDI key presses MULTI once, on the edge",
                passed: beforeMIDI == .x16 && afterMIDI == .off
                    && engine.registry.value(slot: slot, code: .ave5PressMulti) == 0,
                detail: "\(beforeMIDI.label) → \(afterMIDI.label)"))

            // A keyboard joystick: pitch bend delivered through a real binding lands
            // on positioner X — and the open block shows it. (Decoding the 14-bit
            // message is Core's MIDIAndPlaybackTests; this is the path after it.)
            engine.registry.bind(ControlBinding(
                source: .midiPitchBend(channel: 0), slot: slot, code: .ave5PositionX))
            _ = engine.registry.deliver(normalisedValue: 2048.0 / 16383.0, from: .midiPitchBend(channel: 0))
            controller.fireActionTriggersForChecks()
            panel.show(controller.ave5State(slot: slot))
            let bentX = controller.ave5State(slot: slot).positionX
            check.record(AssertionResult(
                name: "pitch bend drives positioner X, and the block's fader shows it",
                passed: abs(bentX - 2048.0 / 16383.0) < 1e-6 && abs((panel.xFader?.value ?? 0) - bentX) < 1e-6,
                detail: String(format: "X %.4f", bentX)))

            // The picture follows the popover: the positioned diamond at 35%.
            engine.registry.setValue(0.35, slot: slot, code: .crossfadeAB)
            if let picture = frame(from: engine, renderer: renderer, index: 900) {
                _ = try? check.writeImage(picture, named: "ui-driven-diamond.png")
            }

            panel.view.displayIfNeeded()
            // On the dark fill a popover draws behind its content in dark mode: a
            // view cached alone is transparent, and its light print vanishes on the
            // white a PNG viewer puts behind transparency.
            if let shot = render(view: panel.view, over: NSColor(white: 0.17, alpha: 1)) {
                _ = try? check.writeImage(shot, named: "popover.png")
            }
            // The fader key armed with a range of blocks, each drawn on the panel's
            // dark fill as TransitionSelfQA draws its keys.
            var keyShots: [ImageBuffer] = []
            for block in [AVE5Wipe(), AVE5Wipe(keys: []), AVE5Wipe(keys: [.fromRight, .fromBottom]),
                          AVE5Wipe(keys: .circle), AVE5Wipe(keys: [.allEdges, .circle]),
                          AVE5Wipe(keys: [.fromRight, .fromTop, .circle]), AVE5Wipe(keys: .circle, multi: .x4),
                          AVE5Wipe(keys: [.fromRight, .circle], multi: .x16)] {
                let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
                backdrop.appearance = NSAppearance(named: .darkAqua)
                backdrop.wantsLayer = true
                backdrop.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
                let sample = VBTransitionButton(frame: NSRect(x: 5, y: 5, width: 30, height: 30))
                sample.translatesAutoresizingMaskIntoConstraints = true
                sample.transition = .ave5
                sample.ave5 = block
                backdrop.addSubview(sample)
                if let shot = render(view: backdrop) { keyShots.append(shot) }
            }
            if let strip = contactSheet([keyShots]) {
                _ = try? check.writeImage(strip, named: "key-pictograms.png")
                check.note("key-pictograms.png: the fader key armed with A|B, cut, corner box, circle, "
                    + "diamond, diagonal, circle ×4, arrow ×16")
            }

            // The key toggles the block closed; leaving AVE-5 would too.
            key.mouseDown(with: NSEvent.mouseEvent(
                with: .leftMouseDown, location: key.convert(NSPoint(x: 5, y: 5), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)!)
            check.record(AssertionResult(
                name: "clicking the key again closes the block",
                passed: controller.ave5Panel == nil,
                detail: controller.ave5Panel == nil ? "closed" : "still open"))
            window.orderOut(nil)
            withExtendedLifetime(controller) {}
        }

        return check.finish()
    }

    // MARK: - Helpers

    /// `hitTest` takes a point in the view's SUPERVIEW's coordinates. A popover's
    /// content view sits offset inside its frame view (the arrow), so converting to
    /// the content view's own coordinates lands the hit a row away.
    private static func windowPointInSuperview(_ point: NSPoint, of view: NSView) -> NSPoint {
        view.superview?.convert(point, from: nil) ?? point
    }

    private static func filterIsNotes(_ filter: MIDIInput.DetectFilter) -> Bool {
        if case .notesOnly = filter { return true }
        return false
    }

    /// A Shift-modified left click at the centre of a view, addressed to a window.
    private static func shiftClick(at view: NSView, in window: NSWindow) -> NSEvent? {
        let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return NSEvent.mouseEvent(
            with: .leftMouseDown, location: centre, modifierFlags: [.shift],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    private static func mappableControls(in view: NSView) -> [MappableControl] {
        ((view as? MappableControl).map { [$0] } ?? []) + view.subviews.flatMap { mappableControls(in: $0) }
    }

    /// Every control's frame in window coordinates, for "nothing moved".
    private static func controlFrames(in view: NSView) -> [NSRect] {
        let own = (view as? NSControl).map { [$0.convert($0.bounds, to: nil)] } ?? []
        return own + view.subviews.flatMap { controlFrames(in: $0) }
    }

    private static func loadedEngine(fileA: URL, fileB: URL, check: SelfQACheck) -> Engine? {
        let engine = Engine()
        guard engine.load(url: fileA, intoChannel: "A"), engine.load(url: fileB, intoChannel: "B") else {
            check.record(AssertionResult(name: "sources load", passed: false, detail: "a DV file failed to load"))
            return nil
        }
        for slot in Engine.busEffectSlots {
            engine.registry.setValue(0, slot: slot, code: .wetDry)
        }
        engine.registry.setValue(0.0, slot: GraphTopology.primary, code: .crossfadeOneTwo)
        return engine
    }

    private static func frame(from engine: Engine, renderer: OffscreenRenderer, index: Int) -> ImageBuffer? {
        let context = RenderContext(
            frameIndex: index, presentationTime: Double(index) / StandardDefinition.frameRate,
            musicalPosition: nil)
        guard let texture = engine.evaluateGraph(context: context)[GraphTopology.subMixOne] else { return nil }
        return renderer.readback(texture)
    }

    private static func close(
        _ a: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), _ b: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
    ) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= 6 && abs(Int(a.g) - Int(b.g)) <= 6 && abs(Int(a.b) - Int(b.b)) <= 6
    }

    /// Tiles images into a grid with a 4 px mid-grey gutter (grey, not black, so a
    /// black A reads as picture and not as gutter).
    private static func contactSheet(_ rows: [[ImageBuffer]]) -> ImageBuffer? {
        let gutter = 4
        let tileWidth = rows.flatMap { $0 }.map(\.width).max() ?? 0
        let tileHeight = rows.flatMap { $0 }.map(\.height).max() ?? 0
        let columns = rows.map(\.count).max() ?? 0
        guard tileWidth > 0, tileHeight > 0, columns > 0 else { return nil }
        let width = columns * tileWidth + (columns + 1) * gutter
        let height = rows.count * tileHeight + (rows.count + 1) * gutter
        var pixels = ImageBuffer(width: width, height: height, r: 110, g: 110, b: 110).pixels
        let stride = ImageBuffer.bytesPerPixel
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, tile) in row.enumerated() {
                let originX = gutter + columnIndex * (tileWidth + gutter)
                let originY = gutter + rowIndex * (tileHeight + gutter)
                for y in 0..<tile.height {
                    let source = y * tile.bytesPerRow
                    let destination = ((originY + y) * width + originX) * stride
                    pixels.replaceSubrange(
                        destination..<(destination + tile.bytesPerRow),
                        with: tile.pixels[source..<(source + tile.bytesPerRow)])
                }
            }
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }

    /// Draws a view into an `ImageBuffer` — repeated from TransitionSelfQA rather
    /// than shared (CLAUDE.md: a little duplication over the wrong abstraction).
    private static func render(view: NSView, over background: NSColor? = nil) -> ImageBuffer? {
        guard view.bounds.width >= 1, view.bounds.height >= 1,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: representation)
        let width = Int(view.bounds.width)
        let height = Int(view.bounds.height)
        var pixels = [UInt8](repeating: 0, count: width * height * ImageBuffer.bytesPerPixel)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * ImageBuffer.bytesPerPixel, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let image = representation.cgImage else { return false }
            if let background {
                context.setFillColor(background.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? ImageBuffer(width: width, height: height, pixels: pixels) : nil
    }
}

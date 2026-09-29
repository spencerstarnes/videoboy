//
//  ISFSelfQA.swift — ISF modules, end to end, in the real window.
//
//  Purpose : Proves the ISF host is usable from the FX panel the way a performer uses
//            it, not just in Core: a shader file becomes a card from the Add menu, its
//            faders move the picture, its card can be dragged and the GRAPH follows,
//            MIDI reaches a runtime `x:` code, a saved edit reloads live, a broken
//            save keeps the last good version, a new file appears without a relaunch,
//            an ISF generator can be a channel's source, and ✕ takes a card out.
//  Inputs  : fixture shaders written to temporary folders (the operator's ISF
//            library is never touched); the real built-ins; samples/bars.dv.
//  Outputs : selfqa/out/isf/app/{result.txt, *.png}.
//  Connects: MainWindowController (given an Engine whose ModuleCatalog points at
//            the temporary folders), the FX panel, ShellController, Engine.
//  Extend  : a new ISF behaviour is one more step and one more assertion.
//
//  Clicks are real events sent through the window (so hit-testing and first-click
//  delivery are tested) wherever AppKit allows. The Add menu is a pop-up menu, which
//  runs its own modal tracking loop; it is driven by selecting the item and firing
//  the control's action — the exact call a completed click makes.
//

import AppKit
import VideoboyCore

enum ISFSelfQA {

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "isf/app")
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("videoboy-isf-qa-\(UUID().uuidString)")
        let user = root.appendingPathComponent("Videoboy ISF", isDirectory: true)
        let shared = root.appendingPathComponent("Shared ISF", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        do {
            for folder in [user, shared] { try fileManager.createDirectory(at: folder, withIntermediateDirectories: true) }
            try invert(body: "mix(c.rgb, 1.0 - c.rgb, amount)").write(to: user.appendingPathComponent("QA Invert.fs"), atomically: true, encoding: .utf8)
            try stripes.write(to: user.appendingPathComponent("QA Stripes.fs"), atomically: true, encoding: .utf8)
            try "this is not a shader".write(to: shared.appendingPathComponent("QA Broken.fs"), atomically: true, encoding: .utf8)
        } catch {
            return check.finish(blockedReason: "could not write fixtures: \(error)")
        }

        let catalog = ModuleCatalog(folders: [(ISFLibrary.builtinFolder, .builtin), (user, .user), (shared, .shared)])
        let engine = Engine(catalog: catalog)
        let store = PreferenceStore(fileURL: root.appendingPathComponent("prefs.json"))
        let controller = MainWindowController(preferences: store, engine: engine)
        guard let window = controller.window, let screen = NSScreen.main,
              let shell = window.contentView as? ShellView else {
            return check.finish(blockedReason: "no window, screen or shell")
        }
        window.setFrame(screen.visibleFrame.insetBy(dx: 40, dy: 40), display: true)
        controller.showWindow(nil)
        let bars = RepoPaths.samples.appendingPathComponent("bars.dv")
        guard engine.load(url: bars, intoChannel: "A") else { return check.finish(blockedReason: "samples/bars.dv would not load") }
        engine.registry.setValue(0, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        pump(1)

        let panel = shell.grid.panels.effectsOneBody
        // This check follows the card's BUS copy (the A/B sub-mix): focus MIX first, so
        // the card added below edits it (a new card takes the panel's focus).
        panel.pickFocusForChecks(EffectChainPanelBody.mixFocus)
        let cardName = "QA Invert"
        let instance = "isf-qa-invert"
        let busSlot = EffectChain.slot(instanceID: instance, lane: "one")
        let amount = ParamCode.isolated(inputName: "amount")

        // 1. The Add menu lists what the folders hold, grouped, with failures greyed.
        guard let addMenu = find(NSPopUpButton.self, id: "fx-add", in: panel) else {
            return check.finish(blockedReason: "the FX panel has no Add menu")
        }
        let titles = addMenu.itemArray.map(\.title)
        let broken = addMenu.itemArray.first { $0.title == "QA Broken" }
        check.record(AssertionResult(
            name: "the Add menu offers built-ins, the imported shader by category, and the broken file greyed",
            passed: titles.contains("Built-in") && titles.contains("Colour") && titles.contains("QA Test")
                && titles.contains(cardName) && titles.contains("Failed to load (1)") && broken?.isEnabled == false
                && !titles.contains("QA Stripes"),
            detail: titles.filter { !$0.isEmpty }.joined(separator: " | ")))
        check.record(AssertionResult(
            name: "the Add menu is where a click lands", passed: hitTarget(addMenu, window) === addMenu, detail: ""))

        // 2. Choose it. Nothing already on screen may move.
        let before = cardFrames(panel)
        addMenu.selectItem(withTitle: cardName)
        _ = addMenu.target?.perform(addMenu.action, with: addMenu)
        pump(0.3)
        let after = cardFrames(panel)
        let moved = before.filter { name, frame in after[name].map { $0 != frame } ?? true }.map(\.key)
        check.record(AssertionResult(
            name: "adding a shader puts its card in the chain and moves no existing card",
            passed: engine.chains[.one]?.entry(instance) != nil && after[cardName] != nil && moved.isEmpty,
            detail: moved.isEmpty ? "cards: \(panel.effects.map(\.name).joined(separator: " → "))" : "moved: \(moved)"))
        let origin = find(NSTextField.self, id: "origin|\(cardName)", in: panel)?.stringValue
        let faders = VBFader.all(in: panel).filter { $0.ownerCard == cardName }
        check.record(AssertionResult(
            name: "the card says ISF and has a fader per input, each mappable",
            passed: origin == "ISF" && faders.map { $0.mappingCode?.rawValue ?? "" } == ["x:amount", "x:mode", "x:tint.r", "x:tint.g", "x:tint.b", "x:tint.a"]
                && faders.allSatisfy { $0.mappingSlot == busSlot },
            detail: "badge \(origin ?? "none"); faders \(faders.map { "\($0.mappingCode?.rawValue ?? "?")→\($0.mappingSlot ?? "?")" })"))

        // 3. It compiles in the background; the card says so until it is ready.
        waitFor(10) { (engine.chainNode(busSlot) as? ISFNode)?.state == .ready }
        pump(0.6)
        let status = find(NSTextField.self, id: "status|\(cardName)", in: panel)
        check.record(AssertionResult(
            name: "the shader compiles off the render path and its card stops saying 'compiling'",
            passed: (engine.chainNode(busSlot) as? ISFNode)?.state == .ready && status?.isHidden == true,
            detail: "state \(String(describing: (engine.chainNode(busSlot) as? ISFNode)?.state)), status '\(status?.stringValue ?? "")'"))

        // 4. Switch it on and push its fader, with real clicks.
        let clean = capture(engine)
        guard let toggle = find(NSSwitch.self, id: cardName, in: panel),
              let amountFader = faders.first(where: { $0.mappingCode == amount }) else {
            window.orderOut(nil)
            return check.finish(blockedReason: "the card's switch or fader is missing")
        }
        let switchHit = click(toggle, at: 0.5, window: window)
        pump(0.2)
        let faderHit = click(amountFader, at: 0.95, window: window)
        pump(0.5)
        let value = engine.registry.value(slot: busSlot, code: amount) ?? -1
        let inverted = capture(engine)
        let difference = meanDifference(clean, inverted)
        check.record(AssertionResult(
            name: "the card's switch and fader, clicked, reach the shader and invert the picture",
            passed: switchHit && faderHit && value > 0.8 && difference > 60,
            detail: String(format: "hits %@/%@, x:amount %.2f, picture changed by %.1f", switchHit ? "yes" : "no", faderHit ? "yes" : "no", value, difference)))
        if let inverted { _ = try? check.writeImage(inverted, named: "inverted.png") }

        // A long reads as its label, not a number.
        let modeReadout = find(NSTextField.self, id: "value|x:mode", in: panel)?.stringValue
        check.record(AssertionResult(
            name: "a choice input's readout says the choice", passed: modeReadout == "plain", detail: modeReadout ?? "none"))

        // 5. Drag it to the top: the GRAPH follows, and the picture changes because
        // invert-then-grade is not grade-then-invert.
        engine.registry.setValue(0.4, slot: Engine.colourSlot, code: .brightness)
        pump(0.5)
        let bottomFirst = capture(engine)
        let inputsBefore = engine.graph.inputs(of: busSlot)
        dragCard(cardName, in: panel, window: window, by: 2000)
        pump(0.5)
        let order = engine.chains[.one]?.entries.map(\.instanceID) ?? []
        let inputsAfter = engine.graph.inputs(of: busSlot)
        let topFirst = capture(engine)
        check.record(AssertionResult(
            name: "dragging the card to the top rewires the graph, and the picture follows",
            passed: order.last == instance && inputsAfter != inputsBefore && meanDifference(bottomFirst, topFirst) > 5,
            detail: "chain \(order.joined(separator: " → ")); input was \(inputsBefore), now \(inputsAfter); "
                + String(format: "picture changed by %.1f", meanDifference(bottomFirst, topFirst))))
        engine.registry.setValue(0, slot: Engine.colourSlot, code: .brightness)

        // 6. MIDI reaches the runtime code, through the registry a controller uses.
        let knob = ControlSource.midiControlChange(channel: 3, controller: 44)
        engine.registry.bind(ControlBinding(source: knob, slot: busSlot, code: amount))
        engine.registry.deliver(normalisedValue: 0.25, from: knob)
        pump(0.2)
        check.record(AssertionResult(
            name: "a MIDI mapping to an x: code moves the shader's input",
            passed: abs(((engine.chainNode(busSlot) as? ISFNode)?.value(ofInput: "amount")?.first ?? -1) - 0.25) < 0.01,
            detail: "amount \((engine.chainNode(busSlot) as? ISFNode)?.value(ofInput: "amount") ?? [])"))

        // 7. Save an edit: it reloads live, keeping the fader.
        engine.registry.setValue(1, slot: busSlot, code: amount)
        pump(0.2)
        let beforeEdit = capture(engine)
        try? invert(body: "vec3(0.0, c.g, 0.0) * amount + c.rgb * (1.0 - amount)").write(
            to: user.appendingPathComponent("QA Invert.fs"), atomically: true, encoding: .utf8)
        waitFor(10) { (engine.chainNode(busSlot) as? ISFNode)?.sourceText?.contains("c.g") == true
            && (engine.chainNode(busSlot) as? ISFNode)?.program?.document.fragmentSource.contains("c.g") == true }
        pump(0.4)
        let afterEdit = capture(engine)
        let keptValue = engine.registry.value(slot: busSlot, code: amount) ?? -1
        check.record(AssertionResult(
            name: "saving the shader reloads it live, keeping its fader",
            passed: meanDifference(beforeEdit, afterEdit) > 20 && abs(keptValue - 1) < 0.01,
            detail: String(format: "picture changed by %.1f; amount still %.2f", meanDifference(beforeEdit, afterEdit), keptValue)))
        if let afterEdit { _ = try? check.writeImage(afterEdit, named: "reloaded.png") }

        // 8. Save a broken edit: the last good version keeps running, and the card says so.
        try? invert(body: "undefined_function(c)").write(to: user.appendingPathComponent("QA Invert.fs"), atomically: true, encoding: .utf8)
        waitFor(10) { (engine.chainNode(busSlot) as? ISFNode)?.reloadProblem != nil }
        pump(0.8)
        let afterBroken = capture(engine)
        let brokenStatus = find(NSTextField.self, id: "status|\(cardName)", in: panel)
        check.record(AssertionResult(
            name: "a broken save keeps the last good version on screen and says why on the card",
            passed: meanDifference(afterEdit, afterBroken) < 2 && brokenStatus?.isHidden == false
                && (brokenStatus?.stringValue.contains("edit not applied") ?? false),
            detail: "status '\(brokenStatus?.stringValue.prefix(80) ?? "")'"))

        // 9. A file dropped into the folder appears in the Add menu without a relaunch.
        try? invert(body: "c.rgb * 0.5").replacingOccurrences(of: "QA Test", with: "QA Late Category")
            .write(to: user.appendingPathComponent("QA Late.fs"), atomically: true, encoding: .utf8)
        waitFor(10) { find(NSPopUpButton.self, id: "fx-add", in: panel)?.itemArray.contains { $0.title == "QA Late" } == true }
        check.record(AssertionResult(
            name: "a shader dropped into the folder shows up in the Add menu",
            passed: find(NSPopUpButton.self, id: "fx-add", in: panel)?.itemArray.contains { $0.title == "QA Late" } == true,
            detail: ""))

        // 10. An ISF generator as a channel's source, from the Generators tab.
        let library = shell.grid.panels.libraryOneBody
        let stripesItem = library.isfGeneratorItems.first { $0.name == "QA Stripes" }
        if let stripesItem { library.onItemOpened?(stripesItem, "A", nil) }
        waitFor(10) { engine.isfGenerators["A"]?.state == .ready }
        // Generators left the source menu for the Generators tab, so the tile must carry
        // a picture. It is rendered once the file compiles, which is asynchronous.
        waitFor(10) { library.isfGeneratorItems.first { $0.name == "QA Stripes" }?.thumbnail != nil }
        let hasThumbnail = library.isfGeneratorItems.first { $0.name == "QA Stripes" }?.thumbnail != nil
        pump(0.5)
        let generatorSlot = Engine.isfGeneratorSlot(forChannel: "A")
        let first = engine.texture(for: generatorSlot).flatMap { OffscreenRenderer()?.readback($0) }
        pump(0.5)
        let later = engine.texture(for: generatorSlot).flatMap { OffscreenRenderer()?.readback($0) }
        check.record(AssertionResult(
            name: "an ISF generator runs as channel A's source, animated, from the Generators tab",
            passed: stripesItem != nil && hasThumbnail && engine.channelSourceKinds["A"] == .isfGenerator(ModuleCatalog.ID.isf("QA Stripes"))
                && (first.map { FrameAssertions.signalPresent($0, varianceThreshold: 100) } ?? false)
                && meanDifference(first, later) > 1,
            detail: "listed \(stripesItem != nil), has thumbnail \(hasThumbnail), kind \(String(describing: engine.channelSourceKinds["A"]))"))
        if let later { _ = try? check.writeImage(later, named: "generator.png") }

        // 10b. Every tile in the Generators tab has a picture: the built-ins and the ISF files.
        let browser = shell.grid.panels.assetBrowserBody
        func segmented(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl,
               (0..<control.segmentCount).contains(where: { control.label(forSegment: $0) == "Generators" }) {
                return control
            }
            return view.subviews.lazy.compactMap { segmented(in: $0) }.first
        }
        if let tabs = segmented(in: browser),
           let index = (0..<tabs.segmentCount).first(where: { tabs.label(forSegment: $0) == "Generators" }) {
            tabs.selectedSegment = index
            _ = tabs.target?.perform(tabs.action, with: tabs)
        }
        pump(0.5)
        let tiles = HoverScrubView.all(in: browser).filter { !$0.isHiddenOrHasHiddenAncestor }
        let pictured = tiles.filter(\.hasDecodedFrame).count
        check.record(AssertionResult(
            name: "every generator tile in the Generators tab has a thumbnail",
            passed: tiles.count >= GeneratorKind.allCases.count + 1 && pictured == tiles.count,
            detail: "\(pictured) of \(tiles.count) tiles pictured"))
        browser.layoutSubtreeIfNeeded()
        if let rep = browser.bitmapImageRepForCachingDisplay(in: browser.bounds) {
            browser.cacheDisplay(in: browser.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: check.artifactURL("generators-tab.png"))
        }

        // 11. ✕ takes the card out, with every copy.
        if let remove = find(NSButton.self, id: cardName, in: panel, title: "✕") {
            _ = click(remove, at: 0.5, window: window)
            pump(0.3)
        }
        check.record(AssertionResult(
            name: "✕ removes the card and every copy of its node",
            passed: engine.chains[.one]?.entry(instance) == nil && !panel.effects.contains { $0.name == cardName }
                && EffectChain.slots(instanceID: instance, bus: .one).allSatisfy { engine.graph.nodes[$0] == nil },
            detail: "cards: \(panel.effects.map(\.name).joined(separator: ", "))"))

        window.orderOut(nil)
        return check.finish()
    }

    // MARK: - Fixtures

    /// An effect whose look is `body` (an expression of `c`, the input colour, and
    /// `amount`), with a choice and a colour input so every control type is present.
    private static func invert(body: String) -> String {
        """
        /*{
            "DESCRIPTION": "self-QA effect",
            "CATEGORIES": ["QA Test"],
            "INPUTS": [
                { "NAME": "inputImage", "TYPE": "image" },
                { "NAME": "amount", "TYPE": "float", "DEFAULT": 0.0 },
                { "NAME": "mode", "TYPE": "long", "VALUES": [0, 1], "LABELS": ["plain", "fancy"], "DEFAULT": 0 },
                { "NAME": "tint", "TYPE": "color", "DEFAULT": [1.0, 1.0, 1.0, 1.0] }
            ]
        }*/
        void main() {
            vec4 c = IMG_THIS_PIXEL(inputImage);
            gl_FragColor = vec4(\(body), c.a);
        }
        """
    }

    /// A generator: no image input, moving with TIME.
    private static let stripes = """
    /*{
        "DESCRIPTION": "self-QA generator",
        "INPUTS": [ { "NAME": "speed", "TYPE": "float", "DEFAULT": 1.3, "MAX": 10.0 } ]
    }*/
    void main() {
        float band = step(0.5, fract(isf_FragNormCoord.x * 6.0 + TIME * speed));
        gl_FragColor = vec4(band, 0.4, 1.0 - band, 1.0);
    }
    """

    // MARK: - Helpers

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private static func waitFor(_ seconds: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { pump(0.05) }
    }

    /// The bus ONE chain's finished picture, before DATA BURN.
    private static func capture(_ engine: Engine) -> ImageBuffer? {
        guard let texture = engine.texture(for: engine.busOutputSlot(.one)) else { return nil }
        return OffscreenRenderer()?.readback(texture)
    }

    private static func meanDifference(_ a: ImageBuffer?, _ b: ImageBuffer?) -> Double {
        guard let a, let b, a.width == b.width, a.height == b.height else { return 0 }
        var total = 0
        for index in stride(from: 0, to: a.pixels.count, by: 4) {
            for channel in 0..<3 { total += abs(Int(a.pixels[index + channel]) - Int(b.pixels[index + channel])) }
        }
        return Double(total) / Double(a.width * a.height * 3)
    }

    private static func hitTarget(_ view: NSView, _ window: NSWindow) -> NSView? {
        view.scrollToVisible(view.bounds)
        guard let content = window.contentView else { return nil }
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return content.hitTest(content.convert(point, from: nil))
    }

    /// A real mouse down/up through the window at `fraction` across the view.
    @discardableResult
    private static func click(_ view: NSView, at fraction: CGFloat, window: NSWindow) -> Bool {
        view.scrollToVisible(view.bounds)
        window.contentView?.layoutSubtreeIfNeeded()
        let point = view.convert(NSPoint(x: view.bounds.minX + view.bounds.width * fraction, y: view.bounds.midY), to: nil)
        guard let content = window.contentView,
              let hit = content.hitTest(content.convert(point, from: nil)),
              hit === view || hit.isDescendant(of: view) else { return false }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        return true
    }

    /// Drags a card by its grip, through the grip's own callbacks with window points —
    /// the path a real drag takes. Positive `by` is up the screen.
    private static func dragCard(_ name: String, in panel: EffectChainPanelBody, window: NSWindow, by distance: CGFloat) {
        guard let toggle = find(NSSwitch.self, id: name, in: panel),
              let card = ancestorCard(of: toggle, in: panel),
              let grip = descendants(of: card).compactMap({ $0 as? DragHandleView }).first else { return }
        grip.scrollToVisible(grip.bounds)
        let start = grip.convert(NSPoint(x: 4, y: 4), to: nil)
        grip.onDragBegan?(start)
        var moved = start
        moved.y += distance
        grip.onDrag?(moved)
        grip.onDragEnded?()
        pump(0.4)
    }

    /// The card view (a direct child of the panel's stack) that holds a control.
    private static func ancestorCard(of view: NSView, in panel: NSView) -> NSView? {
        var current: NSView? = view
        while let candidate = current, let parent = candidate.superview {
            if parent is NSStackView, parent.superview is FlippedView { return candidate }
            current = parent
        }
        return nil
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    /// Each card's switch position, by card name — "did anything move".
    private static func cardFrames(_ panel: EffectChainPanelBody) -> [String: NSRect] {
        var frames: [String: NSRect] = [:]
        for control in descendants(of: panel).compactMap({ $0 as? NSSwitch }) {
            guard let name = control.identifier?.rawValue else { continue }
            frames[name] = control.convert(control.bounds, to: panel)
        }
        return frames
    }

    private static func find<T: NSView>(_ type: T.Type, id: String, in view: NSView, title: String? = nil) -> T? {
        for candidate in [view] + descendants(of: view) {
            guard let match = candidate as? T, match.identifier?.rawValue == id else { continue }
            if let title, (match as? NSButton)?.title != title { continue }
            return match
        }
        return nil
    }
}

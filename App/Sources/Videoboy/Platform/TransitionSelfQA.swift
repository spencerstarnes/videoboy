//
//  TransitionSelfQA.swift — every crossfader transition, from the live graph and the UI.
//
//  Purpose : The pattern geometry is unit-tested on flat colours in Core; this renders
//            each pattern over real DV through the engine's own mixer so the moves can
//            actually be looked at, and then drives the transition key on a real fader
//            panel — the path a hand takes — to prove a click reaches the picture.
//  Inputs  : samples/motion.dv and samples/bars.dv.
//  Outputs : selfqa/out/phase-4/transitions/{*.png,result.txt}.
//  Connects: Engine, CrossfadeNode, Transition, FaderPanelBody, VBTransitionButton,
//            ShellController.
//

import AppKit
import Metal
import VideoboyCore

/// Renders every transition at three points of its travel, then drives the UI key.
enum TransitionSelfQA {

    /// The points of travel each pattern is rendered at.
    private static let positions: [Double] = [0.25, 0.5, 0.75]

    static func run() -> SelfQAVerdict {
        let check = SelfQACheck(name: "phase-4/transitions")

        guard let metal = MetalContext.shared, let renderer = OffscreenRenderer(context: metal) else {
            return check.finish(blockedReason: "no Metal device is available")
        }
        let samples = RepoPaths.samples
        let fileA = samples.appendingPathComponent("motion.dv")
        let fileB = samples.appendingPathComponent("bars.dv")
        for file in [fileA, fileB] where !FileManager.default.fileExists(atPath: file.path) {
            return check.finish(blockedReason: "\(file.lastPathComponent) is missing — run scripts/make-fixtures.sh")
        }

        // Each section is a labelled block and skips with `break`, never `return`:
        // returning would silently stop every later section from asserting.

        // ── 1. Every pattern, through the engine ─────────────────────────────────
        section1: do {
            guard let engine = loadedEngine(fileA: fileA, fileB: fileB, check: check) else {
                break section1
            }
            check.note("A = motion.dv (left), B = bars.dv (right), through the engine's ONE bus")

            var frameIndex = 0
            func render(_ transition: Transition, at position: Double) -> ImageBuffer? {
                engine.registry.setValue(
                    transition.normalisedPosition, slot: GraphTopology.subMixOne, code: .transition)
                engine.registry.setValue(position, slot: GraphTopology.subMixOne, code: .crossfadeAB)
                frameIndex += 1
                return frame(from: engine, renderer: renderer, index: frameIndex)
            }

            var midpoints: [Transition: ImageBuffer] = [:]
            var sheetRows: [[ImageBuffer]] = []
            for transition in Transition.allCases {
                var row: [ImageBuffer] = []
                for position in positions {
                    guard let image = render(transition, at: position) else {
                        check.record(AssertionResult(
                            name: "\(transition.displayName) renders", passed: false, detail: "no texture"))
                        continue
                    }
                    if position == 0.5 {
                        midpoints[transition] = image
                        _ = try? check.writeImage(image, named: String(
                            format: "%02d-%@.png", transition.rawValue, fileSlug(transition)))
                    }
                    row.append(image.scaled(toWidth: 240))
                }
                sheetRows.append(row)
            }
            if let sheet = contactSheet(sheetRows) {
                _ = try? check.writeImage(sheet, named: "contact-sheet.png")
                check.note("contact-sheet.png: one row per pattern, at 25% / 50% / 75% of the travel")
            }

            check.record(AssertionResult(
                name: "every transition rendered at its midpoint",
                passed: midpoints.count == Transition.allCases.count,
                detail: "\(midpoints.count) of \(Transition.allCases.count)"
            ))

            // Each pattern must actually differ from a dissolve half-way through —
            // two identical frames would mean a pattern is not wired to the shader.
            if let dissolve = midpoints[.dissolve] {
                let differing = Transition.allCases.filter { transition in
                    guard transition != .dissolve, let image = midpoints[transition] else { return false }
                    return FrameAssertions.differingPixelFraction(dissolve, image) > 0.05
                }
                check.record(AssertionResult(
                    name: "every pattern differs from a dissolve at the midpoint",
                    passed: differing.count == Transition.allCases.count - 1,
                    detail: "\(differing.count) of \(Transition.allCases.count - 1)"
                ))
            }

            // The crossfader contract on real pictures: hard right is B untouched,
            // whatever the pattern. bars.dv is still, so every end frame must match.
            var endMismatches: [String] = []
            let reference = render(.dissolve, at: 1)
            for transition in Transition.allCases where transition != .dissolve {
                guard let reference, let end = render(transition, at: 1) else {
                    endMismatches.append(transition.displayName)
                    continue
                }
                if FrameAssertions.differingPixelFraction(reference, end) > 0.001 {
                    endMismatches.append(transition.displayName)
                }
            }
            check.record(AssertionResult(
                name: "hard right is the right source untouched, for every pattern",
                passed: endMismatches.isEmpty,
                detail: endMismatches.isEmpty ? "all \(Transition.allCases.count) match"
                    : "differ: \(endMismatches.joined(separator: ", "))"
            ))
        }

        // ── 2. The path a hand takes ─────────────────────────────────────────────
        //
        // A real shell, a real controller, the real key on the A/B fader panel.
        // Picked through the key's own MENU ITEM, so the same selector a click runs
        // is the one exercised — then the picture is read back from the engine.
        section2: do {
            guard let engine = loadedEngine(fileA: fileA, fileB: fileB, check: check) else {
                break section2
            }
            let shell = ShellView()
            let controller = ShellController(shell: shell, engine: engine)
            shell.frame = NSRect(origin: .zero, size: NSSize(width: 1460, height: 912))
            shell.layoutSubtreeIfNeeded()

            let panel = shell.grid.panels.faderABBody
            guard let key = panel.transitionButton else {
                check.record(AssertionResult(
                    name: "the A/B fader panel has a transition key", passed: false, detail: "nil"))
                break section2
            }
            check.record(AssertionResult(
                name: "the transition key is laid out left of the transport cluster",
                passed: key.frame.width > 0 && !key.isHidden
                    && key.convert(key.bounds, to: panel).minX < panel.bounds.width * 0.25,
                detail: "frame \(NSStringFromRect(key.convert(key.bounds, to: panel))) "
                    + "in a panel \(Int(panel.bounds.width)) wide"
            ))

            // Hard right first, for a reference picture of B alone.
            engine.registry.setValue(1, slot: GraphTopology.subMixOne, code: .crossfadeAB)
            let bOnly = frame(from: engine, renderer: renderer, index: 1)

            let menu = key.makeMenu()
            let irisIndex = menu.items.firstIndex { $0.title == Transition.iris.displayName }
            check.record(AssertionResult(
                name: "the menu lists every pattern with a pictogram",
                passed: menu.items.filter { !$0.isSeparatorItem && $0.image != nil }.count
                    == Transition.allCases.count,
                detail: "\(menu.items.filter { !$0.isSeparatorItem }.count) items"
            ))
            if let irisIndex { menu.performActionForItem(at: irisIndex) }

            let stored = engine.registry.value(slot: GraphTopology.subMixOne, code: .transition)
            check.record(AssertionResult(
                name: "choosing Iris on the key writes the ONE bus's transition",
                passed: stored.map(Transition.from(normalised:)) == .iris && key.transition == .iris,
                detail: "registry \(stored.map { String(format: "%.3f", $0) } ?? "nil"), "
                    + "key shows \(key.transition.displayName)"
            ))

            // Half-way, through the panel's own fader path. An iris at 0.5 has B in
            // the middle and A in the corners.
            panel.setPosition(0.5)
            engine.registry.setValue(0.5, slot: GraphTopology.subMixOne, code: .crossfadeAB)
            if let bOnly, let iris = frame(from: engine, renderer: renderer, index: 2) {
                _ = try? check.writeImage(iris, named: "ui-chosen-iris.png")
                let centre = (x: iris.width / 2, y: iris.height / 2)
                let centreMatchesB = close(iris.pixel(x: centre.x, y: centre.y),
                                           bOnly.pixel(x: centre.x, y: centre.y))
                let cornerIsNotB = !close(iris.pixel(x: 8, y: 8), bOnly.pixel(x: 8, y: 8))
                check.record(AssertionResult(
                    name: "the picture follows the key: B in the iris, A outside it",
                    passed: centreMatchesB && cornerIsNotB,
                    detail: "centre is B: \(centreMatchesB), corner is not B: \(cornerIsNotB)"
                ))
            } else {
                check.record(AssertionResult(
                    name: "the picture follows the key", passed: false, detail: "no frame"))
            }

            // What the key looks like, armed with each pattern, for the eye.
            // Drawn on the panel's own dark fill: a key rendered alone has a clear
            // background, and its light ink disappears against the white a PNG
            // viewer puts behind transparency.
            var keyShots: [ImageBuffer] = []
            for transition in Transition.allCases {
                let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
                backdrop.appearance = NSAppearance(named: .darkAqua)
                backdrop.wantsLayer = true
                backdrop.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
                let sample = VBTransitionButton(frame: NSRect(x: 5, y: 5, width: 30, height: 30))
                sample.translatesAutoresizingMaskIntoConstraints = true
                sample.transition = transition
                backdrop.addSubview(sample)
                if let shot = render(view: backdrop) { keyShots.append(shot) }
            }
            if let strip = contactSheet([keyShots]) {
                _ = try? check.writeImage(strip, named: "key-pictograms.png")
            }
            panel.setTransition(.iris)
            withExtendedLifetime(controller) {}
        }

        // ── 3. The key fits at every breakpoint ──────────────────────────────────
        //
        // A new key at the leading edge takes width from the shortest panel in the
        // grid. At each of the UI check's three window sizes, on all three faders,
        // it must sit inside its panel and overlap none of the keys beside it.
        let sizes: [(name: String, size: NSSize)] = [
            ("wide", NSSize(width: 1460, height: 912)),
            ("compact", NSSize(width: 1000, height: 760)),
            ("narrow", NSSize(width: 760, height: 640))
        ]
        for (name, size) in sizes {
            let shell = ShellView()
            shell.appearance = NSAppearance(named: .darkAqua)
            shell.frame = NSRect(origin: .zero, size: size)
            shell.layoutSubtreeIfNeeded()
            let panels = shell.grid.panels
            var problems: [String] = []
            for (label, panel) in [("A/B", panels.faderABBody), ("C/D", panels.faderCDBody),
                                   ("1/2", panels.faderOneTwoBody)] {
                guard let key = panel.transitionButton else { problems.append("\(label): no key"); continue }
                // A collapsed or hidden panel has nothing to check.
                guard panel.bounds.width > 1, !panel.isHiddenOrHasHiddenAncestor else { continue }
                let frame = key.convert(key.bounds, to: panel)
                if !panel.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame) {
                    problems.append("\(label): key outside panel \(NSStringFromRect(frame))")
                }
                // The performance keys must not have moved to make room. Before this
                // key existed the cluster was centred in its row; still centred means
                // still exactly where the hands expect it.
                if let busKey = VBBusButton.all(in: panel).first,
                   let cluster = busKey.superview, let row = cluster.superview {
                    let offset = abs(cluster.frame.midX - row.bounds.midX)
                    if offset > 0.5 {
                        problems.append("\(label): transport cluster pushed \(String(format: "%.1f", offset)) pt off centre")
                    }
                } else {
                    problems.append("\(label): could not find the transport cluster")
                }
                for other in siblingControls(in: panel) where other !== key && !other.isHidden {
                    let otherFrame = other.convert(other.bounds, to: panel)
                    if frame.intersects(otherFrame.insetBy(dx: 0.5, dy: 0.5)) {
                        problems.append("\(label): overlaps \(type(of: other)) at \(NSStringFromRect(otherFrame))")
                    }
                }
            }
            check.record(AssertionResult(
                name: "\(name): the transition key fits on every fader, overlapping nothing and moving no key",
                passed: problems.isEmpty,
                detail: problems.isEmpty ? "3 faders clear" : problems.joined(separator: "; ")
            ))
            shell.displayIfNeeded()
            if name == "wide", let shot = render(view: panels.faderABBody.superview ?? panels.faderABBody) {
                _ = try? check.writeImage(shot, named: "fader-panel.png")
            }
        }

        return check.finish()
    }

    /// Every control in a panel, however deeply nested.
    private static func siblingControls(in view: NSView) -> [NSControl] {
        view.subviews.flatMap { subview -> [NSControl] in
            (subview as? NSControl).map { [$0] + siblingControls(in: subview) } ?? siblingControls(in: subview)
        }
    }

    // MARK: - Helpers

    /// An engine with A and B loaded and the bus effects off — this check is about
    /// the compositor.
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

    /// The ONE bus's output for one evaluation of the graph.
    private static func frame(from engine: Engine, renderer: OffscreenRenderer, index: Int) -> ImageBuffer? {
        let context = RenderContext(
            frameIndex: index,
            presentationTime: Double(index) / StandardDefinition.frameRate,
            musicalPosition: nil
        )
        guard let texture = engine.evaluateGraph(context: context)[GraphTopology.subMixOne] else {
            return nil
        }
        return renderer.readback(texture)
    }

    private static func fileSlug(_ transition: Transition) -> String {
        transition.displayName.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// Two pixels within a small tolerance of each other.
    private static func close(
        _ a: (r: UInt8, g: UInt8, b: UInt8, a: UInt8), _ b: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
    ) -> Bool {
        abs(Int(a.r) - Int(b.r)) <= 6 && abs(Int(a.g) - Int(b.g)) <= 6 && abs(Int(a.b) - Int(b.b)) <= 6
    }

    /// Tiles images into a grid, row by row, with a 4 px black gutter. Rows may be
    /// ragged; every tile is placed at its own size.
    private static func contactSheet(_ rows: [[ImageBuffer]]) -> ImageBuffer? {
        let gutter = 4
        let tileWidth = rows.flatMap { $0 }.map(\.width).max() ?? 0
        let tileHeight = rows.flatMap { $0 }.map(\.height).max() ?? 0
        let columns = rows.map(\.count).max() ?? 0
        guard tileWidth > 0, tileHeight > 0, columns > 0 else { return nil }
        let width = columns * tileWidth + (columns + 1) * gutter
        let height = rows.count * tileHeight + (rows.count + 1) * gutter
        var pixels = ImageBuffer(width: width, height: height).pixels
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

    /// Draws a view into an `ImageBuffer` with no window — the same approach as
    /// UISelfQA's private helper, repeated rather than shared (CLAUDE.md: a little
    /// duplication over the wrong abstraction).
    private static func render(view: NSView) -> ImageBuffer? {
        guard view.bounds.width >= 1, view.bounds.height >= 1,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)
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
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? ImageBuffer(width: width, height: height, pixels: pixels) : nil
    }
}

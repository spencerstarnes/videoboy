//
//  GeneratorThumbnails.swift — a still picture of every generator, for the library.
//
//  Purpose : The Generators tab's tiles. A clip's thumbnail is decoded from its file;
//            a generator has no file, so its picture is rendered — once — through the
//            same node and shader the channel will run, at thumbnail size.
//  Inputs  : a `GeneratorKind`, or an ISF generator's `ModuleDescriptor`.
//  Outputs : `NSImage`s, cached by generator.
//  Connects: GeneratorSourceNode, ISFNode (via ModuleDescriptor.makeNode),
//            OffscreenRenderer.readback; read by LibraryPanelBody and ShellController.
//  Extend  : a new generator kind needs nothing here — it is rendered like the rest.
//
//  Never on the frame path: each picture is rendered the first time a tab asks for
//  it, and then only again when an ISF file changes on disk.
//

import AppKit
import VideoboyCore

/// Renders and caches one still per generator.
final class GeneratorThumbnails {

    static let shared = GeneratorThumbnails()

    /// Thumbnail geometry: 4:3, like everything else in an SD graph, and small —
    /// a tile is under 100 points wide.
    private static let width = 160
    private static let height = 120
    /// How far into its animation a generator is caught. Frame 0 is the least
    /// representative moment for most of them — phase 0 is a plain ramp's start.
    private static let stillFrame = 45
    private static let stillPhase = 0.25
    /// How long an ISF file may take to compile before its tile is left blank.
    private static let compileTimeout: TimeInterval = 10

    private var builtIn: [GeneratorKind: NSImage] = [:]
    private var isf: [String: NSImage] = [:]
    /// An ISF generator's thumbnail in progress. Rendered a few steps per poll, so
    /// a generator that needs the remedies below never holds the main thread or the
    /// GPU queue — which the engine shares — for more than a sliver of a frame.
    private struct Job {
        let node: ISFNode
        let started: Date
        /// 0: the small still. 1: the still at fallback size. Then `buildUpFrames`
        /// frames run in order, the frame after them read back, then each of
        /// `laterFrames`. Past that, the "starts black" tile.
        var step = 0
    }

    /// ISF generators compiling or being rendered, by module ID.
    private var pending: [String: Job] = [:]
    private var pollTimer: Timer?

    /// Called on main when an ISF picture becomes available, so the tiles can be rebuilt.
    var onISFUpdated: (() -> Void)?

    private lazy var renderer = OffscreenRenderer()

    // ── When the still comes out blank ──────────────────────────────────────
    //
    // 18 of 146 generators gave a black tile. None was a rendering fault; each was
    // blank at that one small frame for a reason of its own:
    //  - lines thinner than a pixel at 160x120 (CrossGrid, Cosplay): rendered at
    //    half SD and scaled down, they survive as fine lines;
    //  - pictures that build up frame by frame (Color History, Audio Waveform Shape):
    //    the frames are run in order from the start so the build-up happens;
    //  - pictures that bloom late (kali's zoom starts near zero): later moments;
    //  - sound-driven ones: a private test tone, never the live sound;
    //  - and some that really are black at their defaults (Solid Colour, a trail
    //    whose point starts at the corner): those get a tile that says so, since
    //    plain black read as a missing thumbnail.
    // Only a blank still pays for any of this, and only once per generator. The
    // fallback size is half SD, not full: ~100 renders at 720x480 on the queue the
    // engine fences on cost it frames at launch (stress measured 28.5 fps).

    /// Frames run in order from the start before looking again.
    private static let buildUpFrames = 90
    /// Later moments, in frames: 10 s, 30 s, 1 min, 2 min.
    private static let laterFrames = [300, 900, 1800, 3600]
    /// A still counts as a picture when this share of its pixels is lit…
    private static let litShare = 0.002
    /// …where lit means any channel above this level (0...255).
    private static let litLevel: UInt8 = 24

    /// The sound a thumbnail's audio inputs hear — its own, never the live feed.
    private let testTone = ISFAudioFeed()

    private func context(frame: Int, full: Bool = false) -> RenderContext {
        RenderContext(
            frameIndex: frame,
            presentationTime: Double(frame) / 29.97,
            musicalPosition: nil,
            width: full ? StandardDefinition.width / 2 : Self.width,
            height: full ? StandardDefinition.height / 2 : Self.height)
    }

    /// The picture of a built-in generator, rendered on first request.
    func image(for kind: GeneratorKind) -> NSImage? {
        if let cached = builtIn[kind] { return cached }
        let node = GeneratorSourceNode(identifier: "thumbnail.\(kind)")
        node.generator = kind
        node.phase = Self.stillPhase
        guard let image = render(node) else {
            Log.warn(.render, "no thumbnail for generator \(kind.displayName)")
            return nil
        }
        builtIn[kind] = image
        return image
    }

    /// The picture of an ISF generator, or nil while it compiles. `onISFUpdated`
    /// fires once it is ready.
    func image(for module: ModuleDescriptor) -> NSImage? {
        if let cached = isf[module.id] { return cached }
        guard pending[module.id] == nil else { return nil }
        guard let node = module.makeNode(
            identifier: "thumbnail.\(module.id)", context: MetalContext.shared) as? ISFNode else {
            Log.warn(.isf, "no thumbnail for \(module.name): not an ISF node")
            return nil
        }
        node.audioFeed = testTone
        pending[module.id] = Job(node: node, started: Date())
        startPolling()
        return nil
    }

    /// True when no ISF thumbnail is compiling or being rendered.
    var isIdle: Bool { pending.isEmpty }

    /// Drops the ISF pictures, so a changed file is re-rendered.
    func forgetISF() {
        isf.removeAll()
        pending.removeAll()
    }

    // MARK: - Rendering

    /// A built-in pattern: the still, then the same moment at fallback size. A
    /// built-in has no state to build up and its picture does not change with time
    /// alone (its phase is fixed here), so the other remedies would show nothing new.
    private func render(_ node: Node) -> NSImage? {
        guard let still = frame(node, at: Self.stillFrame) else { return nil }
        if Self.hasPicture(still) { return Self.image(still) }
        if let larger = frame(node, at: Self.stillFrame, full: true), Self.hasPicture(larger) {
            return Self.image(larger)
        }
        return makeStartsBlackTile()
    }

    /// Takes one step of an ISF thumbnail. Returns the finished tile, or nil when
    /// there is more to do. `didReadBack` says whether the step waited on the GPU.
    private func advance(_ job: inout Job) -> (tile: NSImage?, didReadBack: Bool) {
        let node = job.node
        let buildUpEnd = 2 + Self.buildUpFrames
        defer { job.step += 1 }
        switch job.step {
        case 0, 1:
            guard let still = frame(node, at: Self.stillFrame, full: job.step == 1) else {
                return (makeStartsBlackTile(), true)
            }
            return (Self.hasPicture(still) ? Self.image(still) : nil, true)
        case 2..<buildUpEnd:
            // From the start, in order, so anything that accumulates can.
            let index = job.step - 2
            playTone(frame: index)
            _ = node.render(inputs: [], context: context(frame: index, full: true))
            return (nil, false)
        case buildUpEnd..<(buildUpEnd + 1 + Self.laterFrames.count):
            let at = job.step == buildUpEnd
                ? Self.buildUpFrames : Self.laterFrames[job.step - buildUpEnd - 1]
            guard let picture = frame(node, at: at, full: true) else { return (nil, true) }
            return (Self.hasPicture(picture) ? Self.image(picture) : nil, true)
        default:
            return (makeStartsBlackTile(), false)
        }
    }

    private func makeStartsBlackTile() -> NSImage {
        let tile = Self.startsBlackTile()
        startsBlackTiles.insert(ObjectIdentifier(tile))
        return tile
    }

    /// The "starts black" tiles handed out, so the self-QA can tell them from pictures.
    private var startsBlackTiles: Set<ObjectIdentifier> = []

    /// True when `image` is a tile saying its generator starts black. For the self-QA.
    func isStartsBlackTile(_ image: NSImage) -> Bool {
        startsBlackTiles.contains(ObjectIdentifier(image))
    }

    /// One frame, read back.
    private func frame(_ node: Node, at index: Int, full: Bool = false) -> ImageBuffer? {
        playTone(frame: index)
        guard let texture = node.render(inputs: [], context: context(frame: index, full: full)) else {
            return nil
        }
        return renderer?.readback(texture)
    }

    /// Puts one window of the test tone in the thumbnail's feed: three partials whose
    /// levels drift with the frame, so a spectrogram has something to scroll and a
    /// waveform something to draw.
    private func playTone(frame: Int) {
        let t = Double(frame) / 29.97
        let partials: [(bin: Int, level: Double)] = [
            (8, 0.9), (40 + Int(20 * sin(t)), 0.7), (140, 0.5 + 0.4 * sin(t * 2.3))
        ]
        var spectrum = [Float](repeating: 0, count: 512)
        for (bin, level) in partials {
            for offset in -6...6 where spectrum.indices.contains(bin + offset) {
                spectrum[bin + offset] = max(spectrum[bin + offset],
                                             Float(level * exp(-Double(offset * offset) / 8)))
            }
        }
        let waveform = (0..<1024).map { index -> Float in
            let x = Double(index) / 1024
            return Float(0.5 * sin(2 * .pi * 4 * x + t) + 0.3 * sin(2 * .pi * 19 * x + 2 * t))
        }
        var window = AudioFrame.silent()
        window.spectrum = spectrum
        window.waveform = waveform
        testTone.update(with: window)
    }

    /// True when enough of the still is lit to show what the generator makes. By lit
    /// pixels, not mean brightness: a thin clock face or a small dim box is a real
    /// picture with a low mean.
    private static func hasPicture(_ buffer: ImageBuffer) -> Bool {
        var lit = 0
        buffer.pixels.withUnsafeBufferPointer { bytes in
            var index = 0
            while index + 2 < bytes.count {
                if max(bytes[index], bytes[index + 1], bytes[index + 2]) > litLevel { lit += 1 }
                index += ImageBuffer.bytesPerPixel
            }
        }
        return Double(lit) >= litShare * Double(max(buffer.width * buffer.height, 1))
    }

    /// The still as a tile-sized image. A full-size frame is scaled down with
    /// smoothing, so a one-pixel line becomes a fine grey line instead of vanishing.
    private static func image(_ buffer: ImageBuffer) -> NSImage? {
        // Opaque, as every picture in an SD graph is. Some generators leave alpha at
        // zero (Bordered Box draws its box into a transparent frame); honoured here,
        // that made the tile black while the channel shows the box.
        var pixels = buffer.pixels
        for index in stride(from: 3, to: pixels.count, by: ImageBuffer.bytesPerPixel) {
            pixels[index] = 255
        }
        let opaque = ImageBuffer(width: buffer.width, height: buffer.height, pixels: pixels)
        guard let cgImage = opaque.makeCGImage() else { return nil }
        guard buffer.width != width || buffer.height != height else {
            return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSImage(cgImage: scaled, size: NSSize(width: width, height: height))
    }

    /// For a generator that is black at its defaults: says so, rather than looking
    /// like a picture that failed to load.
    private static func startsBlackTile() -> NSImage {
        NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            NSColor.black.setFill()
            rect.fill()
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let lines: [(String, NSFont, NSColor)] = [
                ("starts black", .systemFont(ofSize: 17, weight: .medium), NSColor(white: 0.55, alpha: 1)),
                ("try its controls", .systemFont(ofSize: 13), NSColor(white: 0.38, alpha: 1))
            ]
            var y = rect.midY + 2
            for (text, font, colour) in lines {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: colour, .paragraphStyle: style]
                let height = font.boundingRectForFont.height
                (text as NSString).draw(
                    in: NSRect(x: 0, y: y, width: rect.width, height: height),
                    withAttributes: attributes)
                y -= height + 2
            }
            return true
        }
    }

    /// Checks the compiling ISF nodes, and renders the ready ones, a little at a
    /// time until none are left.
    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.pollPending()
        }
    }

    /// How often thumbnails are worked on, and for how long each time. The engine's
    /// frame is 33 ms; this is a sliver of it, between ticks. A folder change reloads
    /// every thumbnail while the show is running, so this bound is what keeps that
    /// from being visible.
    private static let pollInterval: TimeInterval = 0.05
    private static let pollBudget: CFTimeInterval = 0.004
    /// Frames of a build-up submitted per poll at most — GPU work the engine's
    /// once-per-frame fence would otherwise wait on.
    private static let buildUpFramesPerPoll = 6

    private func pollPending() {
        var rendered = false
        let deadline = CACurrentMediaTime() + Self.pollBudget
        var buildUpSubmitted = 0
        for id in Array(pending.keys) {
            guard var job = pending[id] else { continue }
            switch job.node.state {
            case .ready:
                // Steps until the tile is done, the time is spent, or the GPU has
                // been given its share for this poll.
                while CACurrentMediaTime() < deadline, buildUpSubmitted < Self.buildUpFramesPerPoll {
                    let (tile, didReadBack) = advance(&job)
                    if !didReadBack, tile == nil { buildUpSubmitted += 1 }
                    if let tile {
                        isf[id] = tile
                        rendered = true
                        break
                    }
                }
                pending[id] = isf[id] == nil ? job : nil
            case .compiling where Date().timeIntervalSince(job.started) < Self.compileTimeout:
                continue
            default:
                Log.warn(.isf, "no thumbnail for \(id): it did not compile")
                pending[id] = nil
            }
            if CACurrentMediaTime() >= deadline || buildUpSubmitted >= Self.buildUpFramesPerPoll { break }
        }
        if pending.isEmpty {
            pollTimer?.invalidate()
            pollTimer = nil
        }
        if rendered { onISFUpdated?() }
    }
}

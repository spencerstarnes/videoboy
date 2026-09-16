//
//  Engine.swift — everything the app owns at runtime, wired together.
//
//  Purpose : Builds the fixed graph (SPEC 2), owns the clocks, the param registry and
//            MIDI, and drives one frame of work per display refresh. The UI talks to
//            this and nothing else, so no view ever reaches into the graph directly.
//  Inputs  : user actions from the UI, MIDI, and the display link.
//  Outputs : textures into the previews and the output window; status for the bars.
//  Connects: Core's RenderGraph, Transport, Scheduler, ParamRegistry, MIDIInput,
//            DVSourceNode, CrossfadeNode; the UI panels; OutputWindowController.
//  Extend  : a new node is added to `buildGraph` and given a slot name. The fixed
//            A/B->ONE, C/D->TWO routing is not a variable and must not become one.
//

import AppKit
import Metal
import VideoboyCore

/// The running instrument.
final class Engine {

    // MARK: Core state

    let graph = RenderGraph()
    let registry = ParamRegistry()
    let transport = Transport(beatsPerMinute: 120)
    private(set) lazy var scheduler = Scheduler(transport: transport)
    private(set) lazy var midi = MIDIInput(registry: registry)

    /// The four source channels, by letter.
    private(set) var sources: [String: DVSourceNode] = [:]
    /// The three mixers: ONE, TWO and PRIMARY.
    private(set) var subMixOne: CrossfadeNode!
    private(set) var subMixTwo: CrossfadeNode!
    private(set) var primary: CrossfadeNode!

    /// Bus effects on Sub Mix ONE (SPEC 2's `bus FX`). The composite codec is the
    /// analog character; echo and feedback sit after it.
    private(set) var compositeCodec: CompositeCodecNode!
    private(set) var echo: EchoNode!
    private(set) var feedback: FeedbackNode!

    /// Live capture, available as a source (SPEC 10). Fed by the App's capture
    /// session; nothing until then, which renders as the panel's empty state.
    private(set) var capture: CaptureSourceNode!

    /// Test pattern, routable as a source and straight to an output (SPEC 11).
    private(set) var testPattern: TestPatternSourceNode!

    /// Black-frame insertion on the program bus (SPEC 11).
    var blackFrameInsertion = BlackFrameInsertion(everyNFrames: 0)

    /// Overscan applied to the output, 0...1.
    var overscan = 0.0

    /// Round-trip latency of the physical feedback loop, once measured.
    private(set) var measuredFeedbackLatency: FeedbackLatency?

    private let metal = MetalContext.shared

    // MARK: Frame state

    private(set) var frameIndex = 0
    private var displayLink: CADisplayLink?
    /// Host time of the previous tick, for the measured frame rate in the status bar.
    private var lastTickTime: CFTimeInterval = 0
    private(set) var measuredFramesPerSecond = 0.0
    private(set) var droppedFrames = 0

    /// Called after each rendered frame so the UI can refresh previews and readouts.
    var onFrame: ((Engine) -> Void)?

    /// The mode the output display negotiated, logged and shown in the settings bar.
    private(set) var negotiatedOutputMode = "not yet negotiated"

    init() {
        buildGraph()
        buildSchedule()
    }

    // MARK: - Graph

    /// Builds the fixed graph from SPEC 2. A and B always feed ONE; C and D always
    /// feed TWO; ONE and TWO feed PRIMARY. This wiring is not user-editable.
    private func buildGraph() {
        for letter in ["A", "B", "C", "D"] {
            let identifier = Engine.slot(forChannel: letter)
            let node = DVSourceNode(identifier: identifier, context: metal)
            sources[letter] = node
            graph.add(node)
        }

        subMixOne = CrossfadeNode(
            identifier: GraphTopology.subMixOne, positionCode: .crossfadeAB, context: metal)
        subMixTwo = CrossfadeNode(
            identifier: GraphTopology.subMixTwo, positionCode: .crossfadeCD, context: metal)
        primary = CrossfadeNode(
            identifier: GraphTopology.primary, positionCode: .crossfadeOneTwo, context: metal)

        graph.add(subMixOne)
        graph.add(subMixTwo)
        graph.add(primary)

        graph.connect(from: GraphTopology.sourceA, to: GraphTopology.subMixOne, inputIndex: 0)
        graph.connect(from: GraphTopology.sourceB, to: GraphTopology.subMixOne, inputIndex: 1)
        graph.connect(from: GraphTopology.sourceC, to: GraphTopology.subMixTwo, inputIndex: 0)
        graph.connect(from: GraphTopology.sourceD, to: GraphTopology.subMixTwo, inputIndex: 1)
        // Bus FX on ONE, in order: composite codec, then echo, then feedback. The
        // codec runs first on purpose — the analog character should be applied to the
        // picture, and the trails and loop then act on the already-degraded signal,
        // which is the order a real chain would have.
        compositeCodec = CompositeCodecNode(identifier: Engine.compositeSlot, context: metal)
        echo = EchoNode(identifier: Engine.echoSlot, context: metal)
        feedback = FeedbackNode(identifier: Engine.feedbackSlot, context: metal)
        graph.add(compositeCodec)
        graph.add(echo)
        graph.add(feedback)

        graph.connect(from: GraphTopology.subMixOne, to: Engine.compositeSlot, inputIndex: 0)
        graph.connect(from: Engine.compositeSlot, to: Engine.echoSlot, inputIndex: 0)
        graph.connect(from: Engine.echoSlot, to: Engine.feedbackSlot, inputIndex: 0)
        graph.connect(from: Engine.feedbackSlot, to: GraphTopology.primary, inputIndex: 0)
        graph.connect(from: GraphTopology.subMixTwo, to: GraphTopology.primary, inputIndex: 1)

        // Sources that exist but are not wired into a channel until asked for.
        capture = CaptureSourceNode(identifier: Engine.captureSlot, context: metal)
        testPattern = TestPatternSourceNode(identifier: Engine.testPatternSlot, context: metal)
        graph.add(capture)
        graph.add(testPattern)

        graph.registerParameters(into: registry)

        // The bus effects start bypassed so the app opens showing what was loaded
        // rather than a processed version of it. Their switches in the FX panel are
        // what turns them on, which keeps "what you see" traceable to a deliberate act.
        for slot in [Engine.compositeSlot, Engine.echoSlot, Engine.feedbackSlot] {
            registry.setValue(0, slot: slot, code: .wetDry)
        }
        Log.info(.graph, "graph built: \(graph.nodeCount) nodes, max latency \(graph.maximumLatencyInFrames) frames")
    }

    /// Slot names for the bus effects and the extra sources, so mappings and
    /// templates can address them by a stable name.
    static let compositeSlot = "fx.one.composite"
    static let echoSlot = "fx.one.echo"
    static let feedbackSlot = "fx.one.feedback"
    static let captureSlot = "source.capture"
    static let testPatternSlot = "source.testpattern"

    /// The mapping slot name for a channel letter.
    static func slot(forChannel letter: String) -> String {
        switch letter {
        case "A": GraphTopology.sourceA
        case "B": GraphTopology.sourceB
        case "C": GraphTopology.sourceC
        default: GraphTopology.sourceD
        }
    }

    // MARK: - Schedule

    /// Subscribes the corruptors to the musical clock so damage changes on the beat.
    ///
    /// Each source declares its own latency and the scheduler compensates for it, so
    /// the *visible* change lands on the beat rather than one frame after it.
    private func buildSchedule() {
        for (letter, node) in sources {
            scheduler.subscribe(subdivision: .quarter, latencyInFrames: node.latencyInFrames) { event in
                // Seeding from the beat number keeps a performance reproducible.
                node.rerollCorruptionSeed(using: UInt64(event.targetBeat * 1000) &+ 17)
                Log.info(.clock, "source \(letter) reseeded for beat \(event.targetBeat)")
            }
        }
    }

    // MARK: - Run loop

    /// Starts the render clock, driven by the display the window is on.
    func start(drivenBy view: NSView) {
        guard displayLink == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        midi.start()
        Log.info(.render, "render clock started")
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// One frame: advance the clocks, apply parameters, evaluate the graph.
    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp

        // Measure the real rate for the status bar, and notice a skipped refresh.
        if lastTickTime > 0 {
            let delta = now - lastTickTime
            if delta > 0 { measuredFramesPerSecond = 1.0 / delta }
            let expected = link.targetTimestamp - link.timestamp
            if expected > 0, delta > expected * 1.8 { droppedFrames += 1 }
        }
        lastTickTime = now

        // The musical clock advances independently of frame production (SPEC 4).
        scheduler.advance(to: now)

        // Parameters arrive from the UI, MIDI and templates through one path.
        applyAllParameters()

        let context = RenderContext(
            frameIndex: frameIndex,
            presentationTime: link.targetTimestamp,
            musicalPosition: transport.isRunning ? transport.position(atHostTime: now) : nil
        )
        evaluate(context: context)
        frameIndex += 1
        onFrame?(self)
    }

    /// Pushes every node's parameters from the registry into the node.
    ///
    /// One method rather than a list of calls at each site: a node left out of such a
    /// list silently keeps its defaults and ignores the registry, which is a bug that
    /// looks like the effect "not working" and is hard to spot. Anything that
    /// evaluates the graph calls this first.
    func applyAllParameters() {
        for node in sources.values { node.applyParameters(from: registry) }
        subMixOne.applyParameters(from: registry)
        subMixTwo.applyParameters(from: registry)
        primary.applyParameters(from: registry)
        compositeCodec.applyParameters(from: registry)
        echo.applyParameters(from: registry)
        feedback.applyParameters(from: registry)
    }

    /// Evaluates the graph to PRIMARY, in dependency order, and returns every
    /// texture produced along the way.
    ///
    /// Shared with the self-QA checks so they exercise the same traversal the live
    /// render loop does, rather than a copy of it that can drift.
    @discardableResult
    func evaluateGraph(context: RenderContext) -> [String: MTLTexture] {
        applyAllParameters()
        var produced: [String: MTLTexture] = [:]
        for identifier in graph.evaluationOrder(from: GraphTopology.primary) {
            guard let node = graph.nodes[identifier] else { continue }
            let inputs = graph.inputs(of: identifier).compactMap { produced[$0] }
            if let texture = node.render(inputs: inputs, context: context) {
                produced[identifier] = texture
            }
        }
        return produced
    }

    /// Evaluates the graph to PRIMARY, in dependency order.
    private func evaluate(context: RenderContext) {
        currentTextures = evaluateGraph(context: context)
    }

    /// The most recent texture from each node, for the previews to draw.
    private(set) var currentTextures: [String: MTLTexture] = [:]

    /// The texture a given node last produced.
    func texture(for identifier: String) -> MTLTexture? { currentTextures[identifier] }

    // MARK: - Actions from the UI

    /// Loads a media file into a channel.
    @discardableResult
    func load(url: URL, intoChannel letter: String) -> Bool {
        guard let node = sources[letter] else { return false }
        let loaded = node.load(url: url)
        if loaded {
            // Re-register: a source that has just been given a file exposes the same
            // codes, but doing this keeps the swap path exercised and honest.
            registry.register(slot: node.identifier, parameters: node.parameters)
        }
        return loaded
    }

    /// Starts or stops a channel's playback.
    func setPlaying(_ playing: Bool, channel letter: String) {
        sources[letter]?.isPlaying = playing
    }

    /// Starts or stops the musical transport.
    func setTransportRunning(_ running: Bool) {
        let now = CACurrentMediaTime()
        if running { transport.start(atHostTime: now) } else { transport.stop(atHostTime: now) }
    }

    /// Records the output mode that was negotiated, for the settings bar and for
    /// comparison against captured loopback metrics.
    func setNegotiatedOutputMode(_ mode: String) {
        negotiatedOutputMode = mode
    }

    /// Records a measured feedback round trip and tells the nodes that care.
    ///
    /// SPEC 10: once the physical loop's latency is known, beat-driven effects inside
    /// it must be scheduled that much earlier or they play late.
    func applyMeasuredFeedbackLatency(_ latency: FeedbackLatency) {
        measuredFeedbackLatency = latency
        capture.measuredLatencyFrames = latency.frames
        Log.info(.render, "feedback round trip \(latency.frames) frames (\(String(format: "%.1f", latency.seconds * 1000)) ms); scheduling now compensates for it")
    }

    /// True when this frame should be blacked out for BFI.
    func isBlackFrame() -> Bool {
        blackFrameInsertion.isBlackFrame(frameIndex)
    }
}

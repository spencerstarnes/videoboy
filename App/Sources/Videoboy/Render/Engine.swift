//
//  Engine.swift — everything the app owns at runtime, wired together.
//
//  Purpose : Builds the fixed graph (SPEC 2), owns the clocks, the param registry and
//            MIDI, and drives one frame of work per display refresh. The UI talks to
//            this and nothing else, so no view ever reaches into the graph directly.
//  Inputs  : user actions from the UI, MIDI, and the display link.
//  Outputs : textures into the previews and the output window; status for the bars.
//  Connects: Core's RenderGraph, Transport, Scheduler, ParamRegistry, MIDIInput,
//            ClipSourceNode, CrossfadeNode; the UI panels; OutputWindowController.
//  Extend  : a new node is added to `buildGraph` and given a slot name. The fixed
//            A/B->ONE, C/D->TWO routing is not a variable and must not become one.
//

import AppKit
import Metal
import VideoboyCore

/// What a channel is currently playing.
enum ChannelSourceKind {
    case file
    case generator
}

/// Where the musical clock's tempo comes from (SPEC 4b).
enum ClockSource: String {
    case internalTransport
    case audio

    var displayName: String {
        switch self {
        case .internalTransport: "Internal"
        case .audio: "Audio"
        }
    }
}

/// The running instrument.
final class Engine {

    // MARK: Core state

    let graph = RenderGraph()
    let registry = ParamRegistry()
    let transport = Transport(beatsPerMinute: 120)
    private(set) lazy var scheduler = Scheduler(transport: transport)
    private(set) lazy var midi = MIDIInput(registry: registry)

    /// The four source channels, by letter.
    private(set) var sources: [String: ClipSourceNode] = [:]
    /// The three mixers: ONE, TWO and PRIMARY.
    private(set) var subMixOne: CrossfadeNode!
    private(set) var subMixTwo: CrossfadeNode!
    private(set) var primary: CrossfadeNode!

    /// Bus effects, one chain per sub-mix (SPEC 2's `bus FX`). The composite codec is
    /// the analog character; echo and feedback sit after it.
    private(set) var compositeCodec: CompositeCodecNode!
    private(set) var echo: EchoNode!
    private(set) var feedback: FeedbackNode!
    private(set) var compositeCodecTwo: CompositeCodecNode!
    private(set) var echoTwo: EchoNode!
    private(set) var feedbackTwo: FeedbackNode!

    /// Bus data effects: re-encode the mix so its bitstream can be damaged.
    /// One per bus plus one on PROGRAM, since the format leaving the mixer is its
    /// own decision independent of what the sub-mixes carry.
    private(set) var busCodecOne: BusCodecNode!
    private(set) var busCodecTwo: BusCodecNode!
    private(set) var busCodecProgram: BusCodecNode!
    private(set) var compositeProgram: CompositeCodecNode!
    private(set) var mx1One: MX1EffectNode!
    private(set) var mx1Two: MX1EffectNode!

    /// Live capture, available as a source (SPEC 10). Fed by the App's capture
    /// session; nothing until then, which renders as the panel's empty state.
    private(set) var capture: CaptureSourceNode!

    /// Test pattern, routable as a source and straight to an output (SPEC 11).
    private(set) var testPattern: TestPatternSourceNode!

    /// One generator per channel, so any channel can produce a synthetic source
    /// instead of playing a file (SPEC 6A).
    private(set) var generators: [String: GeneratorSourceNode] = [:]

    /// Which kind of source each channel is currently showing.
    private(set) var channelSourceKinds: [String: ChannelSourceKind] = [:]

    /// Transport-locked oscillators driving parameters (SPEC 6A).
    private(set) lazy var lfos = LFOBank(transport: transport)

    /// Audio measurements driving parameters (SPEC 4c, SPEC 13).
    let audioReactivity = AudioReactivityBus()

    /// The live audio tap. Nil until audio is switched on.
    private var audioInput: AudioInput?

    /// Where the transport gets its tempo from.
    private(set) var clockSource: ClockSource = .internalTransport

    /// The most recent tempo estimate from audio, for the toolbar's sync indicator.
    private(set) var latestTempoEstimate: TempoEstimate?

    /// Called when the tempo changes from any source — a tap, beat detection, or by
    /// hand. Two of those three happen without the operator doing it directly, which
    /// is why it is worth announcing.
    var onTempoChanged: ((Double) -> Void)?

    /// The tempo last announced, so a change is reported once rather than per frame.
    private var lastAnnouncedTempo: Double = 0

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
            let node = ClipSourceNode(identifier: identifier, context: metal)
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

        // The MX-1 set sits at the end of the picture chain, after feedback: these
        // are the whole-frame gestures — negative, mirror, freeze — and they read as
        // something done TO the bus rather than as another layer inside it.
        mx1One = MX1EffectNode(identifier: Engine.mx1OneSlot, context: metal)
        graph.add(mx1One)
        graph.connect(from: Engine.feedbackSlot, to: Engine.mx1OneSlot, inputIndex: 0)
        // The bus data stage sits at the END of each chain, just before the mix:
        // it re-encodes whatever the chain produced, so it damages the finished bus
        // rather than something half-processed.
        busCodecOne = BusCodecNode(identifier: Engine.busCodecOneSlot, context: metal)
        busCodecTwo = BusCodecNode(identifier: Engine.busCodecTwoSlot, context: metal)
        busCodecProgram = BusCodecNode(identifier: Engine.busCodecProgramSlot, context: metal)
        graph.add(busCodecOne)
        graph.add(busCodecTwo)
        graph.add(busCodecProgram)

        graph.connect(from: Engine.mx1OneSlot, to: Engine.busCodecOneSlot, inputIndex: 0)
        graph.connect(from: Engine.busCodecOneSlot, to: GraphTopology.primary, inputIndex: 0)

        // The same chain on TWO. Separate instances rather than a shared one: the two
        // buses must be able to carry different looks at once, which is the whole
        // point of having two of them.
        compositeCodecTwo = CompositeCodecNode(identifier: Engine.compositeTwoSlot, context: metal)
        echoTwo = EchoNode(identifier: Engine.echoTwoSlot, context: metal)
        feedbackTwo = FeedbackNode(identifier: Engine.feedbackTwoSlot, context: metal)
        graph.add(compositeCodecTwo)
        graph.add(echoTwo)
        graph.add(feedbackTwo)

        graph.connect(from: GraphTopology.subMixTwo, to: Engine.compositeTwoSlot, inputIndex: 0)
        graph.connect(from: Engine.compositeTwoSlot, to: Engine.echoTwoSlot, inputIndex: 0)
        graph.connect(from: Engine.echoTwoSlot, to: Engine.feedbackTwoSlot, inputIndex: 0)
        mx1Two = MX1EffectNode(identifier: Engine.mx1TwoSlot, context: metal)
        graph.add(mx1Two)
        graph.connect(from: Engine.feedbackTwoSlot, to: Engine.mx1TwoSlot, inputIndex: 0)
        graph.connect(from: Engine.mx1TwoSlot, to: Engine.busCodecTwoSlot, inputIndex: 0)
        graph.connect(from: Engine.busCodecTwoSlot, to: GraphTopology.primary, inputIndex: 1)

        // PROGRAM's own data stage, after the ONE/TWO mix. It was created and added
        // but never connected, so the programme's data controls moved nothing — the
        // graph simply terminated at the mix. It is the last thing before output,
        // which is what makes it the right place for the output emulation too.
        // The output emulation stage, between the mix and the programme data stage.
        // NTSC character belongs at the very END of the chain: it is what the signal
        // picks up on its way out, not something a bus carries into the mix.
        compositeProgram = CompositeCodecNode(
            identifier: Engine.compositeProgramSlot, context: metal)
        graph.add(compositeProgram)
        graph.connect(
            from: GraphTopology.primary, to: Engine.compositeProgramSlot, inputIndex: 0)
        graph.connect(
            from: Engine.compositeProgramSlot, to: Engine.busCodecProgramSlot, inputIndex: 0)

        // A generator per channel, created up front so its parameters are registered
        // and mappable whether or not it is currently the channel's source.
        for letter in ["A", "B", "C", "D"] {
            let generator = GeneratorSourceNode(
                identifier: Engine.generatorSlot(forChannel: letter), context: metal)
            generators[letter] = generator
            graph.add(generator)
            channelSourceKinds[letter] = .file
        }

        // Sources that exist but are not wired into a channel until asked for.
        capture = CaptureSourceNode(identifier: Engine.captureSlot, context: metal)
        testPattern = TestPatternSourceNode(identifier: Engine.testPatternSlot, context: metal)
        graph.add(capture)
        graph.add(testPattern)

        graph.registerParameters(into: registry)

        // The bus effects start bypassed so the app opens showing what was loaded
        // rather than a processed version of it. Their switches in the FX panel are
        // what turns them on, which keeps "what you see" traceable to a deliberate act.
        for slot in Engine.busEffectSlots {
            registry.setValue(0, slot: slot, code: .wetDry)
        }
        Log.info(.graph, "graph built: \(graph.nodeCount) nodes, max latency \(graph.maximumLatencyInFrames) frames")
    }

    /// Slot names for the bus effects and the extra sources, so mappings and
    /// templates can address them by a stable name.
    static let compositeSlot = "fx.one.composite"
    static let echoSlot = "fx.one.echo"
    static let feedbackSlot = "fx.one.feedback"
    static let compositeTwoSlot = "fx.two.composite"
    static let echoTwoSlot = "fx.two.echo"
    static let feedbackTwoSlot = "fx.two.feedback"
    static let busCodecOneSlot = "data.one"
    static let busCodecTwoSlot = "data.two"
    static let busCodecProgramSlot = "data.program"
    static let compositeProgramSlot = "fx.program.composite"
    static let mx1OneSlot = "fx.one.mx1"
    static let mx1TwoSlot = "fx.two.mx1"

    /// The last node in the graph — what output and the programme preview show.
    ///
    /// Named separately from `GraphTopology.primary` because they are not the same
    /// thing: primary is the ONE/TWO mix, and the programme data stage runs after it.
    /// Conflating them is what left that stage unconnected.
    static var outputSlot: String { busCodecProgramSlot }
    static let captureSlot = "source.capture"
    static let testPatternSlot = "source.testpattern"

    /// Every bus-effect slot, both chains.
    static let busEffectSlots = [
        compositeSlot, echoSlot, feedbackSlot, mx1OneSlot,
        compositeTwoSlot, echoTwoSlot, feedbackTwoSlot, mx1TwoSlot
    ]

    /// The generator slot name for a channel letter.
    static func generatorSlot(forChannel letter: String) -> String {
        "generator.\(letter.lowercased())"
    }

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

        // Bus data effects re-roll on the beat too, so damage applied to a mix is as
        // musical as damage applied to a source.
        for (name, codec) in [("ONE", busCodecOne), ("TWO", busCodecTwo), ("PROGRAM", busCodecProgram)] {
            guard let codec else { continue }
            scheduler.subscribe(subdivision: .quarter, latencyInFrames: codec.latencyInFrames) { event in
                codec.rerollCorruptionSeed(using: UInt64(event.targetBeat * 1000) &+ 29)
                Log.info(.clock, "bus \(name) data effects reseeded for beat \(event.targetBeat)")
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
        audioInput?.stop()
        audioInput = nil
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

        // Oscillators write into the registry BEFORE parameters are applied, so an
        // LFO and a MIDI knob reach a node by exactly the same route.
        lfos.update(atHostTime: now, into: registry)

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
        compositeProgram.applyParameters(from: registry)
        mx1One.applyParameters(from: registry)
        mx1Two.applyParameters(from: registry)
        compositeCodecTwo.applyParameters(from: registry)
        echoTwo.applyParameters(from: registry)
        feedbackTwo.applyParameters(from: registry)
        for generator in generators.values { generator.applyParameters(from: registry) }
        busCodecOne.applyParameters(from: registry)
        busCodecTwo.applyParameters(from: registry)
        busCodecProgram.applyParameters(from: registry)
    }

    /// Evaluates the graph to PRIMARY, in dependency order, and returns every
    /// texture produced along the way.
    ///
    /// Shared with the self-QA checks so they exercise the same traversal the live
    /// render loop does, rather than a copy of it that can drift.
    @discardableResult
    func evaluateGraph(context: RenderContext) -> [String: MTLTexture] {
        applyAllParameters()
        // Before evaluation, so each loop sees last frame's picture rather than one
        // being overwritten as this frame is built.
        if !feedbackSends.isEmpty { applyFeedbackSends() }
        var produced: [String: MTLTexture] = [:]
        for identifier in graph.evaluationOrder(from: Engine.outputSlot) {
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

    /// Sets the tempo and announces it, whatever the source.
    ///
    /// Every route to a tempo change goes through here — tap, detection, manual —
    /// so the announcement cannot be forgotten by one of them.
    func setTempo(_ beatsPerMinute: Double) {
        guard beatsPerMinute > 0 else { return }
        transport.beatsPerMinute = beatsPerMinute
        // Announce only a real change: detection nudges by fractions constantly, and
        // flashing the window for each would be a strobe rather than a signal.
        if abs(beatsPerMinute - lastAnnouncedTempo) > 0.4 {
            lastAnnouncedTempo = beatsPerMinute
            onTempoChanged?(beatsPerMinute)
        }
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

    /// Switches a channel between playing a file and running a generator.
    ///
    /// This is a module swap in the sense SPEC 13 means: the graph edge moves, and
    /// any mapping whose param code exists on the new source keeps working. That is
    /// the whole reason mappings target codes rather than node pointers.
    func setChannelSource(_ kind: ChannelSourceKind, channel letter: String) {
        let subMix = GraphTopology.subMix(forChannel: Engine.slot(forChannel: letter))
        // A and C are the lower layer of their bus; B and D the upper.
        let inputIndex = (letter == "A" || letter == "C") ? 0 : 1
        let newUpstream = kind == .file
            ? Engine.slot(forChannel: letter)
            : Engine.generatorSlot(forChannel: letter)

        graph.connect(from: newUpstream, to: subMix, inputIndex: inputIndex)
        channelSourceKinds[letter] = kind
        Log.info(.graph, "channel \(letter) now sourced from \(kind == .file ? "a file" : "a generator")")
    }

    /// Switches the clock source, starting or stopping audio analysis as needed.
    ///
    /// - Returns: false when audio was requested but could not be started, in which
    ///   case the source stays internal and the UI should say so rather than
    ///   silently showing "Audio" with nothing behind it.
    @discardableResult
    func setClockSource(_ source: ClockSource) -> Bool {
        guard source != clockSource else { return true }
        switch source {
        case .internalTransport:
            audioInput?.stop()
            audioInput = nil
            audioReactivity.isRunning = false
            audioReactivity.reset()
            clockSource = .internalTransport
            return true

        case .audio:
            let input = AudioInput()
            input.onFrame = { [weak self] frame in
                guard let self else { return }
                // Analysis arrives on the audio thread; parameter state and the UI
                // both live on the main thread.
                DispatchQueue.main.async {
                    self.audioReactivity.update(with: frame, into: self.registry)
                }
            }
            input.onTempo = { [weak self] estimate in
                DispatchQueue.main.async {
                    self?.applyDetectedTempo(estimate)
                }
            }
            guard input.start() else {
                Log.warn(.clock, "audio clock requested but unavailable; staying on the internal clock")
                return false
            }
            audioInput = input
            audioReactivity.isRunning = true
            clockSource = .audio
            return true
        }
    }

    /// Takes a detected tempo, if it is confident enough to be worth taking.
    ///
    /// A low-confidence estimate is worse than none: it drags the transport around
    /// on speech, drones and applause. The threshold is what keeps the clock steady
    /// through a quiet passage rather than chasing noise.
    private func applyDetectedTempo(_ estimate: TempoEstimate) {
        latestTempoEstimate = estimate
        guard clockSource == .audio, estimate.confidence > 0.25 else { return }
        // Ignore tiny corrections: nudging the tempo every window would make
        // everything locked to it jitter.
        guard abs(estimate.beatsPerMinute - transport.beatsPerMinute) > 0.5 else { return }
        setTempo(estimate.beatsPerMinute)
    }

    /// Sets a bus's interchange codec, which decides what data effects it offers.
    func setInterchange(_ codec: InterchangeCodec, forBus bus: String) {
        switch bus {
        case "ONE": busCodecOne.interchange = codec
        case "TWO": busCodecTwo.interchange = codec
        default: busCodecProgram.interchange = codec
        }
    }

    // MARK: - Feedback sends (SPEC 10)

    /// Which slot, if any, feeds each bus's feedback loop from elsewhere.
    private var feedbackSends: [String: String] = [:]

    /// Routes a bus into a feedback loop's history, or clears it with nil.
    ///
    /// - Parameters:
    ///   - slot: the node whose picture becomes the loop's history.
    ///   - bus: "ONE" or "TWO".
    func setFeedbackSend(from slot: String?, toBus bus: String) {
        if let slot {
            feedbackSends[bus] = slot
            Log.info(.render, "feedback send: \(slot) into bus \(bus)")
        } else {
            feedbackSends.removeValue(forKey: bus)
            Log.info(.render, "feedback send into bus \(bus) cleared")
        }
        applyFeedbackSends()
    }

    /// Which slot is feeding a bus's loop, if any.
    func feedbackSend(forBus bus: String) -> String? { feedbackSends[bus] }

    /// Hands each loop the PREVIOUS frame of whatever is routed into it.
    ///
    /// Previous, not current: a bus downstream of a feedback node feeding back into
    /// it is a cycle, and a graph containing one has no evaluation order at all. The
    /// one-frame delay is what makes the send expressible, and it is the same delay
    /// the internal ring already uses.
    private func applyFeedbackSends() {
        feedback.externalHistory = feedbackSends["ONE"].flatMap { currentTextures[$0] }
        feedbackTwo.externalHistory = feedbackSends["TWO"].flatMap { currentTextures[$0] }
    }

    // MARK: - Output emulation (SPEC 9, 13)

    /// Whether the output carries NTSC signal character.
    ///
    /// Distinct from the per-bus composite codec, which is a look you apply to one
    /// side of the mix. This one is about what the SIGNAL becomes on its way out, so
    /// it sits after everything and applies to whatever is on air.
    var isOutputNTSCEnabled: Bool {
        get { (registry.value(slot: Engine.compositeProgramSlot, code: .wetDry) ?? 0) > 0.5 }
        set {
            registry.setValue(
                newValue ? 1 : 0, slot: Engine.compositeProgramSlot, code: .wetDry)
            Log.info(.render, "output NTSC emulation \(newValue ? "on" : "off")")
        }
    }

    /// Whether the output is passed through DV, giving 4:1:1 colour and 8-bit.
    ///
    /// Turning it on sets one generation; the popover can ask for more. Off is zero
    /// generations rather than one, because one pass is already a real change to the
    /// picture and "off" has to mean untouched.
    var isOutputDVEnabled: Bool {
        get { (registry.value(slot: Engine.busCodecProgramSlot, code: .compositeGeneration) ?? 0) >= 1 }
        set {
            setInterchange(newValue ? .dv : .none, forBus: GraphTopology.primary)
            registry.setValue(
                newValue ? 1 : 0,
                slot: Engine.busCodecProgramSlot, code: .compositeGeneration)
            Log.info(.render, "output DV emulation \(newValue ? "on" : "off")")
        }
    }

    /// The data-effect family a bus currently offers.
    func dataEffectFamily(forBus bus: String) -> DataEffectFamily {
        switch bus {
        case "ONE": busCodecOne.dataEffectFamily
        case "TWO": busCodecTwo.dataEffectFamily
        default: busCodecProgram.dataEffectFamily
        }
    }

    /// The data-effect family a channel's loaded media offers.
    func dataEffectFamily(forChannel letter: String) -> DataEffectFamily {
        // A channel showing a generator has no bitstream, whatever file may also be
        // loaded behind it.
        if channelSourceKinds[letter] == .generator { return .none }
        return sources[letter]?.dataEffectFamily ?? .none
    }

    /// Whether the program bus carries the test pattern instead of the live mix.
    ///
    /// Routed at the graph, not painted over the preview, so what the CRT receives
    /// and what the operator sees are the same signal — which is the entire point of
    /// having a test pattern for calibration (SPEC 11).
    private(set) var programShowsTestPattern = false

    /// Switches the program bus between the live mix and the test pattern.
    func setProgramShowsTestPattern(_ showsPattern: Bool) {
        guard showsPattern != programShowsTestPattern else { return }
        programShowsTestPattern = showsPattern
        if showsPattern {
            graph.connect(from: Engine.testPatternSlot, to: GraphTopology.primary, inputIndex: 0)
            registry.setValue(0, slot: GraphTopology.primary, code: .crossfadeOneTwo)
        } else {
            // The bus data stage sits at the END of each chain, just before the mix:
        // it re-encodes whatever the chain produced, so it damages the finished bus
        // rather than something half-processed.
        busCodecOne = BusCodecNode(identifier: Engine.busCodecOneSlot, context: metal)
        busCodecTwo = BusCodecNode(identifier: Engine.busCodecTwoSlot, context: metal)
        busCodecProgram = BusCodecNode(identifier: Engine.busCodecProgramSlot, context: metal)
        graph.add(busCodecOne)
        graph.add(busCodecTwo)
        graph.add(busCodecProgram)

        graph.connect(from: Engine.mx1OneSlot, to: Engine.busCodecOneSlot, inputIndex: 0)
        graph.connect(from: Engine.busCodecOneSlot, to: GraphTopology.primary, inputIndex: 0)
        }
        Log.info(.output, "program bus now carries \(showsPattern ? "the test pattern" : "the live mix")")
    }

    /// True when this frame should be blacked out for BFI.
    func isBlackFrame() -> Bool {
        blackFrameInsertion.isBlackFrame(frameIndex)
    }
}

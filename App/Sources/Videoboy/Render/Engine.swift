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
enum ChannelSourceKind: Equatable {
    case file
    case generator
    /// The emulated machine — ONE node, shared.
    ///
    /// Shared rather than one per channel because there is one Amiga. Pointing two
    /// channels at it gives both the same picture, which is what a real machine with
    /// one video output does, and what makes a cut between them meaningful.
    case emulator
    /// A configured source (SPEC 6, SPEC 10), by its `ConfiguredSource.id`.
    ///
    /// Was a fixed one-node `case capture` before this — a single global camera slot
    /// that nothing could even route a channel to (see `Engine.setChannelSource`'s
    /// history). Any number of cameras, captured windows, IP cameras and DV decks can
    /// exist now, so the case needs to say WHICH one — an id rather than a kind,
    /// because two cameras of the same kind are still two different sources.
    case capture(String)
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

    /// The node that puts a scope into the programme picture, when SEND is lit.
    private(set) var scopeOverlay: ScopeOverlayNode?

    /// The emulated machine, as a source any channel can be pointed at.
    private(set) var emulator: EmulatedTitlerNode?

    /// Bus effects, one chain per sub-mix (SPEC 2's `bus FX`). The composite codec is
    /// the analog character; echo and feedback sit after it.
    private(set) var compositeCodec: CompositeCodecNode!
    /// Every channel's own copy of the effect chain, in signal order.
    private(set) var channelEffects: [String: [Node]] = [:]

    private(set) var transformOne: TransformNode!
    private(set) var transformTwo: TransformNode!
    private(set) var colour: ColourControlNode!
    private(set) var echo: EchoNode!
    private(set) var feedback: FeedbackNode!
    private(set) var compositeCodecTwo: CompositeCodecNode!
    private(set) var colourTwo: ColourControlNode!
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

    /// Configured sources (SPEC 6, SPEC 10) — cameras, captured windows, IP cameras,
    /// DV decks — by `ConfiguredSource.id`. One `CaptureSourceNode` per entry, created
    /// the first time it is actually needed (`ensureCaptureNode`) rather than one
    /// fixed instance up front, because the LIST is open-ended: any number can exist,
    /// added and removed at runtime from Settings, unlike the four channels or the one
    /// emulator that `buildGraph` can simply enumerate in advance.
    private(set) var captureNodes: [String: CaptureSourceNode] = [:]

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

        // PER-CHANNEL FX (SPEC 2's chFX). Each channel gets its own copy of every
        // effect, between its source and the sub-mix, so an effect can be applied to
        // A without also applying it to B.
        //
        // These do not replace the bus copies downstream of the mix — they sit
        // alongside them, and that is what makes the card's A / B / BOTH selector
        // honest: A and B address these, BOTH addresses the bus copy, which affects
        // both channels because it runs after they are mixed. One pass instead of
        // two, and genuinely "both" rather than "two things set to the same value".
        //
        // Affordable, and measured rather than assumed: one chain is 1.54 ms and all
        // four channels come to 6.17 ms of a 33.4 ms frame (PerChannelCostBenchmark).
        // Idle cost is lower still, because every one of these returns its input
        // untouched while bypassed.
        for (letter, subMix, index) in [
            ("A", GraphTopology.subMixOne, 0), ("B", GraphTopology.subMixOne, 1),
            ("C", GraphTopology.subMixTwo, 0), ("D", GraphTopology.subMixTwo, 1)
        ] {
            let source = Engine.slot(forChannel: letter)
            var upstream = source

            let transform = TransformNode(
                identifier: Engine.channelSlot(letter, "transform"), context: metal)
            let colour = ColourControlNode(
                identifier: Engine.channelSlot(letter, "colour"), context: metal)
            let composite = CompositeCodecNode(
                identifier: Engine.channelSlot(letter, "composite"), context: metal)
            let echo = EchoNode(
                identifier: Engine.channelSlot(letter, "echo"), context: metal)
            let feedbackNode = FeedbackNode(
                identifier: Engine.channelSlot(letter, "feedback"), context: metal)
            let mx1Node = MX1EffectNode(
                identifier: Engine.channelSlot(letter, "mx1"), context: metal)

            for node in [transform, colour, composite, echo, feedbackNode, mx1Node] as [Node] {
                graph.add(node)
                graph.connect(from: upstream, to: node.identifier, inputIndex: 0)
                upstream = node.identifier
            }
            channelEffects[letter] = [transform, colour, composite, echo, feedbackNode, mx1Node]
            graph.connect(from: upstream, to: subMix, inputIndex: index)
        }
        // Bus FX on ONE, in order: composite codec, then echo, then feedback. The
        // codec runs first on purpose — the analog character should be applied to the
        // picture, and the trails and loop then act on the already-degraded signal,
        // which is the order a real chain would have.
        // The grade goes FIRST in the chain, before the composite codec. Matching
        // four sources to each other is something you do to a clean picture; doing it
        // after the NTSC path means grading artefacts as well as the image, and the
        // corrections stop behaving the way the controls say they do.
        transformOne = TransformNode(identifier: Engine.transformSlot, context: metal)
        colour = ColourControlNode(identifier: Engine.colourSlot, context: metal)
        compositeCodec = CompositeCodecNode(identifier: Engine.compositeSlot, context: metal)
        echo = EchoNode(identifier: Engine.echoSlot, context: metal)
        feedback = FeedbackNode(identifier: Engine.feedbackSlot, context: metal)
        graph.add(transformOne)
        graph.add(colour)
        graph.add(compositeCodec)
        graph.add(echo)
        graph.add(feedback)

        graph.connect(from: GraphTopology.subMixOne, to: Engine.transformSlot, inputIndex: 0)
        graph.connect(from: Engine.transformSlot, to: Engine.colourSlot, inputIndex: 0)
        graph.connect(from: Engine.colourSlot, to: Engine.compositeSlot, inputIndex: 0)
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
        transformTwo = TransformNode(identifier: Engine.transformTwoSlot, context: metal)
        colourTwo = ColourControlNode(identifier: Engine.colourTwoSlot, context: metal)
        compositeCodecTwo = CompositeCodecNode(identifier: Engine.compositeTwoSlot, context: metal)
        echoTwo = EchoNode(identifier: Engine.echoTwoSlot, context: metal)
        feedbackTwo = FeedbackNode(identifier: Engine.feedbackTwoSlot, context: metal)
        graph.add(transformTwo)
        graph.add(colourTwo)
        graph.add(compositeCodecTwo)
        graph.add(echoTwo)
        graph.add(feedbackTwo)

        graph.connect(from: GraphTopology.subMixTwo, to: Engine.transformTwoSlot, inputIndex: 0)
        graph.connect(from: Engine.transformTwoSlot, to: Engine.colourTwoSlot, inputIndex: 0)
        graph.connect(from: Engine.colourTwoSlot, to: Engine.compositeTwoSlot, inputIndex: 0)
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

        // The scope overlay, after everything. SEND on a preview's scope keys puts the
        // instrument into the picture that goes to air, which is only possible at the
        // very end — anything earlier and the bus codec and the NTSC stage would chew
        // the trace up on its way past.
        //
        // It costs NOTHING when nothing is being sent: the node returns its input
        // untouched, with no pass and no upload. That matters because it is on the
        // path of every frame that goes out.
        let scopeOverlay = ScopeOverlayNode(
            identifier: Engine.scopeOverlaySlot, context: metal)
        graph.add(scopeOverlay)
        graph.connect(
            from: Engine.busCodecProgramSlot, to: Engine.scopeOverlaySlot, inputIndex: 0)
        self.scopeOverlay = scopeOverlay

        // The emulated machine, created up front for the same reason the generators
        // are: so it exists, is addressable and can be assigned to a channel without
        // the graph being rebuilt. It renders nothing until a machine is running,
        // which is the state it is in on any machine with no emulator installed.
        let emulator = EmulatedTitlerNode(
            identifier: Engine.emulatorSlot,
            host: UnavailableEmulatorHost(reason: FSUAEInstallation.installationHint),
            context: metal)
        graph.add(emulator)
        self.emulator = emulator

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
        // Configured sources (cameras, captured windows...) are NOT created here —
        // there can be any number of them and the list changes at runtime from
        // Settings, so each gets its node lazily, in `ensureCaptureNode`.
        testPattern = TestPatternSourceNode(identifier: Engine.testPatternSlot, context: metal)
        graph.add(testPattern)

        graph.registerParameters(into: registry)

        // The bus effects start bypassed so the app opens showing what was loaded
        // rather than a processed version of it. Their switches in the FX panel are
        // what turns them on, which keeps "what you see" traceable to a deliberate act.
        //
        // The GRADE is the exception, and it is an exception with a reason rather than
        // a convenience: a colour node at its neutral settings changes nothing and
        // skips its render pass entirely, so leaving it live costs nothing and means
        // its faders work the moment you touch them. Every other effect here alters
        // the picture the instant it is armed.
        //
        // This list and the cards' `isEnabled` MUST agree. When they did not, the
        // switch read one thing and the engine did another — which is the NTSC boot
        // bug, and it is why `liveAtLaunchSlots` is spelled out beside the list it
        // is subtracted from rather than left implicit somewhere else.
        for slot in Engine.busEffectSlots where !Engine.liveAtLaunchSlots.contains(slot) {
            registry.setValue(0, slot: slot, code: .wetDry)
        }

        // The per-channel corruptors too. Their cards read OFF, and a switch that
        // says off while the node is live is the same boot-state lie the bus effects
        // had — it just hides better here, because the corrupt amount also starts at
        // zero so there is nothing to see until someone moves a fader.
        for letter in ["A", "B", "C", "D"] {
            registry.setValue(0, slot: Engine.slot(forChannel: letter), code: .wetDry)
            for node in channelEffects[letter] ?? [] {
                registry.setValue(0, slot: node.identifier, code: .wetDry)
            }
        }
        Log.info(.graph, "graph built: \(graph.nodeCount) nodes, max latency \(graph.maximumLatencyInFrames) frames")
    }

    /// Bus effects that are live when the app opens, rather than bypassed.
    ///
    /// Anything here must also be declared `isEnabled: true` on its card in
    /// `PanelSet`, or the switch and the engine will disagree at launch.
    static let liveAtLaunchSlots: Set<String> = [colourSlot, colourTwoSlot]

    /// Slot names for the bus effects and the extra sources, so mappings and
    /// templates can address them by a stable name.
    static let compositeSlot = "fx.one.composite"
    /// A per-channel effect's slot name: `fx.a.colour`, `fx.d.mx1`.
    static func channelSlot(_ letter: String, _ effect: String) -> String {
        "fx.\(letter.lowercased()).\(effect)"
    }

    static let transformSlot = "fx.one.transform"
    static let colourSlot = "fx.one.colour"
    static let echoSlot = "fx.one.echo"
    static let feedbackSlot = "fx.one.feedback"
    static let compositeTwoSlot = "fx.two.composite"
    static let transformTwoSlot = "fx.two.transform"
    static let colourTwoSlot = "fx.two.colour"
    static let echoTwoSlot = "fx.two.echo"
    static let feedbackTwoSlot = "fx.two.feedback"
    static let busCodecOneSlot = "data.one"
    static let busCodecTwoSlot = "data.two"
    static let busCodecProgramSlot = "data.program"
    static let compositeProgramSlot = "fx.program.composite"
    static let mx1OneSlot = "fx.one.mx1"
    static let mx1TwoSlot = "fx.two.mx1"

    /// The scope overlay, last of all — see `scopeOverlaySlot`.
    static let scopeOverlaySlot = "out.scopeoverlay"

    /// The emulated machine, as a source. One for the whole app — see
    /// `ChannelSourceKind.emulator`.
    static let emulatorSlot = "source.emu"

    /// The last node in the graph — what output and the programme preview show.
    ///
    /// Named separately from `GraphTopology.primary` because they are not the same
    /// thing: primary is the ONE/TWO mix, and the programme data stage runs after it.
    /// Conflating them is what left that stage unconnected.
    static var outputSlot: String { scopeOverlaySlot }

    /// What the PROGRAMME scopes measure.
    ///
    /// The end of the picture chain, and deliberately NOT `outputSlot`, which now has
    /// the scope overlay after it. Measuring the output would mean measuring a picture
    /// with the scope already drawn on it — the trace would feed into its own waveform
    /// and climb until the whole instrument was white. Scopes read what goes out
    /// BEFORE the instrument is drawn over it.
    static var scopeSourceSlot: String { busCodecProgramSlot }

    /// The graph slot for one configured source, by its `ConfiguredSource.id`.
    static func captureSlot(for id: String) -> String { "source.capture.\(id)" }

    static let testPatternSlot = "source.testpattern"

    /// The node for a configured source, creating and registering it the first time
    /// it is asked for.
    ///
    /// Called when a channel is pointed at the source, or when a live capture session
    /// (AVFoundation, ScreenCaptureKit) is about to start feeding it — whichever
    /// happens first. Idempotent: asking twice for the same id returns the same node,
    /// the same way `load(url:)` re-registers a `ClipSourceNode`'s parameters without
    /// creating a second one.
    @discardableResult
    func ensureCaptureNode(id: String) -> CaptureSourceNode {
        if let existing = captureNodes[id] { return existing }
        let node = CaptureSourceNode(identifier: Engine.captureSlot(for: id), context: metal)
        captureNodes[id] = node
        graph.add(node)
        registry.register(slot: node.identifier, parameters: node.parameters)
        return node
    }

    /// Every bus-effect slot, both chains.
    /// Every effect that must boot BYPASSED.
    ///
    /// The app should open showing what was loaded rather than a processed version of
    /// it, and — just as important — every switch in the window has to agree with the
    /// engine at launch. The programme composite was missing from this list, so NTSC
    /// emulation was on while its switch read off: the picture was being processed
    /// and nothing on screen said so. A node left off here is invisible until someone
    /// notices the output looks wrong.
    static let busEffectSlots = [
        transformSlot, colourSlot, compositeSlot, echoSlot, feedbackSlot, mx1OneSlot,
        transformTwoSlot, colourTwoSlot, compositeTwoSlot, echoTwoSlot, feedbackTwoSlot, mx1TwoSlot,
        compositeProgramSlot, busCodecProgramSlot
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
        //
        // LOOKED UP THROUGH `self` ON EACH FIRING, never captured. Capturing the node
        // object meant that anything replacing `busCodecOne` — as the test-pattern
        // toggle used to — left this closure holding the old instance: the beat reroll
        // went to a node nothing rendered, and the dead node could never be freed
        // because the scheduler still owned it. Reading the property each time means a
        // swap is simply picked up, and nothing here keeps a node alive.
        for name in ["ONE", "TWO", "PROGRAM"] {
            scheduler.subscribe(subdivision: .quarter, latencyInFrames: 0) { [weak self] event in
                guard let codec = self?.busCodec(forBus: name) else { return }
                codec.rerollCorruptionSeed(using: UInt64(event.targetBeat * 1000) &+ 29)
                Log.info(.clock, "bus \(name) data effects reseeded for beat \(event.targetBeat)")
            }
        }
    }

    /// The data codec on a bus, by the name the schedule and the UI both use.
    private func busCodec(forBus bus: String) -> BusCodecNode? {
        switch bus {
        case "ONE": busCodecOne
        case "TWO": busCodecTwo
        default: busCodecProgram
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
        //
        // Applied by `evaluateGraph`, NOT here. It calls `applyAllParameters` itself so
        // the self-QA checks get the same treatment as the live loop, so doing it here
        // too ran the whole thing — ~30 nodes, including a dynamic-cast loop over all
        // 24 per-channel effects — twice every frame for one set of values. The LFO
        // update above still happens first, so nothing about the ordering changes.

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
        for nodes in channelEffects.values {
            for node in nodes {
                switch node {
                case let n as TransformNode: n.applyParameters(from: registry)
                case let n as ColourControlNode: n.applyParameters(from: registry)
                case let n as CompositeCodecNode: n.applyParameters(from: registry)
                case let n as EchoNode: n.applyParameters(from: registry)
                case let n as FeedbackNode: n.applyParameters(from: registry)
                case let n as MX1EffectNode: n.applyParameters(from: registry)
                default: break
                }
            }
        }
        transformOne.applyParameters(from: registry)
        transformTwo.applyParameters(from: registry)
        colour.applyParameters(from: registry)
        echo.applyParameters(from: registry)
        feedback.applyParameters(from: registry)
        compositeProgram.applyParameters(from: registry)
        mx1One.applyParameters(from: registry)
        mx1Two.applyParameters(from: registry)
        compositeCodecTwo.applyParameters(from: registry)
        colourTwo.applyParameters(from: registry)
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

    /// Takes whatever is loaded out of a channel. Safe to call on an empty one.
    ///
    /// Returns false only when the letter names no source at all, so a caller can
    /// tell "there was nothing to eject" from "that channel does not exist".
    @discardableResult
    func unload(channel letter: String) -> Bool {
        guard let node = sources[letter] else { return false }
        node.unload()
        return true
    }

    /// Starts or stops a channel's playback.
    func setPlaying(_ playing: Bool, channel letter: String) {
        sources[letter]?.isPlaying = playing
    }

    /// Exchanges the clips loaded in two channels, keeping each one playing.
    ///
    /// Asked for as a show control: the thing you reach for when the clip that should
    /// be coming up next is in the wrong channel and the fader is already where you
    /// want it. Swapping the CLIPS rather than moving the fader means whatever is on
    /// air stays on air and the picture does not jump.
    ///
    /// The decoders move as objects, so nothing is re-opened and no seek happens — a
    /// swap costs nothing on the frame path, which is the only way it is usable during
    /// a performance.
    ///
    /// What does NOT move is everything the registry owns: corruption, wet/dry, and
    /// every effect in the channel's chain. Those belong to the channel, not the clip.
    /// A performer who has dialled damage into A expects A to keep sounding like A
    /// when a different picture arrives in it — the alternative is that one button
    /// silently rewrites half the mixer.
    ///
    /// - Returns: false when either letter names no source, so a caller can tell that
    ///   from "swapped two empty channels", which is legitimate and does nothing
    ///   visible.
    @discardableResult
    func swapChannels(_ first: String, _ second: String) -> Bool {
        guard first != second,
              let firstNode = sources[first],
              let secondNode = sources[second] else { return false }

        let firstClip = firstNode.takeLoadedClip()
        let secondClip = secondNode.takeLoadedClip()
        firstNode.adopt(secondClip)
        secondNode.adopt(firstClip)

        // AND WHAT THE CHANNEL IS ACTUALLY SHOWING, not only the clip behind it.
        //
        // Swapping the two `ClipSourceNode`s is the whole job only when both channels
        // are playing FILES. A channel pointed at the emulator takes its picture from
        // the shared emulator slot, and one on a generator from its own generator node
        // — so the clips changed places underneath and nothing on screen moved. The
        // swap looked broken, and on a file/file pair it looked fine, which is the
        // worst way for a bug like this to present.
        //
        // The generator KIND travels with the channel for the same reason the clip
        // does: it is what that channel was showing. The emulator needs nothing moved,
        // because there is one machine and both channels address the same node — only
        // which of them is pointed at it changes.
        let firstGenerator = generators[first]?.generator
        let secondGenerator = generators[second]?.generator
        if let secondGenerator { generators[first]?.generator = secondGenerator }
        if let firstGenerator { generators[second]?.generator = firstGenerator }

        // Re-routed through `setChannelSource` rather than by assigning the dictionary,
        // so the graph edges move with the state. Setting `channelSourceKinds` directly
        // would leave each channel's edge pointing at what it used to show.
        let firstKind = channelSourceKinds[first] ?? .file
        let secondKind = channelSourceKinds[second] ?? .file
        if firstKind != secondKind {
            setChannelSource(secondKind, channel: first)
            setChannelSource(firstKind, channel: second)
        }

        Log.info(.dv, "swapped channel \(first) and channel \(second): "
            + "\(first) now has \(firstNode.mediaURL?.lastPathComponent ?? "nothing"), "
            + "\(second) now has \(secondNode.mediaURL?.lastPathComponent ?? "nothing")")
        return true
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
        // Every configured source, not one fixed capture node — the round trip is a
        // property of the physical chain (HDMI card, cable, DVC100), not of which
        // particular camera or window happens to be assigned right now.
        for node in captureNodes.values { node.measuredLatencyFrames = latency.frames }
        Log.info(.render, "feedback round trip \(latency.frames) frames (\(String(format: "%.1f", latency.seconds * 1000)) ms); scheduling now compensates for it")
    }

    /// Switches a channel between playing a file and running a generator.
    ///
    /// This is a module swap in the sense SPEC 13 means: the graph edge moves, and
    /// any mapping whose param code exists on the new source keeps working. That is
    /// the whole reason mappings target codes rather than node pointers.
    /// Which node a channel is currently taking its picture from.
    ///
    /// The preview has to ask, rather than assume the file slot: a channel showing a
    /// generator renders from a different node entirely, and a preview wired to the
    /// file node shows an empty rectangle while the generator plays into the bus.
    func sourceSlot(forChannel letter: String) -> String {
        Engine.upstreamSlot(for: channelSourceKinds[letter] ?? .file, channel: letter)
    }

    /// Which node feeds a channel, for a given kind of source.
    ///
    /// One function rather than the same conditional in two places: the preview asked
    /// one way and the graph connected the other, and the two agreeing is the whole
    /// reason a channel's picture and its preview show the same thing.
    static func upstreamSlot(for kind: ChannelSourceKind, channel letter: String) -> String {
        switch kind {
        case .file: Engine.slot(forChannel: letter)
        case .generator: Engine.generatorSlot(forChannel: letter)
        case .emulator: Engine.emulatorSlot
        case .capture(let id): Engine.captureSlot(for: id)
        }
    }

    func setChannelSource(_ kind: ChannelSourceKind, channel letter: String) {
        // A configured source's node is created lazily — see `ensureCaptureNode` — so
        // it must exist before the edge below can name it. Every other kind's node was
        // already added in `buildGraph`.
        if case .capture(let id) = kind { ensureCaptureNode(id: id) }

        let subMix = GraphTopology.subMix(forChannel: Engine.slot(forChannel: letter))
        // A and C are the lower layer of their bus; B and D the upper.
        let inputIndex = (letter == "A" || letter == "C") ? 0 : 1
        let newUpstream = Engine.upstreamSlot(for: kind, channel: letter)

        // INTO THE HEAD OF THE CHANNEL'S FX CHAIN, not straight at the sub-mix.
        //
        // Connecting the new source directly to `subMix` replaces the edge that the
        // chain's LAST node owns, which lifts the whole per-channel chain — transform,
        // grade, composite, echo, feedback, MX-1 — out of the signal path. Switching
        // once was enough to do it, and switching back to the file did not put it
        // back: it simply pointed the file at the sub-mix too. Every per-channel
        // effect on that channel then did nothing, with its card still lit and its
        // faders still moving, which reads as "the effects are broken" rather than as
        // a routing mistake.
        //
        // The chain is addressed through `channelEffects` rather than by naming the
        // transform slot here, so adding or reordering a per-channel effect in
        // `buildGraph` cannot leave this function pointing at a node that is no
        // longer first.
        let chain = channelEffects[letter] ?? []
        if let head = chain.first, let tail = chain.last {
            graph.connect(from: newUpstream, to: head.identifier, inputIndex: 0)
            // Re-assert the tail edge as well. A build that ran the old code has
            // already had this edge replaced, and this is what heals it rather than
            // requiring the graph to be rebuilt from scratch.
            graph.connect(from: tail.identifier, to: subMix, inputIndex: inputIndex)
        } else {
            // No chain for this channel (nothing builds one today, but a channel
            // without effects must still reach the mix rather than go silent).
            graph.connect(from: newUpstream, to: subMix, inputIndex: inputIndex)
        }
        channelSourceKinds[letter] = kind

        let description: String
        switch kind {
        case .file: description = "a file"
        case .generator: description = "a generator"
        case .emulator: description = "the emulator"
        case .capture(let id): description = "configured source \(id)"
        }
        Log.info(.graph, "channel \(letter) now sourced from \(description)")
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

    /// Which boundary beat-synced moves wait for, from the toolbar's DIV field.
    ///
    /// It was a control that changed a label and nothing else — the scheduler's own
    /// subscriptions are per-node, and nothing read the setting. Beat-syncing a cut
    /// to "the next 1/16" is a different musical decision from the next bar, so the
    /// field has to mean something.
    var beatSubdivision: Subdivision = .quarter {
        didSet {
            guard beatSubdivision != oldValue else { return }
            Log.info(.clock, "beat-synced moves now wait for \(beatSubdivision.rawValue)")
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
        // A channel showing a generator or a live configured source has no bitstream,
        // whatever file may also be loaded behind it.
        switch channelSourceKinds[letter] {
        case .generator, .capture: return .none
        default: return sources[letter]?.dataEffectFamily ?? .none
        }
    }

    /// Whether the program bus carries the test pattern instead of the live mix.
    ///
    /// Routed at the graph, not painted over the preview, so what the CRT receives
    /// and what the operator sees are the same signal — which is the entire point of
    /// having a test pattern for calibration (SPEC 11).
    private(set) var programShowsTestPattern = false

    /// Where the ONE/TWO fader was before the test pattern took the bus, so switching
    /// back puts it where the operator left it.
    ///
    /// Showing the pattern forces the crossfader to 0 to get bus ONE out of the way.
    /// Nothing used to put it back, so after one round trip PROGRAM carried ONE only
    /// and the fader looked broken until it was touched — during calibration, which is
    /// exactly when the pattern is being toggled.
    private var crossfadeBeforeTestPattern: Double?

    /// Switches the program bus between the live mix and the test pattern.
    ///
    /// This used to REBUILD the three bus codecs on the way out — copy-pasted from
    /// `buildGraph`, comment and all. That orphaned the scheduler's beat subscriptions
    /// (which hold the node objects), leaked three nodes with their encoders and
    /// textures on every toggle, and silently reset each node's `interchange` to none
    /// while `isOutputDVEnabled` still read ON from the registry. The routing was the
    /// one thing that copy-paste got right, and it is the only thing needed here.
    func setProgramShowsTestPattern(_ showsPattern: Bool) {
        guard showsPattern != programShowsTestPattern else { return }
        programShowsTestPattern = showsPattern
        if showsPattern {
            crossfadeBeforeTestPattern =
                registry.value(slot: GraphTopology.primary, code: .crossfadeOneTwo)
            graph.connect(from: Engine.testPatternSlot, to: GraphTopology.primary, inputIndex: 0)
            registry.setValue(0, slot: GraphTopology.primary, code: .crossfadeOneTwo)
        } else {
            // Put the mix back on PROGRAM's first input. The nodes themselves were
            // never removed, so only this one edge has to be restored.
            graph.connect(from: Engine.busCodecOneSlot, to: GraphTopology.primary, inputIndex: 0)
            if let crossfadeBeforeTestPattern {
                registry.setValue(
                    crossfadeBeforeTestPattern,
                    slot: GraphTopology.primary, code: .crossfadeOneTwo)
            }
            crossfadeBeforeTestPattern = nil
        }
        Log.info(.output, "program bus now carries \(showsPattern ? "the test pattern" : "the live mix")")
    }

    /// True when this frame should be blacked out for BFI.
    func isBlackFrame() -> Bool {
        blackFrameInsertion.isBlackFrame(frameIndex)
    }
}

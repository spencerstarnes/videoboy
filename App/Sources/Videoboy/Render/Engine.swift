//
//  Engine.swift — everything the app owns at runtime, wired together.
//
//  Purpose : Builds the fixed graph (SPEC 2), owns the clocks, the param registry and
//            MIDI, and drives one frame of work per 29.97 content frame (see `contentFrameDue`). The UI talks to
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
///
/// MIDI clock and Ableton Link were once listed here as "coming later". They were
/// removed rather than left as dead choices: the toolbar cycled through them, refused
/// them as unbuilt, and so could never get past Audio back to Internal.
enum ClockSource: Equatable {
    case internalTransport
    /// Beat detection, listening to the given source.
    case audio(AudioCaptureSource)

    /// Short enough for the toolbar's CLOCK field.
    var displayName: String {
        switch self {
        case .internalTransport: "Internal"
        case .audio(let source): source.shortName
        }
    }

    var isAudio: Bool {
        if case .audio = self { return true }
        return false
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

    /// The modules an effect chain can hold: natives, the built-in ISF ports, and
    /// every ISF file in the operator's folders (ISF-PLAN M7).
    let catalog: ModuleCatalog

    /// Each sub-mix's effect chain, as data (ISF-PLAN M5). The FX panel's cards are
    /// these entries; `rebuildChain` turns them into nodes and edges.
    private(set) var chains: [ChainBus: EffectChain] = [.one: .standard, .two: .standard]

    /// Every node the chains own, by slot (`fx.a.colour`, `fx.one.isf-bad-tv`…).
    private var chainNodes: [String: Node] = [:]

    /// Every channel's own copy of its chain, in signal order.
    private(set) var channelEffects: [String: [Node]] = [:]

    /// Bus data effects: re-encode the mix so its bitstream can be damaged.
    /// One per bus plus one on PROGRAM, since the format leaving the mixer is its
    /// own decision independent of what the sub-mixes carry.
    private(set) var busCodecOne: BusCodecNode!
    private(set) var busCodecTwo: BusCodecNode!
    private(set) var busCodecProgram: BusCodecNode!
    private(set) var compositeProgram: CompositeCodecNode!

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

    /// The most recent beat tracker report, for the toolbar's sync indicator.
    private(set) var latestBeatReport: BeatTrackerReport?

    /// Called on the main thread with every beat tracker report (four a second while
    /// audio is the clock), so the toolbar can show lock state and flash on a change.
    var onBeatReport: ((BeatTrackerReport) -> Void)?

    /// Why the last attempt to switch to an audio clock failed, for the notice.
    private(set) var audioClockFailure: String?

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

    /// - Parameter catalog: where modules come from. The self-QA passes one pointed at
    ///   temporary ISF folders, so a check never touches the operator's library.
    init(catalog: ModuleCatalog = ModuleCatalog()) {
        self.catalog = catalog
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

        // The bus data stage sits at the END of each chain, just before the mix:
        // it re-encodes whatever the chain produced, so it damages the finished bus
        // rather than something half-processed.
        busCodecOne = BusCodecNode(identifier: Engine.busCodecOneSlot, context: metal)
        busCodecTwo = BusCodecNode(identifier: Engine.busCodecTwoSlot, context: metal)
        busCodecProgram = BusCodecNode(identifier: Engine.busCodecProgramSlot, context: metal)
        graph.add(busCodecOne)
        graph.add(busCodecTwo)
        graph.add(busCodecProgram)
        graph.connect(from: Engine.busCodecOneSlot, to: GraphTopology.primary, inputIndex: 0)
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

        // THE EFFECT CHAINS, from data (ISF-PLAN M5). Each card is a node per channel
        // (upstream of the mix, SPEC 2's chFX) and one on the bus (after it), wired in
        // the chain's order. See `rebuildChain`.
        for bus in ChainBus.allCases { rebuildChain(bus) }

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
        // (Chain nodes are bypassed as they are made, in `makeChainNode`, with the
        // same `liveAtLaunchSlots` exception.)
        for slot in [Engine.compositeProgramSlot, Engine.busCodecProgramSlot] {
            registry.setValue(0, slot: slot, code: .wetDry)
        }

        // The per-channel corruptors too. Their cards read OFF, and a switch that
        // says off while the node is live is the same boot-state lie the bus effects
        // had — it just hides better here, because the corrupt amount also starts at
        // zero so there is nothing to see until someone moves a fader.
        for letter in ["A", "B", "C", "D"] {
            registry.setValue(0, slot: Engine.slot(forChannel: letter), code: .wetDry)
        }
        Log.info(.graph, "graph built: \(graph.nodeCount) nodes, max latency \(graph.maximumLatencyInFrames) frames")
    }

    // MARK: - Effect chains as data (ISF-PLAN M5)

    /// Rebuilds one sub-mix's chain in the graph from `chains[bus]`.
    ///
    /// Makes the nodes of cards that are new, removes the nodes of cards that are
    /// gone, and rewires every copy in order:
    ///
    ///     each channel:  its source → card, card, … → the sub-mix (its input)
    ///     the bus:       the sub-mix → card, card, … → the bus codec
    ///
    /// Main thread, between ticks — the same place every other graph edit happens.
    /// Nodes that stay are kept as they are, so a reorder costs no compiles, drops no
    /// trails and resets no values. A new ISF node compiles in the background and
    /// passes its picture through until it is ready.
    func rebuildChain(_ bus: ChainBus) {
        guard let chain = chains[bus] else { return }

        // Nodes of cards that are no longer in the chain.
        let wanted = Set(chain.entries.flatMap { EffectChain.slots(instanceID: $0.instanceID, bus: bus) })
        let lanes = bus.channels.map { $0.lowercased() } + [bus.lane]
        for slot in chainNodes.keys where !wanted.contains(slot) {
            let lane = slot.split(separator: ".").dropFirst().first.map(String.init) ?? ""
            guard lanes.contains(lane) else { continue }
            graph.remove(slot)
            chainNodes.removeValue(forKey: slot)
        }

        // Nodes of cards that are new.
        for entry in chain.entries {
            for slot in EffectChain.slots(instanceID: entry.instanceID, bus: bus) where chainNodes[slot] == nil {
                makeChainNode(slot: slot, moduleID: entry.moduleID)
            }
        }

        // Every channel's copy, from whatever the channel is showing into the mix.
        let subMix = bus == .one ? GraphTopology.subMixOne : GraphTopology.subMixTwo
        for (index, letter) in bus.channels.enumerated() {
            var previous = Engine.upstreamSlot(for: channelSourceKinds[letter] ?? .file, channel: letter)
            var nodes: [Node] = []
            for entry in chain.entries {
                let slot = EffectChain.slot(instanceID: entry.instanceID, lane: letter)
                graph.connect(from: previous, to: slot, inputIndex: 0)
                previous = slot
                if let node = chainNodes[slot] { nodes.append(node) }
            }
            graph.connect(from: previous, to: subMix, inputIndex: index)
            channelEffects[letter] = nodes
        }

        // The bus copy, from the mix into the bus's data stage.
        var previous = subMix
        for entry in chain.entries {
            let slot = EffectChain.slot(instanceID: entry.instanceID, lane: bus.lane)
            graph.connect(from: previous, to: slot, inputIndex: 0)
            previous = slot
        }
        graph.connect(from: previous, to: bus == .one ? Engine.busCodecOneSlot : Engine.busCodecTwoSlot, inputIndex: 0)

        Log.info(.graph, "chain \(bus.rawValue.uppercased()): "
            + chain.entries.map(\.instanceID).joined(separator: " → "))
    }

    /// Makes one copy of a module under a slot, registers its parameters, and starts
    /// it bypassed — every effect is something you switch on, except the grade on the
    /// bus (`liveAtLaunchSlots`), which costs nothing at its neutral settings.
    private func makeChainNode(slot: String, moduleID: String) {
        let node: Node
        if let module = catalog.module(moduleID), module.isAvailable {
            node = module.makeNode(identifier: slot, context: metal)
        } else {
            let reason = catalog.module(moduleID)?.problem ?? "module '\(moduleID)' is not installed"
            Log.warn(.graph, "\(slot): \(reason); passing the picture through")
            node = MissingModuleNode(identifier: slot, reason: reason)
        }
        graph.add(node)
        chainNodes[slot] = node
        registry.register(slot: slot, parameters: node.parameters)
        if !Engine.liveAtLaunchSlots.contains(slot) {
            registry.setValue(0, slot: slot, code: .wetDry)
        }
    }

    // MARK: - Hot reload (ISF-PLAN M6)

    /// Watches the ISF folders; see `startWatchingModules`.
    private var moduleWatcher: ISFFolderWatcher?

    /// Called on main after the modules changed on disk, so the panels can rebuild
    /// their cards and Add menus.
    var onModulesChanged: (() -> Void)?

    /// Starts noticing ISF files being added, edited, fixed or removed.
    func startWatchingModules() {
        // Videoboy's own folder exists from the start, so the first import into it
        // is noticed rather than needing a relaunch.
        if let user = catalog.folders.first(where: { $0.1 == .user })?.0 {
            do {
                try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
            } catch {
                Log.warn(.isf, "could not create \(user.path): \(error.localizedDescription)")
            }
        }
        moduleWatcher = ISFFolderWatcher(folders: catalog.folders) { [weak self] entries in
            self?.applyLibrary(entries)
        }
    }

    /// Applies a fresh scan of the ISF folders. Main thread, between ticks.
    ///
    /// - A live ISF node whose file changed reloads it: controls kept by name, the
    ///   old program drawing until the new one compiles, and — if the edit does not
    ///   parse or compile — kept drawing, with the reason on its card.
    /// - A card whose module was missing and is back gets its real node.
    /// - New files appear in the Add menu (`onModulesChanged`).
    func applyLibrary(_ entries: [ISFLibraryEntry]) {
        catalog.refresh(with: entries)
        let sources = Dictionary(entries.compactMap { entry in entry.source.map { (entry.url.standardizedFileURL, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        var reloaded = 0
        for bus in ChainBus.allCases {
            guard let chain = chains[bus] else { continue }
            var restored = false
            for entry in chain.entries {
                let module = catalog.module(entry.moduleID)
                for slot in EffectChain.slots(instanceID: entry.instanceID, bus: bus) {
                    switch chainNodes[slot] {
                    case let isf as ISFNode:
                        guard let url = module?.fileURL?.standardizedFileURL, let source = sources[url],
                              source != isf.sourceText else { continue }
                        isf.load(source: source, name: url.deletingPathExtension().lastPathComponent)
                        registry.register(slot: slot, parameters: isf.parameters)
                        reloaded += 1
                    case is MissingModuleNode where module?.isAvailable == true:
                        graph.remove(slot)
                        chainNodes.removeValue(forKey: slot)
                        restored = true
                    default:
                        continue
                    }
                }
            }
            if restored { rebuildChain(bus) }
        }
        Log.info(.isf, "ISF folders changed: \(catalog.modules.count) modules, \(catalog.unavailable.count) unavailable, \(reloaded) live copies reloaded")
        onModulesChanged?()
    }

    /// The node in a chain slot, if there is one.
    func chainNode(_ slot: String) -> Node? { chainNodes[slot] }

    /// Adds a module to a chain as its bottom card (applied first), bypassed.
    @discardableResult
    func addModule(_ moduleID: String, to bus: ChainBus) -> ChainEntry? {
        guard catalog.module(moduleID)?.isAvailable == true else {
            Log.warn(.graph, "cannot add '\(moduleID)': not available")
            return nil
        }
        // A built-in coming back gets its old slot, and with it any mapping to it.
        let preferred = EffectChain.standard.entries.first { $0.moduleID == moduleID }?.instanceID
        let entry = chains[bus, default: .standard].add(moduleID: moduleID, preferredID: preferred)
        rebuildChain(bus)
        Log.info(.graph, "added \(moduleID) to \(bus.rawValue.uppercased()) as \(entry.instanceID)")
        return entry
    }

    /// Takes a card out of a chain, with all its copies.
    func removeModule(_ instanceID: String, from bus: ChainBus) {
        guard chains[bus]?.remove(instanceID) == true else { return }
        rebuildChain(bus)
    }

    /// Reorders a chain to the panel's new top-to-bottom order.
    func reorderChain(_ bus: ChainBus, displayOrder ids: [String]) {
        chains[bus]?.reorder(displayOrder: ids)
        rebuildChain(bus)
    }

    /// Points a card at one channel's copy, or the bus copy.
    func setTarget(_ target: Int, of instanceID: String, on bus: ChainBus) {
        chains[bus]?.setTarget(target, of: instanceID)
    }

    /// Replaces both chains (a template load). Values are applied separately, by slot.
    func loadChains(_ newChains: [ChainBus: EffectChain]) {
        for (bus, chain) in newChains {
            chains[bus] = chain
            rebuildChain(bus)
        }
    }

    /// Bus effects that are live when the app opens, rather than bypassed.
    ///
    /// Anything here must also be declared `isEnabled: true` on its card in
    /// `PanelSet`, or the switch and the engine will disagree at launch.
    static let liveAtLaunchSlots: Set<String> = [colourSlot, colourTwoSlot]

    /// Slot names for the bus effects and the extra sources, so mappings and
    /// templates can address them by a stable name.
    static let compositeSlot = "fx.one.composite"
    /// A per-channel effect's slot name: `fx.a.colour`, `fx.d.freeze`.
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
    static let freezeOneSlot = "fx.one.freeze"
    static let freezeTwoSlot = "fx.two.freeze"
    static let moshOneSlot = "fx.one.mosh"
    static let moshTwoSlot = "fx.two.mosh"

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
        moshOneSlot, transformSlot, colourSlot, compositeSlot, echoSlot, feedbackSlot, freezeOneSlot,
        moshTwoSlot, transformTwoSlot, colourTwoSlot, compositeTwoSlot, echoTwoSlot, feedbackTwoSlot, freezeTwoSlot,
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

    /// The view whose window decides which screen clocks the engine.
    private weak var clockView: NSView?
    private var screenObserver: NSObjectProtocol?
    /// Keeps App Nap from throttling the render clock while the app is in the back.
    private var liveActivity: NSObjectProtocol?

    /// Starts the render clock, driven by the display the window is on.
    ///
    /// A SCREEN display link, not the view's. A view's link stops when its window is
    /// not on screen, and this loop also feeds the OUTPUT window — so hiding or
    /// minimising the main window mid-show froze the analog output (measured: zero
    /// frames in 4 s hidden; a 954 ms stall while merely covered). The screen link
    /// keeps firing whatever the window is doing, and is re-attached when the window
    /// moves to another screen so the clock still follows it (SPEC 4a).
    func start(drivenBy view: NSView) {
        guard displayLink == nil else { return }
        clockView = view
        attachDisplayLink()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow,
                  window === self.clockView?.window else { return }
            self.attachDisplayLink()
        }
        liveActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "live video render loop")
        midi.start()
        Log.info(.render, "render clock started")
    }

    /// (Re)creates the display link on the screen the clock view's window is on.
    private func attachDisplayLink() {
        guard let screen = clockView?.window?.screen ?? NSScreen.main else {
            Log.error(.render, "no screen to clock the render loop from")
            return
        }
        displayLink?.invalidate()
        let link = screen.displayLink(target: self, selector: #selector(tick))
        // PACED AT THE CONTENT RATE, not the display's. Unpaced, the graph ran at 60 Hz
        // (120 on ProMotion) for 29.97 material — re-rendering identical frames — and
        // echo/feedback, which step once per render, decayed 2–4× too fast depending
        // on the monitor. Revert with VIDEOBOY_RENDER_AT_DISPLAY_RATE=1.
        if ProcessInfo.processInfo.environment["VIDEOBOY_RENDER_AT_DISPLAY_RATE"] != "1" {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: 30, preferred: 30)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
        Log.info(.render, "render clock on '\(screen.localizedName)'")
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let liveActivity { ProcessInfo.processInfo.endActivity(liveActivity) }
        liveActivity = nil
        audioInput?.stop()
        audioInput = nil
    }

    /// One frame: advance the clocks, apply parameters, evaluate the graph.
    /// Whole-tick costs in milliseconds (graph + everything `onFrame` does), recorded
    /// only while a check sets this non-nil. Nil in normal use: no cost, no growth.
    var tickCostsForChecks: [Double]?
    /// The graph evaluation's share of each tick, recorded alongside.
    var graphCostsForChecks: [Double]?
    /// Total milliseconds spent in each node's `render`, while a check profiles.
    var nodeCostsForChecks: [String: Double]?

    /// The interval the display link is actually firing at, in seconds.
    private(set) var refreshInterval: Double = 0

    /// When the next 29.97 content frame is due, on the display link's clock.
    private var nextFrameDue: CFTimeInterval = 0

    /// Whether a content frame is due at `now`, advancing the content clock if so.
    ///
    /// THE GRAPH IS FRAME-CLOCKED: a clip advances one frame per render, echo and
    /// feedback step once per render. So it must render once per CONTENT frame, not
    /// once per display refresh — unpaced on a 60 Hz screen every clip played at 2×
    /// speed and trails decayed 2× too fast (4× on 120 Hz ProMotion). The link is
    /// already asked for 30 Hz; this gate makes it exact on any display (50, 144 Hz,
    /// or the display-rate fallback) and absorbs 30-vs-29.97 by holding one refresh
    /// every ~33 s.
    private func contentFrameDue(at now: CFTimeInterval, refresh: CFTimeInterval) -> Bool {
        let interval = 1.0 / StandardDefinition.frameRate
        if nextFrameDue == 0 { nextFrameDue = now }
        // Half a refresh of slack, so timestamp jitter never skips a due frame.
        guard now + refresh * 0.5 >= nextFrameDue else { return false }
        nextFrameDue += interval
        // After a stall, resync rather than rendering a burst of catch-up frames.
        if now - nextFrameDue > interval * 2 { nextFrameDue = now + interval }
        return true
    }

    @objc private func tick(_ link: CADisplayLink) {
        let tickStart = CACurrentMediaTime()
        var rendered = false
        defer {
            if rendered, tickCostsForChecks != nil {
                tickCostsForChecks?.append((CACurrentMediaTime() - tickStart) * 1000)
            }
        }
        let now = link.timestamp

        // Measure the real rate for the status bar, and notice a skipped refresh.
        if lastTickTime > 0 {
            let delta = now - lastTickTime
            if delta > 0 { measuredFramesPerSecond = 1.0 / delta }
            let expected = link.targetTimestamp - link.timestamp
            if expected > 0 { refreshInterval = expected }
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

        guard contentFrameDue(at: now, refresh: link.targetTimestamp - link.timestamp) else { return }
        rendered = true

        let context = RenderContext(
            frameIndex: frameIndex,
            presentationTime: link.targetTimestamp,
            musicalPosition: transport.isRunning ? transport.position(atHostTime: now) : nil
        )
        let graphStart = CACurrentMediaTime()
        evaluate(context: context)
        if graphCostsForChecks != nil {
            graphCostsForChecks?.append((CACurrentMediaTime() - graphStart) * 1000)
        }
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
        // Every chain node, whatever module it is: they share one protocol, so a
        // module added at runtime cannot be the one left out of this list.
        for node in chainNodes.values {
            (node as? ParameterApplying)?.applyParameters(from: registry)
        }
        compositeProgram.applyParameters(from: registry)
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
        let profiling = nodeCostsForChecks != nil
        for identifier in graph.evaluationOrder(from: Engine.outputSlot) {
            guard let node = graph.nodes[identifier] else { continue }
            let inputs = graph.inputs(of: identifier).compactMap { produced[$0] }
            let start = profiling ? CACurrentMediaTime() : 0
            if let texture = node.render(inputs: inputs, context: context) {
                produced[identifier] = texture
            }
            if profiling {
                nodeCostsForChecks?[identifier, default: 0] += (CACurrentMediaTime() - start) * 1000
            }
        }
        // ONE wait per frame, not one per pass (see `MetalContext.submit`): every
        // texture in `produced` is finished by the time anything reads it.
        metal?.waitForIdle()
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
    /// - Parameter announce: false for beat detection, which reports its own lock
    ///   and relock events through `onBeatReport`; announcing its every smoothed
    ///   step as well would flash the window for drift nobody asked about.
    func setTempo(_ beatsPerMinute: Double, announce: Bool = true) {
        guard beatsPerMinute > 0 else { return }
        transport.beatsPerMinute = beatsPerMinute
        // Announce only a real change: a drag moves by fractions constantly, and
        // flashing the window for each would be a strobe rather than a signal.
        if announce, abs(beatsPerMinute - lastAnnouncedTempo) > 0.4 {
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
        // grade, composite, echo, feedback, freeze — out of the signal path. Switching
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
    /// - Returns: false when audio was requested but could not be started. The
    ///   previous source is left running in that case — the new input is opened
    ///   before the old one is closed — and `audioClockFailure` says why.
    @discardableResult
    func setClockSource(_ source: ClockSource) -> Bool {
        guard source != clockSource else { return true }
        switch source {
        case .internalTransport:
            stopAudioInput()
            clockSource = .internalTransport
            latestBeatReport = nil
            Log.info(.clock, "clock source: internal")
            return true

        case .audio(let captureSource):
            let input = AudioInput(source: captureSource)
            input.onFrame = { [weak self, weak input] frame in
                // Analysis arrives on its own queue; parameter state and the UI
                // both live on the main thread.
                DispatchQueue.main.async {
                    guard let self, let input, self.audioInput === input else { return }
                    self.audioReactivity.update(with: frame, into: self.registry)
                }
            }
            input.onBeatReport = { [weak self, weak input] report, windowEndTime in
                DispatchQueue.main.async {
                    guard let self, let input, self.audioInput === input else { return }
                    self.applyBeatReport(report, windowEndTime: windowEndTime)
                }
            }
            guard input.start() else {
                audioClockFailure = input.failureReason
                Log.warn(.clock, "\(captureSource.longName) unavailable; keeping \(clockSource.displayName)")
                return false
            }
            audioClockFailure = nil
            stopAudioInput()
            audioInput = input
            audioReactivity.isRunning = true
            clockSource = source
            latestBeatReport = nil
            Log.info(.clock, "clock source: audio from \(captureSource.longName)")
            return true
        }
    }

    private func stopAudioInput() {
        audioInput?.stop()
        audioInput = nil
        audioReactivity.isRunning = false
        audioReactivity.reset()
    }

    /// Applies a beat tracker report to the transport.
    ///
    /// Only a LOCKED report moves anything. Listening, holding and silence leave the
    /// clock running at the last good tempo — a breakdown or a gap between tracks is
    /// exactly when the visuals should keep time on their own.
    private func applyBeatReport(_ report: BeatTrackerReport, windowEndTime: Double) {
        latestBeatReport = report
        defer { onBeatReport?(report) }
        guard clockSource.isAudio, report.state == .locked, let tempo = report.beatsPerMinute else {
            return
        }

        // A lock or relock is a new tempo and a new beat: take both outright. In
        // between, the tracker's own smoothing has already done the work, so the
        // tempo is taken as given and the phase is only nudged.
        let isNewLock: Bool
        switch report.event {
        case .locked, .relocked: isNewLock = true
        default: isNewLock = false
        }
        if abs(tempo - transport.beatsPerMinute) > 0.01 {
            setTempo(tempo, announce: false)
        }
        alignPhase(to: report, windowEndTime: windowEndTime, snap: isNewLock)
    }

    /// Pulls the transport's beat onto the music's beat.
    ///
    /// Tempo alone is not enough to look locked: at the right BPM but the wrong phase,
    /// every beat-synced effect lands between the drums, forever. The tracker says
    /// how long ago the music's last beat fell; the transport says where it was at
    /// that moment; `BeatTracker.phaseCorrection` turns the difference into a nudge.
    ///
    /// Beat-level only: which beat is "one" of the bar is not attempted, and output
    /// latency to the screen is not compensated here.
    private func alignPhase(to report: BeatTrackerReport, windowEndTime: Double, snap: Bool) {
        guard transport.isRunning, let sinceBeat = report.secondsSinceBeat else { return }
        let now = CACurrentMediaTime()
        let beatsNow = transport.beats(atHostTime: now)
        let musicBeatTime = windowEndTime - sinceBeat
        let clockBeatsAtMusicBeat = beatsNow - (now - musicBeatTime) / transport.secondsPerBeat
        let correction = BeatTracker.phaseCorrection(
            clockBeatsAtMusicBeat: clockBeatsAtMusicBeat, snap: snap)
        if correction != 0 { transport.shiftPosition(byBeats: correction) }
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
        for (bus, name) in [(ChainBus.one, "ONE"), (ChainBus.two, "TWO")] {
            // The bus's first Feedback card, if it still has one: a card can be
            // removed now, and a send into a loop that is not there goes nowhere.
            guard let entry = chains[bus]?.entries.first(where: { $0.moduleID == ModuleCatalog.ID.feedback }),
                  let loop = chainNodes[EffectChain.slot(instanceID: entry.instanceID, lane: bus.lane)] as? FeedbackNode
            else { continue }
            loop.externalHistory = feedbackSends[name].flatMap { currentTextures[$0] }
        }
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

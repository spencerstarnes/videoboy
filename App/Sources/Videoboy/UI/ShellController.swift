//
//  ShellController.swift — wires the window's controls to the engine.
//
//  Purpose : The one place where a click becomes an action. Views stay dumb and the
//            engine stays UI-free; this is the seam between them. It also pushes
//            state the other way each frame — previews, readouts, status.
//  Inputs  : user actions from the panels; a frame callback from the engine.
//  Outputs : engine calls, and refreshed views.
//  Connects: Engine, ShellView and its panels, OutputWindowController.
//  Extend  : wire a new control here. Do not give a view a reference to the engine.
//

import AppKit
import VideoboyCore

/// Connects the shell's views to the engine.
final class ShellController {

    private let shell: ShellView
    private let engine: Engine
    private let preferences: PreferenceStore
    private var outputWindow: OutputWindowController?
    /// Shift-to-detect. Exposed so the self-QA render can arm it.
    private(set) var detectSession: DetectSession?

    /// Channel letters in the order their previews appear.
    private static let channels = ["A", "B", "C", "D"]

    init(shell: ShellView, engine: Engine, preferences: PreferenceStore = PreferenceStore()) {
        self.shell = shell
        self.engine = engine
        self.preferences = preferences
        wireSources()
        wireFaders()
        wireBlendControls()
        wireEffectChains()
        wireToolbar()
        wireSettingsBar()
        wireRecordIndicators()
        wireLibraries()
        wireDetect()
        refreshDrivenParameters()
        engine.onTempoChanged = { [weak self] tempo in
            self?.shell.flashTempoChange()
            self?.shell.toolbar.setTempo(tempo)
        }
        engine.onFrame = { [weak self] engine in self?.refresh(from: engine) }
    }

    /// Loads a clip into a channel and says what happened.
    ///
    /// The single path for every way a file arrives — double-clicked in a library,
    /// dragged onto a source, or chosen from the Load button — so a file that loads
    /// one way cannot silently fail another.
    private func loadClip(
        _ url: URL, into channel: String, range: ClosedRange<Double>? = nil
    ) {
        guard engine.load(url: url, intoChannel: channel) else {
            presentNotice(
                "Could not load \(url.lastPathComponent)",
                url.pathExtension.lowercased() == "dv"
                    ? "The file could not be read as DV. It may be truncated, or PAL — "
                        + "this build reads NTSC."
                    : "The file could not be opened. It may use a codec macOS cannot "
                        + "read, or have no video track."
            )
            return
        }
        engine.sources[channel]?.playbackRange = range
        shell.grid.panels.sourceBodies[channel]?.setMediaName(
            range == nil
                ? url.lastPathComponent
                : "\(url.lastPathComponent) [trimmed]")
        if preferences.preferences.playOnLoad {
            engine.setPlaying(true, channel: channel)
        }
        Log.info(.dv, "loaded \(url.lastPathComponent) into channel \(channel)")
    }

    /// Wires the libraries: double-click loads into the pair's next channel.
    private func wireLibraries() {
        let panels = shell.grid.panels
        // Each sub-mix library defaults to the pair it feeds. The browser starts on
        // A/B and can be pointed anywhere.
        panels.libraryOneBody.setDestinationPair(.ab)
        panels.libraryTwoBody.setDestinationPair(.cd)
        panels.assetBrowserBody.setDestinationPair(.ab)

        for library in [panels.libraryOneBody, panels.libraryTwoBody, panels.assetBrowserBody] {
            library.onItemOpened = { [weak self] item, channel, range in
                guard let url = item.url else {
                    self?.presentNotice(
                        "\(item.name) is not a file",
                        "Generators and the other source kinds are loaded from their own "
                            + "panels, not from the library.")
                    return
                }
                self?.loadClip(url, into: channel, range: range)
            }
        }
    }

    // MARK: - Shift-to-detect

    /// Which slot the crossfaders, shuttles and bus data effects belong to.
    ///
    /// The effect chains have their own tables because a code there means different
    /// slots on different buses. These are one-to-one, so they live here plainly
    /// rather than being bent to fit the same shape.
    private func wireDetect() {
        let panels = shell.grid.panels

        panels.faderABBody.fader.mappingSlot = GraphTopology.subMixOne
        panels.faderABBody.fader.mappingCode = .crossfadeAB
        panels.faderCDBody.fader.mappingSlot = GraphTopology.subMixTwo
        panels.faderCDBody.fader.mappingCode = .crossfadeCD
        panels.faderOneTwoBody.fader.mappingSlot = GraphTopology.primary
        panels.faderOneTwoBody.fader.mappingCode = .crossfadeOneTwo

        // Each shuttle scrubs its own source, so the slot is the channel itself.
        for (channel, body) in panels.sourceBodies {
            body.scrubFader?.mappingSlot = Self.slot(forChannel: channel)
            body.scrubFader?.mappingCode = .scrubPosition
        }

        // The bus data effects: the wedge on the interchange codec, per bus.
        let busData: [(PreviewPanelBody, String)] = [
            (panels.subMixOneBody, Engine.busCodecOneSlot),
            (panels.subMixTwoBody, Engine.busCodecTwoSlot),
            (panels.programBody, Engine.busCodecProgramSlot)
        ]
        for (body, slot) in busData {
            body.dataAmountFader?.mappingSlot = slot
            body.dataAmountFader?.mappingCode = .corruptAmount
            body.dataModeFader?.mappingSlot = slot
            body.dataModeFader?.mappingCode = .corruptMode
        }

        // The effect chains answer per code, because a code names a different slot
        // on each bus.
        panels.effectsOneBody.mappingSlotForCode = { Self.subMixOneSlots[$0] }
        panels.effectsTwoBody.mappingSlotForCode = { Self.subMixTwoSlots[$0] }
        // Adding, removing or reordering an effect builds new fader views, which
        // start unmarked. Without this the pulse would quietly disappear from a
        // parameter that is still very much being driven.
        for panel in [panels.effectsOneBody, panels.effectsTwoBody] {
            panel.onChainRebuilt = { [weak self] in self?.refreshDrivenParameters() }
        }

        let session = DetectSession(root: shell)
        session.onDetectRequested = { [weak self] slot, code in
            self?.armDetect(slot: slot, code: code)
        }
        session.onArmedChanged = { [weak self] armed in
            self?.shell.toolbar.setDetectArmed(armed)
        }
        shell.toolbar.onDetectExplainRequested = { [weak self] in
            self?.presentNotice(
                "Hold Shift to map a control",
                "Every control that can be driven by MIDI lights up while Shift is held. Shift-click one, then move the knob or fader on your controller."
            )
        }
        detectSession = session
    }

    /// Faders with something driving them, cached so the beat pulse does not walk
    /// the view tree on every frame.
    private var drivenFaders: [VBFader] = []

    /// Re-reads which parameters have a driver and marks their faders.
    ///
    /// Asks the engine rather than keeping a parallel record of what has been mapped.
    /// A second copy of that list would be one more thing to forget to update, and
    /// the failure would be a fader claiming a driver it does not have — which is
    /// worse than no mark at all, because it would be believed.
    func refreshDrivenParameters() {
        drivenFaders.removeAll()
        markDriven(in: shell)
        Log.info(.param, "\(drivenFaders.count) parameters have a driver")
    }

    private func markDriven(in view: NSView) {
        if let fader = view as? VBFader,
           let slot = fader.mappingSlot, let code = fader.mappingCode {
            let driven = engine.registry.bindings.contains { $0.slot == slot && $0.code == code }
                || engine.audioReactivity.isDriven(slot: slot, code: code)
                || engine.lfos.isDriven(slot: slot, code: code)
            fader.isDriven = driven
            if driven { drivenFaders.append(fader) }
        }
        for subview in view.subviews { markDriven(in: subview) }
    }

    /// Which graph slot a channel letter is.
    private static func slot(forChannel channel: String) -> String {
        switch channel {
        case "A": GraphTopology.sourceA
        case "B": GraphTopology.sourceB
        case "C": GraphTopology.sourceC
        default:  GraphTopology.sourceD
        }
    }

    /// Arms MIDI learn for a parameter and says so, from wherever it was asked for.
    ///
    /// The status bar is the only report for controls with no badge of their own —
    /// a crossfader has nowhere to light up — so arming must be visible there or a
    /// mis-click looks like nothing happened.
    private func armDetect(slot: String, code: ParamCode) {
        engine.midi.beginDetect(slot: slot, code: code)
        shell.statusBar.setMIDIDevice("learning \(code.displayName)…")
        Log.info(.midi, "detect armed for \(slot)/\(code.rawValue)")
        engine.midi.onDetectCompleted = { [weak self] binding in
            DispatchQueue.main.async {
                guard let self else { return }
                self.shell.statusBar.setMIDIDevice(self.engine.midi.connectedSourceNames.first)
                self.refreshDrivenParameters()
                // Light the badge if this parameter has one, on the bus it belongs
                // to. Faders outside the effect chains have no badge, and that is
                // fine — the mapping is no less real for having nowhere to show
                // itself; the status bar reported it.
                if Self.subMixOneSlots[code] == slot {
                    self.shell.grid.panels.effectsOneBody
                        .setBadgeActive(code: code.rawValue, badge: "M", isActive: true)
                }
                if Self.subMixTwoSlots[code] == slot {
                    self.shell.grid.panels.effectsTwoBody
                        .setBadgeActive(code: code.rawValue, badge: "M", isActive: true)
                }
                Log.info(.midi, "learned \(binding.source.description) for \(binding.slot)/\(binding.code.rawValue)")
            }
        }
    }

    // MARK: - Wiring

    private func wireSources() {
        for letter in Self.channels {
            guard let body = shell.grid.panels.sourceBodies[letter] else { continue }
            body.onLoadRequested = { [weak self] in self?.presentOpenPanel(forChannel: letter) }
            body.onPlayToggled = { [weak self] in self?.togglePlayback(channel: letter) }
            body.onGeneratorSelected = { [weak self] kind in
                self?.setGenerator(kind, channel: letter)
            }
            body.onSeekToStart = { [weak self] in
                self?.engine.sources[letter]?.seek(toNormalised: 0)
            }
            body.onSeekToEnd = { [weak self] in
                self?.engine.sources[letter]?.seek(toNormalised: 1)
            }
            body.onStepBack = { [weak self] in
                self?.engine.sources[letter]?.step(by: -1)
            }
            body.onStepForward = { [weak self] in
                self?.engine.sources[letter]?.step(by: 1)
            }
            body.onScrub = { [weak self] position in
                // Through the registry, not straight to the node: the shuttle and a
                // mapped jog wheel then move the same parameter rather than fighting
                // over the playhead from two directions.
                guard let self, let node = self.engine.sources[letter] else { return }
                self.engine.registry.setValue(
                    position, slot: node.identifier, code: .scrubPosition)
            }
            body.onTimingChanged = { [weak self] timing in
                self?.engine.sources[letter]?.timing = timing
            }
            body.onFileDropped = { [weak self] url in
                self?.loadClip(url, into: letter)
            }
            body.onLoopModeChanged = { [weak self] mode in
                self?.engine.sources[letter]?.loopMode = mode
                Log.info(.dv, "source \(letter) loop mode is now \(mode.displayName)")
            }
        }
    }

    private var playingChannels: Set<String> = []

    /// Points a channel at a generator, or back at its file.
    ///
    /// Also puts a transport-locked LFO on the generator's phase, because a static
    /// generator is not what any of them are for — a checkerboard that does not flip
    /// and a plasma that does not drift are wallpaper (SPEC 6A).
    private func setGenerator(_ kind: GeneratorKind?, channel letter: String) {
        guard let kind else {
            engine.setChannelSource(.file, channel: letter)
            engine.lfos.remove(
                slot: Engine.generatorSlot(forChannel: letter), code: .positionX)
            return
        }
        engine.generators[letter]?.generator = kind
        engine.setChannelSource(.generator, channel: letter)

        // A slow ramp on phase by default: it drifts on the bar rather than
        // strobing, which is the sane starting point. The shape and rate are
        // ordinary parameters the performer can change or map.
        engine.lfos.assign(LFOBank.Assignment(
            lfo: LFO(shape: .rampUp, rate: .subdivision(.whole), depth: 1.0),
            slot: Engine.generatorSlot(forChannel: letter),
            code: .positionX,
            latencyInFrames: engine.generators[letter]?.latencyInFrames ?? 0
        ))
    }

    private func togglePlayback(channel letter: String) {
        if playingChannels.contains(letter) {
            playingChannels.remove(letter)
            engine.setPlaying(false, channel: letter)
        } else {
            playingChannels.insert(letter)
            engine.setPlaying(true, channel: letter)
        }
    }

    /// Opens a file for one channel. DV goes down the wedge's path; other formats are
    /// not wired to a decoder yet, and say so rather than failing silently.
    private func presentOpenPanel(forChannel letter: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = RepoPaths.samples
        panel.message = "Choose a video file for source \(letter)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadClip(url, into: letter)
    }

    /// A plain alert. Used instead of silently doing nothing (SPEC 1.5).
    private func presentNotice(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .informational
        alert.runModal()
    }

    /// Wires the blend mode of the three composites (SPEC 12).
    ///
    /// There is no separate opacity control any more: the crossfader IS the opacity.
    /// It travels base → blend → blend-layer, so hard left and hard right are the two
    /// sources untouched whatever the mode, and the blend is at full strength in the
    /// middle.
    private func wireBlendControls() {
        let panels = shell.grid.panels
        let composites: [(body: PreviewPanelBody, slot: String)] = [
            (panels.subMixOneBody, GraphTopology.subMixOne),
            (panels.subMixTwoBody, GraphTopology.subMixTwo),
            (panels.programBody, GraphTopology.primary)
        ]
        // Which engine bus each preview's data controls drive.
        let busNames: [String: String] = [
            GraphTopology.subMixOne: "ONE",
            GraphTopology.subMixTwo: "TWO",
            GraphTopology.primary: "PROGRAM"
        ]
        let busSlots: [String: String] = [
            GraphTopology.subMixOne: Engine.busCodecOneSlot,
            GraphTopology.subMixTwo: Engine.busCodecTwoSlot,
            GraphTopology.primary: Engine.busCodecProgramSlot
        ]

        for composite in composites {
            composite.body.onBlendModeChanged = { [weak self] mode in
                self?.engine.registry.setValue(
                    mode.normalisedPosition, slot: composite.slot, code: .blendMode)
            }
            composite.body.onInterchangeChanged = { [weak self] codec in
                guard let self, let bus = busNames[composite.slot] else { return }
                self.engine.setInterchange(codec, forBus: bus)
            }
            composite.body.onScopeTabClicked = { [weak self] in
                self?.cycleScopes(for: composite.slot, body: composite.body)
            }
            composite.body.onZebraToggled = { [weak self] on in
                self?.zebraEnabled[composite.slot] = on
            }
            composite.body.onDataParameterChanged = { [weak self] code, value in
                guard let self,
                      let parameter = ParamCode(rawValue: code),
                      let slot = busSlots[composite.slot],
                      let declared = self.engine.graph.nodes[slot]?.parameters
                        .first(where: { $0.code == parameter })
                else { return }
                self.engine.registry.setValue(
                    declared.denormalise(value), slot: slot, code: parameter)
            }
        }
    }

    /// Fades in flight, and cuts waiting for a beat, by bus slot.
    private var activeFades: [String: FadeAutomation] = [:]
    private var pendingCuts: [String: PendingCut] = [:]
    private var beatCutEnabled: [String: Bool] = [:]

    /// Advances any fade or pending cut. Called once per frame.
    ///
    /// A cut waiting on a beat is taken at `fireHostTime`, which is the beat's time
    /// LESS the graph's latency — that is what makes the picture change on the beat
    /// rather than a few frames after it (SPEC 21).
    private func updateFadesAndCuts(from engine: Engine) {
        let now = CACurrentMediaTime()

        for (slot, cut) in pendingCuts where cut.isDue(atHostTime: now) {
            applyFaderPosition(cut.target, to: slot)
            pendingCuts.removeValue(forKey: slot)
            Log.info(.clock, "cut on beat \(String(format: "%.2f", cut.targetBeat)) taken for \(slot)")
        }

        for (slot, fade) in activeFades {
            applyFaderPosition(fade.position(atHostTime: now), to: slot)
            if fade.isFinished(atHostTime: now) {
                activeFades.removeValue(forKey: slot)
            }
        }
    }

    /// Writes a fader position into the registry and back into its panel.
    private func applyFaderPosition(_ position: Double, to slot: String) {
        guard let code = Self.faderCode(for: slot) else { return }
        engine.registry.setValue(position, slot: slot, code: code)
        Self.faderBody(for: slot, panels: shell.grid.panels)?.setPosition(position)
    }

    /// The crossfade param code for a bus slot.
    private static func faderCode(for slot: String) -> ParamCode? {
        switch slot {
        case GraphTopology.subMixOne: .crossfadeAB
        case GraphTopology.subMixTwo: .crossfadeCD
        case GraphTopology.primary: .crossfadeOneTwo
        default: nil
        }
    }

    /// The panel body for a bus slot.
    private static func faderBody(for slot: String, panels: PanelSet) -> FaderPanelBody? {
        switch slot {
        case GraphTopology.subMixOne: panels.faderABBody
        case GraphTopology.subMixTwo: panels.faderCDBody
        case GraphTopology.primary: panels.faderOneTwoBody
        default: nil
        }
    }

    /// Starts a fade, or schedules a cut, for one bus.
    private func beginMove(on slot: String, isCut: Bool, rate: FadeRate) {
        guard let code = Self.faderCode(for: slot),
              let current = engine.registry.value(slot: slot, code: code) else { return }
        // Always travel to the far end from where the fader is now.
        let target: Double = current < 0.5 ? 1.0 : 0.0
        let now = CACurrentMediaTime()

        if isCut {
            guard engine.transport.isRunning else {
                // With the transport stopped there are no beats to wait for, so a
                // beat-cut is just a cut. Waiting forever would look like a dead button.
                applyFaderPosition(target, to: slot)
                return
            }
            pendingCuts[slot] = PendingCut.scheduled(
                target: target,
                transport: engine.transport,
                subdivision: .quarter,
                hostTime: now,
                latencyInFrames: engine.graph.maximumLatencyInFrames
            )
        } else {
            activeFades[slot] = FadeAutomation(
                from: current, to: target, duration: rate.seconds, startedAt: now)
        }
    }

    private func wireFaders() {
        let panels = shell.grid.panels
        // Each fader writes straight into the registry, so a MIDI move and a mouse
        // drag land in exactly the same place.
        // A hand on a fader cancels whatever it was doing on its own.
        let buses: [(body: FaderPanelBody, slot: String)] = [
            (panels.faderABBody, GraphTopology.subMixOne),
            (panels.faderCDBody, GraphTopology.subMixTwo),
            (panels.faderOneTwoBody, GraphTopology.primary)
        ]
        for bus in buses {
            bus.body.onFade = { [weak self] rate in
                guard let self else { return }
                self.beginMove(
                    on: bus.slot,
                    isCut: self.beatCutEnabled[bus.slot] ?? false,
                    rate: rate)
            }
            bus.body.onBeatCutToggled = { [weak self] on in
                self?.beatCutEnabled[bus.slot] = on
            }
            bus.body.onCut = { [weak self] in
                guard let self else { return }
                // Cut-on-beat turns an immediate cut into a scheduled one.
                if self.beatCutEnabled[bus.slot] == true {
                    self.beginMove(on: bus.slot, isCut: true, rate: .fast)
                }
            }
        }

        panels.faderABBody.onFaderMoved = { [weak self] position in
            self?.activeFades.removeValue(forKey: GraphTopology.subMixOne)
            self?.pendingCuts.removeValue(forKey: GraphTopology.subMixOne)
            self?.engine.registry.setValue(position, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        }
        panels.faderCDBody.onFaderMoved = { [weak self] position in
            self?.activeFades.removeValue(forKey: GraphTopology.subMixTwo)
            self?.pendingCuts.removeValue(forKey: GraphTopology.subMixTwo)
            self?.engine.registry.setValue(position, slot: GraphTopology.subMixTwo, code: .crossfadeCD)
        }
        panels.faderOneTwoBody.onFaderMoved = { [weak self] position in
            self?.activeFades.removeValue(forKey: GraphTopology.primary)
            self?.pendingCuts.removeValue(forKey: GraphTopology.primary)
            self?.engine.registry.setValue(position, slot: GraphTopology.primary, code: .crossfadeOneTwo)
        }
    }

    /// Which slot each param code in the Sub Mix 1 chain belongs to.
    ///
    /// The chain shows effects from several nodes in one list, so a code alone is not
    /// enough to know where a slider's value should land. This table is that mapping,
    /// written out rather than inferred so adding an effect is a one-line change.
    private static let subMixOneSlots: [ParamCode: String] = [
        // The wedge lives on the source, because it must run before decode.
        .corruptAmount: GraphTopology.sourceA,
        .corruptMode: GraphTopology.sourceA,
        .corruptRate: GraphTopology.sourceA,
        .corruptSeed: GraphTopology.sourceA,
        // The composite codec and the time-domain effects are bus FX.
        .compositePath: Engine.compositeSlot,
        .compositeCrawl: Engine.compositeSlot,
        .chromaBleed: Engine.compositeSlot,
        .lumaBandwidth: Engine.compositeSlot,
        .tbcWobble: Engine.compositeSlot,
        .headSwitchingNoise: Engine.compositeSlot,
        .chromaSubsampling: Engine.compositeSlot,
        .compositeGeneration: Engine.compositeSlot,
        .echoDecay: Engine.echoSlot,
        .trailLength: Engine.echoSlot,
        .echoThreshold: Engine.echoSlot,
        .feedbackGain: Engine.feedbackSlot,
        .feedbackDelayFrames: Engine.feedbackSlot,
        .feedbackZoom: Engine.feedbackSlot,
        .feedbackRotate: Engine.feedbackSlot,
        .feedbackThreshold: Engine.feedbackSlot
    ]

    /// Which slot each param code in the Sub Mix 2 chain belongs to.
    private static let subMixTwoSlots: [ParamCode: String] = [
        .corruptAmount: GraphTopology.sourceC,
        .corruptMode: GraphTopology.sourceC,
        .corruptRate: GraphTopology.sourceC,
        .compositePath: Engine.compositeTwoSlot,
        .compositeCrawl: Engine.compositeTwoSlot,
        .chromaBleed: Engine.compositeTwoSlot,
        .lumaBandwidth: Engine.compositeTwoSlot,
        .tbcWobble: Engine.compositeTwoSlot,
        .headSwitchingNoise: Engine.compositeTwoSlot,
        .chromaSubsampling: Engine.compositeTwoSlot,
        .compositeGeneration: Engine.compositeTwoSlot,
        .echoDecay: Engine.echoTwoSlot,
        .trailLength: Engine.echoTwoSlot,
        .echoThreshold: Engine.echoTwoSlot,
        .feedbackGain: Engine.feedbackTwoSlot,
        .feedbackDelayFrames: Engine.feedbackTwoSlot,
        .feedbackZoom: Engine.feedbackTwoSlot,
        .feedbackRotate: Engine.feedbackTwoSlot,
        .feedbackThreshold: Engine.feedbackTwoSlot
    ]

    /// Effect card names to the slot they bypass, per bus.
    private static let effectNameToSlot: [String: (one: String, two: String)] = [
        "Composite · NTSC": (Engine.compositeSlot, Engine.compositeTwoSlot),
        "Echo / Trails": (Engine.echoSlot, Engine.echoTwoSlot),
        "Feedback": (Engine.feedbackSlot, Engine.feedbackTwoSlot)
    ]

    private func wireEffectChains() {
        shell.grid.panels.effectsOneBody.onParameterChanged = { [weak self] code, value in
            guard let self, let parameter = ParamCode(rawValue: code) else { return }
            guard let slot = Self.subMixOneSlots[parameter] else {
                Log.warn(.param, "no slot is registered for param code \(code); ignoring the change")
                return
            }
            // The slider is 0...1; the registry scales it into the parameter's range.
            guard let declared = self.engine.graph.nodes[slot]?.parameters
                .first(where: { $0.code == parameter }) else { return }
            self.engine.registry.setValue(declared.denormalise(value), slot: slot, code: parameter)
        }

        shell.grid.panels.effectsOneBody.onMappingBadgeClicked = { [weak self] code, badge, view in
            self?.presentModulationMenu(code: code, badge: badge, from: view, bus: .one)
        }
        shell.grid.panels.effectsTwoBody.onMappingBadgeClicked = { [weak self] code, badge, view in
            self?.presentModulationMenu(code: code, badge: badge, from: view, bus: .two)
        }

        shell.grid.panels.effectsOneBody.onEffectRemoved = { [weak self] name in
            self?.removeEffect(name, bus: .one)
        }
        shell.grid.panels.effectsTwoBody.onEffectRemoved = { [weak self] name in
            self?.removeEffect(name, bus: .two)
        }
        shell.grid.panels.effectsOneBody.onEffectAdded = { [weak self] name in
            self?.addEffect(name, bus: .one)
        }
        shell.grid.panels.effectsTwoBody.onEffectAdded = { [weak self] name in
            self?.addEffect(name, bus: .two)
        }

        shell.grid.panels.effectsOneBody.onEffectToggled = { [weak self] name, isOn in
            // Bypassing is expressed as wet/dry, so there is one mechanism rather
            // than a separate enable flag threaded through every node.
            self?.setEffectEnabled(name, isOn, bus: .one)
        }

        // The same chain on TWO, driving its own node instances.
        shell.grid.panels.effectsTwoBody.onParameterChanged = { [weak self] code, value in
            guard let self, let parameter = ParamCode(rawValue: code) else { return }
            guard let slot = Self.subMixTwoSlots[parameter] else {
                Log.warn(.param, "no slot is registered for param code \(code) on bus TWO; ignoring")
                return
            }
            guard let declared = self.engine.graph.nodes[slot]?.parameters
                .first(where: { $0.code == parameter }) else { return }
            self.engine.registry.setValue(declared.denormalise(value), slot: slot, code: parameter)
        }
        shell.grid.panels.effectsTwoBody.onEffectToggled = { [weak self] name, isOn in
            self?.setEffectEnabled(name, isOn, bus: .two)
        }
    }

    /// Every preview's record indicator, by the label it shows.
    private var recordIndicators: [String: MiniRecordIndicator] = [:]

    /// Scope mode per composite slot.
    private var scopeModes: [String: ScopeDisplayMode] = [:]
    /// Zebra on/off per composite slot.
    private var zebraEnabled: [String: Bool] = [:]
    /// Frame counter for pacing scope refreshes.
    private var scopeRefreshCounter = 0

    /// Advances a preview's scope cycle by one.
    private func cycleScopes(for slot: String, body: PreviewPanelBody) {
        let next = (scopeModes[slot] ?? .off).next
        scopeModes[slot] = next
        body.setScopeMode(next)
        if next == .off {
            body.preview.setScopeImage(nil, dimsPicture: false)
        }
        Log.info(.app, "scopes on \(slot): \(next.displayName)")
    }

    /// Connects each preview's arm indicator and records which feeds are armed.
    private func wireRecordIndicators() {
        let panels = shell.grid.panels
        var found: [String: MiniRecordIndicator] = [:]
        for letter in Self.channels {
            if let indicator = panels.sourceBodies[letter]?.preview.recordIndicator {
                found[letter] = indicator
            }
        }
        if let one = panels.subMixOneBody.preview.recordIndicator { found["1"] = one }
        if let two = panels.subMixTwoBody.preview.recordIndicator { found["2"] = two }
        if let program = panels.programBody.preview.recordIndicator { found["P"] = program }

        for (label, indicator) in found {
            indicator.target = self
            indicator.action = #selector(armChanged(_:))
            // PROGRAM is armed by default: recording the program feed is what anyone
            // means by "record" unless they say otherwise.
            indicator.isArmed = (label == "P")
        }
        recordIndicators = found
        Log.info(.app, "record indicators on \(found.keys.sorted().joined(separator: ", "))")
    }

    @objc private func armChanged(_ sender: MiniRecordIndicator) {
        let armed = recordIndicators.filter { $0.value.isArmed }.keys.sorted()
        Log.info(.app, "armed for recording: \(armed.isEmpty ? "nothing" : armed.joined(separator: ", "))")
    }

    /// Which sub-mix an FX panel drives.
    private enum Bus { case one, two }

    /// Takes an effect out of a chain: bypassed in the graph, card gone from the list.
    ///
    /// The graph itself is fixed, so "remove" means bypass — but the card really does
    /// leave the list, and the chain's Add popup is how it comes back. Removing with
    /// no way to restore would be a trap.
    private func removeEffect(_ name: String, bus: Bus) {
        guard let slots = Self.effectNameToSlot[name] else { return }
        let slot = bus == .one ? slots.one : slots.two
        engine.registry.setValue(0, slot: slot, code: .wetDry)
        let panel = bus == .one ? shell.grid.panels.effectsOneBody : shell.grid.panels.effectsTwoBody
        panel.removeEffect(named: name)
        Log.info(.graph, "\(name) removed from bus \(bus == .one ? "ONE" : "TWO")")
    }

    /// Puts a removed effect back, bypassed, at the end of the chain.
    private func addEffect(_ name: String, bus: Bus) {
        let panel = bus == .one ? shell.grid.panels.effectsOneBody : shell.grid.panels.effectsTwoBody
        panel.restoreEffect(named: name)
        Log.info(.graph, "\(name) added to bus \(bus == .one ? "ONE" : "TWO")")
    }

    /// Refreshes scopes and zebra overlays, well below frame rate.
    ///
    /// A scope reads a signal's shape, which does not change meaningfully between
    /// one frame and the next, and producing one needs a GPU readback plus a CPU
    /// pass. Refreshing every frame would put that in the render loop's way for no
    /// benefit a person could see. Roughly six times a second is plenty.
    private func updateScopesAndZebra(from engine: Engine) {
        scopeRefreshCounter += 1
        guard scopeRefreshCounter % Self.scopeRefreshInterval == 0 else { return }
        guard let renderer = offscreenRenderer else { return }

        let panels = shell.grid.panels
        let composites: [(body: PreviewPanelBody, slot: String, texture: String)] = [
            (panels.subMixOneBody, GraphTopology.subMixOne, Engine.busCodecOneSlot),
            (panels.subMixTwoBody, GraphTopology.subMixTwo, Engine.busCodecTwoSlot),
            (panels.programBody, GraphTopology.primary, GraphTopology.primary)
        ]

        for composite in composites {
            let mode = scopeModes[composite.slot] ?? .off
            let wantsZebra = zebraEnabled[composite.slot] ?? false
            guard mode != .off || wantsZebra else { continue }

            guard let texture = engine.texture(for: composite.texture)
                ?? engine.texture(for: composite.slot),
                  let image = renderer.readback(texture) else { continue }

            if mode != .off {
                let scope: ImageBuffer
                switch mode {
                case .quadOverlay, .quadBlack:
                    scope = ScopeRenderer.renderQuad(from: image, width: 480, height: 360)
                case .histogram:
                    scope = ScopeRenderer.render(.histogram, from: image, width: 480, height: 360)
                case .parade:
                    scope = ScopeRenderer.render(.parade, from: image, width: 480, height: 360)
                case .off:
                    continue
                }
                composite.body.preview.setScopeImage(scope, dimsPicture: mode.showsPicture)
            }

            // Zebra is suppressed while scopes are up: two overlays on one monitor
            // fight each other, and the scope already says what the zebra would.
            if wantsZebra && mode == .off {
                // Animated from the transport so the stripes crawl, which is what
                // makes them read as a warning rather than as part of the picture.
                let phase = engine.transport.isRunning
                    ? engine.transport.beats(atHostTime: CACurrentMediaTime())
                        .truncatingRemainder(dividingBy: 1.0)
                    : 0
                composite.body.preview.setZebraImage(
                    BroadcastSafety.applyZebra(to: image, phase: phase))
            } else {
                composite.body.preview.setZebraImage(nil)
            }
        }
    }

    /// Frames between scope refreshes. About six a second at 29.97.
    private static let scopeRefreshInterval = 5

    /// Used to read textures back for the scopes.
    private lazy var offscreenRenderer: OffscreenRenderer? = OffscreenRenderer()

    /// Advances every armed indicator's pulse from the musical clock.
    ///
    /// The pulse is derived from the transport rather than from a timer, so all the
    /// armed indicators are in step with each other and with the music by
    /// construction — a timer per indicator would drift apart within seconds.
    private func updateRecordPulse(from engine: Engine) {
        let isRecording = shell.toolbar.recordButton.isRecording
        let phase: Double
        if engine.transport.isRunning {
            let beats = engine.transport.beats(atHostTime: CACurrentMediaTime())
            let cycle = beats / Theme.Record.pulseBeats
            phase = cycle - cycle.rounded(.down)
            // The window chrome breathes on the BEAT, not on the record pulse's two
            // beats — they are different rhythms and should not be conflated.
            let beatPhase = beats - beats.rounded(.down)
            shell.setBeatPhase(beatPhase)
        } else {
            // Stopped: hold the indicators at full brightness rather than freezing
            // them mid-fade, which reads as a rendering fault.
            phase = 0
            shell.clearBeatPulse()
        }
        for indicator in recordIndicators.values where indicator.isArmed {
            indicator.isRecording = isRecording
            indicator.pulsePhase = phase
        }
        // Driven parameters breathe on the BEAT, like the window chrome, rather than
        // on the record pulse's two beats.
        let drivenPhase = engine.transport.isRunning
            ? { let b = engine.transport.beats(atHostTime: CACurrentMediaTime())
                return b - b.rounded(.down) }()
            : 0
        for fader in drivenFaders { fader.pulsePhase = drivenPhase }
    }

    /// Opens the MIDI / audio / LFO menu for a parameter and applies the choice.
    private func presentModulationMenu(code: String, badge: String, from view: NSView, bus: Bus) {
        guard let parameter = ParamCode(rawValue: code) else { return }
        let table = bus == .one ? Self.subMixOneSlots : Self.subMixTwoSlots
        guard let slot = table[parameter] else {
            Log.warn(.param, "no slot registered for \(code); cannot map it")
            return
        }

        let panel = bus == .one ? shell.grid.panels.effectsOneBody : shell.grid.panels.effectsTwoBody
        let isDriven: Bool
        switch badge {
        case "M": isDriven = engine.registry.bindings.contains { $0.slot == slot && $0.code == parameter }
        case "S": isDriven = engine.audioReactivity.isDriven(slot: slot, code: parameter)
        default:  isDriven = engine.lfos.isDriven(slot: slot, code: parameter)
        }

        ModulationMenus.present(badge: badge, isCurrentlyDriven: isDriven, from: view) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .learnMIDI:
                // The same act as Shift-clicking the fader, so it takes the same
                // path: the badge lights once something actually arrives, not on
                // arming, or it would claim a mapping that may never be made.
                self.armDetect(slot: slot, code: parameter)

            case .audio(let tap, let shape):
                self.engine.audioReactivity.assign(ReactivityAssignment(
                    tap: tap, shape: shape, slot: slot, code: parameter))
                panel.setBadgeActive(code: code, badge: "S", isActive: true)
                if self.engine.clockSource != .audio {
                    // An audio mapping with no audio running would silently do
                    // nothing, which is the kind of thing found out mid-set. Worth
                    // saying once; not worth saying to someone who maps ten of them
                    // in a row and already knows.
                    ReminderAlert.show(
                        .audioMappingWithoutAudioClock,
                        store: self.preferences,
                        title: "Audio input is not running",
                        detail: "The mapping is saved, but nothing will move until you set Clock to Audio in the toolbar.",
                        buttons: ["OK"]
                    )
                }

            case .lfo(let shape, let rate):
                let latency = self.engine.graph.nodes[slot]?.latencyInFrames ?? 0
                self.engine.lfos.assign(LFOBank.Assignment(
                    lfo: LFO(shape: shape, rate: rate, depth: 1.0),
                    slot: slot, code: parameter, latencyInFrames: latency))
                panel.setBadgeActive(code: code, badge: "C", isActive: true)

            case .clear:
                switch badge {
                case "M":
                    for binding in self.engine.registry.bindings
                    where binding.slot == slot && binding.code == parameter {
                        self.engine.registry.unbind(source: binding.source)
                    }
                case "S":
                    self.engine.audioReactivity.remove(slot: slot, code: parameter)
                default:
                    self.engine.lfos.remove(slot: slot, code: parameter)
                }
                panel.setBadgeActive(code: code, badge: badge, isActive: false)
            }
            // Whatever was chosen, the set of driven parameters may have changed.
            self.refreshDrivenParameters()
        }
    }

    /// Enables or bypasses a named effect on one of the buses.
    private func setEffectEnabled(_ name: String, _ isOn: Bool, bus: Bus) {
        guard let slots = Self.effectNameToSlot[name] else { return }
        let slot = bus == .one ? slots.one : slots.two
        engine.registry.setValue(isOn ? 1 : 0, slot: slot, code: .wetDry)
        Log.info(.app, "\(name) on \(bus == .one ? "ONE" : "TWO") \(isOn ? "enabled" : "bypassed")")
    }

    private func wireToolbar() {
        shell.toolbar.onPlayToggled = { [weak self] running in
            self?.engine.setTransportRunning(running)
        }
        shell.toolbar.onTap = { [weak self] in self?.tapTempo() }

        // The toolbar and the rails are two ways to do the same thing, so each keeps
        // the other in step rather than letting them disagree about what is shown.
        shell.toolbar.onPanelGroupToggled = { [weak self] panelGroup, collapsed in
            self?.shell.grid.setGroup(panelGroup, collapsed: collapsed)
        }
        shell.grid.onGroupCollapseChanged = { [weak self] panelGroup, collapsed in
            self?.shell.toolbar.setPanelGroupShown(panelGroup, !collapsed)
        }
        shell.toolbar.onRecordToggled = { [weak self] isRecording in
            guard let self else { return }
            let armed = self.recordIndicators.filter { $0.value.isArmed }.keys.sorted()
            if isRecording && armed.isEmpty {
                self.shell.toolbar.recordButton.isRecording = false
                self.presentNotice(
                    "Nothing is armed",
                    "Arm at least one feed first — click the dot in the top right of a preview."
                )
                return
            }
            Log.info(.app, "record \(isRecording ? "started" : "stopped") for \(armed.joined(separator: ", "))")
            if isRecording {
                self.presentNotice(
                    "Recording is not built yet",
                    "Arming and the transport-locked indicators work, but there is no encoder behind them — AVAssetWriter and the discrete-channel plumbing are still to come (SPEC §15)."
                )
                self.shell.toolbar.recordButton.isRecording = false
            }
        }
        shell.toolbar.onClockSourceChanged = { [weak self] choice in
            guard let self else { return false }
            switch choice {
            case "Audio":
                let started = self.engine.setClockSource(.audio)
                if !started {
                    self.presentNotice(
                        "Audio clock unavailable",
                        "Videoboy could not open an audio input. Check that an input device is connected and that microphone access is allowed in System Settings ▸ Privacy & Security ▸ Microphone."
                    )
                }
                return started
            case "Internal":
                return self.engine.setClockSource(.internalTransport)
            default:
                // MIDI clock and Ableton Link are not built yet. Saying so is better
                // than selecting them and quietly doing nothing.
                self.presentNotice(
                    "\(choice) is not built yet",
                    "The clock currently runs from its internal transport or from audio beat detection. MIDI clock and Link are later work."
                )
                return false
            }
        }
    }

    /// Tap tempo: average the intervals between the last few taps.
    private var tapTimes: [CFTimeInterval] = []

    private func tapTempo() {
        let now = CACurrentMediaTime()
        // A gap longer than two seconds starts a new measurement rather than
        // averaging in a tap from some earlier moment.
        if let last = tapTimes.last, now - last > 2.0 { tapTimes.removeAll() }
        tapTimes.append(now)
        if tapTimes.count > 4 { tapTimes.removeFirst() }
        guard tapTimes.count >= 2 else { return }

        let intervals = zip(tapTimes.dropFirst(), tapTimes).map(-)
        let average = intervals.reduce(0, +) / Double(intervals.count)
        guard average > 0 else { return }
        let tempo = 60.0 / average
        // Ignore taps that imply an implausible tempo rather than lurching to it.
        guard tempo > 40, tempo < 300 else { return }
        engine.setTempo(tempo)
        shell.toolbar.setTempo(tempo)
    }

    private func wireSettingsBar() {
        let settings = shell.grid.panels.settingsBarBody
        // Output is its own switch now. Test Pattern is a separate thing: what the
        // output SHOWS, not whether it is running — conflating them was part of what
        // made this bar confusing.
        settings.onOutputEnabledChanged = { [weak self] on in
            self?.setOutputWindowVisible(on)
        }
        settings.onTestPatternToggled = { [weak self] on in
            self?.setTestPatternVisible(on)
        }
        settings.onSafeZoneToggled = { [weak self] on in
            self?.setSafeZonesVisible(on)
        }
        settings.onOverscanToggled = { [weak self] on in
            // A single toggle picks a representative amount; the continuous control
            // is the 82A parameter, which a mapping or a template can drive.
            self?.engine.overscan = on ? 0.5 : 0.0
            self?.shell.grid.panels.programBody.preview.overscan = on ? 0.5 : 0.0
        }
        settings.onBlackFrameInsertionToggled = { [weak self] on in
            self?.engine.blackFrameInsertion = BlackFrameInsertion.from(normalised: on ? 0.5 : 0)
        }
    }

    /// Shows or hides the action-safe and title-safe overlays on every preview.
    private func setSafeZonesVisible(_ visible: Bool) {
        let panels = shell.grid.panels
        for letter in Self.channels {
            panels.sourceBodies[letter]?.preview.showsSafeZones = visible
        }
        panels.subMixOneBody.preview.showsSafeZones = visible
        panels.subMixTwoBody.preview.showsSafeZones = visible
        panels.programBody.preview.showsSafeZones = visible
    }

    // MARK: - Output

    /// Opens or closes the borderless output window on the configured display.
    func setOutputWindowVisible(_ visible: Bool) {
        guard visible else {
            outputWindow?.dismiss()
            outputWindow = nil
            shell.grid.panels.settingsBarBody.setOutput(destination: "off", mode: "—")
            return
        }
        let config = DeviceConfig.load()
        guard let display = DisplayRouter.preferredOutputDisplay(config: config) else {
            presentNotice("No display available", "Videoboy could not find a display to send output to.")
            shell.grid.panels.settingsBarBody.setOutputEnabled(false)
            return
        }
        let controller = OutputWindowController(display: display, requestedMode: config.requestedMode)
        controller.present()
        outputWindow = controller
        engine.setNegotiatedOutputMode(controller.negotiatedMode)
        shell.grid.panels.settingsBarBody.setOutput(
            destination: display.name, mode: controller.negotiatedMode)
    }

    /// Routes a test pattern to the program bus instead of the live mix.
    ///
    /// This is about what the output CARRIES; whether output is running at all is the
    /// Output switch beside it.
    private func setTestPatternVisible(_ visible: Bool) {
        engine.setProgramShowsTestPattern(visible)
    }

    // MARK: - Per-frame refresh

    /// Pushes this frame's textures and readouts into the views.
    private func refresh(from engine: Engine) {
        let panels = shell.grid.panels
        updateRecordPulse(from: engine)

        for letter in Self.channels {
            let slot = Engine.slot(forChannel: letter)
            panels.sourceBodies[letter]?.preview.texture = engine.texture(for: slot)
            panels.sourceBodies[letter]?.preview.present()
            // The scrub track follows playback, so it reads as a position indicator
            // as well as a control.
            if let source = engine.sources[letter], source.isPlaying {
                panels.sourceBodies[letter]?.setScrubPosition(source.normalisedPosition)
            }
        }

        // The END of each bus chain, not the bare crossfade.
        //
        // These previews were showing GraphTopology.subMixOne/Two, which is the
        // crossfade BEFORE the composite codec, echo, feedback and the data stage. So
        // turning on an effect changed PROGRAM while the sub-mix preview it belonged
        // to sat there unchanged — which reads as the effect landing in the wrong
        // window. A sub-mix preview must show that sub-mix as it will be mixed.
        panels.subMixOneBody.preview.texture = engine.texture(for: Engine.busCodecOneSlot)
            ?? engine.texture(for: GraphTopology.subMixOne)
        panels.subMixOneBody.preview.present()
        panels.subMixTwoBody.preview.texture = engine.texture(for: Engine.busCodecTwoSlot)
            ?? engine.texture(for: GraphTopology.subMixTwo)
        panels.subMixTwoBody.preview.present()

        let program = engine.texture(for: GraphTopology.primary)
        panels.programBody.preview.texture = program
        panels.programBody.preview.present()
        outputWindow?.present(texture: program)

        updateFadesAndCuts(from: engine)
        updateScopesAndZebra(from: engine)

        // The status and transport readouts are cheap, but not free; once a second is
        // plenty for a human reading them, and it keeps text redraw off the hot path.
        if engine.frameIndex % 30 == 0 {
            shell.statusBar.setNodeCount(engine.graph.nodeCount)
            shell.statusBar.setRate(
                droppedFrames: engine.droppedFrames,
                framesPerSecond: engine.measuredFramesPerSecond
            )
            shell.statusBar.setMIDIDevice(engine.midi.connectedSourceNames.first)
            if engine.transport.isRunning {
                let position = engine.transport.position(atHostTime: CACurrentMediaTime())
                shell.toolbar.setBeat(position.beat)
            }

            // The sync readout says what the clock is actually doing, including how
            // confident audio detection is — a number the performer needs when
            // deciding whether to trust it or tap the tempo in by hand.
            if engine.clockSource == .audio {
                if let estimate = engine.latestTempoEstimate {
                    shell.toolbar.setTempo(engine.transport.beatsPerMinute)
                    shell.toolbar.setSyncStatus(
                        String(format: "audio %.0f%%", estimate.confidence * 100))
                } else {
                    shell.toolbar.setSyncStatus("listening")
                }
            } else {
                shell.toolbar.setSyncStatus(engine.transport.isRunning ? "running" : "stopped")
            }
        }
    }
}

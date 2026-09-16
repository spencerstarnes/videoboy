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
    private var outputWindow: OutputWindowController?

    /// Channel letters in the order their previews appear.
    private static let channels = ["A", "B", "C", "D"]

    init(shell: ShellView, engine: Engine) {
        self.shell = shell
        self.engine = engine
        wireSources()
        wireFaders()
        wireBlendControls()
        wireEffectChains()
        wireToolbar()
        wireSettingsBar()
        wireRecordIndicators()
        engine.onFrame = { [weak self] engine in self?.refresh(from: engine) }
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
                self?.engine.sources[letter]?.seek(toNormalised: position)
            }
            body.onTimingChanged = { [weak self] timing in
                self?.engine.sources[letter]?.timing = timing
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
        panel.message = "Choose a DV file for source \(letter)"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == "dv" else {
            presentNotice(
                "Only DV files play so far",
                "\(url.lastPathComponent) is not a .dv file. The AVFoundation path for ordinary video formats is not wired up yet — the DV bitstream path is what this build does."
            )
            return
        }
        if !engine.load(url: url, intoChannel: letter) {
            presentNotice("Could not load that file", "See the log for why. The channel is unchanged.")
        }
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

    private func wireFaders() {
        let panels = shell.grid.panels
        // Each fader writes straight into the registry, so a MIDI move and a mouse
        // drag land in exactly the same place.
        panels.faderABBody.onFaderMoved = { [weak self] position in
            self?.engine.registry.setValue(position, slot: GraphTopology.subMixOne, code: .crossfadeAB)
        }
        panels.faderCDBody.onFaderMoved = { [weak self] position in
            self?.engine.registry.setValue(position, slot: GraphTopology.subMixTwo, code: .crossfadeCD)
        }
        panels.faderOneTwoBody.onFaderMoved = { [weak self] position in
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
        } else {
            // Stopped: hold the indicators at full brightness rather than freezing
            // them mid-fade, which reads as a rendering fault.
            phase = 0
        }
        for indicator in recordIndicators.values where indicator.isArmed {
            indicator.isRecording = isRecording
            indicator.pulsePhase = phase
        }
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
                self.engine.midi.beginDetect(slot: slot, code: parameter)
                self.shell.statusBar.setMIDIDevice("learning \(parameter.displayName)…")
                // The badge lights once something actually arrives, not on arming —
                // otherwise it would claim a mapping that may never be made.
                self.engine.midi.onDetectCompleted = { [weak self] binding in
                    DispatchQueue.main.async {
                        panel.setBadgeActive(code: code, badge: "M", isActive: true)
                        self?.shell.statusBar.setMIDIDevice(
                            self?.engine.midi.connectedSourceNames.first)
                        Log.info(.midi, "learned \(binding.source.description) for \(binding.slot)/\(binding.code.rawValue)")
                    }
                }

            case .audio(let tap, let shape):
                self.engine.audioReactivity.assign(ReactivityAssignment(
                    tap: tap, shape: shape, slot: slot, code: parameter))
                panel.setBadgeActive(code: code, badge: "S", isActive: true)
                if self.engine.clockSource != .audio {
                    // An audio mapping with no audio running would silently do
                    // nothing, which is the kind of thing found out mid-set.
                    self.presentNotice(
                        "Audio input is not running",
                        "The mapping is saved, but nothing will move until you set Clock to Audio in the toolbar."
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
        engine.transport.beatsPerMinute = tempo
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

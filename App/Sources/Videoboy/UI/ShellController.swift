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
        wireEffectChains()
        wireToolbar()
        wireSettingsBar()
        engine.onFrame = { [weak self] engine in self?.refresh(from: engine) }
    }

    // MARK: - Wiring

    private func wireSources() {
        for letter in Self.channels {
            guard let body = shell.grid.panels.sourceBodies[letter] else { continue }
            body.onLoadRequested = { [weak self] in self?.presentOpenPanel(forChannel: letter) }
            body.onPlayToggled = { [weak self] in self?.togglePlayback(channel: letter) }
        }
    }

    private var playingChannels: Set<String> = []

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

    private func wireEffectChains() {
        // Sub Mix 1's FX chain drives channel A's corruptor. One chain per sub-mix is
        // the shape SPEC 14.2 describes; per-channel chains arrive with channel FX.
        shell.grid.panels.effectsOneBody.onParameterChanged = { [weak self] code, value in
            guard let self, let parameter = ParamCode(rawValue: code) else { return }
            self.engine.registry.setValue(value, slot: GraphTopology.sourceA, code: parameter)
        }
    }

    private func wireToolbar() {
        shell.toolbar.onPlayToggled = { [weak self] running in
            self?.engine.setTransportRunning(running)
        }
        shell.toolbar.onTap = { [weak self] in self?.tapTempo() }
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
        shell.grid.panels.settingsBarBody.onTestPatternToggled = { [weak self] on in
            self?.setOutputWindowVisible(on)
        }
    }

    // MARK: - Output

    /// Opens or closes the borderless output window on the configured display.
    func setOutputWindowVisible(_ visible: Bool) {
        guard visible else {
            outputWindow?.dismiss()
            outputWindow = nil
            return
        }
        let config = DeviceConfig.load()
        guard let display = DisplayRouter.preferredOutputDisplay(config: config) else {
            presentNotice("No display available", "Videoboy could not find a display to send output to.")
            return
        }
        let controller = OutputWindowController(display: display, requestedMode: config.requestedMode)
        controller.present()
        outputWindow = controller
        engine.setNegotiatedOutputMode(controller.negotiatedMode)
        shell.grid.panels.settingsBarBody.setNegotiatedMode(controller.negotiatedMode)
    }

    // MARK: - Per-frame refresh

    /// Pushes this frame's textures and readouts into the views.
    private func refresh(from engine: Engine) {
        let panels = shell.grid.panels

        for letter in Self.channels {
            let slot = Engine.slot(forChannel: letter)
            panels.sourceBodies[letter]?.preview.texture = engine.texture(for: slot)
            panels.sourceBodies[letter]?.preview.present()
        }

        panels.subMixOneBody.preview.texture = engine.texture(for: GraphTopology.subMixOne)
        panels.subMixOneBody.preview.present()
        panels.subMixTwoBody.preview.texture = engine.texture(for: GraphTopology.subMixTwo)
        panels.subMixTwoBody.preview.present()

        let program = engine.texture(for: GraphTopology.primary)
        panels.programBody.preview.texture = program
        panels.programBody.preview.present()
        outputWindow?.present(texture: program)

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
        }
    }
}

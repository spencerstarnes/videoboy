//
//  PanelBodies.swift — the contents of each panel in the grid.
//
//  Purpose : One body view per panel type from SPEC 14.2. Each is built from real
//            AppKit controls (SPEC 14.3). Controls whose features are not built yet
//            are present and disabled, never omitted (CLAUDE.md).
//  Inputs  : construction parameters (channel letter, bus identity).
//  Outputs : views handed to `PanelView` as its body.
//  Connects: Controls (the control factories), MetalPreviewView (the video boxes),
//            Theme (every measurement).
//  Extend  : when a feature ships, enable its controls here and wire them to Core.
//            Keep the arrangement as the mockup has it.
//

import AppKit
import VideoboyCore

// MARK: - Source panels

/// A source channel: a 4:3 preview plus its shuttle strip (SPEC 14.2, SPEC 12).
final class SourcePanelBody: NSView {

    /// The preview this channel draws into.
    let preview: MetalPreviewView

    /// Channel letter, A-D.
    let channel: String

    private var generatorPopUp: NSPopUpButton?
    /// The shuttle scrub track. Exposed so the shell can give it a mapping address.
    private(set) var scrubFader: VBFader?
    private var timingPopUp: NSPopUpButton?

    /// Loads a file into this channel. Wired by the app; nil until then.
    var onLoadRequested: (() -> Void)?

    /// Switches this channel to a generator, or back to its file.
    /// A nil kind means "go back to the file".
    var onGeneratorSelected: ((GeneratorKind?) -> Void)?

    /// Jump to the start or the end of the clip.
    var onSeekToStart: (() -> Void)?
    var onSeekToEnd: (() -> Void)?
    /// Step one frame back or forward.
    var onStepBack: (() -> Void)?
    var onStepForward: (() -> Void)?
    /// Scrub to a 0...1 position.
    var onScrub: ((Double) -> Void)?
    /// Loop behaviour changed.
    var onLoopModeChanged: ((LoopMode) -> Void)?
    /// Playback timing changed — live, or stepped on a subdivision.
    var onTimingChanged: ((PlaybackTiming) -> Void)?

    init(channel: String) {
        self.channel = channel
        self.preview = MetalPreviewView(caption: channel, recordLabel: channel)
        super.init(frame: .zero)

        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)

        // Shuttle strip: transport buttons, a scrub track, and the loop-mode toggle.
        // Every source gets one (SPEC 14.2).
        let toStart = Controls.button("⇤", target: self, action: #selector(seekStartPressed))
        let back = Controls.button("◀", target: self, action: #selector(stepBackPressed))
        let play = Controls.button("▶", target: self, action: #selector(playPressed))
        let toEnd = Controls.button("⇥", target: self, action: #selector(seekEndPressed))
        let scrub = Controls.fader(
            value: 0, compact: true, target: self, action: #selector(scrubbed(_:)))
        self.scrubFader = scrub
        // Loop / ping-pong / one-shot, per SPEC 12.
        let loopMode = Controls.segmented(
            ["↻", "⇄", "1"], selected: 0, target: self, action: #selector(loopModeChanged(_:)))
        loopMode.setToolTip("Loop", forSegment: 0)
        loopMode.setToolTip("Ping-pong", forSegment: 1)
        loopMode.setToolTip("One shot", forSegment: 2)

        let shuttle = Controls.row([toStart, back, play, toEnd, scrub, loopMode], spacing: 2)
        shuttle.translatesAutoresizingMaskIntoConstraints = false
        scrub.setContentHuggingPriority(.init(1), for: .horizontal)
        addSubview(shuttle)

        let load = Controls.button("Load", target: self, action: #selector(loadPressed))
        load.setContentCompressionResistancePriority(.required, for: .horizontal)

        // A generator is an alternative source for the channel, not a separate panel:
        // SPEC 6A says generators are selectable anywhere A/B/C/D.
        let generatorPopUp = Controls.popUp(
            ["File"] + GeneratorKind.allCases.map(\.displayName),
            target: self, action: #selector(generatorChanged(_:))
        )
        self.generatorPopUp = generatorPopUp

        // Step playback: hold each frame until the next musical subdivision, so a
        // clip becomes a slideshow locked to the beat. "Live" is ordinary playback.
        let timingPopUp = Controls.popUp(
            ["Live"] + PlaybackTiming.presets.map(\.displayName),
            target: self, action: #selector(timingChanged(_:))
        )
        timingPopUp.toolTip = "Playback timing — hold each frame until the next beat subdivision"
        for (index, preset) in PlaybackTiming.presets.enumerated() {
            timingPopUp.item(at: index + 1)?.toolTip = preset.explanation
        }
        self.timingPopUp = timingPopUp

        let stepRow = Controls.row([
            Controls.label("Step", font: Theme.Font.tinyLabel,
                           color: Theme.Color.textTertiary, holdsWidth: true),
            timingPopUp
        ], spacing: 4)

        let sourceRow = Controls.column([
            Controls.row([load, generatorPopUp], spacing: 4),
            stepRow
        ], spacing: 3)
        sourceRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sourceRow)
        let loadRowForConstraints = sourceRow

        let padding = Theme.Metrics.panelBodyPadding
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),

            shuttle.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 2),
            shuttle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            shuttle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),

            loadRowForConstraints.topAnchor.constraint(equalTo: shuttle.bottomAnchor, constant: 2),
            loadRowForConstraints.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            loadRowForConstraints.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -padding),
            loadRowForConstraints.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor, constant: -padding)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    @objc private func loadPressed() {
        Log.info(.app, "load requested for source \(channel)")
        onLoadRequested?()
    }

    /// Play/pause for this channel. Wired by the app.
    var onPlayToggled: (() -> Void)?

    @objc private func playPressed() {
        Log.info(.app, "play toggled on source \(channel)")
        onPlayToggled?()
    }

    @objc private func seekStartPressed() { onSeekToStart?() }
    @objc private func seekEndPressed() { onSeekToEnd?() }
    @objc private func stepBackPressed() { onStepBack?() }
    @objc private func stepForwardPressed() { onStepForward?() }

    @objc private func scrubbed(_ sender: VBFader) {
        onScrub?(sender.value)
    }

    @objc private func timingChanged(_ sender: NSPopUpButton) {
        // Item 0 is Live; the rest are the step presets in order.
        let index = sender.indexOfSelectedItem
        let timing: PlaybackTiming = (index <= 0 || index - 1 >= PlaybackTiming.presets.count)
            ? .continuous
            : PlaybackTiming.presets[index - 1]
        Log.info(.dv, "playback timing on \(channel): \(timing.displayName)")
        onTimingChanged?(timing)
    }

    @objc private func loopModeChanged(_ sender: NSSegmentedControl) {
        onLoopModeChanged?(LoopMode.from(index: sender.selectedSegment))
    }

    /// Moves the scrub track to follow playback, without firing its action.
    func setScrubPosition(_ position: Double) {
        scrubFader?.value = position
    }

    @objc private func generatorChanged(_ sender: NSPopUpButton) {
        // Item 0 is "File"; the rest are the generator kinds in order.
        let index = sender.indexOfSelectedItem
        guard index > 0, index - 1 < GeneratorKind.allCases.count else {
            onGeneratorSelected?(nil)
            return
        }
        onGeneratorSelected?(GeneratorKind.allCases[index - 1])
    }
}

// MARK: - Preview-only panels

/// Sub Mix ONE / TWO / Program: a large 4:3 preview, optionally with the blend
/// controls for the composite it represents (SPEC 14.2).
final class PreviewPanelBody: NSView {

    let preview: MetalPreviewView

    /// Called when the blend mode changes, with the chosen mode.
    var onBlendModeChanged: ((BlendMode) -> Void)?

    /// Called when the bus's interchange codec changes.
    var onInterchangeChanged: ((InterchangeCodec) -> Void)?
    /// Called when a bus data-effect parameter moves: (param code, 0...1).
    var onDataParameterChanged: ((String, Double) -> Void)?

    /// Called when the scope tab is clicked, to advance the scope cycle.
    var onScopeTabClicked: (() -> Void)?
    /// Called when the zebra toggle changes.
    var onZebraToggled: ((Bool) -> Void)?

    /// The scope tab, so its title can show the current mode.
    private var scopeTab: NSButton?
    /// The zebra toggle, hidden while scopes are showing.
    private var zebraToggle: NSButton?
    private var blendPopUp: NSPopUpButton?
    private var interchangePopUp: NSPopUpButton?
    private var dataEffectRow: NSStackView?
    /// The bus data-effect faders, exposed so the shell can address them for MIDI.
    private(set) var dataAmountFader: VBFader?
    private(set) var dataModeFader: VBFader?

    /// - Parameter showsBlendControls: true for the composites that carry a blend
    ///   mode — the two sub-mixes and the program.
    init(caption: String, showsBlendControls: Bool = false, recordLabel: String? = nil) {
        self.preview = MetalPreviewView(caption: caption, recordLabel: recordLabel)
        super.init(frame: .zero)
        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)

        var bottomAnchorTarget = bottomAnchor
        var bottomConstant: CGFloat = -2

        if showsBlendControls {
            let popUp = Controls.popUp(
                BlendMode.allCases.map(\.displayName),
                target: self, action: #selector(blendModeChanged(_:))
            )
            blendPopUp = popUp

            // No separate opacity control: the crossfader in the fader panel below IS
            // the opacity for this composite. Two controls doing one job is what made
            // this confusing. The note lives in the tooltip rather than the row,
            // where it was stealing width from the two popups that matter.
            popUp.toolTip = "Blend mode. The crossfader below sets this layer's opacity."

            // The bus interchange codec. A mixed bus is a texture with no bitstream,
            // so data effects on it are only possible if it is re-encoded first —
            // this popup is that choice, and it decides which data effects appear.
            let interchange = Controls.popUp(
                InterchangeCodec.allCases.map(\.displayName),
                target: self, action: #selector(interchangeChanged(_:))
            )
            interchangePopUp = interchange

            // The zebra: a striped-animal glyph, because the pattern it draws is
            // literally called a zebra. It toggles, and it hides itself while scopes
            // are up — with a scope on screen the stripes are redundant and the two
            // overlays fight each other.
            let zebra = Controls.button("🦓", target: self, action: #selector(zebraPressed))
            zebra.toolTip = "Zebra — stripe pixels outside the NTSC legal range"
            zebra.setButtonType(.pushOnPushOff)
            zebraToggle = zebra

            // The scope tab. One control that cycles every scope view, so reaching a
            // vectorscope is never more than a few clicks and never a menu.
            let scopes = Controls.button("Scopes", target: self, action: #selector(scopeTabPressed))
            scopes.toolTip = "Cycle the scopes: quad overlay, histogram, parade, quad over black, off"
            scopeTab = scopes

            let row = Controls.row([
                Controls.label("Blend", font: Theme.Font.tinyLabel,
                               color: Theme.Color.textTertiary, holdsWidth: true),
                popUp,
                Controls.label("Data", font: Theme.Font.tinyLabel,
                               color: Theme.Color.textTertiary, holdsWidth: true),
                interchange,
                Controls.spacer(),
                zebra,
                scopes
            ], spacing: 4)
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)

            // The bus data-effect controls, hidden until an interchange is chosen.
            // Hidden rather than disabled: with no interchange there is no bitstream,
            // so these are not "not yet built", they are meaningless.
            let dataAmount = Controls.fader(
                value: 0, compact: true, accent: Theme.Color.recordActive,
                target: self, action: #selector(dataAmountChanged(_:)))
            let dataMode = Controls.fader(
                value: 0, compact: true, accent: Theme.Color.recordActive,
                target: self, action: #selector(dataModeChanged(_:)))
            dataAmountFader = dataAmount
            dataModeFader = dataMode
            let dataRow = Controls.row([
                Controls.label("dmg", font: Theme.Font.tinyLabel,
                               color: Theme.Color.textTertiary, holdsWidth: true),
                dataAmount,
                Controls.label("mode", font: Theme.Font.tinyLabel,
                               color: Theme.Color.textTertiary, holdsWidth: true),
                dataMode
            ], spacing: 4)
            dataRow.translatesAutoresizingMaskIntoConstraints = false
            dataRow.isHidden = true
            addSubview(dataRow)
            dataEffectRow = dataRow

            NSLayoutConstraint.activate([
                dataRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metrics.panelBodyPadding),
                dataRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Metrics.panelBodyPadding),
                dataRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),

                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metrics.panelBodyPadding),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Metrics.panelBodyPadding),
                row.bottomAnchor.constraint(equalTo: dataRow.topAnchor, constant: -2)
            ])
            bottomAnchorTarget = row.topAnchor
            bottomConstant = -3
        }

        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            preview.bottomAnchor.constraint(equalTo: bottomAnchorTarget, constant: bottomConstant)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    @objc private func scopeTabPressed() { onScopeTabClicked?() }

    @objc private func zebraPressed(_ sender: NSButton) {
        onZebraToggled?(sender.state == .on)
    }

    /// Updates the tab's title to name the mode it is now in, and hides the zebra
    /// while scopes are up.
    func setScopeMode(_ mode: ScopeDisplayMode) {
        scopeTab?.title = mode == .off ? "Scopes" : mode.displayName
        scopeTab?.contentTintColor = mode == .off ? nil : Theme.Color.accent
        zebraToggle?.isHidden = mode != .off
    }

    @objc private func interchangeChanged(_ sender: NSPopUpButton) {
        let codec = InterchangeCodec.allCases[
            min(sender.indexOfSelectedItem, InterchangeCodec.allCases.count - 1)]
        // The data controls only exist when there is a bitstream for them to act on.
        dataEffectRow?.isHidden = (codec == .none)
        Log.info(.bitstream, "bus interchange set to \(codec.displayName)")
        onInterchangeChanged?(codec)
    }

    @objc private func dataAmountChanged(_ sender: VBFader) {
        onDataParameterChanged?(ParamCode.corruptAmount.rawValue, sender.value)
    }

    @objc private func dataModeChanged(_ sender: VBFader) {
        onDataParameterChanged?(ParamCode.corruptMode.rawValue, sender.value)
    }

    @objc private func blendModeChanged(_ sender: NSPopUpButton) {
        let mode = BlendMode.allCases[min(sender.indexOfSelectedItem, BlendMode.allCases.count - 1)]
        Log.info(.graph, "blend mode set to \(mode.displayName)")
        onBlendModeChanged?(mode)
    }

}

// MARK: - Faders

/// A crossfader panel: Cut, Fade, cut-on-beat, Auto, mapping badges, the fader
/// itself and its numeric value (SPEC 14.2).
final class FaderPanelBody: NSView {

    /// The crossfader. 0 is the left source, 1 is the right.
    let fader: VBFader
    /// Live numeric readout beside the fader.
    private let valueLabel = Controls.monoLabel("0.50")

    /// Called whenever the fader moves, with the new 0...1 position.
    var onFaderMoved: ((Double) -> Void)?
    /// Called when Cut is pressed.
    var onCut: (() -> Void)?
    /// Called when Fade is pressed, with the chosen rate.
    var onFade: ((FadeRate) -> Void)?
    /// Called when cut-on-beat is switched on or off.
    var onBeatCutToggled: ((Bool) -> Void)?
    private var cutButton: NSButton?
    private var beatCutButton: NSButton?
    private var rateControl: NSSegmentedControl?
    private var leftName = ""
    private var rightName = ""

    /// - Parameters:
    ///   - leftLabel/rightLabel: the two ends, e.g. "A" and "B".
    ///   - leftColor/rightColor: bus identity colours for those ends.
    ///   - includesSwap: true for the ONE/TWO fader, which carries the swap-cut.
    init(
        leftLabel: String, rightLabel: String,
        leftColor: NSColor, rightColor: NSColor,
        includesSwap: Bool
    ) {
        self.fader = Controls.fader(value: 0.5, fillsFromCentre: true, accent: leftColor)
        fader.leadingTint = leftColor
        fader.trailingTint = rightColor
        // All three crossfaders carry the heavy track. They are the controls the
        // hands live on, and making only the programme cut thick meant A/B and C/D
        // read as lesser controls than they are — they are the same gesture, one
        // stage earlier.
        fader.trackHeightOverride = Theme.Fader.primaryTrackHeight
        super.init(frame: .zero)

        fader.target = self
        fader.action = #selector(faderMoved)

        // Broadcast language throughout, and the cut says where it is going: a button
        // labelled "Swap" tells you the mechanism, but "CUT TO TWO" tells you what is
        // about to be on air, which is the thing that matters in the moment.
        var buttons: [NSView] = []
        let cutButton = Controls.button(
            "CUT TO \(rightLabel.uppercased())",
            target: self, action: #selector(cutPressed))
        cutButton.toolTip = "Hard cut to \(rightLabel)"
        self.cutButton = cutButton
        self.leftName = leftLabel
        self.rightName = rightLabel
        buttons.append(cutButton)
        let fadeButton = Controls.button("Fade", target: self, action: #selector(fadePressed))
        fadeButton.toolTip = "Auto-fade to the other source at the chosen rate"
        buttons.append(fadeButton)

        // Cut-on-beat. With this on, a cut waits for the next subdivision and is
        // taken early by the graph's latency so the picture changes ON the beat.
        let beatToggle = Controls.button("Beat", target: self, action: #selector(beatCutPressed))
        beatToggle.setButtonType(.pushOnPushOff)
        beatToggle.toolTip = "Cut on the next beat instead of immediately"
        self.beatCutButton = beatToggle
        buttons.append(beatToggle)

        // The rate control: three positions, turtle to rabbit. A performance wants
        // "slow" without choosing a number, and the exact seconds matter far less
        // than the feel — which is why this is not a continuous slider.
        let rateControl = Controls.segmented(
            ["🐢", "•", "🐇"], selected: 1, target: self, action: #selector(rateChanged(_:)))
        rateControl.setToolTip("Slow fade", forSegment: 0)
        rateControl.setToolTip("Medium fade", forSegment: 1)
        rateControl.setToolTip("Fast fade", forSegment: 2)
        self.rateControl = rateControl
        buttons.append(rateControl)
        // The mapping badges ride on this row rather than getting a line of their
        // own. This is the shortest panel in the grid and a fourth line does not fit
        // at the compact breakpoint — it clipped instead of laying out.
        buttons.append(Controls.mappingBadges(includesSwap ? ["M", "S", "C", "Slo"] : ["M", "S", "Slo"]))
        buttons.append(Controls.spacer())
        buttons.append(Controls.button("Auto", enabled: false))
        let buttonRow = Controls.row(buttons, spacing: 4)

        let left = Controls.label(leftLabel, font: Theme.Font.tinyLabel, color: leftColor,
                                  holdsWidth: true)
        let right = Controls.label(rightLabel, font: Theme.Font.tinyLabel, color: rightColor,
                                   holdsWidth: true)
        left.translatesAutoresizingMaskIntoConstraints = false
        right.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        fader.translatesAutoresizingMaskIntoConstraints = false

        // The crossfader is the panel's main control, so it gets the full width and
        // more height than a parameter fader — it is the one a hand reaches for
        // without looking. Everything else arranges around it rather than competing
        // with it for width, which is what squeezed it to nothing before.
        addSubview(left)
        addSubview(right)
        addSubview(valueLabel)
        addSubview(fader)
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonRow)

        let padding = Theme.Metrics.panelBodyPadding
        NSLayoutConstraint.activate([
            buttonRow.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -padding),

            // End labels and the live value sit on one line above the fader. The
            // gaps are tight because this panel is the shortest in the grid (row
            // weight 0.6) and the content has to fit at the compact breakpoint —
            // anything looser and the rows overlap instead of just being close.
            left.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 3),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),

            valueLabel.centerYAnchor.constraint(equalTo: left.centerYAnchor),
            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: Theme.Metrics.valueReadoutWidth),

            right.centerYAnchor.constraint(equalTo: left.centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),

            // The fader spans the panel.
            fader.topAnchor.constraint(equalTo: left.bottomAnchor, constant: 2),
            fader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            fader.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            fader.heightAnchor.constraint(equalToConstant: Theme.Fader.crossfaderHeight),
            fader.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -padding)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Moves the fader programmatically (from a MIDI mapping or a scheduled cut).
    func setPosition(_ position: Double) {
        fader.value = position
        valueLabel.stringValue = String(format: "%.2f", position)
        updateCutLabel()
    }

    @objc private func faderMoved() {
        valueLabel.stringValue = String(format: "%.2f", fader.value)
        updateCutLabel()
        onFaderMoved?(fader.value)
    }

    @objc private func fadePressed() {
        onFade?(currentRate)
    }

    @objc private func beatCutPressed(_ sender: NSButton) {
        sender.contentTintColor = sender.state == .on ? Theme.Color.accent : nil
        onBeatCutToggled?(sender.state == .on)
    }

    @objc private func rateChanged(_ sender: NSSegmentedControl) {
        Log.info(.app, "fade rate: \(currentRate.displayName)")
    }

    /// The rate the three-position control is set to.
    private var currentRate: FadeRate {
        FadeRate.from(index: rateControl?.selectedSegment ?? 1)
    }

    @objc private func cutPressed() {
        // A hard cut snaps to whichever end is further from the current position.
        let target: Double = fader.value < 0.5 ? 1.0 : 0.0
        setPosition(target)
        onFaderMoved?(target)
        onCut?()
    }

    /// Retitles the cut button to name where the cut would land.
    ///
    /// Called whenever the fader moves, so the label always describes what pressing
    /// it would do rather than what it did last time.
    private func updateCutLabel() {
        let destination = fader.value < 0.5 ? rightName : leftName
        cutButton?.title = "CUT TO \(destination.uppercased())"
        cutButton?.toolTip = "Hard cut to \(destination)"
    }
}

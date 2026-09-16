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

    /// Loads a file into this channel. Wired by the app; nil until then.
    var onLoadRequested: (() -> Void)?

    init(channel: String) {
        self.channel = channel
        self.preview = MetalPreviewView(caption: channel)
        super.init(frame: .zero)

        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)

        // Shuttle strip: transport buttons, a scrub track, and the loop-mode toggle.
        // Every source gets one (SPEC 14.2).
        let toStart = Controls.button("⇤", enabled: false)
        let back = Controls.button("◀", enabled: false)
        let play = Controls.button("▶", target: self, action: #selector(playPressed))
        let toEnd = Controls.button("⇥", enabled: false)
        let scrub = Controls.slider(value: 0, enabled: false)
        // Loop / ping-pong / one-shot, per SPEC 12.
        let loopMode = Controls.segmented(["↻", "⇄", "1"], selected: 0, enabled: false)

        let shuttle = Controls.row([toStart, back, play, toEnd, scrub, loopMode], spacing: 2)
        shuttle.translatesAutoresizingMaskIntoConstraints = false
        scrub.setContentHuggingPriority(.init(1), for: .horizontal)
        addSubview(shuttle)

        let load = Controls.button("Load…", target: self, action: #selector(loadPressed))
        load.translatesAutoresizingMaskIntoConstraints = false
        addSubview(load)

        let padding = Theme.Metrics.panelBodyPadding
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),

            shuttle.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 2),
            shuttle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            shuttle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),

            load.topAnchor.constraint(equalTo: shuttle.bottomAnchor, constant: 2),
            load.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            load.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -padding)
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
}

// MARK: - Preview-only panels

/// Sub Mix ONE / TWO / Program: a large 4:3 preview, optionally with the blend
/// controls for the composite it represents (SPEC 14.2).
final class PreviewPanelBody: NSView {

    let preview: MetalPreviewView

    /// Called when the blend mode changes, with the chosen mode.
    var onBlendModeChanged: ((BlendMode) -> Void)?
    /// Called when the layer opacity changes, 0...1.
    var onLayerOpacityChanged: ((Double) -> Void)?

    private var blendPopUp: NSPopUpButton?

    /// - Parameter showsBlendControls: true for the composites that carry a blend
    ///   mode — the two sub-mixes and the program.
    init(caption: String, showsBlendControls: Bool = false) {
        self.preview = MetalPreviewView(caption: caption)
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
            let opacity = Controls.slider(
                value: 1.0, target: self, action: #selector(opacityChanged(_:)))
            opacity.setContentHuggingPriority(.init(1), for: .horizontal)

            let row = Controls.row([
                Controls.label("Blend", font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary),
                popUp,
                Controls.label("Opacity", font: Theme.Font.tinyLabel, color: Theme.Color.textTertiary),
                opacity
            ], spacing: 4)
            row.translatesAutoresizingMaskIntoConstraints = false
            addSubview(row)

            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Metrics.panelBodyPadding),
                row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Metrics.panelBodyPadding),
                row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
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

    @objc private func blendModeChanged(_ sender: NSPopUpButton) {
        let mode = BlendMode.allCases[min(sender.indexOfSelectedItem, BlendMode.allCases.count - 1)]
        Log.info(.graph, "blend mode set to \(mode.displayName)")
        onBlendModeChanged?(mode)
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        onLayerOpacityChanged?(sender.doubleValue)
    }
}

// MARK: - Faders

/// A crossfader panel: Cut, Fade, cut-on-beat, Auto, mapping badges, the fader
/// itself and its numeric value (SPEC 14.2).
final class FaderPanelBody: NSView {

    /// The crossfader. 0 is the left source, 1 is the right.
    let fader: NSSlider
    /// Live numeric readout beside the fader.
    private let valueLabel = Controls.monoLabel("0.50")

    /// Called whenever the fader moves, with the new 0...1 position.
    var onFaderMoved: ((Double) -> Void)?
    /// Called when Cut is pressed.
    var onCut: (() -> Void)?
    /// Called when Swap is pressed (the ONE/TWO fader only).
    var onSwap: (() -> Void)?

    /// - Parameters:
    ///   - leftLabel/rightLabel: the two ends, e.g. "A" and "B".
    ///   - leftColor/rightColor: bus identity colours for those ends.
    ///   - includesSwap: true for the ONE/TWO fader, which carries the swap-cut.
    init(
        leftLabel: String, rightLabel: String,
        leftColor: NSColor, rightColor: NSColor,
        includesSwap: Bool
    ) {
        self.fader = Controls.slider(value: 0.5)
        super.init(frame: .zero)

        fader.target = self
        fader.action = #selector(faderMoved)

        var buttons: [NSView] = []
        if includesSwap {
            buttons.append(Controls.button("◆ Swap", target: self, action: #selector(swapPressed)))
        } else {
            buttons.append(Controls.button("Cut", target: self, action: #selector(cutPressed)))
        }
        buttons.append(Controls.button("Fade", enabled: false))
        // Cut-on-beat needs the musical clock scheduler to be wired to the mixer.
        buttons.append(Controls.segmented(["Beat"], selected: -1, enabled: false))
        buttons.append(Controls.spacer())
        buttons.append(Controls.button("Auto", enabled: false))
        let buttonRow = Controls.row(buttons, spacing: 4)

        // M(IDI) / S(audio-react) / C(lock) / Slo(w-fade) badges, per the mockup.
        let badges = Controls.mappingBadges(includesSwap ? ["M", "S", "C", "Slo"] : ["M", "S", "Slo"])

        let left = Controls.label(leftLabel, font: Theme.Font.tinyLabel, color: leftColor)
        let right = Controls.label(rightLabel, font: Theme.Font.tinyLabel, color: rightColor)
        let ends = Controls.row([left, Controls.spacer(), right], spacing: 2)

        let faderColumn = Controls.column([ends, fader, valueLabel], spacing: 2)
        faderColumn.alignment = .leading
        ends.translatesAutoresizingMaskIntoConstraints = false
        fader.translatesAutoresizingMaskIntoConstraints = false

        let middle = Controls.row([badges, faderColumn], spacing: 8)
        let stack = Controls.column([buttonRow, middle], spacing: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let padding = Theme.Metrics.panelBodyPadding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -padding),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            middle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ends.widthAnchor.constraint(equalTo: faderColumn.widthAnchor),
            fader.widthAnchor.constraint(equalTo: faderColumn.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code, never from a nib") }

    /// Moves the fader programmatically (from a MIDI mapping or a scheduled cut).
    func setPosition(_ position: Double) {
        fader.doubleValue = position
        valueLabel.stringValue = String(format: "%.2f", position)
    }

    @objc private func faderMoved() {
        valueLabel.stringValue = String(format: "%.2f", fader.doubleValue)
        onFaderMoved?(fader.doubleValue)
    }

    @objc private func cutPressed() {
        // A hard cut snaps to whichever end is further from the current position.
        let target: Double = fader.doubleValue < 0.5 ? 1.0 : 0.0
        setPosition(target)
        onFaderMoved?(target)
        onCut?()
    }

    @objc private func swapPressed() {
        let target = 1.0 - fader.doubleValue.rounded()
        setPosition(target)
        onFaderMoved?(target)
        onSwap?()
    }
}
